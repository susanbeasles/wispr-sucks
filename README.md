# SonarDictate

Push-to-talk dictation for macOS that puts your words into the focused field the
instant you release the key. 100% on-device (Apple's macOS 26 SpeechAnalyzer), no
network egress, PHI-safe at rest. It is a menu-bar app (no Dock icon): hold the
fn/globe key to talk, release to capture, and the text is pasted into whatever
field is focused. A floating live-transcript widget shows what it hears as you
speak, and a clickable control panel manages vocabulary and settings.

## TL;DR

- Hold the fn/globe key, talk, release -> the text is pasted into the focused field instantly.
- On-device recognition plus an on-device personal vocabulary that biases recognition toward your jargon.
- Everything is encrypted at rest under a Secure Enclave key; nothing leaves the machine.
- Manage it from the menu-bar mic: live vocabulary add/remove, cleanup toggle, history, stats.
- CLI for power use: `sonar-dictate list | read | dict | logs | bind | ...`.

## Status: the core capture pipeline is SEALED

As of 2026-06-14 the capture -> recognize -> assemble -> inject path is finished,
validated, and frozen. Changing it requires the owner's explicit, per-change
approval. The full declaration (exact files, functions, and rationale) lives in
[DECISIONS.md](DECISIONS.md). The four invariants that must never regress:

1. Release-to-field is INSTANT - nothing on the release->inject path may block on async/LLM/network work.
2. Injection is by PASTE (clipboard + Cmd-V), never per-character keystrokes.
3. Vocabulary bias is APPLIED via `SpeechAnalyzer.setContext`, not merely built.
4. The speech model is prewarmed at launch so the first dictation is not the slow one.

Sealed files: `SpeechAnalyzerSession.swift` (entire) and the `Dictator` capture
path in `main.swift`. Storage and crypto (`SecureStore`, `KeychainStore`,
`RecordingDatabase`, `EncryptedLog`) are protected by the project's security rules
regardless. Everything else - all UI, the dictionary / RAG / edit-watcher, the
cleanup pass, workflows, the CLI, and build tooling - is OPEN for iteration (the
"peripherals").

## Quick start

```
./scripts/build-app.sh debug      # build + wrap in dist/SonarDictate.app + codesign
open dist/SonarDictate.app        # launch; menu-bar mic appears; grant Mic/Speech/Accessibility once
```

Requires macOS 26+ for the dictation runtime (the CLI and storage build on macOS
14+). First launch downloads the on-device speech model for your locale. Read the
encrypted diagnostics with `sonar-dictate logs` (or `sonar-dictate logs --follow`).
Full build rationale is in the "Build and run" part of the automation section below.

---

## Core capture pipeline (SEALED) - mic -> recognizer -> assembly -> instant injection

This is the load-bearing path: hold the fn/globe key, talk, release, and the words
are in the focused field instantly. Two files own it end to end. Treat both as
SEALED: every block here exists because a specific failure happened. The inline
comments are tombstones for bugs. Do not "clean up" without reading the WHY.

- `SpeechAnalyzerSession.swift` - the recognizer wrapper: format negotiation,
  AVAudioConverter, finalized-vs-volatile assembly, finalize ordering, vocabulary
  bias, prewarm.
- `main.swift` (the `Dictator` class) - the capture path: audio tap, listen
  lifecycle, transcript routing, and injection by paste.

### WHAT it does

On-device, low-latency dictation. The fn key down starts the mic and the
recognizer; fn up stops them, flushes the recognizer to a final transcript, and
pastes that text into whatever field is focused. 100% on-device
(`requiresOnDeviceRecognition`, no network IO; see the file header in
`main.swift:7-18`). The recognizer is macOS 26's `DictationTranscriber` driven by
`SpeechAnalyzer`, chosen for a partial cadence of ~50-100ms
(`SpeechAnalyzerSession.swift:6-12`).

### HOW it works

**1. Recognizer choice and preset.** `start(inputFormat:)` builds a
`DictationTranscriber(locale:preset: .progressiveLongDictation)`
(`SpeechAnalyzerSession.swift:94`). `DictationTranscriber` (not
`SpeechTranscriber`) is the live-voice-into-text recognizer; `.progressiveLongDictation`
gives the streaming-with-volatile-partials cadence the live preview UX depends on
(`SpeechAnalyzerSession.swift:87-93`).

**2. Asset gate.** Before running, `start()` checks
`AssetInventory.status(forModules:)` and, if `.supported`, downloads and installs
the per-locale language model (`SpeechAnalyzerSession.swift:102-120`). This is
load-bearing: without installed assets the transcriber runs through audio and
emits ZERO results - WAVs persist, finalize fires, transcript is empty. This is a
classic empty-output regression trap.

**3. Audio-format negotiation + conversion.** The mic input node is typically
48kHz Float32; the transcriber wants whatever
`SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` reports. `start()`
negotiates that format and builds an `AVAudioConverter` from mic format to it
(`SpeechAnalyzerSession.swift:122-132`). Every buffer is run through `convert(...)`
in `append(buffer:)` before being yielded as `AnalyzerInput`
(`SpeechAnalyzerSession.swift:187-197`, `253-278`). REGRESSION TRAP: feeding raw
mic buffers directly makes `SpeechAnalyzer` trap with EXC_BREAKPOINT inside
`preRunRecognition()` (`SpeechAnalyzerSession.swift:14-19`). Because negotiation is
async and must finish before any buffer arrives, `start()` is `async` and the
caller starts `AVAudioEngine` only after it returns
(`SpeechAnalyzerSession.swift:66-69`; enforced at `main.swift:404-426`).

**4. Vocabulary bias - the load-bearing wire.** `setContextualStrings` populates
`context.contextualStrings[.general]` (`SpeechAnalyzerSession.swift:62-64`), but the
bias does nothing until `start()` calls `try await analyzer.setContext(context)`
(`SpeechAnalyzerSession.swift:146-150`). That `setContext` call is the wire that was
missing: the `AnalysisContext` was populated but never applied, so the recognizer
got zero bias and mangled jargon ("git" -> "get", "egress" -> "addresses") even
when the term was in the dictionary. It is wrapped in best-effort try/catch - a
context failure must never break dictation. The caller seeds this each session in
`startListening` (dictionary terms first, then RAG bias, deduped, capped at 200;
`main.swift:368-384`).

**5. Assembly: finalized chunks vs volatile tail + the empty-final guard.** Results
arrive on `resultsTask` and flow through `handle(result:)`
(`SpeechAnalyzerSession.swift:280-309`). Finalized segments accumulate in
`finalizedChunks: [Double: String]` keyed by range-start-in-ms; the in-progress
guess lives SEPARATELY in `volatileText`
(`SpeechAnalyzerSession.swift:36-44`). They are kept separate because a volatile
result and its final can have range starts that jitter by ~1ms, producing
different map keys, so a single map would keep both and double every phrase. Two
guards matter:
  - Empty-final guard (`SpeechAnalyzerSession.swift:288-300`): an `isFinal` result
    with empty text is ignored entirely - `guard !plain.isEmpty else { return }`.
    `DictationTranscriber` and the forced flush in `stop()` can emit an empty final
    at a segment boundary; storing "" and clearing `volatileText` would drop the
    words the user just said and still sees on screen. This is the "swallowed the
    whole utterance, shows empty" bug. Do not remove this guard.
  - Volatile is replaced, never appended (`SpeechAnalyzerSession.swift:301-306`):
    each volatile result is the full guess for its un-finalized range.

  `emitTranscript` sorts finals by key, joins with spaces, and always appends the
  live `volatileText` tail - including on the final emit
  (`SpeechAnalyzerSession.swift:311-332`). The volatile tail must be included at
  finalize because `DictationTranscriber` keeps the last phrase in volatile state
  until session end; drop it and the last thing said is silently lost. Since each
  final clears `volatileText`, there is no double-count.

**6. Stop ordering - the second load-bearing sequence.** `stop()` first finishes
the audio input stream, then explicitly calls
`analyzer.finalizeAndFinishThroughEndOfInput()`
(`SpeechAnalyzerSession.swift:199-219`). Finishing the input stream alone does NOT
complete `transcriber.results`, so the `resultsTask` loop never ends and its final
`emitTranscript(isFinal: true)` never runs - which is why commit-at-end wrote
nothing. `finalizeAndFinishThroughEndOfInput()` flushes pending audio and promotes
volatile to final, completing the stream so the final transcript fires. The
session-restart teardown in `start()` (`SpeechAnalyzerSession.swift:70-85`)
guarantees exactly one analyzer at a time: a fast re-press while a prior `start()`
was still negotiating would otherwise orphan an analyzer and corrupt the next
session's finalize.

**7. Prewarm - cold-start killer.** `prewarm()` (`SpeechAnalyzerSession.swift:228-249`)
spins a THROWAWAY analyzer at launch and feeds ~100ms of synthetic silence in the
analyzer's own format - no `AVAudioEngine`, no mic, no privacy indicator, no
permission prompt - so the first real dictation does not pay the one-time model
load. It only warms when assets are already `.installed` and never triggers a
download. Fired from `main.swift:1296-1298` as a detached low-priority task.

### The Dictator capture path (main.swift)

**Audio tap.** `startListening` reads the input node format, removes any stale tap
(AVAudioEngine throws if a bus already has one), and installs a 1024-frame tap
(`main.swift:386-402`). The tap closure clones the buffer with `copy(of:)` because
the engine reuses its storage (`main.swift:695-718`), keeps the raw mic-format copy
in `audioFrames` for WAV serialization, and feeds the same copy to
`session.append(buffer:)` (which converts internally). It then launches the async
`session.start(inputFormat:)`; after the await it re-checks `listening` and aborts
the engine start if the key was already released (`main.swift:404-426`) - this is
the guard against the rapid start/stop race.

**stopListening.** Sets `listening = false`, calls `session.stop()`, stops the
engine, removes the tap (`main.swift:429-437`). The final transcript is delivered
later via the recognizer's drain, not synchronously here.

**handleTranscript / decideMode.** `onTranscriptUpdate` is marshalled to main and
lands in `handleTranscript` (`main.swift:448-476`). Every partial updates the
floating overlay. In the current build `streamingIntoField` is hard-set to `false`
in `startListening` (`main.swift:357-364`): the app NEVER live-types into the user's
real field - that was the source of mid-sentence garble and held focus. Live words
stream into the app's own floating widget; the real field is written exactly once,
on release. So `handleTranscript` ignores non-final updates and calls
`finalize(transcript:)` only when `isFinal` is true (`main.swift:474-475`).
`decideMode` (`main.swift:484-504`) and the `streamEmit` diff path
(`main.swift:732-740`) survive for the dormant streaming model and the
trigger-buffering classifier; they are not on the live release path today.

**finalize -> commitDictation -> commit.** `finalize` (`main.swift:509-546`) guards
with `finalPersisted`, classifies for a workflow/trigger, and for plain dictation
calls `commitDictation`, then `persistSession`. REGRESSION TRAP in the default
case (`main.swift:535-543`): if the first word merely looks like a built-in trigger
that has no handler wired, it falls back to plain dictation rather than EATING the
user's text. `commitDictation` (`main.swift:744-764`) trims, and injects the raw
recognizer text immediately. The on-device LLM cleanup pass is explicitly OFF the
release path: the old code did `await cleanup.clean()` (seconds) before injecting in
cleanup-target apps - the multi-second release hang. Instant-on-release is the
entire product; cleanup is never allowed to block release. `commit`
(`main.swift:770-801`) routes by priority: selector targets -> broadcast to all;
else AX-trusted -> direct inject and arm the edit-watcher; else -> park in the chip
so text is never stranded.

**inject - PASTE, not keystrokes.** `inject` (`main.swift:906-928`) puts the text on
the pasteboard and calls `postPaste()` (synthesized Cmd-V,
`main.swift:933-949`). This is deliberate and load-bearing: char-by-char keystroke
synthesis posts 2 events per character (1686 events for an 843-char utterance), and
slow targets - Electron and terminal inputs especially - cannot drain that flood,
so long text lands in stalled chunks or is partially dropped. A single Cmd-V
delivers any length in one action. The dictated text is left on the clipboard
deliberately: restoring previous contents on a timer would race a slow paste and
could inject stale clipboard data into the field. `injectByKeystroke`
(`main.swift:954-967`) is the FALLBACK ONLY, used when the pasteboard set fails; it
clears modifier flags so a held hotkey modifier does not turn synthesized keys into
dead-key combos.

### WHY it is built this way (summary of load-bearing constraints)

- Instant-on-release is the product. Anything that can block the release path
  (LLM cleanup, format negotiation, keystroke floods) is either removed from it or
  forced to complete before the key is pressed.
- Paste over keystrokes because Electron/terminal targets choke on a per-character
  event flood.
- `setContext(context)` is the one wire that makes the dictionary actually bias
  recognition; without it the bias is dead code.
- The audio converter is mandatory: raw mic buffers crash `SpeechAnalyzer`.
- `finalizeAndFinishThroughEndOfInput()` is mandatory at stop; finishing the input
  stream alone leaves the results loop hanging and the final transcript never
  fires.
- The empty-final guard and the volatile/final split are the fix for the
  whole-utterance-to-empty swallow and the phrase-doubling bugs respectively; both
  are regression traps if touched.
- Prewarm removes the first-use cold-start delay without any mic/privacy cost.

## Security, Storage, and PHI Posture

This app runs on a HIPAA/SOC2 machine where PHI is present. Dictated audio and transcripts are
Protected Health Information, so the storage layer is designed so that nothing sensitive ever
lands on disk in cleartext, nothing leaves the machine, and a single `reset` makes everything
cryptographically unrecoverable. Two independent key custodians back this: a per-app Secure
Enclave keypair (recordings/transcripts on disk) and a Keychain-resident AES key (corpus DB and
the diagnostic log).

### Verified posture (the two load-bearing facts)

- **No network egress anywhere in the source tree. 100% on-device.** A symbol scan of
  `Sources/` for `URLSession`, `URLRequest`, `dataTask`, the `Network` framework (`NWConnection`),
  raw sockets, `http(s)://`, and any telemetry/analytics SDK returns zero call sites; the only
  hit is a comment in `RAGIndex.swift` that reads "No training, no telemetry." No networking
  framework is even imported - the import set is Foundation, AppKit, CryptoKit,
  ApplicationServices, Speech, AVFoundation, Security, SQLite3, NaturalLanguage, FoundationModels,
  CoreMedia. Speech recognition is Apple's on-device `SpeechAnalyzer`. If you add a dependency or
  call that opens a socket, you have broken the core security property of this app - do not do it
  without an explicit decision in `DECISIONS.md`.
- **The diagnostic log is content-free for transcripts: counts and lengths only, never the
  words.** Every `NSLog` that touches transcript text logs `.count`, not the text - e.g.
  `commit \(text.count) chars` (`main.swift:786`), `len=\(plain.count)` and `FINAL assembled
  len=\(assembled.count)` (`SpeechAnalyzerSession.swift:286,329`), and `\(current.count) chars
  final` (`EditWatcher.swift:154`). The transcript words themselves reach stdout only on explicit
  operator commands (`sonar-dictate read <id>` -> `main.swift:1031`, `list` previews, `similar`),
  never through the stderr stream that the encrypted log captures. Regression trap: do not
  interpolate a raw transcript, phrase, or chip text into any `NSLog`/`print`/`fputs(..., stderr)`
  call - that would write PHI verbatim into the diagnostic log frame.

### Recordings and transcripts: Secure Enclave per-file envelope (`SecureStore.swift`)

WAV audio, transcripts, and the index manifest live under
`~/Library/Application Support/SonarDictate/recordings/` (`SecureStore.baseDir`,
`SecureStore.swift:50`), directory `0700`, every file `0600` plus `.completeFileProtection`.

The custodian is a per-app `SecureEnclave.P256.KeyAgreement.PrivateKey` (`SecureStore.swift:59`).
The private half never leaves the Enclave; only an opaque `dataRepresentation` is persisted to
`device.enclave-key` (`SecureStore.swift:73`), which is useless on any other machine. On first
launch the key is generated only if `SecureEnclave.isAvailable`, otherwise init throws
`secureEnclaveUnavailable` (`SecureStore.swift:69`) - the app refuses to store cleartext rather
than degrade.

Each file is sealed with its own symmetric key via an ECDH envelope (`encrypt`,
`SecureStore.swift:168`): a fresh ephemeral P256 keypair does ECDH against the Enclave key, the
shared secret is run through `hkdfDerivedSymmetricKey(using: SHA256.self, ...)` with
`salt = recording UUID` and `sharedInfo = "sonar-dictate.v1.file"` to produce a 32-byte AES key,
then `AES.GCM.seal` produces the ciphertext. The on-disk blob is
`[4-byte BE ephemeral-pubkey length][ephemeral pubkey raw][AES.GCM.combined]` (`SecureStore.swift:182-189`);
`decrypt` reverses this with bounds checks that throw `malformedCiphertext` on a truncated or
corrupt frame (`SecureStore.swift:192-210`). The index (`index.enc`) is sealed the same way under
a fixed salt `__sonar_dictate_index__` (`SecureStore.swift:57`).

`reset()` (`SecureStore.swift:142`) removes the entire directory including the Enclave key. Once
the key data representation is gone, every `.wav.enc`/`.txt.enc` - including any copy on a backup
or snapshot - is permanently undecryptable. This is the intended "cryptographic erase."

### Corpus DB key: Keychain, ThisDeviceOnly (`KeychainStore.swift`)

The corpus database and the encrypted log use a different custodian: a 32-byte AES-256 key stored
as a Keychain Generic Password (`service = com.sonarmd.dictate.dbkey`, `KeychainStore.swift:37`)
with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`KeychainStore.swift:111`).
`loadOrCreateDBKey()` (`KeychainStore.swift:43`) is idempotent across launches; `deleteKey()`
(`KeychainStore.swift:61`) is called by `reset` so the DB and log go cryptographically dark, the
same erase story as the WAVs (and it tolerates `errSecItemNotFound`).

