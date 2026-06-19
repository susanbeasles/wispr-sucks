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

UPDATE 2026-06-15 (owner-requested): the clipboard IS now restored. inject()
snapshots every pasteboard item/type before overwriting, pastes the dictation,
then restores the original ~0.5s later - guarded by NSPasteboard.changeCount so
it only restores when our dictated text is still on the board (if the user copied
something in the gap, that is left alone). The restore is deferred + async, so it
never blocks release->inject. The 0.5s delay avoids the race the original decision
warned about (an early restore makes a slow target paste the OLD contents); the
residual risk is only an app that reads the pasteboard later than 0.5s.

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

## 2026-06-18 - SEALED (owner-approved): mid-word truncation guard at finalize

Reported regression: dictation intermittently "cuts off the last letters" of the
final word (e.g. shows "github" live, commits "githu"). Diagnosed from the
encrypted log over 3025 speech sessions (analysis script + a 4-agent verification
pass):
  - 12.4% (376/3025) of sessions committed a FINAL whose text is SHORTER than the
    longest volatile the user already saw. Drop sizes cluster at 1-5 chars.
  - The final's AUDIO range end >= the peak volatile's range end in 375/376 cases
    (only 4/3025 sessions discard audio tail), and ZERO sessions dropped buffers.
  - Conclusion: not lost audio and not a buffer drop. The recognizer hears the
    whole word but its FORCED finalize commits a shorter PREFIX of its own peak
    hypothesis. All 376 are single-segment (no multi-segment assembly artifact).

Fix (SpeechAnalyzerSession.swift, handle(), final branch only): when a non-empty
final arrives that is a strict character PREFIX of the current volatileText, and
the dropped remainder (a) contains no space, (b) is <=5 chars, and (c) the final
ends mid-word (last char is a letter/digit), commit volatileText instead of the
truncated final. This is the deliberate, surprising part: we OVERRIDE the
recognizer's own final in this narrow case because what the user SAW (the volatile)
is the fuller, correct word. The guard is a strict superset of the old behavior -
it diverges ONLY on a clean single-token forward-extension; a real rewrite
("git" -> "get", not a prefix) or a whole-word collapse ("testing testing" ->
"testing", space in remainder) falls through to the final unchanged.

Why the caps (do not loosen without re-checking the log):
  - no-space remainder: a space means a DISTINCT later word the final intentionally
    dropped (correct collapse), not a truncated tail. Restoring it would re-inject
    text the model deliberately removed.
  - <=5 chars: a longer no-space tail over a multi-second utterance is a deliberate
    revision / URL / compound, not one truncated English word. Caps the blast
    radius of a prefix-shaped revision (e.g. "bilaterally" -> "bilateral") to one
    short token. Accepted false negative: rare long single-word truncations
    (">5 char tail") stay unfixed.
  - ends-mid-word: if the final already ends on a space or sentence punctuation the
    finalize ADDED, that is an improvement, not a truncation - leave it.

Measurement: logSessionDiagnostics() now emits content-free `truncRestore=N
restoredChars=M` (counts only, no transcript text) so `sonar-dictate logs` proves
how often the guard fires and lets a follow-up baseline quantify precision. If a
text-bearing (gated) log is ever added, the no-space/prefix predicates can be
measured directly; the len-only log cannot separate truncation from a
prefix-shaped revision per-session.

## 2026-06-18 - The Eyes: on-device screen perception (new capability, Phase 1)

New peripheral subsystem ("the eyes"): the app can watch a user-placed region of
the screen and produce a live situational read, fully on-device. First brick of a
larger goal (a see/speak/embody companion); see
.claude/plans/the-eyes-screen-perception.md and the paired rollback.

Decision / shape (Phase 1):
- Capture: ScreenCaptureKit (SCScreenshotManager), one-shot per 3s heartbeat of a
  resizable, persistent "look here" overlay frame (EyeOverlay). Region capture, not
  full-display. The SCStream rolling replay buffer is deferred to Phase 3.
- OCR: Apple Vision (VNRecognizeTextRequest), on-device.
- Reasoning: Apple FoundationModels text LLM over the OCR text (the on-device model
  is text-only in macOS 26.5 - verified; a local VLM via ollama for true pixel
  sight is Phase 3). Mirrors Cleanup.swift; fails open.
- Delta gate: a cheap text-change ratio gates re-reasoning (Phase 1). The semantic
  embedding gate + perceptual memory (reusing RAGIndex) is Phase 2.
- Output: EyeSignals (in-memory bus) + a caption strip below the frame. The caption
  sits OUTSIDE the watched rect so the eyes never OCR their own output.
- Toggle: right-click / option-click the menu-bar mic. Off by default.

ISOLATION: the eyes share nothing with the SEALED capture path (no change to
SpeechAnalyzerSession or the Dictator capture path). New files only + launch
wiring + a menu toggle.

PHI POSTURE (load-bearing - the screen is the most sensitive surface on this box):
- Frames and OCR text live in memory only; nothing is persisted in Phase 1.
- Nothing leaves the device (no cloud model; ollama, when added, is localhost).
- No frame / OCR text / summary is ever written to a cleartext log (only the
  existing content-free NSLog lines on unavailability).
- Requires the macOS Screen Recording TCC grant; capture fails closed (a status
  hint) if denied. If any frame/text is ever persisted later, it must be AES-GCM
  encrypted at rest and Spotlight-excluded, exactly like RecordingDatabase.
