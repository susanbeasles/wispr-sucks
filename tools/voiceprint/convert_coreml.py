# Convert the ECAPA speaker-embedding pipeline to CoreML for on-device (ANE) use in
# sonar-dictate (tier 2 voiceprint lock). Tries Plan A (full graph: audio -> 192-dim
# L2 embedding) and falls back to Plan B (ECAPA_TDNN only: log-mel feats -> embedding,
# with Fbank done in Swift). Validates the CoreML embeddings reproduce the PyTorch
# discrimination (same/diff cosine gap) on clips2/ before declaring success.
#
# Run: HF_HUB_OFFLINE=1 .venv/bin/python convert_coreml.py

import glob
import itertools
import os

import coremltools as ct
import numpy as np
import soundfile as sf
import torch
from speechbrain.lobes.features import Fbank
from speechbrain.lobes.models.ECAPA_TDNN import ECAPA_TDNN
from speechbrain.processing.features import InputNormalization

OUT_DIR = "coreml_out"
os.makedirs(OUT_DIR, exist_ok=True)

fbank = Fbank(n_mels=80)
mvn = InputNormalization(norm_type="sentence", std_norm=False)
ecapa = ECAPA_TDNN(
    input_size=80,
    channels=[1024, 1024, 1024, 1024, 3072],
    kernel_sizes=[5, 3, 3, 3, 1],
    dilations=[1, 2, 3, 4, 1],
    attention_channels=128,
    lin_neurons=192,
)
ecapa.load_state_dict(torch.load("ecapa_model/embedding_model.ckpt", map_location="cpu", weights_only=True))
ecapa.eval()


def pt_feats(path):
    data, _ = sf.read(path, dtype="float32")
    if data.ndim > 1:
        data = data.mean(1)
    sig = torch.from_numpy(data).unsqueeze(0)
    with torch.no_grad():
        return mvn(fbank(sig), torch.ones(1))  # [1, T, 80]


def pt_embed(path):
    feats = pt_feats(path)
    with torch.no_grad():
        emb = ecapa(feats, torch.ones(1)).squeeze()
    return (emb / emb.norm()).numpy()


# ECAPA-only module: feats [1, T, 80] -> L2-normalized 192-dim embedding.
class EcapaEmbed(torch.nn.Module):
    def __init__(self, core):
        super().__init__()
        self.core = core

    def forward(self, feats):
        # No lengths arg: ECAPA_TDNN skips length-masking when lengths is None,
        # which avoids a relative-length int cast that does not trace to CoreML.
        emb = self.core(feats).squeeze(1)  # [1, 192]
        return emb / emb.norm(dim=-1, keepdim=True)


# Plan A: full pipeline (raw mono audio [1, n] -> L2-normalized 192-dim embedding).
# If this converts + validates, Swift feeds samples directly and there is no Swift
# Fbank to match bit-for-bit.
class FullEmbed(torch.nn.Module):
    def __init__(self, fbank, mvn, core):
        super().__init__()
        self.fbank = fbank
        self.mvn = mvn
        self.core = core

    def forward(self, audio):
        feats = self.mvn(self.fbank(audio), torch.ones(audio.shape[0]))
        emb = self.core(feats).squeeze(1)
        return emb / emb.norm(dim=-1, keepdim=True)


def try_plan_a():
    wrapped = FullEmbed(fbank, mvn, ecapa).eval()
    example = torch.rand(1, 16000)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)
    n_dim = ct.RangeDim(lower_bound=4000, upper_bound=480000, default=16000)
    m = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(1, n_dim))],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
    )
    return m


def cosines(embs):
    names = list(embs)
    spk = lambda n: n.split("_")[0]
    same = [float(np.dot(embs[a], embs[b])) for a, b in itertools.combinations(names, 2) if spk(a) == spk(b)]
    diff = [float(np.dot(embs[a], embs[b])) for a, b in itertools.combinations(names, 2) if spk(a) != spk(b)]
    return same, diff


clips = sorted(glob.glob("clips2/*.wav"))
pt = {os.path.basename(c)[:-4]: pt_embed(c) for c in clips}
ps, pd = cosines(pt)
print(f"[pytorch] same avg={sum(ps)/len(ps):.3f} diff avg={sum(pd)/len(pd):.3f} gap={min(ps)-max(pd):.3f}")


def audio_of(path):
    data, _ = sf.read(path, dtype="float32")
    if data.ndim > 1:
        data = data.mean(1)
    return data[None].astype(np.float32)


# Try Plan A first (full audio->embedding). If it converts and matches, prefer it.
try:
    mlA = try_plan_a()
    outA = os.path.join(OUT_DIR, "ECAPA_Full.mlpackage")
    mlA.save(outA)
    cmA = {}
    for c in clips:
        out = mlA.predict({"audio": audio_of(c)})
        e = np.array(out["embedding"]).squeeze()
        cmA[os.path.basename(c)[:-4]] = e / np.linalg.norm(e)
    aS, aD = cosines(cmA)
    agA = [float(np.dot(pt[n], cmA[n])) for n in pt]
    okA = (min(aS) - max(aD)) > 0.15 and min(agA) > 0.99
    print(f"[planA]   same avg={sum(aS)/len(aS):.3f} diff avg={sum(aD)/len(aD):.3f} gap={min(aS)-max(aD):.3f}  agree min={min(agA):.4f}")
    print("[planA]   VERDICT:", "PASS - full audio->embedding, no Swift Fbank needed" if okA else "FAIL - fall back to Plan B")
except Exception as e:  # noqa: BLE001 - conversion is exploratory; record and fall back
    print(f"[planA]   conversion FAILED ({type(e).__name__}: {str(e)[:160]}) - using Plan B")

