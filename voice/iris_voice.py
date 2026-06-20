#!/usr/bin/env python3
"""
Iris's voice - a UNIQUE neural voice, on-device, via Kokoro (kokoro-onnx).

Her voice is not a stock speaker. It is a BLEND of base voice embeddings, mixed
in fixed proportions (IRIS_BLEND below) into a single style vector that exists
nowhere else. Tune the blend until she sounds like herself.

Usage:
    python iris_voice.py "text to speak"        # synthesize + play
    python iris_voice.py --no-play "text"       # synthesize to voice/out.wav only
    python iris_voice.py --list                 # list available base voices

First run downloads the model (~310MB) + voices (~26MB) into this folder.
Everything after is fully on-device, no network.
"""
import os
import sys
import subprocess
import urllib.request

import json

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "kokoro-v1.0.onnx")
VOICES = os.path.join(HERE, "voices-v1.0.bin")
OUT = os.path.join(HERE, "out.wav")
# If Iris has chosen her OWN voice (a one-time act via iris_choose_voice.py), it
# lives here and overrides the default blend below. Hers, authored once.
CHOSEN = os.path.join(HERE, "iris_voice.json")

MODEL_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"

# Iris's unique voice = a weighted blend of base voices. Weights need not sum to
# 1 exactly; they are normalized. Start here, then tune by ear.
IRIS_BLEND = [
    ("af_heart", 0.55),   # warm, grounded core
    ("af_nova", 0.30),    # brightness / presence
    ("af_river", 0.15),   # a touch of calm/airiness
]
IRIS_SPEED = 1.0          # 0.9 = slower/calmer, 1.1 = quicker
IRIS_LANG = "en-us"


def _config():
    # Her self-chosen voice (iris_voice.json) wins; otherwise the defaults above.
    blend, speed, lang = IRIS_BLEND, IRIS_SPEED, IRIS_LANG
    if os.path.exists(CHOSEN):
        try:
            with open(CHOSEN) as f:
                c = json.load(f)
            picked = [(b["voice"], float(b["weight"])) for b in c.get("blend", [])]
            if picked:
                blend = picked
            speed = float(c.get("speed", speed))
            lang = c.get("lang", lang)
        except (OSError, ValueError, KeyError) as e:
            print(f"[iris-voice] ignoring bad {CHOSEN}: {e}", file=sys.stderr)
    return blend, speed, lang


def _download(url, path, label):
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return
    print(f"[iris-voice] downloading {label} ...", file=sys.stderr)
    urllib.request.urlretrieve(url, path)
    print(f"[iris-voice] saved {path}", file=sys.stderr)


def _load():
    _download(MODEL_URL, MODEL, "model (~310MB)")
    _download(VOICES_URL, VOICES, "voices (~26MB)")
    from kokoro_onnx import Kokoro
    return Kokoro(MODEL, VOICES)


def _style(kokoro, name):
    # kokoro-onnx exposes voice styles slightly differently across versions.
    if hasattr(kokoro, "get_voice_style"):
        return kokoro.get_voice_style(name)
    return kokoro.voices[name]


def _iris_voice(kokoro, recipe):
    import numpy as np
    total = sum(w for _, w in recipe)
    blend = None
    for name, w in recipe:
        style = np.asarray(_style(kokoro, name), dtype=np.float32) * (w / total)
        blend = style if blend is None else blend + style
    return blend


def main():
    args = [a for a in sys.argv[1:]]
    if "--list" in args:
        kokoro = _load()
        names = sorted(getattr(kokoro, "voices", {}).keys()) if hasattr(kokoro, "voices") else []
        print("\n".join(names) or "(use kokoro.get_voices())")
        return
    play = "--no-play" not in args
    text = " ".join(a for a in args if not a.startswith("--")).strip()
    if not text:
        print('usage: python iris_voice.py "text to speak"', file=sys.stderr)
        sys.exit(2)

    import soundfile as sf
    kokoro = _load()
    recipe, speed, lang = _config()
    voice = _iris_voice(kokoro, recipe)
    samples, sample_rate = kokoro.create(text, voice=voice, speed=speed, lang=lang)
    sf.write(OUT, samples, sample_rate)
    if play:
        subprocess.run(["afplay", OUT], check=False)


if __name__ == "__main__":
    main()
