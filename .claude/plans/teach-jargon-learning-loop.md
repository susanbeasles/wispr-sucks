# Plan: teach-it-your-jargon (close the correction -> dictionary loop)

Date: 2026-06-06
Repo: sonar-dictate
Status: done - loop closed, `swift build` passes, live (PID 67651)

## Problem

The personalization loop is fully built but disconnected at one point:
- `DictionaryStore` biases the recognizer every session (terms() -> contextualStrings). WIRED.
- `DictionaryStore.add(weight, .correction)` / `learnCorrection` exist. READY.
- `EditWatcher` captures what the user keeps/fixes 60s after each dictation. WIRED -
  but only to the corpus DB (corrections table), NOT to the dictionary.

So corrections are recorded for future model training but never bias live
recognition. Correcting the same misheard jargon repeatedly teaches nothing.

## Fix (additive; does NOT touch the live recognition path)

1. `EditWatcher` gains a `DictionaryStore` dependency (init param).
2. On capture (`_captureNowLocked`), after the existing DB writes, extract the
   corrected/added words and promote each into the dictionary at correction
   weight (3), source `.correction`.
3. `learnableTerms(original:corrected:)` - pure, testable:
   - Gate: only when `corrected.count <= original.count*2 + 40` (the field is
     mostly our dictated text, lightly edited). Prevents a big target document
     (the 50888-char case) from dumping the whole doc into the dictionary.
   - Tokenize on ASCII word chars (letters/digits/apostrophe).
   - Keep words present in `corrected` but absent from `original`.
   - Drop a small stopword set and tokens shorter than 2 chars.
   - Preserve original casing (Kubernetes, SonarMD), dedup case-insensitively.
4. `main.swift`: pass `dictionary` into `EditWatcher(database:dictionary:)`.

## Effect

Fix a misrecognized term in a native field -> 60s later it lands in the
weighted dictionary -> next session the recognizer is biased toward it. The
tool learns the user's vocabulary over time, 100% on device.

## Limits (v1)

- Only learns from native AX-readable fields where the field is close to our
  injected text (length gate). Big-document dictation does not teach the
  dictionary yet. Manual `dict add "<term>"` covers explicit teaching.

## Verify
- `swift build` clean.
- After correcting a term in a native field, `sonar-dictate dict list` shows the
  new term (source=correction, weight 3).

## Constraints
- ASCII only. Log COUNT of learned terms, never the terms (may include names/PHI).
- No push/PR without explicit approval.
