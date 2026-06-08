import Foundation
import AppKit
import ApplicationServices

// The learning loop. After we inject dictated text into a field, watch that
// field for ~60 seconds and capture what the user actually keeps. The diff
// between "what we typed" and "what they kept" is gold-labeled training data
// for the personal language model - the moat that no cloud tool can match,
// because it's THIS user's vocabulary and corrections, accumulating over time
// on this device.
//
// Coverage: AX reads of kAXValueAttribute are reliable on native macOS
// controls (TextEdit, Mail, Notes, Xcode, native fields generally) and
// flaky on Electron/web (Claude, Cursor, Slack, etc.) - the same gap we hit
// with isEditableFieldFocused(). Where the read works, we capture; where it
// doesn't, we log and skip. The corpus accumulates from the native captures
// and the model trains on whatever data we have.
//
// State machine:
//
//     [idle]
//       |
//       |  commit() inject -> armForNextRecording(element, text)
//       
//     [armed]    (waiting for persistSession to produce a recording_id)
//       |
//       |  persistSession -> linkRecording(id)
//       
//     [watching]  (60s timer running)
//       |
//       |  timer fires OR new injection arms again (preempt)
//       
//     captureCorrections()
//       reads AXValue, diffs, writes (raw, corrected) row + updates
//       recordings.corrected_text_enc; back to [idle].

final class EditWatcher {
    private let database: RecordingDatabase
    private let dictionary: DictionaryStore
    private let checkDelay: TimeInterval

    // Pending state: armed by commit(), waiting for a recording_id.
    private var pendingElement: AXUIElement?
    private var pendingInjectedText: String?

    // Active state: linked to a recording_id, timer scheduled.
    private var activeRecordingId: String?
    private var activeElement: AXUIElement?
    private var activeInjectedText: String?
    private var checkWorkItem: DispatchWorkItem?

    // Serial queue protects the state transitions; the actual AX read + DB
    // write happen on the work item's main-queue execution.
    private let queue = DispatchQueue(label: "sonar-dictate.edit-watcher")

    init(database: RecordingDatabase, dictionary: DictionaryStore, checkDelaySeconds: TimeInterval = 60) {
        self.database = database
        self.dictionary = dictionary
        self.checkDelay = checkDelaySeconds
    }

    // Called from commit() right after inject lands keystrokes. We don't yet
    // know the recording_id (persistSession generates it shortly after). We
    // stash the element + text and wait for linkRecording. If a previous watch
    // was still active, capture its corrections now before being replaced.
    func armForNextRecording(focusedElement: AXUIElement?, injectedText: String) {
        queue.sync {
            if activeRecordingId != nil {
                _captureNowLocked(reason: "preempted by new injection")
            }
            pendingElement = focusedElement
            pendingInjectedText = injectedText
            if focusedElement == nil {
                NSLog("SonarDictate: edit-watcher armed with NO focused element (will skip capture)")
            } else {
                NSLog("SonarDictate: edit-watcher armed (\(injectedText.count) chars), waiting for recording id")
            }
        }
    }

