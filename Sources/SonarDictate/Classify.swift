import Foundation

// The classifier: every incoming item gets a Verdict before ingest. The Verdict
// drives routing (owner -> which seal), the brain (kind/salience), and recall
// (topic/about/tags). See .claude/plans/iris-sources-ingest.md.
//
// The OWNER rule IS the wall, and it has one job: fail toward protection. Owner
// starts from PROVENANCE (the source knows: a SonarMD-Slack message is company by
// origin). The content check may only ESCALATE personal -> company (more
// protection); it can NEVER relax company -> personal. A misclassification can
// only ever over-protect. Bleed is structurally impossible, not just unlikely.

struct Verdict {
    var kind: Salience.Kind
    var owner: DataOwner
    var topic: String?
    var about: [String]
    var tags: [String]
    var salience: Double
}

enum Classifier {
    // Deterministic sensitivity markers. Their PRESENCE escalates a personal-origin
    // item to company (the safe direction). Conservative substring match - it is
    // fine to over-escalate; it is never fine to under-protect.
    static let sensitiveMarkers: [String] = [
        // confidentiality
        "confidential", "internal only", "internal use", "do not share", "do not forward",
        "proprietary", "nda", "trade secret", "privileged",
        // healthcare / PHI cues
        "patient", "diagnosis", "mrn", "phi", "hipaa", "prescription", "medical record",
        // company identity / business ops
        "sonarmd", "sonar md", "roadmap", "cap table", "payroll", "acquisition", "term sheet",
    ]

    // The owner decision - provenance default, escalate-only. Company and brain are
    // sticky (never downgraded); personal escalates to company on a sensitive marker.
    static func owner(provenance: DataOwner, text: String) -> DataOwner {
        switch provenance {
        case .company, .brain:
            return provenance                        // sticky - never relaxed
        case .personal:
            return looksSensitive(text) ? .company : .personal
        }
    }

    static func looksSensitive(_ text: String) -> Bool {
        let t = text.lowercased()
        return sensitiveMarkers.contains { t.contains($0) }
    }

    // Lightweight, deterministic kind. A question asks; an action cues a to-do;
    // an observation is passive (eyes/screen); otherwise a fact.
    static func kind(_ text: String, source: String) -> Salience.Kind {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasSuffix("?") { return .question }
        if actionCues.contains(where: { t.contains($0) }) { return .action }
        if source == "eye" || source == "screen" { return .observation }
        return .fact
    }

    private static let actionCues: [String] = [
        "need to", "have to", "todo", "to-do", "to do", "must ", "should ",
        "remember to", "follow up", "follow-up", "let's ", "i'll ", "we'll ",
        "schedule", "send the", "set up", "don't forget",
    ]

    // The deterministic verdict (owner + kind + salience). topic/about/tags are
    // model-enriched separately (best-effort, off this safety-critical path).
    static func verdict(text: String, source: String, provenance: DataOwner) -> Verdict {
        let k = kind(text, source: source)
        return Verdict(
            kind: k,
            owner: owner(provenance: provenance, text: text),
            topic: nil,
            about: [],
            tags: [],
            salience: Salience.base(kind: k, age: 0)
        )
    }
}
