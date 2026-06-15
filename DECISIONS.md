# Architectural Decisions

## 2026-06-13 - Diagnostic log is encrypted at rest

The app redirected stderr (every NSLog) into a plaintext, 0644
`~/Library/Logs/SonarDictate.log`. On a PHI machine that was a leak: a prior
classifier log interpolated the first 40 chars of every utterance
(`TriggerAction.description`), and 5040 cleartext snippets had accumulated.

Decision:
- `TriggerAction.description` is content-free (route + length only, never the
  spoken words). See `Triggers.swift`.
- stderr is piped through an in-process AES-256-GCM sink (`EncryptedLog`) to
  `~/Library/Logs/SonarDictate.log.enc` (0600, complete file protection).
- Key: `KeychainStore.loadOrCreateDBKey()` (same key as the corpus DB), NOT the
  SecureStore Secure-Enclave key, because the Enclave key triggers Touch ID
  prompts from background contexts and the sink installs at launch.
- On-disk format: append-only framed records `[4-byte BE length][AES.GCM.combined]`,
  one independent GCM seal per record; a crash-truncated trailing record is
  skipped on read.
- Any pre-existing plaintext log is migrated into one encrypted record and the
  cleartext removed on first launch.
- Read it back with `sonar-dictate logs [--follow]`. `tail`/`grep` no longer
  work on the log; the CLI is the replacement and the way to capture live
  diagnostics.

Consequence: the encrypted log is keyed to the Keychain DB key; `sonar-dictate
reset` (which today wipes only SecureStore + the SE key) does not yet wipe the
log key, so the encrypted log survives a reset. Revisit if reset should also
purge it.

## 2026-06-13 - Instant-on-release is inviolable; cleanup never blocks injection

The product's entire value is that releasing the talk key puts the text in the
field instantly. Two things were breaking that and are fixed:

1. inject() typed text character-by-character (CGEvent keystroke synthesis, 2
   events/char). Slow targets (Electron/terminal) choked on long text -> stalls
   and partial drops. Now inject() PASTES (clipboard + Cmd-V via postPaste()),
   instant for any length. Dictated text is left on the clipboard (no timed
   restore - it races a slow paste and could inject stale data). Keystroke path
   kept as injectByKeystroke() fallback when the pasteboard can't be set.

2. commitDictation ran `await cleanup.clean()` (on-device LLM, ~seconds) BEFORE
   injecting in cleanup-target apps - a multi-second release hang. Cleanup is no
   longer allowed to block release; commitDictation injects the recognizer's
   final text immediately in every app.

Rule: nothing on the release->inject path may block on async/LLM work. Cleanup,
if reinstated, must run live during dictation so the result is ready AT release.
See .claude/plans/live-cleanup.md. Note the LLM cleanup is punctuation-only and
word-preserving; the live word-revision users notice is the recognizer, not the
LLM.

## 2026-06-13 - Vocabulary bias must be applied via SpeechAnalyzer.setContext

The personal dictionary (DictionaryStore) and RAG terms were being collected and
passed to SpeechAnalyzerSession.setContextualStrings(), which set
`AnalysisContext.contextualStrings[.general]` - but that AnalysisContext was NEVER
handed to the analyzer, so the bias did nothing and jargon got mangled even when
the term was in the dictionary. Fix: SpeechAnalyzerSession.start() now calls
`try await analyzer.setContext(context)` after creating the analyzer (best-effort;
a failure logs and proceeds unbiased). REGRESSION-PRONE: building an AnalysisContext
is not enough - it must be applied via setContext (or the analyzer init's
analysisContext: param) or it silently does nothing.

Note: the running app loads the dictionary once at launch (DictionaryStore.init),
so `sonar-dictate dict add` from the CLI only takes effect after an app restart.
Reloading the dictionary per session would remove that friction (not yet done).

## 2026-06-14 - CORE CAPTURE IS SEALED (change requires explicit owner approval)