    // Called from persistSession once SecureStore has produced a UUID. Promotes
    // the pending arm to an active watch and schedules the 60s capture.
    func linkRecording(_ recordingId: String) {
        queue.sync {
            guard let element = pendingElement, let text = pendingInjectedText else {
                pendingElement = nil
                pendingInjectedText = nil
                return
            }
            activeRecordingId = recordingId
            activeElement = element
            activeInjectedText = text
            pendingElement = nil
            pendingInjectedText = nil

            let work = DispatchWorkItem { [weak self] in
                self?.queue.sync { self?._captureNowLocked(reason: "timer expired") }
            }
            checkWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay, execute: work)
            NSLog("SonarDictate: edit-watcher linked to \(recordingId), will capture in \(Int(checkDelay))s")
        }
    }

    // Force-capture immediately (e.g., on app shutdown). Public so the caller
    // can flush before exit.
    func flush() {
        queue.sync { _captureNowLocked(reason: "explicit flush") }
    }

    // MARK: - Internals (run on `queue`)

    private func _captureNowLocked(reason: String) {
        defer {
            activeRecordingId = nil
            activeElement = nil
            activeInjectedText = nil
            checkWorkItem?.cancel()
            checkWorkItem = nil
        }
        guard let id = activeRecordingId,
              let element = activeElement,
              let original = activeInjectedText else {
            return
        }

        // Read the focused field's current value via AX. May fail for
        // Electron/web inputs - that's fine, we just skip those.
        var valueRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        guard err == .success, let current = valueRef as? String else {
            NSLog("SonarDictate: edit-watcher cannot read AXValue (err=\(err.rawValue)) for \(id) [\(reason)] - no correction captured")
            return
        }

        // No edits: the field still contains exactly what we typed (or includes
        // it as a substring with no surrounding edits). Skip writing a no-op
        // correction row.
        if current == original || (current.contains(original) && current.count == original.count) {
            NSLog("SonarDictate: edit-watcher: no edits for \(id) [\(reason)]")
            return
        }

        // Capture the pair verbatim. Word-level segmentation happens at
        // training time (when the corpus actually feeds SFCustomLanguageModel
        // Data); here we just store the source-of-truth raw + corrected pair.
        do {
            try database.addCorrection(
                recordingId: id,
                rawPhrase: original,
                correctedPhrase: current
            )
            try database.updateCorrectedText(recordingId: id, correctedText: current)
            NSLog("SonarDictate: edit-watcher captured correction for \(id) [\(reason)] -> \(current.count) chars final")

            // Close the loop: promote the corrected/added words into the weighted
            // dictionary so the NEXT session's recognizer is biased toward them.
            // Length-gated inside learnableTerms so a big target document does not
            // dump its whole vocabulary in. Count-only logging (terms may be PHI).
            let learned = Self.learnableTerms(original: original, corrected: current)
            for term in learned {
                dictionary.add(term, weight: 3, source: .correction)
            }
            if !learned.isEmpty {
                NSLog("SonarDictate: edit-watcher learned \(learned.count) term(s) into the dictionary for \(id)")
            }
        } catch {
            NSLog("SonarDictate: edit-watcher write failed for \(id): \(error)")
        }
    }

    // MARK: - Learning

    // Words present in `corrected` but absent from `original` - the terms the
    // user typed that we failed to dictate, i.e. the highest-value teaching
    // signal. Gated so a large target document (field >> our text) does not pour
    // its whole vocabulary in. Original casing is preserved (jargon casing
    // matters: Kubernetes, SonarMD). Deduped case-insensitively.
    static func learnableTerms(original: String, corrected: String) -> [String] {
        guard !corrected.isEmpty else { return [] }
        // Only when the field is mostly our dictated text, lightly edited.
        guard corrected.count <= original.count * 2 + 40 else { return [] }

        let originalSet = Set(tokens(in: original).map { $0.lowercased() })
        var seen = Set<String>()
        var result: [String] = []
        for token in tokens(in: corrected) {
            if token.count < 2 { continue }
            let lower = token.lowercased()
            if originalSet.contains(lower) { continue }   // already dictated correctly
            if stopwords.contains(lower) { continue }
            if seen.contains(lower) { continue }
            seen.insert(lower)
            result.append(token)
        }
        return result
    }

    // Word tokens: runs of letters/digits/apostrophe; everything else separates.
    // Apostrophe is kept so contractions stay whole.
    private static func tokens(in s: String) -> [String] {
        var current = ""
        var out: [String] = []
        for ch in s {
            if ch.isLetter || ch.isNumber || ch == "'" {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    // Trivial words that carry no teaching value if "added"; never worth biasing.
    private static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "to", "of", "in", "on", "at", "for",
        "is", "it", "this", "that", "these", "those", "i", "you", "he", "she",
        "we", "they", "my", "your", "his", "her", "our", "their", "be", "do",
        "so", "if", "as", "by", "up", "no", "yes", "ok", "okay", "with", "was",
        "are", "not", "just", "like", "have", "has", "had", "will", "can",
    ]
}
