# Voiceprint model (tier 2) - ECAPA speaker embedding

On-device speaker embedding for owner-locked voice isolation (tier 2 of
.agent/plans/2026-06-29-124654-tier2-voiceprint-lock.md). Lets the isolator gate on
"is this the OWNER speaking" by cosine similarity to an enrolled template. Single
mic, no system-audio grant - only this local model file.

## What ships

- `Resources/voiceprint/ECAPA_TDNN.mlpackage` - SpeechBrain spkrec-ecapa-voxceleb
  embedding model (192-dim, L2-normalized), converted to CoreML. Input: log-mel
  feats `[1, T, 80]` (flexible T); output: 192-dim embedding. Runs on ANE.
- `Resources/voiceprint/fbank_constants.json` - the EXACT Fbank constants (80x201
  triangular mel matrix + 400-pt Hamming window + STFT params) so the Swift feature
  extractor matches SpeechBrain bit-for-bit instead of reconstructing the mel basis.

## Validation (proven)

`convert_coreml.py` converts AND validates against the PyTorch reference on
voiceprint-build/clips2: CoreML reproduces the proof exactly -
same-speaker cosine avg 0.786, diff 0.181, separation gap 0.359, and per-clip
CoreML-vs-PyTorch agreement 1.0000. Threshold ~0.55-0.6 separates cleanly.

`golden.json` is a tracked fixture (one clip's audio + expected log-mel feats +
expected embedding) so the Swift Fbank + embedder are validated bit-for-bit by the
`voicetest` CLI.

## Reproduce the model

Source repo: ~/code/voiceprint-build (ECAPA weights curled from HF; see its README).
coremltools 9 works on the existing py3.13 .venv (the "py<=3.12" note is stale).

```sh
cd ~/code/voiceprint-build
HF_HUB_OFFLINE=1 .venv/bin/python convert_coreml.py   # writes coreml_out/
# then copy coreml_out/ECAPA_TDNN.mlpackage + fbank_constants.json into
# sonar-dictate/Resources/voiceprint/ and golden.json into tools/voiceprint/
```

Plan A (full audio->embedding graph) does not convert - the Fbank STFT has a
length-based int cast coremltools cannot trace - so we ship Plan B (ECAPA only) and
compute Fbank in Swift from the constants above.
