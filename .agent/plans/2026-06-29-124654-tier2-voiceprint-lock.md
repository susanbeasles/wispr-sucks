---
name: tier2-voiceprint-lock
status: in_progress
blast_radius: medium
owner_approved: yes (owner: "nice yeah" - proceed with tier 2 after tier 1 merged)
design_ref: ~/code/voiceprint-build/README.md (ECAPA proof, 0.359 separation gap)
builds_on: .agent/plans/2026-06-29-105844-native-voice-isolation.md (tier 1 merged, PR #1)
---

# Tier 2: lock voice isolation onto the OWNER via ECAPA voiceprint

## Goal

Tier 1 isolates ANY voice (harmonics of the tracked F0). Tier 2 makes it the
OWNER'S voice: enroll the owner once, compute a speaker embedding at runtime, and
gate/weight the isolation + transcriber feed by cosine similarity to the enrolled
template. Single mic, no system-audio grant (only a local model file).

## Proven foundation (voiceprint-build)

ECAPA-TDNN (SpeechBrain spkrec-ecapa-voxceleb, 192-dim L2-normalized). Local weights
ecapa_model/embedding_model.ckpt (83MB). Pipeline: audio -> Fbank(80 mel) ->
InputNormalization(sentence) -> ECAPA_TDNN -> 192-dim -> L2 normalize. Validated
same-speaker cosine 0.72-0.88, diff 0.03-0.37, gap 0.359, threshold ~0.55-0.6.
coremltools 9.0 already imports in the .venv (py3.13); README's py<=3.12 is stale.

## Phases (validate each before the next)

P1 - CoreML conversion (KEYSTONE, in voiceprint-build):
  Convert the embedding pipeline to a .mlpackage. Plan A: full graph (audio ->
  192-dim) so Swift only feeds samples. If Fbank/STFT ops do not convert cleanly,
  Plan B: convert ECAPA_TDNN only (input [1,T,80] log-mel), compute Fbank + sentence
  MVN in Swift (vDSP). VALIDATE: CoreML embeddings reproduce the PyTorch cosines on
  clips2/ (same/diff gap within ~0.02 of 0.359). Conversion script lives in
  voiceprint-build (has env+weights+clips); only the .mlpackage ships to sonar-dictate.

P2 - Swift inference (VoiceEmbedder.swift, sonar-dictate):
  Load the .mlpackage, audio (+ Swift Fbank if Plan B) -> 192-dim L2 embedding.
  Unit-check against a known clip's expected embedding.

P3 - Enrollment (CLI + storage):
  `sonar-dictate enroll` captures a few seconds, averages embeddings into a template,
  stores it as BIOMETRIC in SecureStore/Keychain (never plaintext, never logged).
  `enroll --status` / `--reset`.

P4 - Runtime gate (seam, behind IRIS_VOICEPRINT, default OFF):
  Sliding-window embedding during dictation; cosine vs template. Above threshold ->
  owner present -> isolate + forward; below -> attenuate/hold. Conservative + the
  tier-1 hysteresis so the owner is never clipped. Raw WAV always complete.

## Safety / seal

DECISIONS.md 2026-06-14: P4 touches the sealed capture seam (same flagged-default-off
discipline as tier 1). Voiceprint = biometric: SecureStore only, never logged. Model
file is large - store under Resources/models, sign in build-app.sh, gitignore the raw
ckpt (ship only the converted mlpackage or fetch+convert via a documented script).

## Done means

CoreML embeddings match the PyTorch proof; enrollment stores an owner template
securely; behind IRIS_VOICEPRINT, dictation locks onto the owner over music/other
voices with no owner-word drop; then consider default-on.

## Risks (honest)

- Fbank/STFT may not convert -> Plan B (Swift Fbank), more work, must match SpeechBrain
  exactly (mel basis, log offset, sentence MVN) or embeddings drift.
- ECAPA needs ~1-3s of audio for a stable embedding; per-tiny-buffer gating is noisy
  -> gate on a sliding window/utterance, not per 1024-sample buffer.
- Latency/ANE budget for live gating - validate it does not slow capture.
