# Live LED-matrix mic widget

Owner approved (chose "Build the live visual" over hunting a drop that the log
shows is already fixed). Build the signature visualization into the floating
widget on REAL signals. This was designed across a long mockup session but never
wired into the app; the running widget is still the plain mic-icon + text pill.

## The 3 signals (independent)

1. AUDIO ENERGY  -> bar height + motion. Louder = taller bars, more chaotic
   motion. Source: per-buffer RMS from the live mic.
2. RECOGNIZER CONFIDENCE -> block INTEGRITY (not motion). High = solid, saturated
   lit cells. Low = flicker (75%) + rare missing cells (25%) + desaturation.
   Source: transcriptionConfidence if available, else volatile-churn proxy.
3. TRANSCRIPT STABILITY -> finalization snap (a pulse when a segment locks) and
   the release LOCK. Source: isFinal segment boundaries + release.

Decoupled: noise changes MOTION, confidence changes INTEGRITY. "Noisy but
understood" = chaotic tall bars + solid saturated cells + locked mic.

## Palette / rules (from the design session, do not redesign)

- Base recording RED -> electric BLUE (mid energy) -> PURPLE (peak). Near-black bg.
- WHITE is RESERVED: recovery peaks, final lock, commit/release ONLY. Never a
  generic "success" color.
- Release / lock: border fills white all the way around, holds, then powers down
  to black. Quick (~2s back to normal).
- Recovery (low->high confidence): ~3s arc, white bloom on the heel.
- Low-confidence release: hesitant gray / flickering / incomplete signal, NO white.

## Files

- NEW Sources/SonarDictate/WidgetSignals.swift (peripheral): thread-safe bus.
  publishEnergy(rms) / publishConfidence(c) / snap() / setListening(on) /
  snapshot(). NSLock-guarded scalar stores; safe from the realtime audio thread.
- Sources/SonarDictate/RecordingOverlay.swift (peripheral): replace the static
  NSImageView mic with LEDMicView (mic-silhouette-clipped LED grid, ~60fps timer
  reading WidgetSignals). Keep the right-aligned transcript label. Timer runs only
  while listening or during the release/powerdown animation; idle is static.
- SEALED, additive only (no invariant touched):
  - SpeechAnalyzerSession.recordDiagnostics: add sum-of-squares in the EXISTING
    sample loop, publishEnergy(rms) per buffer.
  - SpeechAnalyzerSession.handle: snap() on a non-empty final; best-effort
    publishConfidence from result.text runs (fall back to proxy if the attribute
    is unavailable).

## Order

1. WidgetSignals.swift.
2. LEDMicView + rewire RecordingOverlay icon area + show/hide/setBufferingMode.
3. Additive energy publish (recordDiagnostics).
4. snap + best-effort confidence (handle).
5. build-app.sh debug + codesign + relaunch.
6. Verify dictation STILL commits/injects via `sonar-dictate logs` (no regression
   to the sealed capture path).
7. Tune the look live with the owner at true widget size.
8. DECISIONS.md entry (owner-approved additive signal taps) + mark this plan done.

## Risks

- transcriptionConfidence may not exist on DictationTranscriber.Result -> wire
  energy+stability first; confidence is a defensive add with a churn-derived
  fallback.
- Reads rough at 24-32px -> generous grid, vivid palette, tune live (expected).
- Realtime-thread publish must not block -> single lock + float store, RMS reuses
  the existing loop.

## Status

2026-06-15: BUILT and live (PID relaunched). All four files in, package compiles
clean (only the pre-existing main.swift:126 Sendable warning), bundle codesigned
+ valid, fresh instance running. v1 grid 5x7 in a 28px mic. Awaiting live tuning
with the owner at true size (energy gain/curve, color ramp, flicker amount, the
release lock sweep). DECISIONS.md updated with the owner-approved additive taps.
Confidence is a churn proxy in v1; real transcriptionConfidence is the follow-up.