**Why Keychain and not the Enclave key here (load-bearing decision, `KeychainStore.swift:5-20`):**
the Secure Enclave key triggers Touch ID prompts when accessed from non-foreground/background
contexts, which broke this app's background daemon repeatedly. The `AfterFirstUnlockThisDeviceOnly`
Keychain item is readable with no user interaction after first login, is encrypted at rest under
the account password / FileVault key, never syncs to iCloud Keychain, and is codesign-bound (only
an app with the same signing identity can read it). Regression trap: do not "unify" the two key
systems onto the Enclave key - the background-prompt problem is the reason they are split.

### Corpus database: column-level AES-GCM (`RecordingDatabase.swift`)

`recordings.db` (SQLite, `SQLITE_OPEN_FULLMUTEX`, file forced to `0600` at
`RecordingDatabase.swift:123`, parent dir `0700`) is the long-term training corpus. The split is
deliberate (`RecordingDatabase.swift:10-18`): sensitive columns are stored as AES-GCM blobs and
plain metadata is left queryable. Encrypted columns include `raw_transcript_enc`,
`committed_text_enc`, `corrected_text_enc`, `audio_path_enc` (schema v1) and
`raw_phrase_enc`/`corrected_phrase_enc` in `corrections` (schema v2, `RecordingDatabase.swift:55-99`).
Plain columns are `id`, timestamps, durations, `app_bundle`, `locale`, model names - "None of
these are PHI on their own" - so the menu bar and CLI can `COUNT`/`SUM` without decrypting any row
(`stats()`, `RecordingDatabase.swift:239`).