# Plan B (robust): convert ECAPA_TDNN only; Swift computes Fbank. ECAPA is fully
# convolutional over time + attentive pooling, so use a FLEXIBLE time dimension (no
# padding) - matches PyTorch's variable-length processing exactly (zero-padding would
# pollute the attentive statistics pooling and drift the embedding).
wrapped = EcapaEmbed(ecapa).eval()
example = torch.rand(1, 300, 80)
with torch.no_grad():
    traced = torch.jit.trace(wrapped, example)

time_dim = ct.RangeDim(lower_bound=16, upper_bound=4000, default=300)
# Force float32 IO: the default fp16 IO mismatches a float32 MLMultiArray in Swift
# (CoreML reinterprets the bytes -> garbage). Internal weights stay fp16.
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="feats", shape=(1, time_dim, 80), dtype=np.float32)],
    outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    minimum_deployment_target=ct.target.macOS14,
    compute_units=ct.ComputeUnit.ALL,
)
out_path = os.path.join(OUT_DIR, "ECAPA_TDNN.mlpackage")
mlmodel.save(out_path)
print(f"[coreml] saved {out_path}")

# Validate: feed the SAME pytorch feats (padded/truncated to T) through CoreML.
def cm_embed(path):
    feats = pt_feats(path).numpy()  # [1, t, 80] - variable length, no padding
    out = mlmodel.predict({"feats": feats.astype(np.float32)})
    emb = np.array(out["embedding"]).squeeze()
    return emb / np.linalg.norm(emb)


cm = {os.path.basename(c)[:-4]: cm_embed(c) for c in clips}
cs, cd = cosines(cm)
# Agreement: how close CoreML embeddings are to PyTorch (same clip).
agree = [float(np.dot(pt[n], cm[n])) for n in pt]
print(f"[coreml]  same avg={sum(cs)/len(cs):.3f} diff avg={sum(cd)/len(cd):.3f} gap={min(cs)-max(cd):.3f}")
print(f"[agree]   coreml-vs-pytorch same-clip cosine: min={min(agree):.4f} avg={sum(agree)/len(agree):.4f}")
ok = (min(cs) - max(cd)) > 0.15 and min(agree) > 0.99
print("VERDICT:", "PASS - CoreML matches the proof" if ok else "FAIL - investigate")

# Golden vectors so the Swift Fbank can be validated bit-for-bit: a reference clip's
# mono audio, the expected log-mel feats, and the expected embedding. JSON (flat
# float arrays) so Swift reads it with no extra dependency. Truncated to ~1s to keep
# it small; the Swift test feeds `audio`, computes Fbank, and asserts feats match.
import json

gclip = clips[0]
gaudio, gfs = sf.read(gclip, dtype="float32")
if gaudio.ndim > 1:
    gaudio = gaudio.mean(1)
gaudio = gaudio[: int(gfs)]  # first 1s
gsig = torch.from_numpy(gaudio).unsqueeze(0)
with torch.no_grad():
    gfeats = mvn(fbank(gsig), torch.ones(1))  # [1, t, 80]
    gemb = ecapa(gfeats).squeeze()
    gemb = (gemb / gemb.norm()).numpy()
golden = {
    "clip": os.path.basename(gclip),
    "sampleRate": int(gfs),
    "audio": gaudio.tolist(),
    "featsShape": list(gfeats.shape[1:]),  # [t, 80]
    "feats": gfeats.squeeze(0).reshape(-1).tolist(),
    "embedding": gemb.tolist(),
}
with open(os.path.join(OUT_DIR, "golden.json"), "w") as f:
    json.dump(golden, f)
print(f"[golden]  wrote {OUT_DIR}/golden.json (clip={golden['clip']} feats={golden['featsShape']})")

# Fbank constants so the Swift feature extractor matches SpeechBrain exactly instead
# of reconstructing the mel basis (a common source of drift): the 80x201 triangular
# mel filter matrix and the 400-pt Hamming window. STFT params: win 400, hop 160,
# n_fft 400, center (zero-pad n_fft//2), power spectrogram, log = 10*log10(max(1e-10,
# x)) clamped to top_db 80 below the per-utterance max; then sentence mean-norm.
# SpeechBrain builds the triangular filters on the fly (no stored matrix). Extract
# the exact [n_stft=201, n_mels=80] matrix by probing a NON-log Filterbank with an
# identity spectrogram: feeding 201 frames, each a unit impulse at one freq bin,
# yields each bin's response across the 80 mel filters = the filter matrix.
from speechbrain.processing.features import Filterbank

_fbm = Filterbank(n_mels=80, n_fft=400, sample_rate=16000, f_min=0, f_max=8000, log_mel=False)
with torch.no_grad():
    mel_fb = _fbm(torch.eye(201).unsqueeze(0)).squeeze(0).detach().numpy()  # [201, 80]
# Pull the EXACT window SpeechBrain's STFT uses (do not guess periodic vs not).
window = fbank.compute_STFT.window_fn(fbank.compute_STFT.win_length).numpy()
consts = {
    "winLength": 400, "hopLength": 160, "nFft": 400, "nStft": 201, "nMels": 80,
    "sampleRate": 16000, "logMultiplier": 10.0, "amin": 1e-10, "topDb": 80.0,
    "window": window.tolist(),
    "melMatrixShape": list(mel_fb.shape),
    "melMatrix": mel_fb.reshape(-1).tolist(),
}
with open(os.path.join(OUT_DIR, "fbank_constants.json"), "w") as f:
    json.dump(consts, f)
print(f"[fbank]   wrote {OUT_DIR}/fbank_constants.json (mel matrix {list(mel_fb.shape)})")
