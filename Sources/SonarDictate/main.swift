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

final class Dictator {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isOptionDown = false
    private var emittedText = ""

    // Persistence
    private let store: SecureStore
    private let workflows: WorkflowStore
    private let rag: RAGIndex
    private var audioFrames: [AVAudioPCMBuffer] = []
    private var sessionStart: Date?
    private var sessionFormat: AVAudioFormat?
    private var sessionAppContext: String?
    private var finalPersisted = false  // guard so we persist once per session

    init(store: SecureStore, workflows: WorkflowStore, rag: RAGIndex) {
        self.store = store
        self.workflows = workflows
        self.rag = rag
    }

    func bootstrap() {
        NSLog("SonarDictate: bootstrap()")

        guard recognizer.supportsOnDeviceRecognition else {
            NSLog("SonarDictate: on-device recognition NOT supported on this Mac")
            exit(1)
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
                self.startListening()
            } else if !nowDown && self.isOptionDown {
                self.isOptionDown = false
                NSLog("SonarDictate: Option UP — stopListening")
                self.stopListening()
            }
        }
        NSLog("SonarDictate: Ready. Focus any app, hold Option to talk, release to stop.")
    }

    private func startListening() {
        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true
        request?.requiresOnDeviceRecognition = true  // thesis line — never falls back to cloud
        emittedText = ""
        audioFrames.removeAll()
        sessionStart = Date()
        finalPersisted = false
        sessionAppContext = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Seed the recognizer with vocabulary biased toward what this user has
        // said recently in this app context. Costs ~5ms for a few-hundred-item
        // index; no-op when the RAG store is empty (first runs).
        if rag.assetsReady, rag.count > 0 {
            do {
                let bias = try rag.vocabularyBias(forContext: sessionAppContext, k: 8)
                if !bias.isEmpty {
                    request?.contextualStrings = bias
                    NSLog("SonarDictate: biased recognizer with \(bias.count) terms from RAG")
                }
            } catch {
                NSLog("SonarDictate: RAG bias skipped: \(error)")
            }
        }

        let format = engine.inputNode.outputFormat(forBus: 0)
        sessionFormat = format
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            if let copy = self?.copy(of: buffer) {
                self?.audioFrames.append(copy)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request!) { [weak self] result, error in
                guard let self else { return }
                if let error = error {
                    NSLog("SonarDictate: recognitionTask error: \(error.localizedDescription)")
                }
                guard let result = result else { return }
                let current = result.bestTranscription.formattedString

                if result.isFinal {
                    DispatchQueue.main.async {
                        self.streamEmit(target: current, isFinal: true)
                        self.finalize(transcript: current)
                    }
                } else {
                    // Hold back the trailing word — most likely to get revised.
                    let words = current.split(separator: " ", omittingEmptySubsequences: false)
                    guard words.count >= 2 else { return }
                    let stable = words.dropLast().joined(separator: " ") + " "
                    DispatchQueue.main.async { self.streamEmit(target: stable, isFinal: false) }
                }
            }
        } catch {
            NSLog("SonarDictate: audio start failed: \(error.localizedDescription)")
        }
    }

    private func stopListening() {
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // isFinal callback flushes the tail and triggers finalize().
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

        // If this was a user-defined workflow trigger, fire the workflow via
        // /usr/bin/automator. The streaming inject already typed the trigger
        // phrase into the focused app — backspace it now so the user doesn't
        // see "rotate cert" sitting in their editor after the workflow runs.
        if case let .runWorkflow(binding, input) = action {
            let toBackspace = emittedText.count
            emittedText = ""
            if toBackspace > 0 { backspace(count: toBackspace) }

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

let dictator = Dictator(store: store, workflows: workflows, rag: rag)
dictator.bootstrap()
NSApplication.shared.run()