`bindEncrypted` (`RecordingDatabase.swift:272`) seals each value with `AES.GCM.seal` under the
Keychain key before binding it to the prepared statement, and binds SQL `NULL` for nil/empty
plaintext (so an empty transcript stores nothing, not an encryption of ""). All access is
serialized through one `DispatchQueue` (`RecordingDatabase.swift:50`). Schema is versioned via
`PRAGMA user_version` with an append-only `migrations` array (`RecordingDatabase.swift:52-100`);
the migrator runs only tuples strictly greater than the current version - never edit an existing
migration, append a new one.

### Encrypted diagnostic log (`EncryptedLog.swift`)

`NSLog` writes to stderr (fd 2). `EncryptedLog.install()` (`EncryptedLog.swift:39`, called once at
startup from `main.swift:1250`) replaces the old plaintext `~/Library/Logs/SonarDictate.log` -
which left every line in cleartext on a PHI machine - with an in-process sink: it `dup2`s a `Pipe`
over `STDERR_FILENO` (`EncryptedLog.swift:55`) and seals each chunk with the same Keychain AES-256
key the corpus DB uses, appending to `~/Library/Logs/SonarDictate.log.enc` (`0600`,
`.completeFileProtection`).

On-disk format is a sequence of framed records, each `[4-byte BE length N][N bytes
AES.GCM.combined]`, one independent GCM seal (random nonce) per record (`seal`,
`EncryptedLog.swift:157`). `decode` (`EncryptedLog.swift:138`) walks frames and stops at the first
length-prefix overrun or failed `AES.GCM.open`, so a crash-truncated trailing record is skipped
rather than aborting the readable history. Read it back with `sonar-dictate logs` (`readAll`) or
`sonar-dictate logs --follow` (`follow`, a 0.3s-interval tail, `main.swift:1181-1190`).

Two safety properties to preserve:
- **Fail safe, never fail open.** If the Keychain key or logs directory is unavailable,
  `install()` does NOT fall back to a plaintext file (that is exactly the leak being closed);
  diagnostics drop to the unified log only (`EncryptedLog.swift:44-49`).
- **No `NSLog` inside the sink's `queue`.** `append` runs on `queue` and must never call `NSLog`,
  because that would write back into the same stderr pipe and recurse (`EncryptedLog.swift:86-87`).
- Migration of any pre-existing plaintext log is one-time and idempotent (`migratePlaintext`,
  `EncryptedLog.swift:67`); note the in-code caveat that truncate-then-remove is not a true
  secure-erase on APFS, it removes the live cleartext only.

### Spotlight exclusion

`SecureStore.ensureDir()` drops an empty `.metadata_never_index` marker into the recordings
directory (`SecureStore.swift:162-165`), telling Spotlight to skip indexing it. This keeps even
the encrypted filenames and any incidental metadata out of the Spotlight store. The corpus DB and
the encrypted log live under `~/Library/Logs` and `~/Library/Application Support` and are sealed
blobs regardless, but the recordings directory specifically opts out of indexing.

## Personalization and Learning

### What it does

This subsystem makes the recognizer better at *your* words over time, entirely on-device. Three pieces cooperate:

- A weighted, encrypted **personal dictionary** (`DictionaryStore`) of the terms you care about - jargon, names, acronyms, and corrections - that biases the recognizer toward getting them right.
- A local **RAG vocabulary index** (`RAGIndex`) over your past transcript corpus that surfaces proper nouns and identifiers you have actually said before.
- An **edit-capture loop** (`EditWatcher`) that reads the target field ~60s after we inject dictated text, diffs what you kept against what we typed, and feeds the words we got wrong back into the dictionary at high weight.

At the start of every dictation session, the dictionary and RAG terms are merged, deduped, capped, and handed to the SpeechAnalyzer as contextual-bias strings (`main.swift:373-381`). All three stores share one Secure Enclave key and never touch the network.

### How it works

**Dictionary: weighted, curated, encrypted.** `DictionaryStore` (`DictionaryStore.swift:40`) keeps an in-memory `[String: DictionaryEntry]` map keyed by lowercased term (`DictionaryStore.swift:50`), so adds and removes are case-insensitive while `DictionaryEntry.term` (`DictionaryStore.swift:26`) preserves original casing (jargon casing matters: `Kubernetes`, `SonarMD`). `add(_:weight:appContext:source:)` (`DictionaryStore.swift:84`) accumulates weight on repeat adds (`e.weight += weight`, line 90), so frequency naturally ranks terms up; a brand-new term is created at the passed weight. `learnCorrection(from:to:)` (`DictionaryStore.swift:112`) is just `add(right, weight: 3, source: .correction)` - corrections land at 3x a manual add (which is weight 2; see `main.swift:1163` and `ControlPanel.swift:192`). `terms(forContext:limit:)` (`DictionaryStore.swift:118`) returns the strongest-weight terms first, scoped to the current app's bundle ID only when at least 8 context-specific entries exist, else falling back to the global pool (line 124). Persistence (`persist`/`loadAll`, `DictionaryStore.swift:151-172`) writes `dictionary.enc` with the same envelope as RAG: ephemeral-P256 ECDH against the Secure Enclave key, HKDF-SHA256, AES-GCM, written with `.completeFileProtection` and `0o600`.

