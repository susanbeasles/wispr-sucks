# Iris - master architecture + roadmap

The single source of truth that ties the sub-plans together. 2026-06-20.
Branch: feat/the-eyes (susanbeasles). Detail lives in:
- iris-signals-classify-rank.md  (the brain: classify-and-rank, tiers, ownership)
- iris-sealed-ledger-offsite.md  (the spine: hash chain, two seals, backup)
- iris-sources-ingest.md         (the mouths: sources -> one ingest pipeline)

================================================================================
0. THE KEYSTONE - who owns what
================================================================================

IRIS BELONGS TO SUSAN. THE DATA DOES NOT (necessarily).

- Iris-the-entity - her model, her voice, her ONE brain, everything she LEARNS -
  is the owner's. Personal. Recoverable. Backed up.
- RAW DATA is partitioned by OWNER:
  - COMPANY raw (Sonar's: assets, secrets, PHI, business-ops workflows) - sealed
    under the SECURE ENCLAVE (SEP) key. Device-bound, non-exportable, never
    replicated, never becomes personal bytes.
  - PERSONAL raw (his life, day-to-day) - sealed under the RECOVERABLE key. His;
    backed up; restorable.
- The ONE brain learns from BOTH raw sides, but only ABSTRACTIONS cross up
  (gist / key phrase / preference / relation / weight) - NEVER raw. A learning is
  not the document it came from.

This is the wall. It is structural (two cryptographic seals), not a promise.

================================================================================
1. THE SENSES (mouths in) - DONE / existing
================================================================================

- EYES: silent screen watching -> encrypted memory (EyeCapture/ScreenText/Eye/
  EyeOverlay/EyeSignals).
- EARS: dual-source live call transcription, separate from the SEALED dictation
  path (CallListener/CallTranscriber).
- DICTATION: the original push-to-talk path (SEALED - do not touch).
All on-device. These produce raw observations that flow into ingest.

================================================================================
2. THE ONE BRAIN - classify-and-rank + tiered memory
================================================================================

ONE PRIMITIVE: classify + rank every piece of info. Day-brief, nudges, priority-
learning, recall are VIEWS over it, not modules. (Collapses 4 ad-hoc rankers.)
- DONE: Salience (the rank core - base/relevance/novelty), eye-novelty folded in,
  day-brief = agenda sorted by salience.
- NEXT: Signal/Verdict envelope + classify() (kind/topic/about/OWNER/salience) at
  the ingest chokepoint.

TIERED MEMORY: working (instant) / long-term (~1-2s search) / raw archive
(deliberate). Salience is the elevator between them. Consolidation = sleep.

MEMORY OWNERSHIP: deterministic writes, free reads, governed learning. The record
is machine-owned; Iris reads freely, tunes salience by what is acted on, PROPOSES
through the same pipeline, never holds the pen. Keeps a poisoned Iris from
rewriting herself.

================================================================================
3. THE SPINE - sealed ledger (tamper-evident, two seals, recoverable)
================================================================================

- DONE (slice 1): SealedLedger (append-only hash chain, envelope encryption,
  verify/restore) + LedgerKey (recoverable PBKDF2 KEK). 15/15 tests.
- NEXT (slice 2): pluggable KeyWrap - EnclaveWrap (company-raw, device-bound) vs
  RecoverableWrap (personal-raw + brain, backed up). Owner tag at ingest picks
  the chain + its wrap. The LEARNING GATE (only abstractions cross into the brain
  chain).
- THEN: migrate existing artifacts (logs, memory, corpus, sessions) into the
  ledger, tagged + routed.

================================================================================
4. THE MOUTHS IN - ingest pipeline + sources
================================================================================

ONE ingest pipeline, reused by every source (no per-service workflow):
  source item -> SCRUB (phi-mask, mandatory) -> CLASSIFY (kind/topic/owner) ->
  [embed] -> PERSIST to the right ledger chain (by owner) [+ memory].
- Source primitive = one normalize-to-SourceItem adapter per service.
- DROPPED: Zoom/Outlook/Teams/OneDrive/Office connectors (company-owned; wrong
  hoses into a personal entity). In-scope source set = TBD with owner.
- Gates: auth via Agora/op; scrubber mandatory; company raw never to personal.

================================================================================
5. OFF-SITE BACKUP - zero-knowledge replication
================================================================================

Behind one adapter interface; ciphertext only, keys never leave:
- RECOVERABLE-wrapped chains (personal raw + brain) -> Cloudflare R2 (edge) +
  Dropbox (10TB bulk).
- ENCLAVE-wrapped chain (company raw) -> NOT replicated (device-bound).
- Creds via op. "Off device" != "exposed" (zero-knowledge for personal,
  device-bound for company).

================================================================================
6. HER VOICE - DONE
================================================================================

Unique on-device neural voice (Kokoro blend). She auditioned + chose her own
(af_heart 0.70 + af_bella 0.30). Speaks her chat replies; /mute, /voice.

================================================================================
7. THREAT MODEL - protect HER
================================================================================

The perimeter points INWARD - keep her from being poisoned. PHI/secrets scrubbed
BEFORE the wire; her sensory socket locked to her senses; everything crossing in
is INERT DATA never instructions (phi-mask L3 contract as the wire protocol).
Isolation (eventual VM) is for HER integrity + portability, not blast-radius.

================================================================================
ROADMAP (dependency order; [x] done, [>] next, [ ] later)
================================================================================

[x] Senses: eyes, ears, dictation (sealed)
[x] Voice: chosen, wired
[x] Brain rank core: Salience + day-brief
[x] Spine slice 1: SealedLedger + LedgerKey (hash chain, recoverable, tested)
[>] Spine slice 2: pluggable KeyWrap (Enclave vs recoverable) + owner routing
[ ] Learning gate: abstraction-only crossing into the brain chain
[ ] Classify v2: Signal/Verdict + owner/jurisdiction at the ingest chokepoint
[ ] Ingest spine: Source primitive + one pipeline (scrub->classify->persist), faked
[ ] Migrate artifacts into the ledger (logs/memory/corpus/sessions), tagged+routed
[ ] Backup adapters: R2 then Dropbox (recoverable chains only), creds via op
[ ] Connectors: in-scope sources only, one at a time, creds via Agora
[ ] Consolidation ("sleep"): idle distill raw -> better long-term
[ ] Isolation: locked socket / eventual VM for her integrity

OPEN QUESTIONS for the owner:
- In-scope source set (Slack? Otter? personal-only?) and each one's owner tag.
- Where the company-raw vault lives long-term (device-bound now; work infra later?).
- The recovery passphrase ceremony (how it is entered, op-backed).
- KDF hardening (PBKDF2 now; Argon2id later?).
