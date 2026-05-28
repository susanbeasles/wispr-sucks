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
    private var isOptionDown = false
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

    // Double-space commit detection: timestamp of the last space keyDown.
    private var lastSpaceDown: TimeInterval = 0

    // Clipboard stash for the chip's "click to copy, paste anywhere, clipboard
    // unharmed" flow: clicking the chip saves the user's current clipboard, puts
    // the chip text on it, and after their next V we put the original back.
    private var clipboardStash: [[String: Data]]?
    private var stashChangeCount: Int = -1

    // Selector engine — the set of target fields a dictation broadcasts to.
    // Built up by clicking fields while ⌥ is held (or ⌃⌥L for the focused
    // field). Persists until wiped. On release, the transcript writes to all.
    private let selector = SelectorEngine()

    // Optional on-device Foundation Models cleanup pass (opt-in per app).
    private let cleanup = Cleanup()
    private var sessionNeedsCleanup = false

    init(store: SecureStore, workflows: WorkflowStore, rag: RAGIndex, dictionary: DictionaryStore) {
        self.store = store
        self.workflows = workflows
        self.rag = rag
        self.dictionary = dictionary
    }

    func bootstrap() {
        NSLog("SonarDictate: bootstrap() (engine=SpeechAnalyzer)")

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
            NSLog("SonarDictate: System Settings → Privacy & Security → Accessibility → enable SonarDictate, then restart this app.")
        }

        // Speech Recognition TCC permission is still required by SpeechAnalyzer.
        SFSpeechRecognizer.requestAuthorization { status in
            NSLog("SonarDictate: Speech auth status raw=\(status.rawValue)")
            guard status == .authorized else {
                NSLog("SonarDictate: Speech permission NOT authorized. Grant in System Settings → Privacy & Security → Speech Recognition.")
                return
            }
            DispatchQueue.main.async { self.installMonitor() }
        }
    }

    private func installMonitor() {
        NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self else { return }
            let nowDown = event.modifierFlags.contains(.option)
            if nowDown && !self.isOptionDown {
                self.isOptionDown = true
                NSLog("SonarDictate: Option DOWN — startListening")
                self.statusItem?.setListening(true)
                self.overlay?.show()
                self.startListening()
            } else if !nowDown && self.isOptionDown {
                self.isOptionDown = false
                NSLog("SonarDictate: Option UP — stopListening")
                self.statusItem?.setListening(false)
                self.overlay?.hide()
                self.stopListening()
            }
        }
        // Separate keyDown monitor for the double-space commit gesture. We
        // only ACT on it when the chip is showing pending text — so normal
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

            // ⌃⌥L → add the focused field to the selector.
            if ctrlOpt, event.keyCode == 37 {  // 37 = kVK_ANSI_L
                if let label = self.selector.addFocused() {
                    NSLog("SonarDictate: + target '\(label)' (selector now \(self.selector.count))")
                    self.highlighter?.update(targets: self.selector.targets)
                } else {
                    NSLog("SonarDictate: ⌃⌥L — focused element not editable / already in set")
                }
                return
            }
            // ⌃⌥K → wipe the selector.
            if ctrlOpt, event.keyCode == 40 {  // 40 = kVK_ANSI_K
                self.selector.wipe()
                self.highlighter?.clear()
                NSLog("SonarDictate: selector WIPED")
                return
            }
            // ⌃⌥⌫ → remove the last target.
            if ctrlOpt, event.keyCode == 51 {  // 51 = kVK_Delete
                self.selector.removeLast()
                self.highlighter?.update(targets: self.selector.targets)
                NSLog("SonarDictate: removed last target (selector now \(self.selector.count))")
                return
            }

            // Double-space → commit the chip into the focused field (only
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

        // Click-to-target: while ⌥ is held (dictating), a click adds the
        // editable field under the pointer to the selector. Observed via a
        // global mouse-down monitor; the click still does its normal thing in
        // the target app — we just also capture the field.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self, self.isOptionDown else { return }
            if let label = self.selector.addElement(atCocoaPoint: NSEvent.mouseLocation) {
                NSLog("SonarDictate: + target '\(label)' via click (selector now \(self.selector.count))")
                self.highlighter?.update(targets: self.selector.targets)
            }
        }

        NSLog("SonarDictate: Ready. Hold Option to talk, release to capture. Double-space to drop the chip into a field.")
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

    // Chip clicked -> copy its text to the clipboard, stashing whatever was there
    // so we can hand it back after the user pastes. Then dismiss the chip. This
    // is what frees the captured words from the chip when no field was focused.
    private func copyChipToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        clipboardStash = Self.snapshotPasteboard(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        stashChangeCount = pb.changeCount
        NSLog("SonarDictate: chip -> clipboard (\(text.count) chars); original stashed, armed for restore-on-paste")
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

        // Decide cleanup at session start (we know the focused app now). When a
        // cleanup app is focused, we suppress streaming entirely and inject a
        // single cleaned transcript on finalize. For everything else (default,
        // incl. all LLM clients) we stream raw as before.
        sessionNeedsCleanup = Cleanup.shouldClean(appContext: sessionAppContext)
        if sessionNeedsCleanup {
            NSLog("SonarDictate: cleanup mode ON for \(sessionAppContext ?? "?") — buffering, will clean on finalize")
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
        // comes first (curated + corrections — the signal that actually teaches
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
        // Remove any tap left over from a racy prior session before installing —
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

        // session.start(inputFormat:) is async — it negotiates the transcriber-
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
                    NSLog("SonarDictate: released before audio start finished — aborting session")
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
        session.stop()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        // The transcriber's results stream drains naturally after audio
        // input is finished; its final emission triggers finalize() via
        // handleTranscript(isFinal: true).
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
    //   .initial   — not enough signal yet (single-word partial, or empty)
    //   .buffering — first word matches a built-in trigger or a workflow
    //                binding prefix (longest-prefix wins for workflows)
    //   .streaming — first word is plain dictation; safe to stream
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
        // Leading built-in trigger ("yo"/"claude"/"note"/"todo") → buffer so we
        // don't live-type it. Otherwise stream from the very first word — waiting
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
        finalPersisted = true

        // Classify trigger (user-defined workflow bindings win over built-in triggers).
        let action = TriggerRouter.classify(transcript, workflowStore: workflows)
        NSLog("SonarDictate: classified -> \(action)")

        // Route the result:
        //   - plain dictation → commit (direct inject if a field is focused,
        //     else park in the draggable chip for later double-space commit)
        //   - workflow binding → fire it via automator, never inject text
        //   - other triggers (yo/claude/note/todo) → log for now
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
        DispatchQueue.global(qos: .utility).async { [store, rag] in
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

    // PCM buffer copy — the original buffer's storage is reused by the audio
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
        if sessionNeedsCleanup {
            Task { [weak self] in
                guard let self else { return }
                let cleaned = await self.cleanup.clean(trimmed)
                await MainActor.run { self.commit(cleaned) }
            }
        } else {
            commit(trimmed)
        }
    }

    // Routing priority:
    //   1. Selector has targets → broadcast to ALL of them.
    //   2. An editable field is focused → direct inject ("shoot for the stars").
    //   3. Otherwise → park in the draggable chip.
    private func commit(_ text: String) {
        if !selector.isEmpty {
            NSLog("SonarDictate: broadcasting \(text.count) chars to \(selector.count) target(s): \(selector.summary)")
            for target in selector.targets {
                broadcast(to: target, text: text)
            }
            return
        }
        if isEditableFieldFocused() {
            NSLog("SonarDictate: editable field focused -> direct inject")
            inject(text)
        } else {
            NSLog("SonarDictate: no editable field focused -> chip")
            chip?.present(text)
        }
    }

    // Deliver text to one selector target via the reliable keystroke path.
    //
    // We learned the hard way that AX value-set is silently ignored by Electron/
    // web inputs (Claude, ChatGPT, Cursor, web textareas) — React never sees the
    // change. So instead we do what a human does and what the single-field path
    // already proved fast: CLICK the exact point the user clicked (which focuses
    // the real input, even in Electron), let focus settle, then type. When there's
    // no click point (a ⌃⌥L focused-add), fall back to AX setFocused.
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
    // editable text control. Requires the Accessibility grant (which we already
    // need for keystroke injection).
    private func isEditableFieldFocused() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        if editableRoles.contains(role) { return true }

        // Fallback for web/Electron inputs that report odd roles: treat as
        // editable if the focused element's AXValue is settable.
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        return settable.boolValue
    }

    private func inject(_ text: String) {
        guard !text.isEmpty else { return }
        // Diagnostic: confirms inject is reached + whether we're trusted to
        // synthesize input. AXIsProcessTrusted() == false here means the
        // Accessibility grant (separate from Input Monitoring) is missing and
        // every post() below is silently dropped.
        NSLog("SonarDictate: inject \(text.count) chars (AXtrusted=\(AXIsProcessTrusted()))")

        let source = CGEventSource(stateID: .hidSystemState)
        for char in Array(text.utf16) {
            var ch = char
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            // CRITICAL: clear modifier flags. The user is physically holding
            // Option (our hotkey) while we stream-inject, so without this the
            // synthesized events become Option+<char> and produce dead keys /
            // nothing instead of the literal text.
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
    do {
        store = try SecureStore()
        workflows = try WorkflowStore()
        rag = try RAGIndex()
        dictionary = try DictionaryStore()
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
                    print("\(b.id)  \"\(b.triggerPhrase)\"  →  \(b.name)")
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
            print("bound \(b.id): \"\(b.triggerPhrase)\" → \(b.name)")
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
            print("running '\(binding.name)' (\(binding.workflowPath))…")
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

        // Personal dictionary — the learning substrate. Terms here bias the
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
                        let ctx = e.appContext.map { " · \($0)" } ?? ""
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

            dictionary (personalization — biases the recognizer to your words):
              dict                          list dictionary terms by weight
              dict add "<term>"             add/reinforce a term
              dict rm "<term>"              remove a term
              dict reset                    wipe the dictionary

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

// Mirror stderr (where NSLog also writes) to a readable plaintext log. The
// unified log redacts our interpolated NSLog messages as <private>, so
// `log show` is useless for our own diagnostics; redirecting fd 2 to
// ~/Library/Logs/SonarDictate.log captures every NSLog verbatim with zero
// per-call changes — the idiomatic macOS app log location, greppable by us.
let logPath = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/SonarDictate.log")
freopen(logPath, "a", stderr)
NSLog("SonarDictate: --- launch \(ISO8601DateFormatter().string(from: Date())) ---")

// No args → background dictation mode.
let store: SecureStore
let workflows: WorkflowStore
let rag: RAGIndex
let dictionary: DictionaryStore
do {
    store = try SecureStore()
    workflows = try WorkflowStore()
    rag = try RAGIndex()
    dictionary = try DictionaryStore()
} catch {
    NSLog("SonarDictate: failed to init stores: \(error)")
    exit(1)
}

if #available(macOS 26.0, *) {
    let dictator = Dictator(store: store, workflows: workflows, rag: rag, dictionary: dictionary)
    let statusItem = StatusItemController(store: store, workflows: workflows, rag: rag)
    let overlay = RecordingOverlay()
    let chip = TextChip()
    let highlighter = FieldHighlighter()
    dictator.statusItem = statusItem
    dictator.overlay = overlay
    dictator.chip = chip
    dictator.highlighter = highlighter
    // The widget is always-on - install it now so the user can position it
    // before the first dictation. It morphs between idle (small icon) and
    // listening (expanded with live transcript) as sessions come and go.
    overlay.install()
    dictator.bootstrap()
    NSApplication.shared.run()
} else {
    NSLog("SonarDictate requires macOS 26.0+ (SpeechAnalyzer is unavailable on this OS)")
    exit(1)
}