**RAG: vocabulary bias from past transcripts.** `RAGIndex` (`RAGIndex.swift:54`) embeds each transcript with on-device `NLContextualEmbedding`, mean-pooling per-token vectors into one document vector (`meanPooledEmbedding`, `RAGIndex.swift:175`). `add(id:transcript:appContext:createdAt:)` (`RAGIndex.swift:110`) appends a `RAGEntry` and persists the whole index (`rag-index.enc`). The bias actually fed to the recognizer comes from `vocabularyBias(forContext:k:)` (`RAGIndex.swift:149`): note it does NOT use semantic similarity for biasing - the call `query("", ...)` produces noisy scores by design, so the function instead pulls the K most-recent entries in the scoped pool and runs `extractTerms` (`RAGIndex.swift:211`) over their previews. `extractTerms` is a cheap dictionary-free heuristic: keep tokens that start uppercase OR contain a digit (proper nouns, acronyms, instance IDs, version strings), dedup, cap at 200. Cosine similarity (`RAGIndex.swift:198`) and `query` (`RAGIndex.swift:130`) exist for downstream few-shot retrieval but are not on the biasing path. RAG biasing is gated on `assetsReady` (the OS may still be downloading the embedding model) and a non-empty index (`main.swift:374`).

**Merge order at session start** (`main.swift:373-381`):

```swift
var bias = dictionary.terms(forContext: sessionAppContext, limit: 100)
if rag.assetsReady, rag.count > 0 {
    if let ragBias = try? rag.vocabularyBias(forContext: sessionAppContext, k: 8) {
        bias += ragBias
    }
}
var seen = Set<String>()
let merged = bias.filter { seen.insert($0.lowercased()).inserted }
session.setContextualStrings(Array(merged.prefix(200)))
```

Dictionary terms come FIRST and survive the 200-term cap; RAG fills remaining slots. The order is deliberate: the dictionary is curated and correction-driven (it teaches the *right* words), while RAG is "half-blind" - it will happily reinforce a word it previously misheard. `setContextualStrings` (`SpeechAnalyzerSession.swift:62`) writes the list to `context.contextualStrings[.general]`, which is later applied via `analyzer.setContext` (`SpeechAnalyzerSession.swift:147`).

**EditWatcher: the correction-capture loop.** `EditWatcher` (`EditWatcher.swift:37`) is a three-state machine (idle -> armed -> watching) guarded by a serial queue:

1. `armForNextRecording(focusedElement:injectedText:)` (`EditWatcher.swift:66`) is called from `commit()` right after keystrokes land (`main.swift:794`). The recording UUID does not exist yet, so it stashes the AX element + injected text as *pending*. If a prior watch is still active, it captures that one first (`_captureNowLocked(reason: "preempted by new injection")`).
2. `linkRecording(_:)` (`EditWatcher.swift:83`) is called from `persistSession` once SecureStore mints the UUID (`main.swift:638`). It promotes pending -> active and schedules a `DispatchWorkItem` for `checkDelay` (default 60s, `EditWatcher.swift:56`).
3. `_captureNowLocked(reason:)` (`EditWatcher.swift:113`) reads `kAXValueAttribute` from the field, compares against what we injected, and if there were real edits (`EditWatcher.swift:139` skips exact-match and clean-substring no-ops) writes a `(rawPhrase, correctedPhrase)` row via `database.addCorrection` plus `database.updateCorrectedText`. Then it closes the loop: `learnableTerms(original:corrected:)` (`EditWatcher.swift:179`) extracts words present in the corrected text but absent from what we dictated, and each is pushed back with `dictionary.add(term, weight: 3, source: .correction)` (`EditWatcher.swift:160-163`).

`learnableTerms` is length-gated: `guard corrected.count <= original.count * 2 + 40` (`EditWatcher.swift:182`) ensures we only learn when the field is mostly our lightly-edited text, so dictating into a large pre-existing document does not dump that document's entire vocabulary into the dictionary. Tokens shorter than 2 chars, stopwords (`EditWatcher.swift:217`), and words we already dictated correctly are dropped; original casing is preserved and dedup is case-insensitive.

### Why it is built this way

- **Weight as the ranking signal, with corrections at 3x.** The contextual-bias list handed to the recognizer is capped (100 dictionary terms, 200 total). Weight decides what survives the cap, and corrections - the implicit thumbs-down made concrete - outrank casual manual adds 3-to-2. Repeated use compounds weight rather than creating duplicates.
- **Dictionary before RAG, deliberately.** The merge order encodes a trust hierarchy. RAG's term extractor cannot tell a real proper noun from a previously-misheard one, so it is fed *after* the curated dictionary and only fills leftover capacity.
- **RAG biasing uses recency, not similarity, on purpose.** An empty query yields meaningless cosine scores; the code leans on most-recent scoped entries instead. Do not "fix" `vocabularyBias` to rank by similarity expecting better bias - that path was intentionally avoided as noisy.
- **Same Secure Enclave envelope everywhere.** Dictionary, RAG index, and recordings all use one device key under `SecureStore.baseDir`, ECDH + HKDF-SHA256 + AES-GCM, `0o600` / `.completeFileProtection`. PHI lives on this machine; nothing leaves it. Logs in this subsystem are count-only (`EditWatcher.swift:165`, `main.swift:383`) because the terms themselves may be PHI.
- **AX-read coverage gap is accepted, not worked around.** `EditWatcher` reads `kAXValueAttribute`, reliable on native macOS controls and flaky on Electron/web fields - the same gap as `isEditableFieldFocused()`. Where the read fails it logs and skips (`EditWatcher.swift:131-134`); the corpus simply grows from native captures.

### Regression traps

- **CLI `dict add` requires a daemon restart to take effect; control-panel adds do not.** This is the load-bearing friction. The dictionary's `entries` map is loaded once in `DictionaryStore.init()` (`DictionaryStore.swift:74`) and never re-read from disk. The running app constructs its own `DictionaryStore` at startup (`main.swift:1262`). A `sonar-dictate dict add` invocation runs `runCLI`, which builds a *separate* `DictionaryStore` instance (`main.swift:996`), writes `dictionary.enc`, and exits - the daemon's in-memory copy is now stale until it is relaunched. The control panel, by contrast, calls `dictionary.add` on the daemon's *live* shared instance (`ControlPanel.swift:192`), so its adds bias the very next dictation. Anyone adding a new write path must decide which instance it mutates; a disk write alone will not reach the running recognizer.
- **No file-watch / reconciliation between the two instances.** If both the daemon (via control panel or correction loop) and a CLI process write `dictionary.enc` in overlapping windows, the last `.atomic` write wins and the other process's in-memory additions are lost on its next persist. There is no merge-on-load.
- **`terms(forContext:)` app-scoping has an 8-entry floor; RAG has a `k`-entry floor.** Below those thresholds both silently fall back to the global pool (`DictionaryStore.swift:124`, `RAGIndex.swift:137`). A test expecting per-app isolation with few entries will see global terms instead.
- **`learnableTerms` length gate is intentional.** Loosening `original.count * 2 + 40` (`EditWatcher.swift:182`) to capture more corrections will cause large target documents to flood the dictionary with their vocabulary, polluting future bias.

## User-Facing UI and Peripherals

SonarDictate ships `LSUIElement=YES` (no Dock icon), so every pixel of UI is a separately-managed floating affordance built in code (no nibs - this is a SwiftPM executable). There are six of them, plus a selection-state helper: a menu-bar status item and its control-panel popover, a draggable live transcript widget, a draggable text chip, a gold field-highlighter, and a recoverable history window. The Dictator (in `main.swift`) owns all of them as optionals and wires them after construction.

