# Plan: word recovery from saved audio (re-transcribe)

Date: 2026-06-06
Repo: sonar-dictate
Status: done (AUTOMATIC). Evolution this session:
  - CLI `retranscribe` removed: SFSpeechRecognizer auth does NOT carry to a bare
    command-line launch (TCC binds it to the app).
  - ctrl-opt-R hotkey removed: user does not want hotkeys.
  - Final: automatic. persistSession calls Dictator.autoRecover when the live
    transcript is empty/short for the audio length (< durationSeconds*6 chars).
    It re-transcribes the saved WAV in the background and, only if it finds
    meaningfully more (> live+4 chars), pops the recovered text into the chip
    (click to copy). BatchTranscriber.swift reused. Build passes, live (PID 19502).

## Insight

Every dictation persists the FULL WAV, even when the live transcript came back
empty (e.g. recording b8728b8d: 349 KB / 2.0s of real speech, transcript empty).
The user's voice is never lost - only the live (streaming) transcript drops
words. Re-running recognition over the saved file recovers them.

## Feature (additive - never touches live dictation)

A `retranscribe <id>` path that re-runs recognition on a saved recording's audio
and prints the recovered text next to the live one.

- New `BatchTranscriber.swift`: `recoverTranscript(wavURL:) -> String` using
  `SFSpeechRecognizer` + `SFSpeechURLRecognitionRequest`, on-device only, final
  result. File/batch recognition is non-streaming and more forgiving than the
  live `DictationTranscriber` - a different engine, better on recorded audio.
- `main.swift` runCLI: `retranscribe <id>` - read SecureStore audio (already WAV
  bytes), write a temp .wav (shredded after), recover, print live-vs-recovered
  with char counts. Help line added.

## Verify
- `swift build` clean.
- `retranscribe b8728b8d` on a clip whose live transcript was empty: recovered
  text non-empty == words provably recoverable from the audio.

## Limits / notes
- Speech authorization for the CLI invocation inherits the signed app's TCC
  grant; if not authorized, the command fails cleanly (additive, breaks nothing).
- Next step (if proven): auto-recover in the background when the live pass comes
  back short, and a History-window "recover" button. Not in this slice.

## Constraints
- ASCII only. No push/PR without explicit approval.
