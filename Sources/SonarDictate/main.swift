import Foundation
import AVFoundation
import Speech
import AppKit

// On-device voice-to-text spike.
//
// Behavior:
//   - Press and hold the Option key to talk; release to stop.
//   - Stable phrases stream into the focused app as you speak.
//   - On revision, characters are backspaced and corrected.
//   - 100% on-device: `requiresOnDeviceRecognition = true`.
//
// Permissions on first run (System Settings → Privacy & Security):
//   - Microphone (Terminal or whatever runs this)
//   - Speech Recognition (Terminal)
//   - Accessibility (Terminal) — required for global hotkey + keystroke injection
//
// macOS 26+: migrate to SpeechAnalyzer + SpeechTranscriber for faster partial
// cadence and explicit volatile/stable result types. This SFSpeechRecognizer
// version is the proven-compatible baseline.

class Dictator {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))!
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var isOptionDown = false
    private var emittedText = ""

    func bootstrap() {
        guard recognizer.supportsOnDeviceRecognition else {
            print("On-device recognition not supported on this Mac.")
            exit(1)
        }
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                print("Speech permission denied. Grant in System Settings → Privacy & Security → Speech Recognition.")
                exit(1)
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
                self.startListening()
            } else if !nowDown && self.isOptionDown {
                self.isOptionDown = false
                self.stopListening()
            }
        }
        print("Ready. Focus any app, hold Option to talk, release to stop.")
    }

    private func startListening() {
        request = SFSpeechAudioBufferRecognitionRequest()
        request?.shouldReportPartialResults = true
        request?.requiresOnDeviceRecognition = true  // thesis line — never falls back to cloud
        emittedText = ""

        let format = engine.inputNode.outputFormat(forBus: 0)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
            task = recognizer.recognitionTask(with: request!) { [weak self] result, _ in
                guard let self, let result = result else { return }
                let current = result.bestTranscription.formattedString

                if result.isFinal {
                    DispatchQueue.main.async { self.streamEmit(target: current) }
                } else {
                    // Hold back the trailing word — most likely to get revised.
                    let words = current.split(separator: " ", omittingEmptySubsequences: false)
                    guard words.count >= 2 else { return }
                    let stable = words.dropLast().joined(separator: " ") + " "
                    DispatchQueue.main.async { self.streamEmit(target: stable) }
                }
            }
        } catch {
            print("Audio start failed: \(error)")
        }
    }

    private func stopListening() {
        request?.endAudio()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // The isFinal callback flushes the tail; task/request will be GC'd on next startListening().
    }

    private func streamEmit(target: String) {
        if target.hasPrefix(emittedText) {
            // Forward extension — inject the new suffix.
            let delta = String(target.dropFirst(emittedText.count))
            if !delta.isEmpty {
                inject(delta)
                emittedText = target
            }
        } else if emittedText.hasPrefix(target) {
            // Revision shrinks the text — backspace to match.
            backspace(count: emittedText.count - target.count)
            emittedText = target
        } else {
            // Mid-string revision — nuke and reinject.
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

let dictator = Dictator()
dictator.bootstrap()
NSApplication.shared.run()
