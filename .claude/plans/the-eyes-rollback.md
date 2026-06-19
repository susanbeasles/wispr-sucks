# Rollback - The Eyes, Phase 1

Pairs with: .claude/plans/the-eyes-screen-perception.md
Branch: feat/the-eyes
Blast radius: MEDIUM (new Screen Recording TCC capability + PHI-bearing frames)

## Pre-state (before Phase 1)

- Branch feat/the-eyes was cut from main at the commit that is HEAD when this
  note was written. Pre-existing UNCOMMITTED owner changes are in the tree
  (LEDMicView.swift, RecordingOverlay.swift, SpeechAnalyzerSession.swift) - these
  are NOT part of the eyes work and must be preserved on any rollback.
- No new persisted on-disk state, no schema change, no DB migration in Phase 1.
  Frames/OCR/summaries live in memory only and are never written to disk.

## What Phase 1 adds (all reversible by deletion)

New files (delete to remove):
- Sources/SonarDictate/EyeCapture.swift
- Sources/SonarDictate/ScreenText.swift
- Sources/SonarDictate/ScreenReasoner.swift
- Sources/SonarDictate/EyeSignals.swift
- Sources/SonarDictate/Eye.swift
- Sources/SonarDictate/EyeOverlay.swift

Edits (revert the eyes hunks only):
- Sources/SonarDictate/main.swift - launch-block wiring + an `eyes` CLI/menu
  toggle. Revert these hunks; leave the rest of main.swift untouched.
- Sources/SonarDictate/StatusItemController.swift - optional menu toggle item.

## Exact reverse steps

1. Remove the new files:
   rm Sources/SonarDictate/{EyeCapture,ScreenText,ScreenReasoner,EyeSignals,Eye,EyeOverlay}.swift
2. Revert the wiring hunks in main.swift (+ StatusItemController.swift) with
   `git checkout -p` selecting ONLY the eyes hunks - do NOT discard the owner's
   pre-existing uncommitted widget changes.
3. swift build to confirm the tree compiles without the eyes.

## TCC / permission cleanup (only if the user wants it gone)

- The app will have been granted Screen Recording in System Settings > Privacy &
  Security > Screen Recording. Removing the feature does NOT auto-revoke it.
- To fully reset: System Settings > Privacy & Security > Screen Recording ->
  toggle SonarDictate off (or remove). Or `tccutil reset ScreenCapture
  com.sonarmd.dictate` (requires the user; not run by the agent).

## No data to purge

Phase 1 persists nothing. There is no encrypted store, no log entry bearing
frame/OCR/summary content (only content-free counters, if any). Nothing to wipe.
