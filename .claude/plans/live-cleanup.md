# Plan: live (as-you-speak) cleanup, never blocking release

## Hard requirement (non-negotiable)
When the user releases the talk key, the text is in the field IMMEDIATELY. Zero
end-of-utterance processing, zero hang. The instant-on-release feel is the entire
value of the product. Any cleanup that delays release is a death sentence.

## Current state (after 2026-06-13)
- commitDictation injects the recognizer's final text instantly (paste / Cmd-V).
  The old `await cleanup.clean()`-before-inject path (the multi-second hang in
  cleanup-target apps) is REMOVED.
- The LLM cleanup pass (Cleanup.swift) is word-preserving and only repairs
  punctuation/capitalization. The "words changing / repeats dropping as you pause"
  the user values is the RECOGNIZER revising volatile results live, not the LLM.

## Goal
Bring back punctuation cleanup for cleanup-target apps WITHOUT touching the
release latency: the cleaned text must already be computed by the time the key is
released, by cleaning incrementally WHILE the user speaks.

## Design
- Clean finalized SEGMENTS during dictation, in the background, as they finalize
  (the recognizer commits a segment on each natural pause). SpeechAnalyzerSession
  already tracks finalizedChunks vs the volatile tail; surface a callback
  `onSegmentFinalized(text)` (or pass finalized vs volatile separately up through
  onTranscriptUpdate).
- Maintain an ordered cleaned-segment cache in Dictator. Reuse ONE
  LanguageModelSession across segments (avoid per-call setup cost). Keep the
  word-preservation guard per segment.
- On release: assemble cleaned segments that are ready, in order, plus RAW for any
  segment not yet cleaned and the raw volatile tail. Inject that instantly. NEVER
  await a pending clean. If you pause naturally, most/all is cleaned by release; if
  you release mid-phrase, the tail is raw - acceptable, instant is preserved.

## Correctness risks to handle
- Segment ordering/mapping must be exact or the injected text duplicates/drops
  words. Drive assembly from the same finalizedChunks ordering the session uses.
- Do NOT mutate the field after release (no backspace+repaste patching) - it
  races the user's next keystrokes and can corrupt their input. Cleanup must land
  BEFORE injection or not at all for that utterance.
- Keep a global on/off (Cleanup.isEnabled) and the per-app target set.

## Out of scope
- Removing repeated words / rephrasing: that is the recognizer's job (volatile
  revision), not the LLM (which is word-preserving by contract).

See [[encrypted-diagnostic-log]] sibling plan and DECISIONS.md.
