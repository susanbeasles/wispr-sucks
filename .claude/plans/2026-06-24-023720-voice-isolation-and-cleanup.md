# Plan: best-in-class voice isolation + cleanup

Date: 2026-06-24
Repo: sonar-dictate (SonarDictate, SwiftPM, macOS 26)
Status: planning

## What the user wants

Dictate over loud music and have ONLY their voice reach the transcriber. A
filter that recognizes the user by voiceprint/pitch and refuses to pipe music,
other speakers, or noise into the interpreter. "Be the best at it."

Plus the cleanup lane (split main.swift, repo hygiene). Build is already clean
(0 warnings), so the "dead code + warnings" item is essentially done.

## Current state (grounded in code)

- "Voice isolation ON by default" today = `engine.inputNode
  .setVoiceProcessingEnabled(true)` (main.swift ~144) = Apple VPIO: acoustic
  echo cancellation + generic noise suppression. It cancels music played
  through THIS Mac's own output (as echo - hence the duplex render fix in git
  log), but it is NOT speaker-aware: cannot separate the user from another
  human voice or from music on an external speaker.
- Audio seam: tap at main.swift:439-449. Each buffer is cloned, stored raw for
  WAV (`audioFrames`), and fed to the transcriber via `session.append(buffer:)`
  (line 448). THE GATE INSERTS HERE: gate what reaches session.append; keep
  audioFrames raw (full record).
- Cutoff bug from the old plan appears already fixed (stopListening reordering,
  486-495). Confirm on-device, do not re-touch blindly.

## Approach - tiered, safest first

Target-speaker isolation is real ML work. Tier it so each step ships value and
the risky parts come last. Dropped-words sensitivity is paramount: every tier
gates ONLY the transcriber feed, never the raw WAV, and rolls out in shadow
mode first.

- Tier 0 (now, native): confirm VPIO is fully engaged + duplex render intact.
- Tier 1 (native, no model, no network): `VoiceGate` at the seam. vDSP/Accelerate
  analyzer per short window: voiced-speech detection (autocorrelation pitch in
  ~80-300Hz), energy, spectral flatness (music/broadband -> high flatness ->
  reject). Hysteresis: once the user is speaking, hold the gate open through
  short pauses so word endings are never clipped. SHADOW MODE FIRST: compute and
  log forward/drop decisions, drop NOTHING, until validated against real
  dictations that it never false-drops speech. Then flip to active.
- Tier 2 (speaker-specific, needs model + network): enroll the user's voiceprint
  once (a few seconds), compute a speaker embedding via a CoreML model
  (ECAPA-TDNN / x-vector class, ~10-20MB, ANE, <10ms/window). Gate on cosine
  similarity to the enrollment. Store the voiceprint as sensitive/biometric data
  in SecureStore. BLOCKED: fetching/converting the CoreML model needs network
  (DNS currently down).
- Tier 3 (the "best at it" stretch): target-speaker EXTRACTION (separation), not
  just gating - a CoreML TSE model (VoiceFilter / SpeakerBeam class) that
  subtracts music/other voices from frames where the user IS speaking and feeds
  CLEANED audio to the transcriber. Heaviest; real-time latency budget must be
  validated. Needs model + network.

## Safety rules (dropped-words is the cardinal sin)

- Gate only `session.append`; raw WAV stays complete.
- Shadow mode -> measure false-drop rate on real speech -> only then activate.
- Conservative thresholds + open-gate hysteresis around speech.
- Hard off-switch env var; default conservative.
- Voiceprint = biometric: SecureStore, never logged in plaintext.

## Cleanup lane (lower priority, unblocked)

- Split main.swift (1586 lines) into focused files in-module: recording
  lifecycle, hotkeys, paste, persistence, CLI. Mechanical, behavior-preserving;
  delicate audio race code stays intact, just relocated.
- Repo hygiene: untrack built `dist/SonarDictate.app` + `.DS_Store`, add to
  .gitignore; note stray `~/code/sonar-dictate.zip` (outside repo).
- Warnings: already 0.

## Recommended sequence

1. Tier 1 VoiceGate seam in shadow mode (native, unblocked, real progress).
2. main.swift split (safe, makes the audio code easier to work in).
3. Tier 2 voiceprint gate when network is back (model fetch).
4. Tier 3 separation as the best-in-class finish.

## Open decision for the user

Start Tier 1 (native shadow-mode gate) now, or hold the whole feature until
network is back and go straight for the Tier 2/3 model-based path? Tier 1 is
real, safe, and ships today; Tier 2/3 is what makes it truly speaker-specific.