### Menu-bar status item and control panel

`StatusItemController` (`StatusItemController.swift:12`) is the only persistent UI affordance. The icon flips between `mic.circle` (idle) and `mic.circle.fill` (listening) via `setIcon(listening:)` (`StatusItemController.swift:88`); the image is set `isTemplate = true` so macOS tints it for light/dark menu bars. The Dictator calls `setListening(_:)` (`StatusItemController.swift:49`) on every state change and `refreshCounts()` (`StatusItemController.swift:57`) after every finalize; both hop to the main thread.

Clicking the mic toggles an `NSPopover`. The popover behavior is deliberately `.applicationDefined`, not the usual `.transient`:

```swift
// applicationDefined (not transient) so a click on the mic toggles the
// popover instead of AppKit auto-dismissing it mid-click and reopening.
popover.behavior = .applicationDefined
```

With `.transient`, AppKit would dismiss the popover on the same click that is supposed to reopen it, so the controller manages dismissal itself: `showPanel()` (`StatusItemController.swift:67`) installs an `NSEvent.addGlobalMonitorForEvents` for outside clicks and `NSApp.activate(ignoringOtherApps:)` so the vocabulary text field can take keyboard focus (an LSUIElement app is not active by default). Clicks inside the popover are local events the global monitor never sees, so the panel stays open while in use; `closePanel()` (`StatusItemController.swift:81`) tears the monitor down. Regression trap: do not switch the behavior back to `.transient` or drop the global monitor - either breaks click-to-toggle.

The destructive **Reset** lives here, not in the panel: `handleReset()` (`StatusItemController.swift:99`) runs a `.critical` `NSAlert`, and only on confirm calls `store.reset()` + `rag.reset()`. Its copy is load-bearing - resetting destroys the Secure Enclave device key, so backups and Time Machine snapshots become permanently unrecoverable. After a successful reset the app must restart to re-create the key, so it force-quits via `NSApp.terminate(nil)`.

`ControlPanelController` (`ControlPanel.swift:13`) is the popover content. It is pure UI: it only calls existing store methods and never touches the audio or dictation path. The centerpiece is **live vocabulary**: the panel holds the *same* `DictionaryStore` instance the Dictator reads at each session start, so `handleAddWord()` (`ControlPanel.swift:188`) - which adds with `weight: 2, source: .manual` to match a CLI add - takes effect on the next dictation with no restart. The panel also exposes the LLM cleanup toggle (`handleToggleCleanup()`, `ControlPanel.swift:213`, gated `@available(macOS 26.0, *)` and disabled below that), a live stats line, and the action buttons (History, Show Storage in Finder, Reset, Quit). Reset and Quit are not handled here; they fire `onReset`/`onQuit` closures the `StatusItemController` set.

The critical regression fix is the `isViewLoaded` guard in both `setState(listening:)` (`ControlPanel.swift:136`) and `refresh()` (`ControlPanel.swift:144`):

```swift
func refresh() {
    // refreshCounts() fires after every dictation, which can be
    // long before the user ever opens the panel. Touching cleanupToggle (an
    // implicitly-unwrapped outlet) before loadView() ran is what crashed the
    // app. No view -> nothing to refresh.
    guard isViewLoaded else { return }
    ...
}
```

The popover's view (and its implicitly-unwrapped outlets like `cleanupToggle`) only exist after the popover is first opened, but `refreshCounts()` fires after every dictation. Without the guard, a refresh that arrives before the user has ever opened the panel dereferences a nil outlet and crashes. `setState` keeps the last-known `listening` flag in a field and applies it on load; `refresh` simply returns early. Do not remove these guards.

### Live transcript widget (RecordingOverlay)

`RecordingOverlay` (`RecordingOverlay.swift:24`) is the floating, user-positioned live widget. The class name is retained so the Dictator's call sites (`show` / `hide` / `updateTranscript` / `setBufferingMode`) do not change, but the semantics shifted: `show()` (`RecordingOverlay.swift:51`) now means "expand to listening" and `hide()` (`RecordingOverlay.swift:64`) means "collapse back to idle" - the widget stays on screen permanently. `install()` (`RecordingOverlay.swift:41`) is called once at launch to create it idle at its saved position.

Two fixed sizes, both anchored on the **top-right corner** (`idleSize` 52x40 mic-only at `RecordingOverlay.swift:28`; `listeningSize` 480x56 at `RecordingOverlay.swift:29`) so the icon stays visually put while the bubble expands leftward - see `applyIdle()`/`applyListening()` (`RecordingOverlay.swift:96`, `:113`), which both recompute origin from the current `maxX/maxY` rather than a stored origin. Position survives launches via `savePosition()`/`loadOrDefaultTopRight()` (`RecordingOverlay.swift:131`, `:140`); the loader clamps against `NSScreen` visible frames so a stale position from a disconnected monitor falls back to default instead of stranding the widget offscreen.

The widget is draggable from anywhere - including the mic icon - which required two custom subclasses:

