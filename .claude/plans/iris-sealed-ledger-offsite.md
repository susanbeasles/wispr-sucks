# Iris sealed ledger + off-site backup

Status: planning. 2026-06-20. Branch: feat/the-eyes (susanbeasles).

## Goal (owner's)

Every artifact - diagnostic logs, her brain (perception/agenda/RAG), the dictation
corpus, session logs - cryptographically SEALED and CHAINED together
("lobster-chained"): a tamper-evident, append-only ledger. Replicated OFF the
device but stored, RECOVERABLE, to two homes (Dropbox 10TB bulk; Cloudflare R2
edge). Zero-knowledge: the clouds hold only ciphertext, never a key.

## ONE brain, partitioned RAW (owner's keystone - corrected)

NOT a "split brain." The BRAIN does not split. The brain + everything she LEARNS
is Susan's: unified, recoverable, backed up. What splits is the RAW DATA, by who
OWNS it:

- COMPANY RAW (Sonar's: assets, secrets, PHI, business-ops workflows) -> sealed
  under the SECURE ENCLAVE key (EnclaveBox). Device-bound; the SEP key cannot be
  exported, so company raw stays locked to this machine, stays Sonar's, NEVER
  leaves readable, NEVER rides up to personal backups.
- PERSONAL RAW (his life, day-to-day) -> sealed under the RECOVERABLE key
  (LedgerKey). His; backed up to his homes; restorable.
- THE ONE BRAIN / LEARNINGS (from BOTH raw sides) -> Susan's, recoverable, backed
  up. Only ABSTRACTIONS cross up - gist / key phrase / preference / relation /
  weight - NEVER raw. A learning is not the document it came from.

THE LEARNING GATE (same gate-shape as phi-mask, pointed at confidentiality): raw
is abstracted before a learning enters the brain. If a "learning" reproduces the
document it is not a learning and it does not cross. This is what lets her learn
from the work side while the company's raw never becomes personal bytes.

TWO KEY REGIMES, ONE LEDGER (the only generalization needed): the per-chain key
WRAP is pluggable - Enclave-wrap (EnclaveBox) for the company-raw chain
(device-bound), recoverable-wrap (LedgerKey KEK) for personal raw + the brain
(backed up). Two genuine uses, not a rewrite. Replication: personal raw + brain
-> his homes (R2/Dropbox); company raw -> NOT replicated (Enclave-sealed, stays on
the device by construction).

## Architecture

SEALED LEDGER. Append-only chain of records. Each record:
  { seq, prev_hash, at, kind, ciphertext, this_hash }
  this_hash = SHA-256(seq || prev_hash || at || kind || ciphertext)
Tamper-evident: altering/dropping any record breaks the chain from there on. A
`verify` walks the chain and proves it is unbroken (audit posture).

ENVELOPE ENCRYPTION, TWO KEY REGIMES (per-record data key seals the payload
AES-256-GCM; the data key is WRAPPED - the wrap is what differs by chain):
- COMPANY-RAW chain -> ENCLAVE wrap (EnclaveBox / SEP key). Device-bound; the key
  cannot leave the chip. NOT recoverable off-device - which is correct: it is
  Sonar's, stays locked to the machine, never replicated.
- PERSONAL-RAW chain + the BRAIN/LEARNING chain -> RECOVERABLE wrap (LedgerKey KEK,
  passphrase-derived PBKDF2, high cost). His; backed up; restorable on a new
  device with the passphrase.
- The wrap is the ONLY thing that varies (a pluggable KeyWrap: EnclaveWrap vs
  RecoverableWrap). Two genuine uses, not a rewrite.

ZERO-KNOWLEDGE REPLICATION behind ONE adapter interface:
- PERSONAL-RAW + BRAIN/LEARNING (recoverable-wrapped) -> his homes:
  - Cloudflare R2 - edge / immediate read. Free tier: ~10 GB-month storage, ~1M
    Class A + 10M Class B ops/month, EGRESS FREE. Domain already in the CF account.
  - Dropbox (10TB) - bulk archive, incl. heavy personal corpus audio.
- COMPANY-RAW (Enclave-wrapped) -> NOT replicated. Device-bound by construction
  (the SEP key cannot leave), so it physically cannot ride to a personal target.
- All store ciphertext ONLY; no key ever leaves the device.

## What rides off-device (and what never does)

Only the RECOVERABLE-wrapped chains ride off-device: PERSONAL RAW (his own data +
PII of people in his life) and the BRAIN/LEARNINGS (Susan's, abstractions only).
That is PERSONAL BACKUP of his OWN encrypted data - sealed with HIS key, the clouds
hold ciphertext only he can open. Her brain holds NO PHI and NO raw company data:
the scrubber gates ingestion and the learning gate lets only abstractions cross.

The COMPANY-RAW vault (Enclave/SEP-sealed) may contain sensitive Sonar data
(secrets, PHI, business-ops) - but it NEVER rides off-device (the SEP key cannot
leave), never becomes personal bytes, and only abstracted learnings derived from
it enter the one brain. So "off device" is never "exposed": zero-knowledge for the
personal backup, and physically-device-bound for the company vault.

## HARD GATES (do not bypass)

1. THE SCRUBBER STAYS IN FRONT OF INGESTION. The "no PHI in the bytes" guarantee
   holds ONLY while the masker gates everything that enters her stores. That is
   the real invariant - protect it. (No new ingestion source bypasses it.)
2. CREDENTIALS. Dropbox token + R2 access keys are secrets -> through Agora/op
   (1Password), never hardcoded, never in logs. Build the mechanism; wire creds
   the sanctioned way. (Global directive rules 2-4.)
3. The recoverable MASTER passphrase is the highest-order secret - losing it =
   losing everything; leaking it = losing zero-knowledge. Handle via op; never
   echo.

## Build order (each slice real, destination-agnostic first)

1. SEALED LEDGER (on-device, no cloud): the hash-chained, envelope-encrypted,
   append-only record store, parameterized by JURISDICTION (one chain per
   jurisdiction). `append(jurisdiction, kind, plaintext)` + `verify(jurisdiction)`
   that walks the chain and proves integrity + `restore(passphrase)`. Recoverable
   KEK (passphrase-wrapped). Unit-test: append N, verify ok; tamper one, verify
   fails at that seq; restore round-trips bytes.
2. KEY REGIMES + ownership routing: pluggable KeyWrap (EnclaveWrap for company-raw,
   RecoverableWrap for personal-raw + brain). Tag each artifact owner = company /
   personal at ingest -> picks the chain + its wrap. Define the LEARNING gate (what
   abstraction may cross from any raw into the one brain: gist/key-phrase/
   preference/relation/weight - never raw). Brain/learning = its own recoverable
   chain.
3. MIGRATE artifacts INTO the ledger: EncryptedLog records, PerceptionMemory /
   AgendaStore / RAGIndex writes, recordings.db rows, session logs - each tagged
   by owner + routed to the right chain/wrap. Preserve existing on-device fast paths.
4. REPLICATION adapters behind one interface (put/list/get ciphertext objects):
   recoverable-wrapped chains (personal-raw + brain) -> R2 (edge) then Dropbox
   (bulk); company-raw (Enclave-wrapped) -> NOT replicated (device-bound). Creds
   via op. Sync = push new chain records since last cursor; the chain makes "what
   is new" exact.

## PROGRESS

2026-06-20 slice 1 (the sealed ledger) - DONE, builds clean, 15/15 tests pass:
- LedgerKey.swift: recoverable KEK via PBKDF2-HMAC-SHA256 (CommonCrypto), persisted
  salt + 600k iterations. Deterministic (same passphrase -> same key = recovery).
  Passphrase via op at call site; never stored/logged.
- SealedLedger.swift: per-jurisdiction append-only hash chain. append/verify/
  entries + height. Envelope encryption (per-record data key wrapped by KEK).
  Wire format: [4B BE len][seq|atMs|prevHash|kind|wrappedKey|sealedPayload|thisHash],
  thisHash = SHA-256(prefix). dir injected for testability.
- Verified standalone: append+verify, reopen continues chain, restore round-trip
  decrypts, WRONG KEK cannot decrypt (zero-knowledge), chain verifies WITHOUT the
  key (hashes public), TAMPER (flipped byte) caught at exact seq, KDF determinism
  + different passphrase -> different key.
- NOT yet wired into the app (slice 3): artifact migration, replication adapters.
  Ledger is destination- and source-agnostic by design.

2026-06-20 slice 2 (two seals + owner routing + learning gate) - DONE, builds
clean, 13/13 tests pass:
- KeyWrap.swift: KeyWrap protocol + RecoverableWrap (AES-GCM under LedgerKey KEK)
  + EnclaveWrap (delegates to EnclaveBox / SEP). SealedLedger now takes a KeyWrap
  (was a SymmetricKey); chain/format/verify unchanged.
- Ledgers.swift: DataOwner {company, personal, brain} + TaggedRecord (provenance:
  owner/source/kind/topic/tags/text) + the coordinator. company -> Enclave (device-
  bound), personal + brain -> recoverable (backed up). Routing total + explicit.
- LearningGate.swift: Learning {gist/keyPhrase/preference/relation/weight} +
  LearningDeriver (injected) + LearningGate.admit - drops non-abstractions
  (substring lift, contiguous run >= 6, mostly-a-lift, over-length). Only admitted
  learnings reach the brain chain.
- Verified: KeyWrap round-trips + zero-knowledge, EnclaveWrap over a real SE key,
  owner routing (company=Enclave / personal+brain=recoverable, distinct chains),
  company record decrypts via Enclave chain, gate admits abstraction / rejects
  verbatim + over-length, only admitted reach brain, tamper caught at exact seq.
- NOTE: verify() detects MODIFICATION, not tail TRUNCATION (hash-chain property;
  truncation -> external head/height anchoring at the replication layer).

## Open decisions (resolve before/within slice 1)

- KDF + params for the passphrase KEK (scrypt N/r/p or Argon2id).
- One ledger for everything, or one chain per artifact-class (logs / brain /
  corpus / sessions) sharing the KEK? (Per-class chains = independent verify +
  selective replication; one chain = a single total order. Lean per-class.)
- Does the local fast path stay Enclave-sealed with the ledger as the
  recoverable export, or does the ledger become the single store? (Lean: ledger
  is the durable+recoverable spine; Enclave optional local accelerator.)
