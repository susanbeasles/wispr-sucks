# Iris sources + ingest pipeline

Status: in progress. 2026-06-20. Branch: feat/the-eyes (susanbeasles).
Builds on: iris-sealed-ledger-offsite.md (the ledger) + iris-signals-classify-rank.md.

## Ownership first (the correction)

IRIS BELONGS TO SUSAN. THE DATA DOES NOT. Iris-the-entity (model, voice, brain-
software) is the owner's, personal. The data inside company services (Outlook,
Teams, OneDrive, Office, Zoom, the SonarMD Slack) is SONAR's asset - not Susan's.
Piping Sonar-owned data into a Susan-owned personal Iris = company data in a
personally-owned system. That is the "bleed/corruption" to prevent.

The model: the SAME Iris can be POWERED BY data she does not OWN. When she touches
company data, that data and anything derived close to it stays in the WORK brain,
on WORK infra, Sonar's - it never replicates, never bleeds, never becomes
personal-side bytes. The entity is Susan's; the data is Sonar's; the wall is
structural, not a promise.

DROPPED (company-owned, out of scope - they were the wrong hoses):
- Zoom, Outlook, Teams, OneDrive, Office. No connectors. Not into her brain.

The pipeline below is still ONE pipeline (a source is one normalize-to-SourceItem
adapter, never a per-service workflow), but NO company-owned source feeds the
personal brain. In-scope sources + their jurisdiction = TBD with the owner; any
company-owned source is work-only, work-infra-only, and may at most yield
abstracted LEARNINGS - never raw - and even those are conservative when derived
from Sonar data.

## Gates (do not bypass)

1. AUTH via Agora/op. Every connector's OAuth/creds flow through Agora; never
   hardcoded, never logged. (Agora MCP dropped this session - real connectors
   wait on it; the spine does not.)
2. SCRUBBER mandatory in front. No external source persists a byte un-scrubbed
   (phi-mask). The pipeline REQUIRES a scrubber; there is no passthrough in prod.
3. Work raw never routes to a personal target (enforced downstream by the ledger
   replication adapter, not by convention).

## The primitive

SourceItem - the normalized unit every connector emits:
  { source, externalId, at, author?, title?, text, threadId?, jurisdictionHint }
Source - the adapter interface:
  id, defaultJurisdiction, fetch(since cursor) -> (items, nextCursor)
Ingest - the one pipeline (reused by all sources):
  for each item: scrub(text) -> classify(kind, topic, jurisdiction) ->
  [embed] -> persist to SealedLedger(jurisdiction) [+ memory]

## Build order (smallest testable slice first)

1. SOURCE PRIMITIVE + INGEST SPINE: SourceItem, Source, Scrubber (protocol;
   prod = phi-mask), and Ingest that pulls a Source, scrubs, routes by
   jurisdiction, and persists to the per-jurisdiction SealedLedger. Test with a
   FAKE source emitting work + personal items + an identity scrubber; assert each
   lands in the correct chain and both verify. (No external auth, no cloud.)
2. CLASSIFY + JURISDICTION REFINEMENT: fold jurisdiction into the classify pass
   (Apple/IrisClient), so a work-workspace personal DM can be re-routed. Embed +
   memory integration so ingested items are recallable.
3. CONNECTORS (only after scope + ownership are settled with the owner; one at a
   time, behind Source, creds via Agora). NO company-owned source into the
   personal brain. Each is a thin normalize-to-SourceItem adapter. In-scope set
   TBD.
4. CURSORS + INCREMENTAL SYNC: persist per-source cursors so each fetch pulls only
   what is new; idempotent on externalId (no double-ingest).

## PROGRESS

2026-06-21: classifier + ingest spine - DONE, builds clean, 21/21 tests pass.
- Classify.swift: Verdict {kind, owner, topic, about, tags, salience} + Classifier.
  OWNER rule = provenance-first, fail-toward-protection: company/brain sticky
  (never relaxed), personal escalates to company on a deterministic sensitive
  marker. kind = lightweight heuristic (?, action cues, eye->observation, else
  fact). salience reuses Salience.base.
- Ingest.swift: SourceItem + Scrubber (mandatory, no default; IdentityScrubber is
  a test double, prod = phi-mask) + Ingest.ingest = scrub -> classify -> route to
  Ledgers by owner. One pipeline, all sources.
- Verified: owner asymmetry (company never downgraded even on "private diary";
  personal+PHI/confidential escalates), kind heuristic, end-to-end NO-BLEED -
  a sensitive personal item lands in company and is absent from personal.
2026-06-21: learning loop - DONE, builds clean, 8/8 tests pass.
- LearningDeriver made async; ModelLearningDeriver.swift asks the local model to
  abstract a record into learnings (best-effort, [] on failure - never leaks raw).
- Ingest.learn = derive -> LearningGate.admit -> append admitted to the ONE brain
  chain (owner=.brain, recoverable). Learnings from BOTH personal and company raw
  are Susan's and land in the brain; raw stays in its owner-sealed chain.
- Verified: only abstractions admitted; company raw stays company-sealed; NO raw
  company text ("confidential...") reaches the brain; the abstraction does.
- NEXT: model enrichment (topic/about/tags via IrisClient/Apple, off the safety
  path); the Source adapter (fetch/cursor) for real connectors; wire ingest+learn
  into the live app (senses/chat -> ingest).

## Notes

- Any company-owned source (if any are in scope at all) runs work-only, work-infra
  only, raw never leaves Sonar control; the personal brain only ever sees
  abstracted learnings, conservatively.
- Runtime: connectors may run in-app or via a sidecar that holds Agora creds and
  feeds the app over the locked socket (see the sealed-ledger threat model). TBD.