- `DraggableWidgetWindow` (`RecordingOverlay.swift:249`) overrides `canBecomeKey`/`canBecomeMain` to `false` so dragging never steals keyboard focus (the user's real input field must stay focused for the on-release commit), and reports drag-end via `onDragEnd` to persist position.
- `DragPassthroughEffectView` (`RecordingOverlay.swift:239`) overrides `hitTest` so every click inside the widget bounds resolves to the background view, not to a subview. The mic icon (`NSImageView`) and labels (`NSTextField`) are `NSControl`s that return `mouseDownCanMoveWindow=false` and would otherwise swallow the click and defeat `isMovableByWindowBackground` - the "I can't drag from the icon" bug. As a plain `NSView`, the passthrough view allows window-background dragging:

```swift
override func hitTest(_ point: NSPoint) -> NSView? {
    // Inside the widget -> us (draggable). Outside -> nil (pass through).
    return super.hitTest(point) == nil ? nil : self
}
```

Two transcript-readability details: `updateTranscript(_:)` (`RecordingOverlay.swift:72`) attaches an ~80ms fade `CATransition` so word-swaps (for example "by lateral" -> "bilateral") crossfade instead of snapping; and the transcript label is right-aligned with `lineBreakMode = .byTruncatingHead` (`RecordingOverlay.swift:218`) so the latest words sit at a fixed right edge instead of shoving the line leftward on every revision. `setBufferingMode(_:)` (`RecordingOverlay.swift:87`) recolors the mic blue and shows "Action" while a voice command is buffering.

### Text chip (deferred commit)

`TextChip` (`TextChip.swift:19`) implements "talk first, decide where it lands second." When a dictation finishes with no editable field focused, the chip appears bottom-right holding the full text in `pendingText` (`TextChip.swift:26`). It is the holding pen and visual only - actual commit is driven by the Dictator. Clicking the chip fires `onCopy` (`TextChip.swift:30`), which the Dictator wires to copy the text to the clipboard (stashing the prior clipboard first) so captured words are never trapped with no way out. Unlike the listening overlay, the chip is mouse-interactive (not click-through): an `NSClickGestureRecognizer` (`TextChip.swift:114`) distinguishes a click (copy) from a drag (move). `DraggableChipWindow` (`TextChip.swift:134`) again overrides `canBecomeKey`/`canBecomeMain` to `false` to preserve the user's field focus for the double-tap commit.

### History window

`HistoryWindow` (`HistoryWindow.swift:14`) is a read-only `NSTableView` over every dictation in the encrypted `SecureStore` - the recovery path when a live paste misfired and the text never landed. Selecting a row (double-click, or Copy) puts that transcript on the clipboard via `copyTranscript(id:)` (`HistoryWindow.swift:68`); nothing here mutates or deletes. `copyMostRecent()` (`HistoryWindow.swift:52`) is the no-window "give me my last dictation back" fast path. Because an LSUIElement background process cannot bring a real titled window forward, `show()` (`HistoryWindow.swift:33`) flips `NSApp.setActivationPolicy(.regular)`, calls `orderFrontRegardless()`, and the `windowWillClose` delegate (`HistoryWindow.swift:178`) restores `.accessory` - the standard accessory-app pattern. The window is `isReleasedWhenClosed = false` so it is reused across opens. Cells are reused by per-column identifier in `tableView(_:viewFor:row:)` (`HistoryWindow.swift:189`); `store.list()` returns newest-first.

### Selector engine and field highlighter (multi-target broadcast)

These two power "broadcast one dictation to N fields." `SelectorEngine` (`SelectorEngine.swift:15`) owns selection state only - the actual write lives in the Dictator's `broadcast(to:text:)` (`main.swift:823`) so it can reuse the single-field path. The user builds a persistent target set by holding the dictation key and clicking fields (`addElement(atCocoaPoint:)`, `SelectorEngine.swift:42`, called from `main.swift:267`) or Ctrl-Opt-L to add the focused field (`addFocused()`, `SelectorEngine.swift:58`, called from `main.swift:206`); Ctrl-Opt-K wipes it. The set persists until removed/wiped, so you configure N agent inputs once and fire many prompts at all of them; on release the Dictator loops `selector.targets` and broadcasts to each (`main.swift:771`).

Each `Target` (`SelectorEngine.swift:16`) stores both the `AXUIElement` and the exact `clickPoint`. The click point is load-bearing: the captured AX element is flaky in Electron/web apps (returns toolbar junk), but the click point is by definition on the real input, so the Dictator focuses by clicking the point and then types. This also drives dedup in `addIfEditable` (`SelectorEngine.swift:76`) - click-adds dedup by point proximity (within 8pt) because two distinct web inputs can return the *same* flaky AX element and element-equality would wrongly collapse them, while focus-adds (no click point) dedup by `CFEqual` element identity. `isEditable` (`SelectorEngine.swift:96`) accepts text-field/text-area/combo-box roles or any element whose `kAXValue` is settable. The coordinate flip in both `addElement` and `FieldHighlighter.screenRect` assumes the common single-display-or-right-of-primary arrangement (it flips against `NSScreen.screens.first` height); displays above/left of primary are not yet handled.

`FieldHighlighter` (`FieldHighlighter.swift:15`) draws a gold, border-only, click-through floating window over each target's screen rect so the user sees exactly what a dictation will hit - even when the target's window is behind others (`ignoresMouseEvents = true`, `level = .floating`, no interior fill, soft gold glow; `makeHighlight`, `FieldHighlighter.swift:46`). It is refreshed (`update(targets:)`, `FieldHighlighter.swift:19`) on every selector mutation from `main.swift` (`:208`, `:224`, `:269`). `screenRect(of:)` (`FieldHighlighter.swift:77`) reads `kAXPosition`/`kAXSize` and converts AX top-left (Quartz) coordinates to Cocoa bottom-left. Known v1 limitation noted in the source: it does not track live window moves or scrolls, so highlights only re-snap to position on the next selector change.

## Triggers, Automation, Cleanup, Recovery, and Build/Run

This section covers how a finalized transcript gets routed (trigger classification and
user-defined Automator workflows), the optional on-device punctuation cleanup pass, the
automatic word-recovery path, and how the CLI binary is built, signed, and driven.

### What it does

After the recognizer emits a final transcript, `finalize(transcript:)`
(`main.swift:509`) asks `TriggerRouter.classify` what to do with it, then either commits
the text as plain dictation, fires a bound Automator workflow, or (for unwired trigger
verbs) falls back to plain dictation. A separate background path
(`Dictator.autoRecover`, `main.swift:675`) re-transcribes the saved audio off the
recognizer's saved WAV when the live pass looks suspiciously short and surfaces anything
it recovers. An optional `Cleanup` pass can repair punctuation/capitalization with an
on-device LLM, but it is currently OFF the release path. All of this is reachable and
inspectable through the `sonar-dictate` CLI subcommands, and the whole thing ships as a
code-signed `.app` produced by `scripts/build-app.sh`.

### How it works

**Trigger classification (`Triggers.swift`).** `TriggerRouter.classify`
(`Triggers.swift:50`) trims the transcript, gives user-defined workflow bindings first
crack (longest-prefix match via `WorkflowStore.match`), then checks the first word
against a vocabulary set. The result is a `TriggerAction` enum (`Triggers.swift:13`):
`.dictate`, `.action`, `.llmPrompt`, `.note`, `.todo`, or `.runWorkflow`.

Built-in trigger words are DISABLED:

```swift
// Triggers.swift:48
static let defaultTriggers: Set<String> = []
```

With an empty vocabulary set, the `guard vocabulary.contains(first)` at
`Triggers.swift:79` always falls through to `.dictate`, so leading words like "yo",
"note", "todo", "claude" land as ordinary dictated text. WHY: the user dictates
naturally and often starts a sentence with "yo"; routing those to action/note/todo
handlers got in the way for zero benefit, because those handlers were never wired -- and
even when classified, `finalize`'s `default` case (`main.swift:535`) logs "no handler"
and falls back to `commitDictation(transcript)` rather than eating the user's words. So
the only live route besides plain dictation is `.runWorkflow`, which is gated on an
explicit user binding. The `switch first` block at `Triggers.swift:81` and the verb-based
`TriggerAction` cases are retained as scaffolding for the planned MCP-gateway / notes /
todo handlers but are dead paths today.

`TriggerAction.description` (`Triggers.swift:28`) is deliberately content-free -- it logs
only the route and a body LENGTH, never the spoken words. REGRESSION TRAP: this string is
logged on every utterance via `NSLog("classified -> \(action)")` (`main.swift:515`).
Interpolating any transcript text into a `description` case would put dictation content
(PHI) into the diagnostic log. Trigger verbs, target names, and workflow names are
user-chosen config labels, not dictation, so those stay.

**User-defined Automator workflows (`WorkflowStore.swift`).** A `WorkflowBinding`
(`WorkflowStore.swift:20`) ties a lowercased, trimmed trigger phrase to an absolute
`.workflow` bundle path. Bindings are persisted encrypted under the same Secure
Enclave-bound P-256 key as recordings (the key file `device.enclave-key` and
`SecureStore.baseDir` are shared; `WorkflowStore.init` at `WorkflowStore.swift:51` reuses
or creates that key), with per-blob ephemeral-key ECDH + HKDF-SHA256 + AES-GCM
(`encrypt`/`decrypt`, `WorkflowStore.swift:185`). `register` (`WorkflowStore.swift:84`)
expands the tilde, requires the bundle to exist, and rejects duplicate phrases.
`match` (`WorkflowStore.swift:122`) returns the binding whose phrase is the longest
case-insensitive prefix of the transcript. `execute` (`WorkflowStore.swift:141`) shells
out to `/usr/bin/automator`, passing the post-trigger remainder of the transcript via
`-i`:

```swift
// WorkflowStore.swift:152
if let input = input, !input.isEmpty {
    process.arguments = ["-i", input, binding.workflowPath]
} else {
    process.arguments = [binding.workflowPath]
}
```

In `finalize` the workflow runs on a detached task so it does not block
(`main.swift:526`). EGRESS CAVEAT: the transcript remainder is handed to an arbitrary
user-bound Automator workflow as a process argument (argv). Once a workflow is bound, the
words spoken after the trigger phrase leave the app's encrypted boundary in cleartext as
a launch argument to `automator`, and whatever that workflow does with its input (network
post, file write, AppleScript) is outside this app's control. The on-device,
encrypted-at-rest guarantee covers storage and the recognizer, NOT what a user-authored
workflow does with the text it is handed.

**Cleanup pass (`Cleanup.swift`) -- currently OFF the release path.** `Cleanup.clean`
(`Cleanup.swift:63`) runs Apple's on-device Foundation Models (`SystemLanguageModel`) with
a strict punctuation/capitalization-only instruction (`Cleanup.swift:49`). It is
word-preserving by enforcement, not just by prompt: `wordsPreserved`
(`Cleanup.swift:99`) normalizes both strings to lowercase ASCII-letter/digit word tokens
(stripping punctuation, treating straight and curly apostrophes as removable so "dont"
== "don't") and rejects the rewrite if the word sequence changed, dropped, added, or
reordered (`Cleanup.swift:82`). It fails open: any model-unavailability or error returns
the raw transcript. WHY it is off the release path: `commitDictation`
(`main.swift:744`) injects the raw recognizer text immediately and never awaits cleanup.
The old code did `await cleanup.clean()` (a multi-second on-device LLM call) BEFORE
injecting in cleanup-target apps, which produced a multi-second hang on key release --
fatal to a "text is in the field the instant you let go" product. `Cleanup.shouldClean`
(`Cleanup.swift:43`) and the per-session `sessionNeedsCleanup` flag
(`main.swift:352`) are still computed and logged, but only as a placeholder for the
planned live, as-you-speak cleanup pass (so cleaned text would be ready AT release, not
computed after it). `cleanupApps` (`Cleanup.swift:24`) lists document/messaging targets
(Notes, Mail, TextEdit, Pages, Slack, Outlook, Notion, Discord); LLM clients are
deliberately excluded because raw transcript is the right input for an LLM prompt.

**Automatic word recovery (`BatchTranscriber.swift` + `Dictator.autoRecover`).** The
live streaming engine (`DictationTranscriber`) can drop words under rapid or short use,
but the full audio is always persisted, so the saved WAV can be re-recognized.
`autoRecover` (`main.swift:675`) runs after persistence on a utility queue. It estimates
expected length at ~6 chars/sec (`let floor = durationSeconds * 6.0`,
`main.swift:677`) and only proceeds when the session is at least 1s, the live transcript
is empty or below that floor, and audio exists. It writes the WAV to a temp file and calls
`BatchTranscriber.recoverTranscript` (`BatchTranscriber.swift:33`), which uses a
file-based `SFSpeechURLRecognitionRequest` with `requiresOnDeviceRecognition = true` and
`shouldReportPartialResults = false` -- non-streaming recognition that sees the whole
utterance at once. The completion-handler API is bridged to a synchronous call with a
`DispatchSemaphore` (`BatchTranscriber.swift:48`). Recovered text is only surfaced when
it clearly beats the live pass (`trimmed.count > transcript.count + 4`,
`main.swift:689`), and then only into the draggable chip via `chip?.present` -- no
clipboard clobber, no hotkey needed. Logs report char COUNTS only, never the words
(`main.swift:690`).

`autoRecover` is `static` and takes the `chip` as a parameter (`main.swift:675`) because
its caller is the `persistSession` closure (`main.swift:560`), which intentionally
captures only the specific stores it needs and avoids capturing `self`.

**CLI subcommands and launch (`main.swift`).** The entry point (`main.swift:1239`)
splits on argv: any args go to `runCLI` (`main.swift:986`), which opens the stores and
dispatches a single command then exits; no args means background dictation mode.
`runCLI` handles recordings (`list`, `read <id>`, `delete <id>`, `reset`), workflows
(`workflows`, `bind`, `unbind`, `runwf`), RAG retrieval (`rag`, `similar`, `rag-reset`),
the personal dictionary (`dict [list|add|rm|reset]`), diagnostics (`logs [--follow]`),
a hidden `dev-correction` path that exercises the encrypted corrections write end-to-end,
and `help`. The `bind` subcommand (`main.swift:1059`) is how a user registers an Automator
workflow; `runwf` (`main.swift:1077`) fires one manually for testing.

The `logs` command (`main.swift:1181`) decrypts and prints the diagnostic log via
`EncryptedLog.readAll()` / `EncryptedLog.follow()`. CRITICAL launch step:
`EncryptedLog.install()` (`main.swift:1250`) runs before the background app starts and
pipes stderr (where `NSLog` writes) through an in-process AES-256-GCM sink keyed by the
Keychain DB key, migrating any pre-existing plaintext `~/Library/Logs/SonarDictate.log`
into the encrypted file and removing the cleartext. WHY: the old behavior left every
`NSLog` line in cleartext on a PHI machine. This is why log strings throughout the
codebase log lengths and counts, not content -- the encrypted log is the safety net, but
the content discipline is the primary defense. After init the app warms the speech model
in the background (`SpeechAnalyzerSession.prewarm()`, `main.swift:1298`) so the first
dictation is not the slow one.

### Build and run

`Package.swift` declares a single executable target `sonar-dictate` (a CLI binary), min
macOS 14, though the dictation runtime gates on macOS 26.0+ at launch
(`main.swift:1278`) because `SpeechAnalyzer` is unavailable below that.

`scripts/build-app.sh [debug|release]` runs `swift build`, copies the binary plus
`Resources/Info.plist` into `dist/SonarDictate.app/Contents/`, then codesigns. WHY the
`.app` wrapper: macOS terminates Speech / `AVAudioEngine` binaries that lack an
`Info.plist` with `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`,
and SwiftPM produces a bare CLI binary with no `Info.plist`.

WHY signing is load-bearing: an UNSIGNED `.app` gets a fresh code hash on every rebuild,
so macOS TCC invalidates its Accessibility grant each time (the "worked, then didn't"
whiplash). Signing with a STABLE identity makes TCC key the grant on the
(bundle-id + cert team) designated requirement, which is constant across rebuilds, so
Accessibility is granted once and sticks. The script auto-picks the local "Apple
Development" identity by SHA-1 hash (not by name -- the same cert can live in multiple
keychains, which makes name-based signing ambiguous), overridable via `SIGN_IDENTITY`,
and pins `--identifier` to the `com.sonarmd.dictate` bundle id so the requirement stays
stable.

