---
name: own-aec-replace-vpio
status: proposed
blast_radius: high
owner_approved: pending (owner said "and then replace VPIO"; capture path is SEALED -
  needs explicit per-change approval per DECISIONS.md 2026-06-14)
supersedes_context: .claude/plans/2026-06-24-053629-own-echo-canceller.md (phases 1-4
  proven in poc/aec; this plan is phase 5: integration)
---

# Replace Apple VPIO with our own NLMS acoustic echo canceller

## Goal

Dictate cleanly over music from ANY source (built-in, Bluetooth, external) with no
ducking of playback. Keep Apple's recognizer; own the cancellation in front of it.
Behind IRIS_OWN_AEC=1, default OFF until validated on-device. VPIO stays as a
fallback path; plain capture stays the default.

## What already exists (committed, poc/aec)

- aectap / aecsync: real CoreAudio capture - CATapDescription
  (monoGlobalTapButExcludeProcesses) + AudioHardwareCreateAggregateDevice combining
  the default mic (main subdevice) + the system-audio tap, one IOProc delivering
  [mic ch(s), reference ch(s)] frame-aligned on a single clock. Proven RMS>0.
- aecnlms: NLMS adaptive FIR in Accelerate/vDSP (dotpr/svesq/vsma), L=1024 taps
  (~64ms @ 16kHz), mu=0.5, eps=1e-6. Proven to converge (positive ERLE) on a
  synthetic music+room sim. This is the cancellation core.

## What is NOT done (the real work)

1. Real-time streaming canceller (POC NLMS is offline/batch over an array).
2. Double-talk handling: freeze/slow adaptation when the user speaks, or the filter
   diverges and eats the voice. (Parked-plan phase 4, never built.)
3. Exclude OUR OWN app's audio from the tap (pass our pid to the tap-exclude list)
   so Iris's TTS / playback is not treated as reference/echo.
4. Sample-rate + format: aggregate device is likely 48kHz multichannel; the
   recognizer path negotiates its own format. Resample/downmix the cleaned mono
   voice to what SpeechAnalyzerSession expects.
5. Entitlement + TCC: NSAudioCaptureUsageDescription in Resources/Info.plist and the
   system-audio-capture grant; fold into build-app.sh signing.
6. Wire the cleaned stream INTO the recognizer in place of the AVAudioEngine mic tap.

## SEAL constraint

DECISIONS.md 2026-06-14 seals the capture path (SpeechAnalyzerSession.swift entirely;
the Dictator capture path in main.swift: tap closure, startListening, stopListening,
handleTranscript, decideMode, finalize, commit*, inject*, serializeWAV). Phase B
below touches that path and requires explicit per-change owner approval. Phases A and
the new AECEngine module are net-new files and do not modify sealed code.

## Phases (validate each on-device before the next; never break working dictation)

A. AECEngine module (NEW file Sources/SonarDictate/AECEngine.swift), behind
   IRIS_OWN_AEC=1, NOT yet wired to the recognizer.
   - Port aecsync capture (tap + aggregate + IOProc), excluding our own pid.
   - Port aecnlms into a streaming canceller: per-IOProc-block, mic=d, ref=x,
     output cleaned e; carry filter state w across blocks.
   - Instrument: log per-interval ERLE + mic/residual RMS to the ENCRYPTED log
     (EncryptedLog), never plaintext. Validate: music playing, no voice ->
     residual near silence (positive ERLE).
   - Owner gate: confirm reference capture + cancellation work on THIS hardware,
     including a Bluetooth output device.

B. Wire cleaned output -> recognizer (SEALED - per-change approval here).
   - When IRIS_OWN_AEC=1, source frames from AECEngine instead of the AVAudioEngine
     mic tap; convert to the negotiated recognizer format; feed SpeechAnalyzerSession.
   - VPIO path and plain path unchanged for other flag states.
   - Owner gate: dictate over speaker music AND over Bluetooth; transcript captures
     voice, music does not bleed into text.

C. Double-talk + tuning.
   - Add a double-talk detector (energy ratio / normalized cross-correlation);
     hold adaptation during near-end speech so the voice is never cancelled.
   - Budget: NLMS must fit the realtime IOProc deadline (alloc-free, vDSP).
   - Owner gate: speak continuously over loud music; no word clipping; stable.

D. Entitlements + ship.
   - NSAudioCaptureUsageDescription in Info.plist; system-audio-capture grant flow;
     build-app.sh signs for the entitlement. Then consider flipping IRIS_OWN_AEC on
     by default; VPIO becomes the explicit fallback.

## Done means

Music (any source, incl. Bluetooth) playing, user dictating: transcript captures the
user's words, music does not bleed in, ERLE meaningfully positive, voice never
clipped during double-talk. All native (Apple recognizer + CoreAudio tap), our
canceller. IRIS_OWN_AEC validated, then default-on with VPIO as fallback.

## Rollback

Each phase is behind IRIS_OWN_AEC and additive; phase B keeps the existing paths for
other flag states. Revert is per-commit. blast_radius high because phase B edits the
sealed capture path - paired rollback note required before phase B executes.

## Prereq

Validate the stop-the-bleeding pass first (2026-06-29-061130) so there is a known-good
baseline (normal + Bluetooth dictation clean, Sentry wins) before the rewrite begins.