The core capture pipeline is finished and validated by the owner ("its so fucking
fast i fucking love it"). It is now SEALED. No agent may alter the files/functions
below without the owner's explicit, per-change approval. This is intentional: the
instant-capture feel is the entire product and was hard-won across a long debugging
session (see the entries above). Do not "improve", refactor, or optimize it on your
own initiative.

SEALED - the capture -> recognize -> assemble -> inject path:
- Sources/SonarDictate/SpeechAnalyzerSession.swift  (ENTIRE FILE): DictationTranscriber
  setup, audio-format negotiation + AVAudioConverter, finalized-vs-volatile assembly
  and the empty-final guard, stop()/finalizeAndFinishThroughEndOfInput ordering,
  setContext vocabulary-bias wire, and prewarm().
- Sources/SonarDictate/main.swift, the Dictator capture path ONLY: the audio tap
  closure, startListening, stopListening, handleTranscript, decideMode, finalize,
  commitDictation, commit, inject, postPaste, injectByKeystroke, serializeWAV.

INVARIANTS that must never regress without approval:
1. Release-to-field is INSTANT. Nothing on the release -> inject path may block on
   async/LLM/network work. (Cleanup stays OFF this path.)
2. Injection is by PASTE (clipboard + Cmd-V), not per-character keystrokes.
3. The vocabulary bias must be APPLIED via SpeechAnalyzer.setContext, not just built.
4. The model is prewarmed at launch so the first dictation is not the slow one.

OPEN for iteration WITHOUT per-change approval (the "peripherals"): all UI
(ControlPanel, StatusItemController, RecordingOverlay, HistoryWindow, TextChip,
FieldHighlighter, SelectorEngine), DictionaryStore, RAGIndex, EditWatcher,
EncryptedLog, Cleanup (as long as it stays off the release path), WorkflowStore,
BatchTranscriber, the CLI, and build tooling. Storage/crypto (SecureStore,
KeychainStore, RecordingDatabase) remains protected by the global security
directives regardless.

## 2026-06-15 - SEALED FIX (owner-approved): overlapping-session commit drop

Owner approved a change to the sealed capture path to fix a real drop: a long,
fully-recognized dictation (visible word-for-word in the widget) vanished on
release. Root cause, confirmed from the encrypted log: the per-session one-shot
commit guard `finalPersisted` is a single shared flag, and a stale/aborted
session's EMPTY final (e.g., a fed=0 short-tap abort) completed ~15ms AFTER the
new session reset the flag, set finalPersisted=true, so the new session's real
final hit `guard !finalPersisted` in finalize() and was silently skipped - no
error, no commit, no inject. Evidence: `FINAL assembled len=323` logged with no
following `classified`/`inject`; an empty fed=0 final landed right after the new
session's startListening.

Fix (main.swift, capture path):
1. finalize(): an empty (whitespace-only) final is a no-op - it does NOT set
   finalPersisted and does not persist. A stale empty final can no longer poison
   the slot. (Also stops persisting junk empty recordings.)
2. stopListening(): reset finalPersisted=false on every release, so each real
   release gets a fresh commit slot even if something stale tripped it mid-record.

No async/format/engine-lifecycle changes; behavior-preserving except closing the
drop. Invariant still holds: one commit per real (non-empty) final per release.

## 2026-06-15 - SEALED ADDITIVE (owner-approved): live widget signal taps

Owner chose "Build the live visual," which requires the floating widget to read
live signals that only exist inside the sealed capture path. The capture path was
touched ONLY to PUBLISH signals to a new peripheral bus (WidgetSignals); nothing
inside transcription reads them, and none of the four sealed invariants
(instant-on-release, paste-not-keystrokes, setContext-bias, prewarm) is affected.

Additive taps (SpeechAnalyzerSession.swift):
1. recordDiagnostics(): the per-buffer sample loop already scanned for peak; it
   now also sums squares and publishes the buffer RMS via
   WidgetSignals.publishEnergy() (realtime thread; single lock + float store).
2. handle(): a non-empty final calls WidgetSignals.snap() (the finalize pulse);
   volatile updates publish a confidence PROXY derived from volatile-tail churn
   (a retracted/shortened guess reads as uncertainty). This is a placeholder for
   a real transcriptionConfidence read; it is not consumed by transcription.

The visualization itself is peripheral: WidgetSignals.swift (thread-safe bus) and
LEDMicView.swift (mic-shaped LED matrix; energy=bars+color, confidence=integrity,
snap/release=lock), hosted by RecordingOverlay. Energy/confidence mapping and the
release/lock animation are expected to be tuned live at true widget size.
