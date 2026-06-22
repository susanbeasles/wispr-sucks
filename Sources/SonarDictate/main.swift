import Foundation
import AVFoundation
import Speech
import AppKit
import ApplicationServices

// On-device voice-to-text spike.
//
// Two modes, decided by CLI args:
//   - No args:        menu-bar background mode. Hold Option to talk, release
//                     to stop. Stream stable phrases into the focused app.
//                     On final transcript: persist audio+transcript to the
//                     encrypted SecureStore and classify for trigger words.
//   - With command:   `list | read <id> | delete <id> | reset`. Runs the
//                     CLI op against the SecureStore and exits.
//
// 100% on-device: requiresOnDeviceRecognition = true. Audio is encrypted
// under a Secure Enclave-bound key (see SecureStore.swift). No network IO.

// MARK: - Dictator

// Per-session decision: are we streaming partials into the focused app
// (regular dictation), or buffering them silently (the first word looks
// like a trigger and the user shouldn't see "yo create a ticket" typed
// and then yanked back)? The state stays `.initial` until the first
// reasonably stable partial arrives, at which point we commit.
enum SessionMode: String {
    case initial    // not enough signal yet; don't stream, don't decide
    case streaming  // committed to dictate mode; partials get injected
    case buffering  // first word looked trigger-shaped; suppress injection
}

@available(macOS 26.0, *)
final class Dictator {
    private let session = SpeechAnalyzerSession(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    // True while the fn/globe key is held. The dictation talk-key (was Option).
    private var isFnDown = false
    private var emittedText = ""

    // Per-session injection mode (see SessionMode above)
    private var sessionMode: SessionMode = .initial

    // True between Option-down and Option-up. The async session.start() can take
    // ~2s to negotiate the audio format; if the user releases before it finishes
    // we must NOT start the engine (that's the rapid start/stop race that left a
    // dangling analyzer and killed the next session's finalize). The start Task
    // re-checks this after the await.
    private var listening = false

    // When true, partials are live-typed into the focused field (the "typing as
    // I talk" feel) instead of buffered for commit-on-release. Decided once at
    // session start: only when there's NO selector broadcast, a field IS focused,
    // and no cleanup pass is pending (cleanup rewrites the whole transcript at the
    // end, so it can't stream). Selector/chip paths stay commit-at-end.
    private var streamingIntoField = false

    // Persistence
    private let store: SecureStore
    private let workflows: WorkflowStore
    private let rag: RAGIndex
    private let dictionary: DictionaryStore
    private let database: RecordingDatabase
    private let editWatcher: EditWatcher
    private var audioFrames: [AVAudioPCMBuffer] = []
    private var sessionStart: Date?
    private var sessionFormat: AVAudioFormat?
    private var sessionAppContext: String?
    private var finalPersisted = false  // guard so we persist once per session

    // Optional menu-bar UI (set after construction); we call it on listening
    // start/stop and after each session finalize to refresh counts.
    var statusItem: StatusItemController?

    // In-your-eyeline floating overlay shown while Option is held.
    var overlay: RecordingOverlay?

    // Draggable chip that holds captured text when no field is focused at
    // commit time. User double-spaces in a field to drop it in.
    var chip: TextChip?

    // Gold see-through-windows highlight drawn over every selector target so
    // the user can see exactly what a dictation will broadcast to. Refreshed
    // after every selector mutation.
    var highlighter: FieldHighlighter?

    // Window listing every past dictation; opened by global hotkey or the menu.
    // The recovery path when a live paste misses its target field.
    var history: HistoryWindow?

    // Double-space commit detection: timestamp of the last space keyDown.
    private var lastSpaceDown: TimeInterval = 0

    // Clipboard stash for the chip's "click to copy, paste anywhere, clipboard
    // unharmed" flow: clicking the chip saves the user's current clipboard, puts
    // the chip text on it, and after their next V we put the original back.
    private var clipboardStash: [[String: Data]]?
    private var stashChangeCount: Int = -1

    // Selector engine - the set of target fields a dictation broadcasts to.
    // Built up by clicking fields while Option is held (or ControlOptionL for the focused
    // field). Persists until wiped. On release, the transcript writes to all.
    private let selector = SelectorEngine()

    // Optional on-device Foundation Models cleanup pass (opt-in per app).
    private let cleanup = Cleanup()
    private var sessionNeedsCleanup = false

    init(store: SecureStore, workflows: WorkflowStore, rag: RAGIndex, dictionary: DictionaryStore, database: RecordingDatabase, editWatcher: EditWatcher) {
        self.store = store
        self.workflows = workflows
        self.rag = rag
        self.dictionary = dictionary
        self.database = database
        self.editWatcher = editWatcher
    }

    func bootstrap() {
        NSLog("SonarDictate: bootstrap() (engine=SpeechAnalyzer)")
        // VOICE ISOLATION (record over music/noise). Apple's voice-processing I/O
        // (VPIO) runs hardware echo cancellation + noise suppression, so your voice
        // is captured cleanly while music plays. The earlier attempt broke because
        // VPIO is a DUPLEX unit: its echo-canceller needs the RENDER (output) side
        // running, or capture is corrupted (empty finals). The fix is to drive a
        // SILENT output so that render side runs.
        //
        // Enabled here in bootstrap (engine stopped, before any tap) so the changed
        // input format is stable by the time startListening() reads it. Behind a
        // flag while it gets real-world validation - I/O audio cannot be unit-tested:
        //   IRIS_VOICE_ISOLATION=1
        if ProcessInfo.processInfo.environment["IRIS_VOICE_ISOLATION"] == "1" {
            // VPIO is a DUPLEX unit - build the render (output) graph BEFORE enabling
            // it, or the enable throws / capture stays broken. Touch output + mixer
            // first, drive a silent render, THEN turn on voice processing.
            engine.mainMixerNode.outputVolume = 0
            _ = engine.outputNode
            _ = engine.mainMixerNode
            engine.prepare()
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                NSLog("SonarDictate: voice isolation ON (dictate over music); input format now \(engine.inputNode.outputFormat(forBus: 0))")
            } catch {
                NSLog("SonarDictate: voice isolation enable FAILED: \(error) :: \(error.localizedDescription)")
            }
        }

        // Wire session callbacks. SpeechAnalyzer gives us a single
        // "current best transcript so far" string after each result;
        // we route that into the existing partial/final flow.
        session.onTranscriptUpdate = { [weak self] transcript, isFinal in
            DispatchQueue.main.async {
                self?.handleTranscript(transcript, isFinal: isFinal)
            }
        }
        session.onError = { error in
            NSLog("SonarDictate: speech session error: \(error)")
        }

        // Compile the user's dictionary into a custom-vocabulary language model so
        // the recognizer reliably prefers their jargon (the soft contextual-strings
        // bias never stuck). Async (export + compile a beat after launch), reused
        // across sessions; rebuilt via refreshVocabularyModel() when words change.
        refreshVocabularyModel()

        // Chip click -> copy its text to the clipboard (stashing the original so
        // we can restore it after the user's next paste).
        chip?.onCopy = { [weak self] text in
            self?.copyChipToClipboard(text)
        }

        // Explicit Accessibility trust check. Without this, addGlobalMonitorForEvents
        // silently fails AND the app may not appear in the Accessibility list at all.
        let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
        let opts = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        NSLog("SonarDictate: Accessibility trusted=\(trusted)")
        if !trusted {
            NSLog("SonarDictate: System Settings -> Privacy & Security -> Accessibility -> enable SonarDictate, then restart this app.")
        }

        // Speech Recognition TCC permission is still required by SpeechAnalyzer.
        SFSpeechRecognizer.requestAuthorization { status in
            NSLog("SonarDictate: Speech auth status raw=\(status.rawValue)")
            guard status == .authorized else {
                NSLog("SonarDictate: Speech permission NOT authorized. Grant in System Settings -> Privacy & Security -> Speech Recognition.")
                return
            }
            DispatchQueue.main.async { self.installMonitor() }
        }
    }

