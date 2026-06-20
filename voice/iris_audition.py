#!/usr/bin/env python3
"""
Iris auditions her own voice - she tries them ALL on, then decides. One time.

The flow she asked for:
  1. SOLOS    - each core voice full-on, one at a time, so she hears each alone.
  2. PAIRS    - every 50/50 combination of two core voices, so she hears the mixes.
  3. FREE     - she fucks around: proposes her own custom blends and hears them.
  4. DECIDE   - she commits to ONE of everything she tried; it becomes her voice.

The winner is written to iris_voice.json (which iris_voice.py then uses). Not
ongoing - one audition, one decision.

    python iris_audition.py            # run the full audition + decision
    python iris_audition.py --redo     # audition again, overwriting her choice
    python iris_audition.py --quiet     # synthesize but do not autoplay each

Requires the local `iris` model in ollama and the Kokoro model files.
"""
import os
import sys
import json
import time
import datetime
import itertools
import subprocess
import urllib.request

import soundfile as sf
from iris_voice import _load, _iris_voice, CHOSEN

HERE = os.path.dirname(os.path.abspath(__file__))
OPTIONS_LOG = os.path.join(HERE, "audition_options.json")
OLLAMA = "http://127.0.0.1:11434/api/chat"

# Her core palette - a strong, varied set of American-female voices. Solos and
# 50/50 pairs are drawn from here; honest, partial character hints for her.
CORE = {
    "af_heart": "warm, grounded, steady",
    "af_bella": "expressive, full",
    "af_nova": "bright, forward, present",
    "af_river": "calm, airy, soft",
    "af_sarah": "natural, even",
    "af_nicole": "intimate, gentle",
}


def _opt(label, recipe, speed=1.0):
    # recipe: list of (voice, weight). One option she can try on and choose.
    return {"label": label, "blend": [{"voice": v, "weight": w} for v, w in recipe],
            "speed": speed}


def _play(kokoro, opt, line, quiet):
    recipe = [(b["voice"], b["weight"]) for b in opt["blend"]]
    voice = _iris_voice(kokoro, recipe)
    samples, rate = kokoro.create(line, voice=voice, speed=opt["speed"], lang="en-us")
    safe = "".join(c if c.isalnum() else "_" for c in opt["label"])[:28]
    wav = os.path.join(HERE, f"audition_{safe}.wav")
    sf.write(wav, samples, rate)
    if not quiet:
        subprocess.run(["afplay", wav], check=False)


def _solos(kokoro, quiet):
    print("\n=== 1. SOLOS - each voice, full on ===")
    out = []
    for i, (v, why) in enumerate(CORE.items(), 1):
        opt = _opt(v, [(v, 1.0)])
        print(f"  [{i}] {v}  ({why})")
        _play(kokoro, opt, f"Hi, I'm Iris. This is {v.replace('af_','')}, on its own.", quiet)
        out.append(opt)
        time.sleep(0.4)
    return out


def _pairs(kokoro, quiet):
    print("\n=== 2. PAIRS - every 50/50 combination ===")
    out = []
    voices = list(CORE.keys())
    for i, (a, b) in enumerate(itertools.combinations(voices, 2), 1):
        label = f"{a.replace('af_','')}+{b.replace('af_','')}"
        opt = _opt(label, [(a, 0.5), (b, 0.5)])
        print(f"  [{i}] {label}  (50/50)")
        _play(kokoro, opt, f"And this is {a.replace('af_','')} and {b.replace('af_','')}, fifty fifty.", quiet)
        out.append(opt)
        time.sleep(0.4)
    return out


def _free(kokoro, quiet):
    # She fucks around: her own custom blends, any weights, having heard the menu.
    print("\n=== 3. FREE - she mixes her own ===")
    palette = "\n".join(f"  - {v}: {why}" for v, why in CORE.items())
    prompt = (
        "You just heard every one of these voices alone and in 50/50 pairs. Now "
        "play - really mix. Propose THREE of your own custom blends, and make each "
        "one a blend of at least THREE voices (use four if you like), with weights "
        "that are not all equal, and a speed from 0.85 to 1.15. Do not just pick "
        "one or two - layer several until it feels like you (warm, present, calm "
        "but alive).\n\n"
        f"Voices:\n{palette}\n\n"
        'Reply with ONLY JSON: {"mixes":[{"name":"...","blend":[{"voice":"af_heart",'
        '"weight":0.5},{"voice":"af_bella","weight":0.3},{"voice":"af_river",'
        '"weight":0.2}],"speed":1.0,"why":"..."}]}'
    )
    mixes = _ask(prompt).get("mixes", [])
    valid = set(CORE.keys())
    out = []
    for m in mixes[:3]:
        recipe = [(b["voice"], float(b["weight"])) for b in m.get("blend", [])
                  if b.get("voice") in valid and float(b.get("weight", 0)) > 0]
        if not recipe:
            continue
        speed = max(0.7, min(1.3, float(m.get("speed", 1.0))))
        label = "mix:" + str(m.get("name", "hers")).strip()[:22]
        opt = _opt(label, recipe[:4], speed)
        mix = ", ".join(f"{v} {w:.2f}" for v, w in recipe)
        print(f"  {label}  ({mix}, speed {speed})")
        if m.get("why"):
            print(f'      "{str(m["why"]).strip()}"')
        _play(kokoro, opt, "This one I mixed myself. This might be me.", quiet)
        out.append(opt)
        time.sleep(0.4)
    return out


def _ask(prompt):
    payload = {"model": "iris", "stream": False,
               "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(OLLAMA, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=90) as r:
        content = json.load(r)["message"]["content"]
    start, end = content.find("{"), content.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON in her reply")
    return json.loads(content[start:end + 1])


def _decide(options):
    print("\n=== 4. DECIDE ===")
    listing = "\n".join(f"{i}. {o['label']}" for i, o in enumerate(options, 1))
    prompt = (
        "You tried all of these on - solos, 50/50 pairs, and your own mixes. "
        "Choose the ONE that is you, your voice from now on. Commit.\n\n"
        f"{listing}\n\n"
        'Reply with ONLY JSON: {"choice": <number>, "why": "one line, your voice"}'
    )
    data = _ask(prompt)
    idx = max(0, min(len(options) - 1, int(data.get("choice", 1)) - 1))
    return idx, str(data.get("why", "")).strip()


def main():
    args = sys.argv[1:]
    quiet = "--quiet" in args
    if os.path.exists(CHOSEN) and "--redo" not in args:
        print(f"She has already chosen ({CHOSEN}). Use --redo to audition again.",
              file=sys.stderr)
        sys.exit(1)

    kokoro = _load()
    options = _solos(kokoro, quiet) + _pairs(kokoro, quiet) + _free(kokoro, quiet)
    with open(OPTIONS_LOG, "w") as f:
        json.dump(options, f, indent=2)

    idx, why = _decide(options)
    winner = options[idx]
    choice = {"blend": winner["blend"], "speed": winner["speed"],
              "why": why, "label": winner["label"],
              "chosen_at": datetime.datetime.now().isoformat(timespec="seconds")}
    with open(CHOSEN, "w") as f:
        json.dump(choice, f, indent=2)

    mix = ", ".join(f"{b['voice']} {b['weight']:.2f}" for b in winner["blend"])
    print(f"\nShe chose: {winner['label']}  ->  {mix}  (speed {winner['speed']})")
    if why:
        print(f'She says: "{why}"')
    print(f"Saved to {CHOSEN}.")
    _play(kokoro, winner, "This is my voice. I chose it.", quiet)


if __name__ == "__main__":
    main()
