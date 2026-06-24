# Plan: our own acoustic echo canceller (take Apple's recognizer, own the cancellation)

Date: 2026-06-24
Repo: sonar-dictate
Status: planning -> phase 1 (reference capture proof)

## Principle (from the user)

Apple did the hard NLP/speech-recognition research and ships it free - we take
advantage of the recognizer. The HEAVY LIFT we WANT to own is the acoustic
cancellation in front of it: blast music (any source), keep only the user's
voice into the transcriber. Not VPIO's black-box AEC - ours.

## Why native is feasible (verified)

macOS 14.4+ CoreAudio process taps exist:
- CATapDescription.initMonoGlobalTapButExcludeProcesses -> tap ALL system audio
  output except our own app = the reference signal (the music/whatever plays).
- AudioHardwareCreateProcessTap + AudioHardwareCreateAggregateDevice -> read it.
No BlackHole, no kext, no install. Apple gives us the recognizer AND the tap.

## Architecture

- Reference: process tap on system output (exclude self) = exact playing audio.
- Mic: raw input.
- SYNC TRICK: put BOTH the tap and the mic in ONE aggregate device so frames
  arrive sample-aligned on a single clock. Aligning two independent streams
  (different clocks/latency) is the trap; the aggregate device avoids it.
- Canceller (ours): adaptive NLMS FIR filter. Learn the echo path (output
  latency + acoustic delay + room + speaker color), subtract the estimated
  echo of the reference from the mic -> clean voice.
- Downstream: clean mono voice -> existing SpeechAnalyzerSession (Apple's model).

## The genuinely hard parts (what we are buying with this work)

- Double-talk: when near-end speech (user) and far-end (music) are both loud,
  freeze/slow adaptation or the filter diverges and eats the voice. Need a
  double-talk detector (e.g. normalized cross-correlation / energy ratio).
- Filter length: cover the echo delay + reverb tail (hundreds of ms) without
  blowing the realtime budget. NLMS in Accelerate (vDSP), allocation-free.
- Convergence + stability: step-size normalization, regularization, leakage.

## Phasing (verify each before the next; never break working dictation)

1. REFERENCE CAPTURE PROOF (this phase, standalone, NOT in the app): create the
   process tap + aggregate device + IOProc, capture ~2s while music plays,
   report RMS > 0. Proves we can get the reference. Surfaces the TCC/entitlement
   need (system-audio capture permission) in isolation.
2. SYNCHRONIZED MIC+REFERENCE: one aggregate device delivering [mic, ref]
   frame-aligned. Prove alignment (cross-correlate a played impulse).
3. NLMS CANCELLER: standalone - feed known mic+ref, measure echo return loss
   enhancement (ERLE) on a music-only segment (no voice -> output near silence).
4. DOUBLE-TALK: hold adaptation during near-end speech; verify voice survives.
5. INTEGRATE behind IRIS_OWN_AEC=1: replace the mic feed to the recognizer with
   the cancelled output. Default OFF until validated. VPIO path stays default.

## Entitlements / permissions

Process taps need the system-audio-capture TCC grant (NSAudioCaptureUsage
Description in Info.plist + user grant). The standalone proof will reveal the
exact requirement; fold into Resources/Info.plist + build-app.sh signing.

## Done means

Music playing, user dictating: transcript captures the user's words, the music
does not bleed into the text; ERLE meaningfully positive; voice never clipped
during double-talk. All native (Apple recognizer + CoreAudio tap), our canceller.