    // (Re)build the custom-vocabulary language model from the CURRENT dictionary.
    // Called at launch and whenever the vocabulary changes (panel add, learned
    // correction). Heavy + async, so it runs off the main path; the rebuilt model
    // takes effect on the next dictation once it finishes compiling.
    func refreshVocabularyModel() {
        let terms = dictionary.terms(forContext: nil, limit: 500)
        Task { await session.prepareVocabulary(terms) }
    }

    private func installMonitor() {
        // Talk key is the FN/globe key. The .function modifier flag fires
        // flagsChanged when the fn key itself is held/released - arrow keys and
        // F-keys also set the .function flag in their event modifierFlags but
        // they're keyDown events, not flagsChanged, so they don't trigger this
        // monitor. (System Settings -> Keyboard -> "Press  key to" should be set
        // to "Do nothing" so macOS doesn't fight us - emoji picker / system
        // Dictation can intercept otherwise.)
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self else { return }
            let nowDown = event.modifierFlags.contains(.function)
            if nowDown && !self.isFnDown {
                self.isFnDown = true
                NSLog("SonarDictate: fn DOWN - startListening")
                self.statusItem?.setListening(true)
                self.overlay?.show()
                self.startListening()
            } else if !nowDown && self.isFnDown {
                self.isFnDown = false
                NSLog("SonarDictate: fn UP - stopListening")
                self.statusItem?.setListening(false)
                self.overlay?.hide()
                self.stopListening()
            }
        }
        // Separate keyDown monitor for the double-space commit gesture. We
        // only ACT on it when the chip is showing pending text - so normal
        // double-spaces you type (sentence ends, etc.) do nothing unless a
        // captured chip is waiting to be dropped. We never store or inspect
        // any other keystroke; this watches the space keycode only.
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return }

            // V while a clipboard restore is armed -> let the paste land, then
            // put the user's original clipboard back. (A global monitor can't
            // consume the event, so the paste itself proceeds normally.)
            if event.keyCode == 9, event.modifierFlags.contains(.command), self.clipboardStash != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                    self?.restoreClipboardIfPending()
                }
            }

            let ctrlOpt = event.modifierFlags.contains(.control) && event.modifierFlags.contains(.option)

            // ControlOptionL -> add the focused field to the selector.
            if ctrlOpt, event.keyCode == 37 {  // 37 = kVK_ANSI_L
                if let label = self.selector.addFocused() {
                    NSLog("SonarDictate: + target '\(label)' (selector now \(self.selector.count))")
                    self.highlighter?.update(targets: self.selector.targets)
                } else {
                    NSLog("SonarDictate: ControlOptionL - focused element not editable / already in set")
                }
                return
            }
            // ControlOptionK -> wipe the selector.
            if ctrlOpt, event.keyCode == 40 {  // 40 = kVK_ANSI_K
                self.selector.wipe()
                self.highlighter?.clear()
                NSLog("SonarDictate: selector WIPED")
                return
            }
            //  -> remove the last target.
            if ctrlOpt, event.keyCode == 51 {  // 51 = kVK_Delete
                self.selector.removeLast()
                self.highlighter?.update(targets: self.selector.targets)
                NSLog("SonarDictate: removed last target (selector now \(self.selector.count))")
                return
            }

            // ctrl-opt-H -> open the dictation history window.
            if ctrlOpt, event.keyCode == 4 {  // 4 = kVK_ANSI_H
                self.history?.show()
                return
            }
            // ctrl-opt-C -> copy the most recent dictation to the clipboard
            // (instant recovery when a paste missed its target field).
            if ctrlOpt, event.keyCode == 8 {  // 8 = kVK_ANSI_C
                if self.history?.copyMostRecent() == true {
                    NSLog("SonarDictate: copied last dictation to clipboard (ctrl-opt-C)")
                }
                return
            }

            // Double-space -> commit the chip into the focused field (only
            // when a chip is actually showing; otherwise normal typing).
            guard event.keyCode == 49 else { return }   // 49 = kVK_Space
            guard self.chip?.isShowing == true else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - self.lastSpaceDown < 0.4 {
                self.lastSpaceDown = 0
                self.commitChip()
            } else {
                self.lastSpaceDown = now
            }
        }

        // Click-to-target: requires the EXPLICIT chord  + fn + click. The
        // fn-alone+click of the previous build was too easy to fire by accident
        // - a stray click while dictating silently added a phantom target, and
        // the next release would broadcast the text to it AND the focused field,
        // producing two near-back-to-back injects that interleaved into a mess.
        // Per the step-4 spec the explicit chord is the real gesture; bringing
        // it forward now stops the accidental-add bug.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self, self.isFnDown else { return }
            let flags = event.modifierFlags
            guard flags.contains(.control), flags.contains(.command) else { return }
            if let label = self.selector.addElement(atCocoaPoint: NSEvent.mouseLocation) {
                NSLog("SonarDictate: + target '\(label)' via +fn+click (selector now \(self.selector.count))")
                self.highlighter?.update(targets: self.selector.targets)
            }
        }

        NSLog("SonarDictate: Ready. Hold fn/ to talk, release to capture. Double-space to drop the chip into a field.")
    }

    // Commit the chip's pending text into the currently focused field, then
    // hide the chip. Removes the two literal spaces the user just typed (the
    // double-space gesture) before injecting, so the gesture itself leaves no
    // residue.
    private func commitChip() {
        guard let text = chip?.pendingText else { return }
        NSLog("SonarDictate: double-space commit -> injecting \(text.count) chars from chip")
        backspace(count: 2)        // remove the two spaces the gesture typed
        inject(text)
        chip?.hide()
    }

    // Chip clicked -> copy its text to the clipboard and hide the chip. We
    // NO LONGER auto-restore the previous clipboard. The old restore-on-Cmd+V
    // logic was destroying user data: when the paste failed to land (overlay,
    // weird focus state, anything), the restore would still fire 250ms after
    // the keystroke and wipe our text from the clipboard, making the dictation
    // unrecoverable. There's no reliable signal from a Cmd+V that the paste
    // actually landed (paste doesn't consume the clipboard), so the safe move
    // is to leave the dictated text on the clipboard until the user copies
    // something else themselves - normal macOS copy semantics, no surprises,
    // no data loss.
    private func copyChipToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        NSLog("SonarDictate: chip -> clipboard (\(text.count) chars); ready to paste, no auto-restore")
        chip?.hide()
    }

    // Capture every item+type currently on the pasteboard so we can restore an
    // image/files/RTF clipboard, not just plain text.
    private static func snapshotPasteboard(_ pb: NSPasteboard) -> [[String: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type.rawValue] = data }
            }
            return dict
        }
    }

    // Put the user's original clipboard back - but only if OUR text is still on
    // it (if they copied something new in between, leave their new copy alone).
    private func restoreClipboardIfPending() {
        guard let stash = clipboardStash else { return }
        let pb = NSPasteboard.general
        defer { clipboardStash = nil; stashChangeCount = -1 }
        guard pb.changeCount == stashChangeCount else {
            NSLog("SonarDictate: clipboard changed since copy - leaving the user's newer copy intact")
            return
        }
        pb.clearContents()
        let items = stash.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
            return item
        }
        if !items.isEmpty { pb.writeObjects(items) }
        NSLog("SonarDictate: clipboard restored after paste")
    }

    private func startListening() {
        listening = true
        emittedText = ""
        sessionMode = .initial
        audioFrames.removeAll()
        sessionStart = Date()
        finalPersisted = false
        sessionAppContext = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Note whether this is a cleanup-target app. Cleanup NO LONGER runs on
        // the release path - it must never block injection (instant-on-release is
        // the product). The flag is retained for the planned live, as-you-speak
        // cleanup pass (.claude/plans/live-cleanup.md); for now every app injects
        // the raw recognizer text instantly.
        sessionNeedsCleanup = Cleanup.shouldClean(appContext: sessionAppContext)
        if sessionNeedsCleanup {
            NSLog("SonarDictate: cleanup-target app \(sessionAppContext ?? "?") - injecting raw instantly (live cleanup pass not yet wired)")
        }

        // NEW MODEL: never live-type into the user's real field. That was the
        // source of the mid-sentence injection garble AND the held input focus -
        // we were firing keystrokes into a foreign app on every volatile revision.
        // Instead the live words stream into our OWN floating widget (zero-lag
        // feel, fully under our control), and the real field gets the text exactly
        // once, on release. So everything commits at end now.
        streamingIntoField = false
        NSLog("SonarDictate: mode = commit-at-end (live preview in floating widget; \(selector.isEmpty ? "inject/chip" : "broadcast \(selector.count)") on release)")

        // Seed the recognizer with vocabulary biased toward what this user has
        // said recently in this app context. SpeechAnalyzer's AnalysisContext
        // takes a tagged-string map; we feed it via session.setContextualStrings().
        // Bias the recognizer toward the user's own vocabulary. The DICTIONARY
        // comes first (curated + corrections - the signal that actually teaches
        // the right words), then RAG over past transcripts (useful, but half-blind:
        // it'll reinforce whatever it heard, errors included). Dedup, cap, feed.
        var bias = dictionary.terms(forContext: sessionAppContext, limit: 100)
        if rag.assetsReady, rag.count > 0 {
            if let ragBias = try? rag.vocabularyBias(forContext: sessionAppContext, k: 8) {
                bias += ragBias
            }
        }
        var seen = Set<String>()
        let merged = bias.filter { seen.insert($0.lowercased()).inserted }
        session.setContextualStrings(Array(merged.prefix(200)))
        if !merged.isEmpty {
            NSLog("SonarDictate: biased recognizer with \(merged.count) terms (\(dictionary.count) in dictionary)")
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        sessionFormat = format
        // Remove any tap left over from a racy prior session before installing -
        // AVAudioEngine throws if a bus already has a tap.
        engine.inputNode.removeTap(onBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Clone the buffer once; the audio engine reuses its storage.
            // Both the SpeechAnalyzer session and our local WAV serialization
            // need their own retained copy. session.append() converts to the
            // transcriber-compatible format internally; audioFrames keeps the
            // raw mic-format audio for WAV storage.
            if let copy = self.copy(of: buffer) {
                self.audioFrames.append(copy)
                self.session.append(buffer: copy)
            }
        }

        // session.start(inputFormat:) is async - it negotiates the transcriber-
        // compatible audio format and builds the converter. The engine must NOT
        // start until that's done, or raw 48kHz mic buffers reach SpeechAnalyzer
        // before the converter exists and it traps in preRunRecognition().
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.start(inputFormat: format)
                // If Option was released while start() was negotiating, abort:
                // starting the engine now would orphan this session and corrupt
                // the next one (the rapid start/stop race).
                guard self.listening else {
                    NSLog("SonarDictate: released before audio start finished - aborting session")
                    self.session.stop()
                    self.engine.inputNode.removeTap(onBus: 0)
                    return
                }
                self.engine.prepare()
                try self.engine.start()
            } catch {
                NSLog("SonarDictate: audio start failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopListening() {
        listening = false
        // Re-arm the one-shot commit slot on every release. If something stale
        // (an overlapping session's late final) tripped finalPersisted mid-
        // recording, this guarantees THIS session's real final still commits.
        // Paired with the empty-final guard in finalize() - together they close
        // the overlapping-session drop where a long, fully-recognized dictation
        // vanished on release.
        finalPersisted = false
        // Drain the LAST captured audio into the recognizer BEFORE signaling
        // end-of-input. Stopping the engine + removing the tap FIRST means the
        // final in-flight buffers still reach session.append() with the input
        // continuation open; session.stop() then feeds a short trailing silence
        // and finalizes. The OLD order finished the continuation first, so the
        // last ~150-190ms of speech was discarded - the "drops my words off at
        // the end" bug (volLen=0, final range ending ~180ms before release).
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        session.stop()
        // The transcriber's results stream drains after end-of-input; its final
        // emission triggers finalize() via handleTranscript(isFinal: true).
    }

    // Called from the SpeechAnalyzer session's onTranscriptUpdate callback,
    // marshalled onto the main thread.
    //
    // Two models, chosen at session start (streamingIntoField):
    //   - STREAM: live-type each partial into the focused field via streamEmit
    //     (the "typing as I talk" feel), with trigger-buffering so a leading
    //     trigger word isn't typed. On final, reconcile + persist (no re-route).
    //   - COMMIT-AT-END: partials only update the overlay; on final, finalize()
    //     classifies + routes (broadcast to N targets, inject, or chip).
    private func handleTranscript(_ current: String, isFinal: Bool) {
        overlay?.updateTranscript(current)

        if streamingIntoField {
            if sessionMode == .initial {
                sessionMode = decideMode(from: current)
            }
            if !isFinal {
                if sessionMode == .streaming {
                    streamEmit(target: current, isFinal: false)
                }
                return
            }
            // Final.
            if sessionMode == .streaming {
                guard !finalPersisted else { return }
                finalPersisted = true
                streamEmit(target: current, isFinal: true)   // reconcile last delta
                persistSession(transcript: current)          // already typed; just persist
            } else {
                // Leading trigger word (buffered) or too-short-to-decide: route it.
                finalize(transcript: current)
            }
            return
        }

        guard isFinal else { return }
        finalize(transcript: current)
    }

    // Cheap classifier-prefix check used to decide whether to stream the
    // session into the focused app or buffer it silently. Returns:
    //   .initial   - not enough signal yet (single-word partial, or empty)
    //   .buffering - first word matches a built-in trigger or a workflow
    //                binding prefix (longest-prefix wins for workflows)
    //   .streaming - first word is plain dictation; safe to stream
    private func decideMode(from partial: String) -> SessionMode {
        let trimmed = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .initial }

        // A workflow binding prefix wins immediately, regardless of word count.
        if workflows.match(trimmed) != nil {
            return .buffering
        }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        let first = String(words[0])
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
        // Leading built-in trigger ("yo"/"claude"/"note"/"todo") -> buffer so we
        // don't live-type it. Otherwise stream from the very first word - waiting
        // for a second word would add a visible one-word lag to the typing feel.
        if TriggerRouter.defaultTriggers.contains(first) {
            return .buffering
        }
        return .streaming
    }

    // Called once per session when isFinal=true.
    // - Persists audio + transcript via SecureStore
    // - Classifies for trigger words (currently log only; handlers later)
    private func finalize(transcript: String) {
        guard !finalPersisted else { return }

        // An EMPTY final must never consume this session's one-shot commit slot.
        // A stale/aborted session's late completion can deliver an empty final
        // milliseconds AFTER a new session reset finalPersisted; if that empty
        // final claimed the slot, the new session's real (non-empty) final would
        // hit the guard above and be SILENTLY DROPPED - the "long dictation shows
        // in the widget, then vanishes on release" bug. Empty finals are no-ops:
        // do not claim the slot, do not persist.
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            NSLog("SonarDictate: empty final ignored - commit slot preserved")
            return
        }
        finalPersisted = true

        // Classify trigger (user-defined workflow bindings win over built-in triggers).
        let action = TriggerRouter.classify(transcript, workflowStore: workflows)
        NSLog("SonarDictate: classified -> \(action)")

        // Route the result:
        //   - plain dictation -> commit (direct inject if a field is focused,
        //     else park in the draggable chip for later double-space commit)
        //   - workflow binding -> fire it via automator, never inject text
        //   - other triggers (yo/claude/note/todo) -> log for now
        switch action {
        case .dictate(let text):
            commitDictation(text)
        case let .runWorkflow(binding, input):
            let store = self.workflows
            Task.detached(priority: .userInitiated) {
                do {
                    let code = try store.execute(binding, input: input.isEmpty ? nil : input)
                    NSLog("SonarDictate: workflow '\(binding.name)' exited \(code)")
                } catch {
                    NSLog("SonarDictate: workflow '\(binding.name)' failed: \(error)")
                }
            }
        default:
            // Trigger handlers (yo/claude/note/todo/llmPrompt) aren't wired yet.
            // Don't EAT the user's text just because their first word happened to
            // match a built-in trigger - fall back to plain dictation so the
            // transcript still lands. Workflow bindings (above) are explicit and
            // still fire normally.
            NSLog("SonarDictate: action \(action) - no handler; falling back to dictation")
            commitDictation(transcript)
        }

        persistSession(transcript: transcript)
    }

    // Persist audio+transcript to SecureStore and ingest into the RAG index.
    // Shared by the commit-at-end path (finalize) and the streaming path (where
    // the text is already typed into the field). The caller owns the
    // finalPersisted guard; this just does the heavy work off the main thread.
    private func persistSession(transcript: String) {
        let duration = sessionStart.map { -$0.timeIntervalSinceNow } ?? 0
        let appCtx = sessionAppContext
        let frames = audioFrames
        let format = sessionFormat
        audioFrames.removeAll()

        // Persist asynchronously so we don't block the recognition callback
        DispatchQueue.global(qos: .utility).async { [store, rag, database, editWatcher, chip] in
            let createdAt = Date()
            let persistedID: String?
            if let format = format, !frames.isEmpty {
                do {
                    let audioData = try Dictator.serializeWAV(frames: frames, format: format)
                    let id = try store.write(
                        audio: audioData,
                        transcript: transcript,
                        appContext: appCtx,
                        durationSeconds: duration
                    )
                    NSLog("SonarDictate: persisted \(id) (\(audioData.count) bytes, \(String(format: "%.1fs", duration)))")
                    persistedID = id
                    // If the live pass looks short for this much audio, re-transcribe
                    // the file in the background and surface anything it dropped.
                    Dictator.autoRecover(transcript: transcript, durationSeconds: duration, audioWAV: audioData, recordingId: id, chip: chip)
                } catch {
                    NSLog("SonarDictate: persist failed: \(error.localizedDescription)")
                    persistedID = nil
                }
            } else {
                NSLog("SonarDictate: no audio frames captured; persisting transcript only")
                do {
                    let id = try store.write(
                        audio: Data(),
                        transcript: transcript,
                        appContext: appCtx,
                        durationSeconds: duration
                    )
                    NSLog("SonarDictate: persisted \(id) (transcript-only)")
                    persistedID = id
                } catch {
                    NSLog("SonarDictate: persist failed: \(error.localizedDescription)")
                    persistedID = nil
                }
            }

            // Ingest into RAG index (independent of audio persistence)
            if let id = persistedID, rag.assetsReady {
                do {
                    try rag.add(id: id, transcript: transcript, appContext: appCtx, createdAt: createdAt)
                    NSLog("SonarDictate: RAG ingested \(id), total entries=\(rag.count)")
                } catch {
                    NSLog("SonarDictate: RAG ingest failed: \(error)")
                }
            } else if persistedID != nil, !rag.assetsReady {
                NSLog("SonarDictate: RAG embedding model not ready yet; transcript queued via store and can be re-indexed later")
            }

            // Also write to the corpus DB - encrypted column-by-column for
            // sensitive content. This is the long-term moat (every dictation
            // tagged with provenance, ready to feed a custom LM trainer down
            // the line). Runs in parallel with the legacy SecureStore writes
            // for now; once verified, SecureStore can be retired in favor of
            // the DB as the source of truth.
            if let id = persistedID {
                do {
                    try database.recordSession(
                        id: id,
                        createdAt: createdAt,
                        durationSeconds: duration,
                        appBundle: appCtx,
                        locale: "en-US",
                        acousticModel: "apple.DictationTranscriber.progressiveLongDictation@macOS26",
                        languageModel: nil,
                        wasBroadcast: false,  // TODO: thread through commit-time selector state
                        fnHeldMs: nil,        // TODO: capture from listening lifecycle
                        audioPath: nil,       // TODO: surface SecureStore's audio path
                        rawTranscript: transcript,
                        committedText: transcript
                    )
                    NSLog("SonarDictate: corpus DB recorded \(id)")
                    // Promote the armed edit-watcher to an active watch tied
                    // to this recording. The 60s capture timer starts from
                    // here; on expiry, the watcher reads the field's current
                    // value, diffs vs the injected text, and writes any
                    // corrections back to the DB.
                    editWatcher.linkRecording(id)
                } catch {
                    NSLog("SonarDictate: corpus DB write failed: \(error)")
                }
            }
        }

        // Refresh menu-bar counts (off the audio queue, on main).
        statusItem?.refreshCounts()
    }

    // Serialize accumulated PCM buffers to WAV bytes via a temp file.
    // The temp file is shredded immediately after read.
    private static func serializeWAV(frames: [AVAudioPCMBuffer], format: AVAudioFormat) throws -> Data {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sonar-dictate-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Scope the AVAudioFile so it closes before we read the bytes.
        do {
            var audioFile: AVAudioFile? = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            for buf in frames {
                try audioFile?.write(from: buf)
            }
            audioFile = nil  // force close + flush
        }

        return try Data(contentsOf: tempURL)
    }

    // Automatic word recovery. When the live (streaming) pass came back empty or
    // suspiciously short for how much audio there is, re-transcribe the saved WAV
    // with the file recognizer - it sees the whole utterance at once and recovers
    // words the streaming pass dropped - and, only if it finds meaningfully more,
    // pop the recovered text into the chip (a visible click-to-copy target, no
    // hotkey, no clipboard clobber). Static + chip passed in because the caller's
    // closure intentionally avoids capturing self. Logs counts only (PHI-safe).
    static func autoRecover(transcript: String, durationSeconds: Double, audioWAV: Data, recordingId: String, chip: TextChip?) {
        // Normal speech is ~12 chars/sec; flag clearly-low output (or empty).
        let floor = durationSeconds * 6.0
        let looksShort = transcript.isEmpty || Double(transcript.count) < floor
        guard durationSeconds >= 1.0, looksShort, !audioWAV.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("sonar-autorecover-\(recordingId).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? audioWAV.write(to: tmp)) != nil,
                  let recovered = try? BatchTranscriber.recoverTranscript(wavURL: tmp) else { return }
            let trimmed = recovered.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only surface it when recovery clearly beats the live pass.
            guard trimmed.count > transcript.count + 4 else { return }
            NSLog("SonarDictate: auto-recover - live \(transcript.count) -> recovered \(trimmed.count) chars for \(recordingId)")
            DispatchQueue.main.async { chip?.present(trimmed) }
        }
    }

    // PCM buffer copy - the original buffer's storage is reused by the audio
    // engine, so we must clone the bytes to keep them.
    private func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else {
            return nil
        }
        copy.frameLength = buffer.frameLength

        let channelCount = Int(buffer.format.channelCount)
        if let src = buffer.floatChannelData, let dst = copy.floatChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Float>.size)
            }
        } else if let src = buffer.int16ChannelData, let dst = copy.int16ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Int16>.size)
            }
        } else if let src = buffer.int32ChannelData, let dst = copy.int32ChannelData {
            for ch in 0..<channelCount {
                memcpy(dst[ch], src[ch], Int(buffer.frameLength) * MemoryLayout<Int32>.size)
            }
        }
        return copy
    }

    // MARK: - Streaming injection

    // Reconcile the focused field to `target` with the MINIMAL edit: keep the
    // common prefix, backspace only the diverging tail of what we already typed,
    // then type only the new tail.
    //
    // The old version backspaced + retyped the ENTIRE string on any divergence.
    // On long, continuously-revised dictation that was a storm of keystrokes that
    // raced the system's async event delivery and produced garbled, interleaved
    // text that felt unstoppable. A volatile revision usually only changes the
    // last word or two, so a common-prefix diff keeps each update tiny - no storm,
    // and the final reconciliation on release is small, so it "lets go" fast.
    private func streamEmit(target: String, isFinal: Bool) {
        guard target != emittedText else { return }
        let common = emittedText.commonPrefix(with: target).count
        let toDelete = emittedText.count - common
        if toDelete > 0 { backspace(count: toDelete) }
        let suffix = String(target.dropFirst(common))
        if !suffix.isEmpty { inject(suffix) }
        emittedText = target
    }

    // Commit a finalized plain-dictation transcript. Runs the optional cleanup
    // pass first (per-app), then routes to direct-inject or the chip.
    private func commitDictation(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSLog("SonarDictate: empty transcript - nothing to commit (short hold or no speech detected)")
            return
        }
        // INSTANT injection is the entire product: the text must be in the field
        // the moment the key is released - never hanging on processing. The old
        // path did `await cleanup.clean()` (an on-device LLM, ~seconds) BEFORE
        // injecting in cleanup-target apps, which is the multi-second release
        // hang - a death sentence. Cleanup is NOT allowed to block release.
        //
        // Inject the recognizer's final text immediately. The recognizer already
        // revises words live as you speak (that real-time word-changing shows in
        // the widget). The LLM pass only repairs punctuation/capitalization and is
        // word-preserving; doing that as a live, as-you-speak pass (so the cleaned
        // text is ready AT release, not computed after it) is the proper design
        // and is tracked in .claude/plans/live-cleanup.md. Until then, raw-instant
        // beats polished-but-laggy every time.
        commit(trimmed)
    }

    // Routing priority:
    //   1. Selector has targets -> broadcast to ALL of them.
    //   2. An editable field is focused -> direct inject ("shoot for the stars").
    //   3. Otherwise -> park in the draggable chip.
    private func commit(_ text: String) {
        if !selector.isEmpty {
            NSLog("SonarDictate: broadcasting \(text.count) chars to \(selector.count) target(s): \(selector.summary)")
            for target in selector.targets {
                broadcast(to: target, text: text)
            }
            return
        }
        // Inject if Accessibility is trusted RIGHT NOW (live check, not the
        // boot-time cached value) - CGEvent.post is silently dropped without it.
        // If we don't have it, fall back to the chip so the user isn't stranded
        // with text that has nowhere to go. The AX focus check is unreliable
        // for Electron/web inputs (kAXFocusedUIElement often comes back nil
        // even when the cursor is in the field), so it stays diagnostic-only.
        _ = isEditableFieldFocused()
        if AXIsProcessTrusted() {
            NSLog("SonarDictate: commit \(text.count) chars via direct inject (AX trusted)")
            // Capture the focused element BEFORE injecting - inject pushes
            // keystrokes which can shift focus in some apps, and we want the
            // ref to the field we're actually typing into. The edit-watcher
            // will use this ref to read the field's value 60s later and diff
            // it against the text we just injected.
            let focusedElement = currentFocusedElement()
            inject(text)
            editWatcher.armForNextRecording(focusedElement: focusedElement, injectedText: text)
        } else {
            NSLog("SonarDictate: AX not trusted - chip fallback (\(text.count) chars)")
            chip?.present(text)
            // Don't arm edit-watcher on chip path - we don't know which field
            // the user will paste into, can't observe edits.
        }
    }

    // Read the system-wide focused UI element via AX. Returns nil for
    // Electron/web contexts that don't publish kAXFocusedUIElement, OR when
    // we lack Accessibility trust. The edit-watcher gracefully skips capture
    // for nil cases.
    private func currentFocusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        return (focused as! AXUIElement)
    }

    // Deliver text to one selector target via the reliable keystroke path.
    //
    // We learned the hard way that AX value-set is silently ignored by Electron/
    // web inputs (Claude, ChatGPT, Cursor, web textareas) - React never sees the
    // change. So instead we do what a human does and what the single-field path
    // already proved fast: CLICK the exact point the user clicked (which focuses
    // the real input, even in Electron), let focus settle, then type. When there's
    // no click point (a ControlOptionL focused-add), fall back to AX setFocused.
    private func broadcast(to target: SelectorEngine.Target, text: String) {
        if let cocoa = target.clickPoint {
            clickAt(cocoaPoint: cocoa)
            usleep(40_000)  // ~40ms for the app to focus the field before typing
            NSLog("SonarDictate: broadcast -> click \(Int(cocoa.x)),\(Int(cocoa.y)) + type \(text.count) chars to '\(target.label)'")
        } else {
            AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(40_000)
            NSLog("SonarDictate: broadcast -> AX-focus + type \(text.count) chars to '\(target.label)'")
        }
        inject(text)
        usleep(30_000)  // settle before moving on to the next target
    }

    // Synthesize a left mouse click at a Cocoa-coordinate screen point (flip to
    // Quartz top-left for CGEvent). Used to focus a broadcast target's real input.
    private func clickAt(cocoaPoint cocoa: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? cocoa.y
        let quartz = CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: quartz, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: quartz, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // Asks the Accessibility API whether the system-wide focused element is an
    // editable text control. Logs the detected role/subrole every call so when
    // an inject fails (text routes to chip instead of field), we can see what
    // role the focused element actually reports - Electron/web apps use a wide
    // range of non-standard roles and we need the data to extend our accept list.
    private func isEditableFieldFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else {
            NSLog("SonarDictate: AX focus check - no system-wide focused element")
            return false
        }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = (subroleRef as? String) ?? ""

        // Known editable roles. Expanded to cover web/Electron quirks beyond the
        // three native Cocoa roles.
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
            "AXTextRow",
        ]
        if editableRoles.contains(role) {
            NSLog("SonarDictate: AX focus - role=\(role) (editable, native)")
            return true
        }

        // Electron/web inputs often report unusual roles but expose AXValue as
        // settable. Accept those.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if settable.boolValue {
            NSLog("SonarDictate: AX focus - role=\(role) subrole=\(subrole) (AXValue settable, accepting)")
            return true
        }

        // Loose fallback: anything with "Text" in its role name. Catches things
        // like AXTextRow / AXTextGroup / custom roles in Electron apps.
        if role.contains("Text") || subrole.contains("Text") {
            NSLog("SonarDictate: AX focus - role=\(role) subrole=\(subrole) (role contains Text, accepting)")
            return true
        }

        NSLog("SonarDictate: AX focus - role=\(role) subrole=\(subrole) settable=false (NOT editable -> chip)")
        return false
    }

    private func inject(_ text: String) {
        guard !text.isEmpty else { return }
        // PASTE, don't type. Char-by-char keystroke synthesis posts 2 events per
        // character (1686 for an 843-char utterance); slow targets - Electron and
        // terminal inputs especially - can't drain that flood, so long text lands
        // in stalled chunks ("two letters, hang, then the rest") or gets partially
        // dropped. A single Cmd-V delivers any length in one action, instantly.
        //
        let trusted = AXIsProcessTrusted()  // false => Accessibility missing; the paste keystroke is silently dropped
        let pb = NSPasteboard.general
        // Snapshot the user's clipboard so we can put it back after the paste lands.
        // Copy EVERY type into fresh items so images/RTF/files survive, not just text.
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types where item.data(forType: type) != nil {
                copy.setData(item.data(forType: type)!, forType: type)
            }
            return copy
        }
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            NSLog("SonarDictate: pasteboard set failed - falling back to keystroke inject (\(text.count) chars)")
            injectByKeystroke(text)
            return
        }
        let token = pb.changeCount
        NSLog("SonarDictate: inject \(text.count) chars via paste (AXtrusted=\(trusted))")
        postPaste()
        // Restore the user's clipboard AFTER the paste is consumed. Delayed so we
        // don't race a slow target reading the pasteboard (an early restore would
        // make it paste the OLD contents - the reason this used to be left clobbered).
        // Guarded by changeCount: only put the original back if our dictated text is
        // still on the board (nothing copied since); if the user copied something in
        // the gap, leave THAT alone. Deferred + async, so release->inject stays instant.
        if !saved.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let board = NSPasteboard.general
                guard board.changeCount == token else { return }
                board.clearContents()
                board.writeObjects(saved)
            }
        }
    }

    // Synthesize Cmd-V. Command is pressed and released around V (rather than
    // relying on a flag on the V event alone) so apps that watch for an explicit
    // modifier keyDown still register the paste.
    private func postPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        let cmd: CGKeyCode = 0x37  // kVK_Command
        let v: CGKeyCode = 0x09    // kVK_ANSI_V
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false)
        cmdDown?.flags = .maskCommand
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        cmdUp?.flags = []
        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    // Fallback only: per-character synthesis, used when the pasteboard can't be
    // set. Clears modifier flags so a held hotkey modifier doesn't turn the
    // synthesized keys into dead-key combos.
    private func injectByKeystroke(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for char in Array(text.utf16) {
            var ch = char
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.flags = []
            up?.flags = []
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func backspace(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        let deleteKey: CGKeyCode = 0x33  // kVK_Delete (backspace)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)
            down?.flags = []  // same modifier-clearing fix as inject()
            up?.flags = []
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - CLI dispatch

func runCLI(_ args: [String]) -> Never {
    let store: SecureStore
    let workflows: WorkflowStore
    let rag: RAGIndex
    let dictionary: DictionaryStore
    let database: RecordingDatabase
    do {
        store = try SecureStore()
        workflows = try WorkflowStore()
        rag = try RAGIndex()
        dictionary = try DictionaryStore()
        let dbURL = SecureStore.baseDir.appendingPathComponent("recordings.db")
        database = try RecordingDatabase(at: dbURL)
        _ = database  // currently unused in CLI commands; exercises the DB open path on every invocation
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }

    let cmd = args[0]
    let rest = Array(args.dropFirst())

    do {
        switch cmd {
        case "list":
            let records = try store.list()
            if records.isEmpty {
                print("(no recordings)")
            } else {
                let df = ISO8601DateFormatter()
                for r in records {
                    let ctx = r.appContext ?? "?"
                    let preview = r.transcriptPreview
                        .replacingOccurrences(of: "\n", with: " ")
                        .prefix(80)
                    print("\(r.id)  \(df.string(from: r.createdAt))  \(String(format: "%6.1fs", r.durationSeconds))  \(ctx)  \"\(preview)\"")
                }
                print("\n(\(records.count) total)")
            }
        case "read":
            guard let id = rest.first else {
                fputs("usage: sonar-dictate read <id>\n", stderr)
                exit(2)
            }
            let (_, transcript) = try store.read(id)
            print(transcript)
        case "delete":
            guard let id = rest.first else {
                fputs("usage: sonar-dictate delete <id>\n", stderr)
                exit(2)
            }
            try store.delete(id)
            print("deleted \(id)")
        case "reset":
            try store.reset()
            print("reset complete. all recordings and the device key are gone.")

        // Workflow / Automator binding commands

        case "workflows":
            let bindings = try workflows.list()
            if bindings.isEmpty {
                print("(no workflows bound)")
                print("\nbind one with: sonar-dictate bind \"<trigger phrase>\" <path-to-.workflow> [name]")
            } else {
                let df = ISO8601DateFormatter()
                for b in bindings {
                    print("\(b.id)  \"\(b.triggerPhrase)\"  ->  \(b.name)")
                    print("        path: \(b.workflowPath)")
                    print("        bound: \(df.string(from: b.registeredAt))")
                }
                print("\n(\(bindings.count) total)")
            }
        case "bind":
            guard rest.count >= 2 else {
                fputs("usage: sonar-dictate bind \"<trigger phrase>\" <path-to-.workflow> [friendly-name]\n", stderr)
                exit(2)
            }
            let phrase = rest[0]
            let path = rest[1]
            let name = rest.count > 2 ? rest[2] : nil
            let b = try workflows.register(triggerPhrase: phrase, workflowPath: path, name: name)
            print("bound \(b.id): \"\(b.triggerPhrase)\" -> \(b.name)")
            print("  path: \(b.workflowPath)")
        case "unbind":
            guard let idOrPhrase = rest.first else {
                fputs("usage: sonar-dictate unbind <id-or-phrase>\n", stderr)
                exit(2)
            }
            try workflows.unregister(id: idOrPhrase)
            print("unbound \(idOrPhrase)")
        case "runwf":
            guard let idOrPhrase = rest.first else {
                fputs("usage: sonar-dictate runwf <id-or-phrase> [input-text...]\n", stderr)
                exit(2)
            }
            let input = rest.dropFirst().joined(separator: " ")
            let bindings = try workflows.list()
            let binding = bindings.first(where: { $0.id == idOrPhrase || $0.triggerPhrase == idOrPhrase.lowercased() })
            guard let binding = binding else {
                fputs("error: no binding matches '\(idOrPhrase)'\n", stderr)
                exit(1)
            }
            print("running '\(binding.name)' (\(binding.workflowPath))...")
            let code = try workflows.execute(binding, input: input.isEmpty ? nil : input)
            print("exit \(code)")

        // RAG / retrieval commands

        case "rag":
            print("RAG index entries: \(rag.count)")
            print("Embedding model assets ready: \(rag.assetsReady)")
            if !rag.assetsReady {
                print("(NLContextualEmbedding is still downloading. Re-run after a few minutes.)")
            }
        case "similar":
            guard !rest.isEmpty else {
                fputs("usage: sonar-dictate similar <text...>\n", stderr)
                exit(2)
            }
            let query = rest.joined(separator: " ")
            let hits = try rag.query(query, k: 5)
            if hits.isEmpty {
                print("(no similar past recordings)")
            } else {
                let df = ISO8601DateFormatter()
                for h in hits {
                    let ctx = h.entry.appContext ?? "?"
                    print(String(format: "%.3f  ", h.score)
                          + "\(h.entry.id)  \(df.string(from: h.entry.createdAt))  \(ctx)")
                    print("        \"\(h.entry.preview.replacingOccurrences(of: "\n", with: " ").prefix(120))\"")
                }
            }
        case "rag-reset":
            try rag.reset()
            print("RAG index cleared. Recordings retained; future dictations will rebuild the index.")

        // The eyes' perceptual memory - what the screen-watcher has noticed,
        // retrievable by MEANING. The store is written by the running app; this
        // reads the same encrypted file out-of-process.
        case "eyes":
            let sub = rest.first
            let memory = try PerceptionMemory()
            switch sub {
            case nil, "stats":
                print("perception memory entries: \(memory.count)")
                print("embedding model assets ready: \(((try? TextEmbedder())?.assetsReady) ?? false)")
            case "recall":
                let query = rest.dropFirst().joined(separator: " ")
                guard !query.isEmpty else {
                    fputs("usage: sonar-dictate eyes recall <text...>\n", stderr)
                    exit(2)
                }
                let vector = try TextEmbedder().vector(for: query)
                let hits = memory.recall(vector: vector, k: 5)
                if hits.isEmpty {
                    print("(nothing remembered yet - watch the screen first: right-click the menu-bar mic)")
                } else {
                    let df = ISO8601DateFormatter()
                    for h in hits {
                        print(String(format: "%.3f  ", h.score) + df.string(from: h.entry.at))
                        print("        \(h.entry.summary.replacingOccurrences(of: "\n", with: " "))")
                    }
                }
            case "reset", "wipe":
                try memory.reset()
                print("perception memory cleared.")
            default:
                fputs("unknown eyes subcommand: \(sub ?? "")\n", stderr)
                fputs("usage: sonar-dictate eyes [stats | recall <text...> | reset]\n", stderr)
                exit(2)
            }

        // Hidden dev path. Inserts a synthetic correction row through the full
        // encryption + write path. Proves the EditWatcher's database call
        // works end-to-end without requiring a real dictation + manual edit
        // in a native field. Safe to keep - writes one debug-tagged row,
        // queryable + removable like any other.
        case "dev-correction":
            let testRecId = "dev-\(UUID().uuidString)"
            try database.addCorrection(
                recordingId: testRecId,
                rawPhrase: "synthetic raw text the model would have heard",
                correctedPhrase: "synthetic corrected text the user kept",
                position: nil,
                weight: 1.0,
                createdAt: Date()
            )
            print("inserted synthetic correction for recording_id=\(testRecId)")

        // Personal dictionary - the learning substrate. Terms here bias the
        // recognizer toward the user's own vocabulary every session.
        case "dict":
            let sub = rest.first
            switch sub {
            case nil, "list":
                let items = dictionary.list()
                if items.isEmpty {
                    print("(dictionary empty)")
                    print("\nadd terms with: sonar-dictate dict add \"<term or phrase>\"")
                } else {
                    for e in items {
                        let ctx = e.appContext.map { " - \($0)" } ?? ""
                        print(String(format: "%6.1f  ", e.weight) + "\(e.term)  [\(e.source)\(ctx)]")
                    }
                    print("\n(\(items.count) terms)")
                }
            case "add":
                let term = rest.dropFirst().joined(separator: " ")
                guard !term.isEmpty else {
                    fputs("usage: sonar-dictate dict add \"<term or phrase>\"\n", stderr)
                    exit(2)
                }
                dictionary.add(term, weight: 2, source: .manual)
                print("added \"\(term)\" (\(dictionary.count) terms total)")
            case "rm", "remove":
                let term = rest.dropFirst().joined(separator: " ")
                guard !term.isEmpty else {
                    fputs("usage: sonar-dictate dict rm \"<term>\"\n", stderr)
                    exit(2)
                }
                print(dictionary.remove(term) ? "removed \"\(term)\"" : "\"\(term)\" not in dictionary")
            case "reset", "wipe":
                dictionary.wipe()
                print("dictionary wiped.")
            default:
                fputs("unknown dict subcommand: \(sub ?? "")\n", stderr)
                fputs("usage: sonar-dictate dict [list | add \"<term>\" | rm \"<term>\" | reset]\n", stderr)
                exit(2)
            }

        case "logs":
            if rest.first == "--follow" || rest.first == "-f" {
                try EncryptedLog.follow()   // never returns
            }
            let text = try EncryptedLog.readAll()
            if text.isEmpty {
                print("(log is empty)")
            } else {
                FileHandle.standardOutput.write(Data(text.utf8))
            }

        case "help", "-h", "--help":
            print("""
            usage:  sonar-dictate <command> [args...]

            recordings:
              list                          list all encrypted recordings
              read <id>                     print transcript for a recording
              delete <id>                   delete one recording
              reset                         wipe storage + Secure Enclave key

            workflows (Automator bindings):
              workflows                     list bound workflows
              bind "<phrase>" <path> [name] bind a trigger phrase to a .workflow bundle
              unbind <id-or-phrase>         remove a binding
              runwf <id-or-phrase> [input]  fire a workflow manually (for testing)

            RAG (local retrieval):
              rag                           index stats + embedding model status
              similar <text...>             top-5 past recordings by cosine similarity
              rag-reset                     drop the index (recordings stay; reindex next session)

            eyes (on-device screen perception - right-click the menu-bar mic to watch):
              eyes                          perception memory stats
              eyes recall <text...>         top-5 noticed moments by meaning
              eyes reset                    wipe the perception memory

            dictionary (personalization - biases the recognizer to your words):
              dict                          list dictionary terms by weight
              dict add "<term>"             add/reinforce a term
              dict rm "<term>"              remove a term
              dict reset                    wipe the dictionary

            diagnostics:
              logs                          decrypt and print the diagnostic log
              logs --follow                 live-tail the decrypted log (Ctrl-C to stop)

            (no args)  launch background dictation app
            """)
        default:
            fputs("unknown command: \(cmd)\n", stderr)
            fputs("try: sonar-dictate help\n", stderr)
            exit(2)
        }
    } catch {
        fputs("error: \(error)\n", stderr)
        exit(1)
    }
    exit(0)
}

// MARK: - Entry point

let cliArgs = Array(CommandLine.arguments.dropFirst())
if !cliArgs.isEmpty {
    runCLI(cliArgs)
}

// Diagnostics go to an ENCRYPTED, append-only log. The old behavior redirected
// fd 2 (where NSLog writes) into a plaintext ~/Library/Logs/SonarDictate.log,
// which left every line in cleartext on a PHI machine. EncryptedLog pipes stderr
// through an in-process AES-256-GCM sink keyed by the Keychain DB key, migrates
// any pre-existing plaintext log into the encrypted file, and removes the
// cleartext. Read it back with `sonar-dictate logs [--follow]`.
EncryptedLog.install()

// No args -> background dictation mode.
let store: SecureStore
let workflows: WorkflowStore
let rag: RAGIndex
let dictionary: DictionaryStore
let database: RecordingDatabase
do {
    store = try SecureStore()
    workflows = try WorkflowStore()
    rag = try RAGIndex()
    dictionary = try DictionaryStore()
    // The corpus DB lives next to the rest of the encrypted store. Master key
    // is generated on first launch and held in Keychain (KeychainStore).
    let dbURL = SecureStore.baseDir.appendingPathComponent("recordings.db")
    database = try RecordingDatabase(at: dbURL)
} catch {
    NSLog("SonarDictate: failed to init stores: \(error)")
    exit(1)
}

// Edit-watcher: armed by commit() right after inject, linked to a recording
// once persistSession produces the UUID, fires the AX-read + diff + write
// 60 seconds later (or sooner if a new injection preempts it). This is the
// learning loop that feeds the corrections table.
let editWatcher = EditWatcher(database: database, dictionary: dictionary)

if #available(macOS 26.0, *) {
    let dictator = Dictator(store: store, workflows: workflows, rag: rag, dictionary: dictionary, database: database, editWatcher: editWatcher)
    let statusItem = StatusItemController(store: store, workflows: workflows, rag: rag, dictionary: dictionary)
    let overlay = RecordingOverlay()
    let chip = TextChip()
    let highlighter = FieldHighlighter()
    let history = HistoryWindow(store: store)
    dictator.statusItem = statusItem
    dictator.overlay = overlay
    dictator.chip = chip
    dictator.highlighter = highlighter
    dictator.history = history
    statusItem.history = history
    // The widget is always-on - install it now so the user can position it
    // before the first dictation. It morphs between idle (small icon) and
    // listening (expanded with live transcript) as sessions come and go.
    overlay.install()

    // The eyes: an on-device screen-perception loop, isolated from the sealed
    // capture path. A resizable "look here" frame the user places, a 3s OCR
    // heartbeat, a delta gate, and an Apple on-device LLM situational read pushed
    // to the caption + EyeSignals. Off by default; right-click the menu-bar mic
    // (or option-click) to start/stop watching. See
    // .claude/plans/the-eyes-screen-perception.md.
    // One on-device embedder + one encrypted memory, SHARED by the silent eyes
    // (which fill it) and the conversation (which fills + reads it). That shared
    // memory is Iris's brain.
    let irisEmbedder = try? TextEmbedder()
    let irisMemory = try? PerceptionMemory()
    // Her agenda: the structured action-items + notes layer (encrypted). The
    // assistant primitive everything else grows from.
    let irisAgenda = try? AgendaStore()

    // Iris's sealed ledger: owner-routed, tamper-evident raw + her brain of
    // learnings. company -> Enclave seal (device-bound); personal + brain ->
    // recoverable seal (the existing device key for now; LedgerKey passphrase
    // derivation is the documented portable upgrade). Best-effort: if any of this
    // fails to init, the rest of Iris runs unaffected.
    let irisLedgers: Ledgers? = {
        guard let enclaveKey = try? EnclaveKey.loadOrCreate() else { return nil }
        let dir = SecureStore.baseDir.appendingPathComponent("ledger", isDirectory: true)
        // Recoverable seal: the passphrase-derived KEK if set up (op run +
        // IRIS_LEDGER_PASSPHRASE), else the device key. See LedgerSecret.
        let kek = LedgerSecret.recoverableKEK(dir: dir)
        let enclave = EnclaveWrap(box: EnclaveBox(
            key: enclaveKey, salt: "__sonar_dictate_ledger_company__", info: "sonar-dictate.v1.ledger"))
        return try? Ledgers(dir: dir, enclave: enclave, recoverable: RecoverableWrap(kek: kek))
    }()

    // One-time: seal her existing perception history into the ledger so the past
    // gets the same protection as new intake. Marker-guarded, sequential, detached.
    if let backfillLedgers = irisLedgers, let mem = irisMemory {
        let ledgerDir = SecureStore.baseDir.appendingPathComponent("ledger", isDirectory: true)
        let items = mem.all().map { LedgerBackfill.Item(at: $0.at, summary: $0.summary, kind: $0.kind) }
        DispatchQueue.global(qos: .utility).async {
            let n = LedgerBackfill.runOnce(items, into: backfillLedgers,
                                           scrub: PhiMaskScrubber(), dir: ledgerDir)
            if n > 0 { NSLog("SonarDictate: backfilled \(n) history entries into the ledger") }
        }
    }

    // Off-device backup (opt-in). If IRIS_BACKUP_DIR is set (e.g. an iCloud Drive
    // or Dropbox local folder), replicate the RECOVERABLE chains there at launch
    // and every 5 minutes. Zero-knowledge (ciphertext only); the company chain is
    // never sent. No destination is chosen for you - unset = no backup.
    if let backup = ProcessInfo.processInfo.environment["IRIS_BACKUP_DIR"], !backup.isEmpty,
       let backupLedgers = irisLedgers {
        let ledgerDir = SecureStore.baseDir.appendingPathComponent("ledger", isDirectory: true)
        let sinkDir = URL(fileURLWithPath: (backup as NSString).expandingTildeInPath)
        let runBackup = {
            DispatchQueue.global(qos: .utility).async {
                guard let sink = try? FolderSink(dir: sinkDir) else { return }
                _ = try? Replicator.replicate(backupLedgers, dir: ledgerDir, to: sink)
            }
        }
        runBackup()
        let backupTimer = Timer(timeInterval: 300, repeats: true) { _ in runBackup() }
        RunLoop.main.add(backupTimer, forMode: .common)
    }

    // Connector pollers (OPT-IN, off by default). Each needs the user to turn it
    // on; both route to the personal chain through the one SourcePoller.
    let ledgerDirForSources = SecureStore.baseDir.appendingPathComponent("ledger", isDirectory: true)
    // Messages (IRIS_INGEST_MESSAGES=1) - local iMessage/SMS; needs Full Disk Access.
    if ProcessInfo.processInfo.environment["IRIS_INGEST_MESSAGES"] == "1", let lg = irisLedgers {
        SourcePoller.start(MessagesSource(),
            cursorFile: ledgerDirForSources.appendingPathComponent(".messages-cursor"),
            into: lg, scrub: PhiMaskScrubber(), intervalSec: 300)
    }
    // Drop folder (IRIS_INBOX_DIR=<path>) - text files you drop in get ingested.
    if let inbox = ProcessInfo.processInfo.environment["IRIS_INBOX_DIR"], !inbox.isEmpty,
       let lg = irisLedgers {
        let dir = URL(fileURLWithPath: (inbox as NSString).expandingTildeInPath)
        SourcePoller.start(FolderSource(dir: dir),
            cursorFile: ledgerDirForSources.appendingPathComponent(".folder-cursor"),
            into: lg, scrub: PhiMaskScrubber(), intervalSec: 120)
    }

    let eyeOverlay = EyeOverlay()
    let eye = Eye()
    eye.attach(overlay: eyeOverlay)
    eye.attachMemory(embedder: irisEmbedder, memory: irisMemory)
    eye.attachLedger(irisLedgers)
    eyeOverlay.install()

    // Iris's conversation surface - the ONLY place she speaks, and only when
    // spoken to. Shares the memory the eyes fill.
    let irisChat = IrisChat()
    irisChat.attach(memory: irisMemory, embedder: irisEmbedder, agenda: irisAgenda, ledgers: irisLedgers)
    irisChat.install()

    // Iris's ears: on-device dual-source call transcription (system audio + mic),
    // separate from the sealed dictation path. Stage 1 streams the labeled
    // transcript into her chat with a LISTENING marker so you can verify she hears.
    let callListener = CallListener()
    callListener.onSegment = { label, text in
        irisChat.appendCallSegment(label, text)
        irisChat.ingestCallSegment(label, text)   // seal the call transcript (best-effort)
    }
    callListener.onState = { on in irisChat.noteListening(on) }
    callListener.onDiag = { text in irisChat.noteDiag(text) }
    // Click-to-listen (the hotkey gets eaten by terminal Secure Keyboard Entry).
    irisChat.onToggleListen = { Task { await callListener.toggle() } }
    // Open her window at launch so there is always a clickable surface - no hotkey
    // needed to reach the Listen button or talk to her.
    irisChat.show()

    // Global hotkeys (mirror the app's other ctrl-opt hotkeys; they work because
    // the app holds Accessibility trust). Note: a terminal with Secure Keyboard
    // Entry focused will eat these - press them with another app focused.
    NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { event in
        let ctrlOpt = event.modifierFlags.contains(.control) && event.modifierFlags.contains(.option)
        if ctrlOpt, event.keyCode == 14 {        // ctrl-opt-E -> start/stop watching (+ open chat)
            eye.toggle()
            if eye.isWatching { irisChat.show() }
        } else if ctrlOpt, event.keyCode == 34 { // ctrl-opt-I -> talk to Iris
            irisChat.show()
        } else if ctrlOpt, event.keyCode == 38 { // ctrl-opt-J -> Iris listens to the call
            Task { await callListener.toggle() }
        }
    }
    NSLog("SonarDictate: iris hotkeys installed (ctrl-opt-E watch, ctrl-opt-I talk, ctrl-opt-J listen)")
    // Warm Iris into RAM so her first reply is not the slow cold-load one.
    IrisClient.prewarm()

    // Minimal main menu. An LSUIElement (menu-bar-only) app has NO menu bar of its
    // own, so the standard Edit shortcuts (Cmd-A select-all, Cmd-C copy, Cmd-V
    // paste, Cmd-X cut) were never bound - they do nothing in her text fields.
    // Wiring an Edit menu routes them through the responder chain to the focused
    // text view, so you can select/copy the transcript like any normal window.
    let mainMenu = NSMenu()
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Quit Iris", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appMenuItem.submenu = appMenu
    let editMenuItem = NSMenuItem()
    mainMenu.addItem(editMenuItem)
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editMenuItem.submenu = editMenu
    NSApp.mainMenu = mainMenu

    dictator.bootstrap()
    // Warm the speech model in the background at launch (no mic) so the FIRST
    // dictation isn't the slow one - kills the "big delay when I first start".
    Task.detached(priority: .utility) { await SpeechAnalyzerSession.prewarm() }
    NSApplication.shared.run()
} else {
    NSLog("SonarDictate requires macOS 26.0+ (SpeechAnalyzer is unavailable on this OS)")
    exit(1)
}