REGRESSION TRAP: `scripts/build-app.sh` currently contains non-ASCII glyphs in its
`echo` and comment lines (decorative play/check/cross/warning marks and an em dash, e.g.
lines 22, 28, 32, 38, 44, 47, 58, 60, 62, 66). These violate the repo's ASCII-only rule
and should be replaced with ASCII (`>`, `[ok]`, `x`, `!`, ` - `) when the script is next
touched.

## What we changed and why (the 2026-06-13/14 session journey)

This section is the engineering narrative behind the current code. Every change below was deliberate, and the load-bearing ones are codified in `DECISIONS.md` and the plan files under `.claude/plans/`. The capture pipeline that came out of this work is now SEALED (`DECISIONS.md:71`); the items here explain how it got there.

### 1. The "swallow" investigation: hypotheses refuted, real causes found in the logs

The reported symptom was that a whole utterance would sometimes drop to empty on release, or land slowly ("two letters, hang ~5s, then the rest"). Rather than patch the first plausible theory, we ran an adversarial audit against the encrypted diagnostic log. The audit split one reported "bug" into two distinct phenomena and refuted the original guesses:

- REFUTED: empty-final-wipes-volatile, trigger words eating text, and fast-repress cancellation (the log showed zero cancelled sessions). The `guard !plain.isEmpty` in `SpeechAnalyzerSession.handle(result:)` (`SpeechAnalyzerSession.swift:296`) was kept as cheap hardening, NOT because it was the cause.
- REAL CAUSE A (the one the user actually hit): perfect transcription, but slow/partial injection. `inject()` typed character-by-character via CGEvent keystroke synthesis - 2 events per character, 1686 events for an 843-char utterance. Slow targets (Electron, terminals; e.g. dictating INTO Claude Code) could not drain that flood. Our code was fast (release-to-posted ~480ms); the target app was the bottleneck.
- REAL CAUSE B (separate, still open): the recognizer occasionally returns zero results on very short utterances. The log showed ~160 lifetime empty commits were all `results=0` - never a recognized-then-lost transcript. The leading hypothesis is startup latency clipping the front of short holds; the proposed fix (capture-from-keydown) touches the crash-sensitive audio lifecycle and was deferred. The prewarm in item 6 is the first mitigation.

The discipline here mattered: the cheap empty-final guard could have been mistaken for "the fix" and shipped, masking the real keystroke-flood and recognizer-latency causes.

### 2. The plaintext-log PHI leak -> encrypted log at rest

The audit surfaced a real compliance problem. stderr (where every `NSLog` writes) was redirected via `freopen` into a plaintext, 0644 `~/Library/Logs/SonarDictate.log`. A prior classifier log interpolated the first 40 chars of every utterance, and 5040 cleartext PHI snippets had accumulated on a PHI machine. Two deliberate fixes, recorded in `DECISIONS.md:3` and planned in `.claude/plans/encrypted-diagnostic-log.md`:

