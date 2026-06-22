import Foundation

// The real learning deriver: asks the local model to abstract a record into
// durable learnings (gist / key phrase / preference / relation). It only
// PROPOSES - LearningGate enforces that nothing raw crosses, so even if the model
// echoes source text, the gate drops it. Best-effort: returns [] on any failure
// (model down, bad JSON), so the loop degrades to "no learning this time", never
// to leaking raw.
struct ModelLearningDeriver: LearningDeriver {
    func learnings(from record: TaggedRecord) async -> [Learning] {
        let prompt = """
        Abstract the text below into 0 to 4 LEARNINGS - durable, reusable knowledge, \
        NOT a copy of the text. Each is one of: gist (a one-line summary), keyPhrase \
        (a salient term), preference (something the user likes or does), relation \
        (X relates to Y). Keep each under 120 characters and do NOT quote the text \
        verbatim.
        Output ONLY JSON: [{"kind":"gist","text":"...","about":["..."]}]. If nothing \
        is worth keeping, output [].
        Text: \(record.text)
        """
        guard let r = await IrisClient.complete(prompt),
              let start = r.firstIndex(of: "["), let end = r.lastIndex(of: "]"), start < end,
              let data = String(r[start...end]).data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var out: [Learning] = []
        for obj in arr {
            guard let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { continue }
            let kind = LearningKind(rawValue: obj["kind"] as? String ?? "") ?? .gist
            let about = (obj["about"] as? [String])?.filter { !$0.isEmpty } ?? []
            // sourceOwner is provenance (where it was learned), NOT the data - all
            // admitted learnings are Susan's and land in the brain chain.
            out.append(Learning(kind: kind, text: text, about: about, sourceOwner: record.owner))
            if out.count >= 4 { break }
        }
        return out
    }
}
