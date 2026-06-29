# Own acoustic echo canceller - recovered POCs

These are the standalone proof-of-concept files for the OWN (non-Apple)
acoustic echo canceller: tap all system audio as a reference, subtract it from
the mic with an adaptive NLMS filter, so dictation works over music from ANY
source (incl. Bluetooth / external) without ducking playback. Design lives in
`.claude/plans/2026-06-24-053629-own-echo-canceller.md`.

## Provenance
Built 2026-06-24 in a god-mode session as standalone programs under `/tmp`
(per the plan: "phase 1, standalone, NOT in the app"). `/tmp` was later reaped
on reboot, so they were never on disk again and never committed. Recovered on
2026-06-27 from the conversation transcript
`~/.claude/projects/-Users-avespoli-god-mode/68992a8d-...jsonl` (the source was
written via Bash heredocs, not the Write tool, which is why repo/disk searches
missed it).

## Files
- `aectap/main.swift`  - phase 1: process tap + aggregate device, capture 3s of
  system audio, prove RMS > 0 ("REFERENCE CAPTURE WORKS").
- `aecsync/main.swift` + `patch.swift` - phase 2: one aggregate device delivering
  mic + reference frame-aligned; reports per-stream channel count + RMS.
- `aecnlms/main.swift` - the NLMS adaptive FIR canceller (Accelerate/vDSP).
- `aecnlms/bt.swift`, `bt2.swift` - NLMS bench/sim variants.

## Status / not yet done
These are POCs, never wired into the running app. The shipped Iris dictation
still uses Apple VPIO (`setVoiceProcessingEnabled`). Integrating this canceller
to REPLACE VPIO is the remaining work.
