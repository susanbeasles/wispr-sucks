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

    // Model enrichment - OFF the safety path. The owner/kind verdict above is
    // deterministic; this only fills topic/about/tags for recall. Best-effort.
    static func enrich(_ text: String) async -> EnrichedMeta {
        let prompt = """
        Classify the text into JSON metadata for search. Give a one-word-or-short \
        topic, the people/projects it is about, and 1-4 lowercase tags.
        Output ONLY JSON: {"topic":"...","about":["..."],"tags":["..."]}.
        Text: \(text)
        """
        guard let r = await IrisClient.complete(prompt) else { return .empty }
        return parseMeta(r)
    }

    // Deterministic parse of the enrichment JSON (testable; bounds the fields).
    static func parseMeta(_ raw: String) -> EnrichedMeta {
        guard let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"), s < e,
              let data = String(raw[s...e]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        let topicRaw = (obj["topic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = (topicRaw?.isEmpty ?? true) ? nil : topicRaw
        let about = ((obj["about"] as? [String]) ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tags = ((obj["tags"] as? [String]) ?? []).map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return EnrichedMeta(topic: topic, about: Array(about.prefix(6)), tags: Array(tags.prefix(6)))
    }
}

struct EnrichedMeta {
    let topic: String?
    let about: [String]
    let tags: [String]
    static let empty = EnrichedMeta(topic: nil, about: [], tags: [])
}
