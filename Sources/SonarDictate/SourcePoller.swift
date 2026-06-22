import Foundation

// Polls any Source on an interval and runs its new items through the ingest
// pipeline, persisting the cursor so each pass only sees what is new. ONE poller
// for every source - Messages, the drop folder, future connectors - no per-source
// loop. Uses the sync deterministic Ingest (bulk sources must not hammer the local
// model); the scrubber still gates PHI on every item.
enum SourcePoller {
    @discardableResult
    static func start(_ source: Source, cursorFile: URL, into ledgers: Ledgers,
                      scrub: Scrubber, intervalSec: TimeInterval, limit: Int = 200) -> Timer {
        let poll = {
            DispatchQueue.global(qos: .utility).async {
                let cursor = try? String(contentsOf: cursorFile, encoding: .utf8)
                guard let result = try? source.fetch(since: cursor, limit: limit) else { return }
                // Scrub the whole batch in ONE pass (the gate runs here), then seal
                // the pre-scrubbed items (IdentityScrubber = already clean, not a
                // bypass). One python process for the batch, not one per item.
                let cleaned = scrub.scrubBatch(result.items.map { $0.text })
                let identity = IdentityScrubber()
                for (item, clean) in zip(result.items, cleaned) {
                    let scrubbed = SourceItem(source: item.source, provenance: item.provenance,
                                              at: item.at, text: clean, externalId: item.externalId)
                    _ = try? Ingest.ingest(scrubbed, scrub: identity, into: ledgers)
                }
                if !result.items.isEmpty, let next = result.next {
                    try? next.write(to: cursorFile, atomically: true, encoding: .utf8)
                    NSLog("SonarDictate: \(source.id) ingested \(result.items.count) item(s)")
                }
            }
        }
        poll()
        let timer = Timer(timeInterval: intervalSec, repeats: true) { _ in poll() }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
