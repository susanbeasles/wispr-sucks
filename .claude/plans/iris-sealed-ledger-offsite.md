# Iris sealed ledger + off-site backup

Status: planning. 2026-06-20. Branch: feat/the-eyes (susanbeasles).

## Goal (owner's)

Every artifact - diagnostic logs, her brain (perception/agenda/RAG), the dictation
corpus, session logs - cryptographically SEALED and CHAINED together
("lobster-chained"): a tamper-evident, append-only ledger. Replicated OFF the
device but stored, RECOVERABLE, to two homes (Dropbox 10TB bulk; Cloudflare R2
edge). Zero-knowledge: the clouds hold only ciphertext, never a key.

## Split brain (the routing principle - owner's keystone)

"What she LEARNS is kept. The actual DATA is not." A learning is not the document
it came from. The brain splits along JURISDICTION, decided at ingest:

- WORK-raw  -> WORK infrastructure ONLY. Company data (SonarMD's, not his) is
  stored only on work infra; it NEVER touches personal Dropbox/R2. The company's
  legitimate concern is answered structurally, not by promise.
- PERSONAL-raw -> personal infra (his homes).
- LEARNINGS -> kept, central, hers - free game regardless of source. Patterns,
  preferences, relationships, KEY PHRASES, salience weights she ABSTRACTS from
  either side are knowledge, not data. Kept because she learned them.

THE BOUNDARY (same gate-shape as phi-mask, pointed at confidentiality instead of
PHI): work-confidential raw is ABSTRACTED before a learning crosses into the kept
layer. Only abstractions cross - a key phrase, a preference, a relation, a weight.
NEVER the raw work payload verbatim. If a "learning" reproduces the document, it
is not a learning and it does not cross. This is data minimization - the thing
privacy frameworks actually bless. The abstraction boundary is the whole ballgame:
too-verbatim learnings smuggle work data into the personal layer. The learning
layer has a DEFINED vocabulary of what may cross (gist / key phrase / preference /
relation / weight); raw stays home.

JURISDICTION becomes a first-class classify dimension (next to kind/topic/about/
salience) and, unlike the others, it ROUTES STORAGE. The sealed ledger is
PER-JURISDICTION chains with per-jurisdiction replication: work chain -> work
infra only; personal chain -> his homes; learning layer = its own kept spine.

## Architecture

SEALED LEDGER. Append-only chain of records. Each record:
  { seq, prev_hash, at, kind, ciphertext, this_hash }
  this_hash = SHA-256(seq || prev_hash || at || kind || ciphertext)
Tamper-evident: altering/dropping any record breaks the chain from there on. A
`verify` walks the chain and proves it is unbroken (audit posture).

RECOVERABLE ENVELOPE ENCRYPTION (the key change from today's posture):
- Per-record data key (random) seals the payload (AES-256-GCM).
- Data keys wrapped by a MASTER key (KEK).
- The KEK is RECOVERABLE: passphrase-derived (scrypt/PBKDF2, high cost) and/or
  escrowed - NOT the Secure Enclave (Enclave keys cannot leave the chip, so an
  off-device copy sealed by Enclave is unrecoverable; owner chose recoverable).
- Her brain is re-keyed off Enclave-only onto this recoverable wrap FOR THE BACKUP
  copy. (Local-only fast path may still use Enclave; the exported chain uses the
  recoverable KEK.)
- Recovery = new device + passphrase + off-device ciphertext -> full restore.

ZERO-KNOWLEDGE REPLICATION, routed BY JURISDICTION behind ONE adapter interface:
- PERSONAL chain + LEARNING spine -> his homes:
  - Cloudflare R2 - edge / immediate read. Free tier: ~10 GB-month storage, ~1M
    Class A + 10M Class B ops/month, EGRESS FREE. Domain already in the CF account.
  - Dropbox (10TB) - bulk archive, incl. heavy personal corpus audio.
- WORK chain -> WORK infra ONLY (never personal). Target TBD (SonarMD-controlled).
- All store ciphertext ONLY; no key ever leaves the device. Work raw NEVER routes
  to a personal target - enforced at the adapter, not by convention.

## What this is (and is NOT)

This is PERSONAL BACKUP of the owner's OWN encrypted data - NOT a PHI-to-cloud
compliance project. Iris never stores PHI: the scrubber is the gate in front of
ingestion, so patient/client/customer PHI never enters her stores. What is in
the ledger is the owner's own data + PII of people in his life. Sealed with HIS
key, the clouds hold ciphertext only he can open. "Off device" here does NOT mean
"exposed" - zero-knowledge breaks that link; off-device AND yours-only. The single
device only adds one risk a backup removes: a dead Mac = her brain + the corpus
gone forever.

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
2. JURISDICTION at classify + the LEARNING gate: tag each artifact work/personal
   at ingest (routes the chain); define the learning-abstraction boundary (what
   may cross from work-raw into the kept learning spine: gist/key-phrase/
   preference/relation/weight - never raw). Learning spine = its own chain.
3. MIGRATE artifacts INTO the ledger: EncryptedLog records, PerceptionMemory /
   AgendaStore / RAGIndex writes, recordings.db rows, session logs - each tagged
   + routed. Preserve existing on-device fast paths.
4. REPLICATION adapters behind one interface (put/list/get ciphertext objects),
   ROUTED BY JURISDICTION: personal+learning -> R2 (edge) then Dropbox (bulk);
   work -> work infra only (hard-enforced). Creds via op. Sync = push new chain
   records since last cursor; the chain makes "what is new" exact.

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
- NOT yet wired into the app (slice 2/3): jurisdiction classification + the
  learning gate, artifact migration, replication adapters. Ledger is destination-
  and source-agnostic by design.

## Open decisions (resolve before/within slice 1)

- KDF + params for the passphrase KEK (scrypt N/r/p or Argon2id).
- One ledger for everything, or one chain per artifact-class (logs / brain /
  corpus / sessions) sharing the KEK? (Per-class chains = independent verify +
  selective replication; one chain = a single total order. Lean per-class.)
- Does the local fast path stay Enclave-sealed with the ledger as the
  recoverable export, or does the ledger become the single store? (Lean: ledger
  is the durable+recoverable spine; Enclave optional local accelerator.)
