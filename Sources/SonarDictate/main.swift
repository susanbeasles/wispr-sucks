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

    // Persistence
    private let store: SecureStore
    private let workflows: WorkflowStore
    private let rag: RAGIndex
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

    // Optional on-device Foundation Models cleanup pass (opt-in per app).
    private let cleanup = Cleanup()
    private var sessionNeedsCleanup = false

    init(store: SecureStore, workflows: WorkflowStore, rag: RAGIndex) {
        self.store = store
        self.workflows = workflows
        self.rag = rag
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
        NSLog("SonarDictate: Ready. Focus any app, hold Option to talk, release to stop.")
    }

    private func startListening() {
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

        // Seed the recognizer with vocabulary biased toward what this user has
        // said recently in this app context. SpeechAnalyzer's AnalysisContext
        // takes a tagged-string map; we feed it via session.setContextualStrings().
        if rag.assetsReady, rag.count > 0 {
            do {
                let bias = try rag.vocabularyBias(forContext: sessionAppContext, k: 8)
                session.setContextualStrings(bias)
                if !bias.isEmpty {
                    NSLog("SonarDictate: biased recognizer with \(bias.count) terms from RAG")
                }
            } catch {
                NSLog("SonarDictate: RAG bias skipped: \(error)")
            }
        } else {
            session.setContextualStrings([])  // clear stale bias from previous session
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        sessionFormat = format
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
                self.engine.prepare()
                try self.engine.start()
            } catch {
                NSLog("SonarDictate: audio start failed: \(error.localizedDescription)")
            }
        }
    }

    private func stopListening() {
        session.stop()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // The transcriber's results stream drains naturally after audio
        // input is finished; its final emission triggers finalize() via
        // handleTranscript(isFinal: true).
    }

    // Called from the SpeechAnalyzer session's onTranscriptUpdate callback,
    // marshalled onto the main thread. Decides session mode (streaming vs
    // buffering for trigger detection), streams stable text into the
    // focused app, and on isFinal=true triggers finalize().
    private func handleTranscript(_ current: String, isFinal: Bool) {
        // Update the floating overlay so the user can see what's being
        // transcribed in real time, regardless of mode.
        overlay?.updateTranscript(current)

        // Cleanup mode: never stream. Buffer silently, then on finalize run the
        // Foundation Models cleanup pass and inject the polished transcript in
        // one shot. (The overlay still shows live text above, so the user sees
        // recognition happening even though nothing is typed yet.)
        if sessionNeedsCleanup {
            overlay?.setBufferingMode(true)
            if isFinal {
                let raw = current
                Task { [weak self] in
                    guard let self else { return }
                    let cleaned = await self.cleanup.clean(raw)
                    await MainActor.run { self.inject(cleaned) }
                }
                finalize(transcript: current)
            }
            return
        }

        if isFinal {
            if sessionMode == .initial {
                let decided = decideMode(from: current)
                sessionMode = decided == .initial ? .streaming : decided
                NSLog("SonarDictate: session mode -> \(sessionMode.rawValue) (on isFinal)")
                overlay?.setBufferingMode(sessionMode == .buffering)
            }
            if sessionMode == .streaming {
                streamEmit(target: current, isFinal: true)
            }
            finalize(transcript: current)
        } else {
            if sessionMode == .initial {
                let decided = decideMode(from: current)
                if decided != .initial {
                    sessionMode = decided
                    NSLog("SonarDictate: session mode -> \(decided.rawValue) (on partial: \(current.prefix(40)))")
                    overlay?.setBufferingMode(decided == .buffering)
                }
            }
            guard sessionMode == .streaming else { return }
            // SpeechAnalyzer's progressiveTranscription gives us stable
            // text per chunk — no need for our manual word-holdback that
            // SFSpeechRecognizer required. streamEmit's diff logic still
            // handles any revisions via backspace.
            streamEmit(target: current, isFinal: false)
        }
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
        // Need at least 2 words for a stable first-word decision in partial
        // mode; the isFinal handler relaxes this and defaults to streaming.
        guard words.count >= 2 else { return .initial }

        let first = String(words[0])
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters)
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

        let duration = sessionStart.map { -$0.timeIntervalSinceNow } ?? 0
        let appCtx = sessionAppContext
        let frames = audioFrames
        let format = sessionFormat
        audioFrames.removeAll()

        // Classify trigger (user-defined workflow bindings win over built-in triggers).
        let action = TriggerRouter.classify(transcript, workflowStore: workflows)
        NSLog("SonarDictate: classified -> \(action)")

        // Backspace any streamed text if classification said this turned out
        // to be a trigger (not plain dictation). In buffering mode nothing
        // was typed, so this is a no-op. In streaming mode we erase what we
        // emitted so the focused app doesn't keep the trigger phrase.
        let isTriggerAction: Bool = {
            switch action {
            case .dictate: return false
            default:       return true
            }
        }()
        if isTriggerAction && sessionMode == .streaming && !emittedText.isEmpty {
            let toBackspace = emittedText.count
            emittedText = ""
            backspace(count: toBackspace)
        }

        // Fire any workflow binding asynchronously so we don't block this
        // method on /usr/bin/automator. Other action types (yo, claude, etc)
        // currently just log — real handlers come later.
        if case let .runWorkflow(binding, input) = action {
            let store = self.workflows
            Task.detached(priority: .userInitiated) {
                do {
                    let code = try store.execute(binding, input: input.isEmpty ? nil : input)
                    NSLog("SonarDictate: workflow '\(binding.name)' exited \(code)")
                } catch {
                    NSLog("SonarDictate: workflow '\(binding.name)' failed: \(error)")
                }
            }
        }

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

    private func streamEmit(target: String, isFinal: Bool) {
        if target.hasPrefix(emittedText) {
            let delta = String(target.dropFirst(emittedText.count))
            if !delta.isEmpty {
                inject(delta)
                emittedText = target
            }
        } else if emittedText.hasPrefix(target) {
            backspace(count: emittedText.count - target.count)
            emittedText = target
        } else {
            backspace(count: emittedText.count)
            inject(target)
            emittedText = target
        }
    }

    private func inject(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for char in Array(text.utf16) {
            var ch = char
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &ch)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func backspace(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let deleteKey: CGKeyCode = 0x33  // kVK_Delete (backspace)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true)
            let up = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false)
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
    do {
        store = try SecureStore()
        workflows = try WorkflowStore()
        rag = try RAGIndex()
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

// No args → background dictation mode.
let store: SecureStore
let workflows: WorkflowStore
let rag: RAGIndex
do {
    store = try SecureStore()
    workflows = try WorkflowStore()
    rag = try RAGIndex()
} catch {
    NSLog("SonarDictate: failed to init stores: \(error)")
    exit(1)
}

if #available(macOS 26.0, *) {
    let dictator = Dictator(store: store, workflows: workflows, rag: rag)
    let statusItem = StatusItemController(store: store, workflows: workflows, rag: rag)
    let overlay = RecordingOverlay()
    dictator.statusItem = statusItem
    dictator.overlay = overlay
    dictator.bootstrap()
    NSApplication.shared.run()
} else {
    NSLog("SonarDictate requires macOS 26.0+ (SpeechAnalyzer is unavailable on this OS)")
    exit(1)
}
