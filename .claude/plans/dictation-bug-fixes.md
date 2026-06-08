# Plan: dictation bug fixes

Date: 2026-06-06
Repo: sonar-dictate (SonarDictate, SwiftPM, macOS 26)
Status: Fix 2 + Fix 3 done (build passes). Fix 1 (cutoff) REVERTED to baseline.
  Reason: the 400ms trailing-capture defer added perceptible delay AND could drop
  a dictation when the next one starts within the window (rapid re-press clobber).
  Also discovered the user was testing a stale June-1 .app, so Fix 1 was never
  actually exercised. Cutoff needs on-device diagnosis (read SonarDictate.log)
  before re-attempting - do NOT guess again.

## Problem (user-reported)

1. Early cutoff: the last word or two of every dictation is lost, even when the
   talk key is held past the end of speech.
2. Lost dictations / no history: when a paste misfires (focus/AX), the user has
   no in-app way to get the text back. CLI-only retrieval today.
3. "Translations" messed up: the on-device LLM cleanup pass over-edits text.

## Findings (grounded in code)

- Cutoff: `main.swift stopListening()` (410-418) calls `session.stop()` (which
  immediately finishes the audio input stream) then stops the engine + removes
  the tap, all synchronously on key release. Trailing mic buffers still in the
  AVAudioEngine pipeline are dropped before reaching the transcriber. Holding
  longer cannot help; the loss is in the ~100-300ms at release.
- History: every finalized session IS persisted (`persistSession`, 533-625;
  `SecureStore.write`) regardless of paste success. The gap is retrieval - the
  menu bar shows counts only (StatusItemController 82-92). Store keeps the RAW
  transcript.
- Cleanup: `Cleanup.clean()` (51-70) rewrites the transcript through Foundation
  Models with "don't change meaning" instructions but no enforcement; a 3B model
  drifts. Runs only for a fixed app set; off for LLM clients.

## Decisions (from user)

- History: a real window listing EVERY dictation, click to copy. Plus a
  copy-last-dictation hotkey for instant recovery.
- Cleanup: muzzle the model. Punctuation/capitalization only, enforced by a hard
  word-preservation guard (any word change -> fall back to raw). Add an off-switch.

## Changes

### Fix 1 - trailing-capture window (Bug 1)  [main.swift]
- In `stopListening()`: set `listening = false`, then defer
  engine.stop() + removeTap() + session.stop() by ~400ms via asyncAfter.
- Add `private var stopGeneration = 0`; capture/compare it in the closure and
  bail if `listening` became true again (re-press) -> avoids killing the next
  session's tail.

### Fix 2 - History window (Bug 2)  [new HistoryWindow.swift, StatusItemController.swift, main.swift]
- New `HistoryWindow`: NSWindow + NSTableView listing `store.list()` newest
  first (created-at, app, duration, preview). Copy button + double-click copy
  full transcript via `store.read(id)`. Refresh on show.
- StatusItemController: add "Dictation History..." menu item -> opens window;
  hold a `HistoryWindow` reference.
- main.swift: a global hotkey to open the window, and one to copy the last
  dictation to the clipboard. No collision with existing fn / ctrl-opt chords.

### Fix 3 - muzzle cleanup (Bug 3)  [Cleanup.swift, StatusItemController.swift]
- Rewrite `instructions` to: punctuation + capitalization only; never add,
  remove, reorder, or change words.
- Add `isSafeRewrite(raw:cleaned:)` pure guard: normalize (lowercase, strip
  punctuation, collapse whitespace) and require identical word sequences; else
  return raw. Wire into `clean()`.
- Add a persisted global toggle (UserDefaults `cleanupEnabled`, default true)
  consulted by `shouldClean`; menu checkbox to flip it.

## Verification
- `swift build` clean.
- Manual: hold-talk-release captures the tail; History window lists all and
  copies; cleanup either matches words or falls back to raw; toggle disables it.

## Constraints
- ASCII only in all changed files.
- Minimal diff; no drive-by refactors. No push/PR without explicit approval.