- Make the log line content-free. `TriggerAction.description` (`Triggers.swift:28`) now emits route + length only (`dictate(len=...)`), never the spoken words. Trigger verbs, target, and workflow names stay because they are user-chosen config labels, not dictation content.
- Encrypt the log at rest. `EncryptedLog.install()` (`EncryptedLog.swift:39`) pipes stderr through an in-process AES-256-GCM sink to `~/Library/Logs/SonarDictate.log.enc` (0600, complete file protection), migrates any pre-existing plaintext into one encrypted record, then removes the cleartext. The call site replaced the old `freopen` block at `main.swift:1250`.

Key decisions, all intentional:
- Key source is `KeychainStore.loadOrCreateDBKey()` (the corpus DB key), NOT the SecureStore Secure-Enclave key. The Enclave key triggers Touch ID prompts from background contexts, and the sink installs at launch, possibly in the background (`EncryptedLog.swift:12`).
- On-disk format is append-only framed records `[4-byte BE length][AES.GCM.combined]`, one independent GCM seal per record. A crash-truncated trailing record is detected by the length prefix and skipped on read (`EncryptedLog.swift:138`, the `decode` loop breaks on the first malformed record).
- FAIL SAFE: if the key is unavailable, `install()` does NOT fall back to plaintext - diagnostics go to the unified log only (`EncryptedLog.swift:44`). The whole point was to stop writing cleartext.
- REGRESSION TRAP: never call `NSLog` inside `append()` or the readability handler - it would write back into the same stderr pipe and recurse (`EncryptedLog.swift:86`).
- `tail`/`grep` no longer work on the log. The replacement is `sonar-dictate logs [--follow]` (`main.swift:1181`), backed by `EncryptedLog.readAll()` / `follow()`.

Honest limitations noted at decision time: true secure-erase of the old plaintext is not achievable at the app level on APFS (copy-on-write / SSD wear-leveling); we truncate-then-remove. And the log key is the Keychain DB key, so `sonar-dictate reset` (which wipes only SecureStore + the SE key) does NOT yet purge the encrypted log (`DECISIONS.md:27`).

### 3. Paste-injection replaces keystroke synthesis

This is the fix for REAL CAUSE A and is now INVARIANT 2 of the sealed core (`DECISIONS.md:92`). `inject()` (`main.swift:906`) sets the clipboard and synthesizes Cmd-V via `postPaste()` (`main.swift:933`) - a single action that delivers any length instantly, instead of a per-character flood that slow targets choke on. Deliberate tradeoffs:

- The dictated text is left on the clipboard on purpose. Restoring the previous contents on a timer would race a slow paste and could inject stale clipboard data into the user's field - a worse failure than a clobbered clipboard.
- `postPaste()` presses and releases Command around V (not just a flag on the V event) so apps that watch for an explicit modifier keyDown still register the paste.
- `injectByKeystroke()` (`main.swift:954`) is kept as a fallback only, used when the pasteboard cannot be set. It clears modifier flags so the physically-held hotkey modifier does not turn synthesized keys into dead-key combos.

### 4. Cleanup moved OFF the release path

`commitDictation` (`main.swift:744`) used to `await cleanup.clean()` - an on-device LLM, multiple seconds - BEFORE injecting in cleanup-target apps. That was a multi-second release hang, fatal to the product's only value proposition. It now calls `commit(trimmed)` immediately in every app; the old branch (the `Task { ... await cleanup.clean ... }` block) was deleted. This is INVARIANT 1 (`DECISIONS.md:90`): nothing on the release-to-inject path may block on async/LLM/network work.

The cleanup flag (`sessionNeedsCleanup`) is retained for a planned LIVE, as-you-speak cleanup pass (`.claude/plans/live-cleanup.md`): clean finalized segments in the background while the user speaks so the polished text is ready AT release, never computed after it. The plan explicitly forbids post-release field patching (no backspace+repaste), since that races the user's next keystrokes. Note: the LLM pass is punctuation-only and word-preserving by contract; the live word-revision users like is the recognizer revising volatile results, not the LLM.

### 5. Launch prewarm

The first dictation paid a one-time cold model-load cost ("big delay when I first start"). `SpeechAnalyzerSession.prewarm()` (`SpeechAnalyzerSession.swift:228`) spins up a throwaway analyzer at launch and feeds it ~100ms of synthetic silence in the analyzer's own format - no AVAudioEngine, no mic, no privacy indicator, no permission prompt. It only warms when assets are already installed (never triggers a download) and is best-effort. The call site is a detached utility task at `main.swift:1298`. This is INVARIANT 4 (`DECISIONS.md:94`) and the first mitigation for REAL CAUSE B.

### 6. The vocabulary `setContext` fix (the dictionary was collected but never applied)

A latent correctness bug, recorded in `DECISIONS.md:55`. The personal dictionary and RAG terms were collected and passed to `setContextualStrings()` (`SpeechAnalyzerSession.swift:62`), which populated `AnalysisContext.contextualStrings[.general]` - but that `AnalysisContext` was NEVER handed to the analyzer, so the bias did nothing and jargon got mangled ("git" -> "get", "egress" -> "addresses") even when the term was in the dictionary. The fix wires it in `start()`:

```swift
do {
    try await analyzer.setContext(context)
} catch {
    NSLog("SonarDictate: setContext failed ...; proceeding without vocabulary bias")
}
```

at `SpeechAnalyzerSession.swift:146`. This is INVARIANT 3 and the documented REGRESSION TRAP: building an `AnalysisContext` is not enough - it must be applied via `setContext` (or the analyzer init's `analysisContext:` param) or it silently does nothing.

### 7. Disabling built-in trigger words

`TriggerRouter.defaultTriggers` went from `["yo", "claude", "cursor", "note", "todo", "jira"]` to the empty set (`Triggers.swift:48`). The user dictates naturally - often starting with "yo" - and routing those words to action/note/todo handlers got in the way for zero benefit: those handlers were unwired and already fell back to plain dictation. With an empty set, `classify()` treats every utterance as plain dictation. User-defined workflow bindings (`WorkflowStore`) are unaffected; they are matched separately and only fire when the user explicitly binds a phrase.

### 8. Control panel, widget drag fix, and the post-dictation crash fix

Three peripheral-UI changes (peripherals are OPEN for iteration per `DECISIONS.md:96`):

- Control panel (`.claude/plans/control-panel.md`, `ControlPanel.swift`, `StatusItemController.swift`). Clicking the menu-bar mic now opens an `NSPopover` control panel instead of an `NSMenu` (NSMenu cannot hold a text field). The key design win: `StatusItemController` gets the SAME `DictionaryStore` instance the Dictator uses (the new `dictionary:` arg threaded through `main.swift:1280`), so a word added in the panel takes effect on the NEXT dictation with no app restart - removing the CLI/restart friction. The popover uses `behavior = .applicationDefined` with a global click monitor (`StatusItemController.swift:36`) so a click on the mic toggles it cleanly instead of AppKit auto-dismissing mid-click.
- Widget drag fix (`RecordingOverlay.swift:239`). The floating widget could only be dragged from outside the icon. The mic `NSImageView` and text `NSTextField` are `NSControl`s that return `mouseDownCanMoveWindow=false` and swallowed the click, blocking `isMovableByWindowBackground`. New `DragPassthroughEffectView` overrides `hitTest` so every click inside the widget resolves to the plain background view (draggable) and clicks outside pass through. Now the whole widget drags.
- Post-dictation crash fix (`ControlPanel.swift:144`). `refreshCounts()` fires after every dictation finalize, which can be long before the user ever opens the panel. The popover's view (and its implicitly-unwrapped outlets like `cleanupToggle`) only exist after the panel is first opened. `refresh()` touched `cleanupToggle` before `loadView()` had run, crashing the app on the first dictation if the panel was never opened. Fixed with `guard isViewLoaded else { return }` in both `refresh()` and `setState()` (`ControlPanel.swift:140`, `:149`): no view means nothing to update, just remember the state.
