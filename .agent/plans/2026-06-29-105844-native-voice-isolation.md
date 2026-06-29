---
name: native-voice-isolation
status: in_progress
blast_radius: medium
owner_approved: yes (owner: revert AEC + build native harmonic isolation - "okay")
supersedes_context: .agent/plans/2026-06-29-071120-own-aec-replace-vpio.md (AEC reverted:
  it needs the system-audio-capture grant we are avoiding)
design_ref: .claude/plans/2026-06-24-023720-voice-isolation-and-cleanup.md (tiers 1-3)
---

# Native, reference-free, single-mic voice isolation (no system-audio grant)

## Principle (from the owner)

Dictate over music from an EXTERNAL speaker and have only the owner's voice reach
the transcriber. Recognize the owner by the pitch/harmonics/rhythm of their voice.
NO system-audio tap, NO system-audio-capture grant. Single mic only.

## Forensic note

The "working" version the owner remembered was never shipped as Swift. Transcripts
hold only: the generic VoiceGate (committed) and a Python ECAPA voiceprint PROOF in
/Users/avespoli/code/voiceprint-build (192-dim, threshold ~0.55) for a vault unlock,
never converted to CoreML or wired to the mic. So this is a build, grounded in the
tier plan, not a recovery.

## Grant clarification

The permission to avoid is the SYSTEM-AUDIO-CAPTURE grant (tapping all output). The
voiceprint/TSE models (tiers 2/3) are single-mic and do NOT need that grant - they
need a model file (one download). So model-based tiers are still "no grant".

## Approach (cardinal rule: degraded/dropped words is the sin)

T1a - native harmonic isolation (this plan, offline-validated FIRST):
  STFT (vDSP.DFT, N=1024, 75% Hann overlap-add). Per frame, with the F0 the gate
  already tracks: keep spectral bins within tolerance of harmonics k*F0, soft-
  attenuate the rest (inharmonic music/noise) to a floor (not zero - limits musical
  noise). UNVOICED frames (no F0) pass through UNCHANGED so consonants survive.
  - Build as a PURE function isolate(samples, sr, f0) -> samples (no realtime/seal
    risk), validated by an `isotest` CLI on synthetic voice+music: report music
    suppression (dB) and voice retention before any wiring.
T1b - streaming wrapper + seam wiring (SEALED capture path - per-change approval):
  Insert at main.swift ~474: when the gate forwards a VOICED buffer, append the
  CLEANED buffer to session.append; raw WAV (audioFrames) stays untouched. Behind
  IRIS_HARMONIC_ISO, DEFAULT OFF, so current instant-capture dictation is unchanged
  until the owner opts in to validate. Must add no perceptible latency.
T2 - voiceprint lock (later, no grant, needs model): convert the voiceprint-build
  ECAPA proof to CoreML; gate/weight isolation by cosine similarity to enrollment so
  it locks onto the OWNER, not any voice. Voiceprint = biometric -> SecureStore.
T3 - target-speaker extraction (stretch): CoreML TSE (VoiceFilter/SpeakerBeam) for
  true separation when voice + music overlap heavily.

## Honest expectation

Pure-DSP single-mic separation of voice from music is genuinely hard; the harmonic
mask is a real but imperfect first tier (artifacts, limited on heavy overlap). The
robust win is T2/T3 (models, still no grant). isotest will show the real numbers.

## SEAL + safety

SpeechAnalyzerSession untouched. T1b edits the sealed Dictator capture seam - default
OFF flag, raw WAV always complete, validate no word-drop/latency on-device before any
default change. DECISIONS.md 2026-06-14.

## Done means

isotest shows meaningful music suppression with voice retained; wired behind
IRIS_HARMONIC_ISO; on-device validation that voiced dictation over an external
speaker reaches the transcriber clean with no dropped/clipped words; then consider
default-on with VPIO removed.
