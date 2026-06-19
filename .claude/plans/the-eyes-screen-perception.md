# The Eyes - on-device, situationally-aware screen perception

Status: DRAFT (awaiting owner approval of shape before any code)
Owner: avespoli
Created: 2026-06-18

## Goal

Give the agent on-device "eyes": it watches the screen, understands what is
there, and reacts to what the user is doing - in the moment, co-present, never
leaving the machine. Replaces the old Agora "IMG" OCR hook with something far
more ambitious: a live perception loop, not a one-shot image->text convert.

## Verified feasibility (probed on this machine, macOS 26.5, M4 Pro)

- ScreenCaptureKit framework: present. Does BOTH one-shot snapshots
  (SCScreenshotManager) and continuous frame streaming (SCStream). Capture is
  the easy part; it can stream at display refresh.
- Vision framework: present. VNRecognizeTextRequest = on-device OCR, sub-second.
- FoundationModels (Apple on-device LLM): present, but TEXT-ONLY in 26.5. Every
  LanguageModelSession.respond(to:) overload takes a text Prompt and returns
  String/Generable - NO image-bearing prompt API. So Apple's on-device LLM can
  reason over OCR'd TEXT, but cannot see pixels.
- ollama: installed (/opt/homebrew/bin/ollama). This is the path for TRUE pixel
  sight via a local vision-language model (llama3.2-vision / qwen2.5-vl /
  moondream), fully on-device. (Local-only; a model must be pulled first.)

Conclusion: the whole loop runs on-device. No cloud. Apple stack covers
capture + OCR + text reasoning; ollama covers true visual reasoning.

## Architecture

A new PERIPHERAL subsystem. It does NOT touch the SEALED capture path
(SpeechAnalyzerSession + the Dictator capture path in main.swift). The eyes are
to vision what the mic is to audio; they share nothing with dictation internals.

Loop:
1. Capture (ScreenCaptureKit)
   - SCStream feeds a rolling in-memory ring buffer of the last ~15-30s of
     frames (downscaled). This is the "replay" that makes reasoning feel
     co-present: when we reason, we hand the model recent MOTION, not one still.
   - A 3s heartbeat pulls the latest frame for the always-on OCR pass.
2. Always-on text layer (Vision OCR)
   - Every 3s tick: VNRecognizeTextRequest over the current frame -> on-screen
     text. Cheap, constant, on-device.
3. Delta gate (the tunable knob)
   - Compare current frame/text to the previous (perceptual hash of a downscaled
     frame, and/or OCR-text diff). A TUNABLE threshold decides "did enough
     change to be worth reasoning about." Turn it up = calm; down = reactive.
4. Escalation to full reasoning, fires on:
   (a) delta crossing the threshold (automatic), and
   (b) the user starting to interact (interaction is itself an automatic
       trigger for a full reasoning pass).
   Full reasoning =
     - text path: Apple FoundationModels text LLM over the OCR text (+ recent
       text deltas) -> situational summary. All Apple, fast.
     - sight path: local VLM via ollama over recent keyframes from the ring
       buffer -> describes/answers about non-text content. Heavier; gated by
       the delta so it does not run every tick.
5. Output: situationally-aware context fed to the agent (the companion's eyes),
   NOT injected into a field. Surfaced/consumable as live context.

## Perception memory + semantic delta (the "cheat code") - reuses RAGIndex

Owner insight (2026-06-18): stream perception into a vector store in real time so
retrieval surfaces the most important change immediately - "skip to the interest,
better than a binary search." Sharpened and adopted.

Infra already exists: RAGIndex.swift does on-device NLContextualEmbedding (free,
no model pull) -> mean-pooled doc vector -> cosine over an in-memory index
(sub-ms) -> AES-GCM encrypted at rest with the corpus key. The eyes' memory is an
EXTENSION of this proven code, not new infra.

Two wins:
1. Semantic delta gate. Embed each 3s tick's OCR text. "Important change" becomes
   a DISTANCE in meaning-space, not a pixel diff. The delta gate escalates on
   semantic novelty, not "pixels moved." Cheap cosine op.
2. Associative perceptual memory. Stream every tick's embedding into the index so
   the agent can RETRIEVE past moments by meaning ("when did that error first
   appear") - jump straight to the relevant moment instead of replaying linearly.
   Associative NN, no time-ordering needed; beats bisecting the timeline because
   interest is not monotonic in time.

The required reference (importance is undefined without it):
   - recent-context centroid -> NOVELTY (how new vs what was just on screen)
   - user "interest" vectors -> RELEVANCE (how much the user cares right now)
   important(frame) = f(novelty, relevance). The vector store makes both cheap;
   the references are what must be defined.

PHI note: embeddings + OCR text are DERIVED PHI - encrypted at rest exactly like
RAGIndex already does; never logged in cleartext.

## PHI / security posture (NON-NEGOTIABLE - this is a PHI machine)

The screen is the most sensitive surface on this box. The eyes inherit the
recordings posture:
- Frames live in memory; prefer ephemeral. Cleared aggressively.
- NOTHING leaves the device. No cloud VLM. ollama is localhost-only.
- No frame, OCR text, or reasoning output is ever written to a cleartext log.
  (Reuse the EncryptedLog discipline; log only content-free counters.)
- If any frame/text is ever persisted (e.g. replay buffer spill, debug), it is
  AES-GCM encrypted at rest (reuse SecureStore/KeychainStore) and
  Spotlight-excluded, exactly like RecordingDatabase.
- Screen Recording TCC permission is required; request it explicitly, fail
  gracefully (and visibly) if denied.

## Phasing

Phase 1 - "reads the screen" (all Apple, ships fast)
  - ScreenCaptureKit one-shot + 3s heartbeat.
  - Vision OCR pass.
  - Delta gate (perceptual hash + OCR-text diff, tunable threshold).
  - FoundationModels text reasoning over OCR text on escalation.
  - Output to a situational-context sink the agent can read.
  - TCC permission flow + PHI-safe (no cleartext) handling.

Phase 2 - "the cheat code" (perception memory + semantic delta)
  - Embed each 3s tick's OCR text via NLContextualEmbedding (extend RAGIndex).
  - Upgrade the delta gate: escalate on SEMANTIC novelty (distance from the
    recent-context centroid), not just pixel diff.
  - Stream embeddings into an encrypted on-device index (RAGIndex pattern); agent
    can retrieve past moments by meaning.
  - "Interests": user interest vectors; score each frame for relevance -> "skip
    to the interest." Surface spikes.

Phase 3 - "true sight" (local VLM)
  - SCStream ring buffer (rolling replay).
  - ollama local VLM over recent keyframes on escalation.
  - Engine abstraction so text-LLM vs VLM is one seam.

Phase 4 - "co-present companion"
  - Interaction-triggered reasoning (key/mouse activity = automatic full pass).
  - Replay-aware prompting (hand the model the recent clip, not a still) so it
    reacts to what just changed.
  - Adaptive delta threshold (auto raise/lower based on how valuable recent
    reactions were).

## Owner decisions (2026-06-18)

1. FIRST-cut reasoning engine: A - OCR text -> Apple FoundationModels text LLM.
   Pure Apple, no model pull, ships fastest. Local VLM (ollama) is Phase 2.
2. Watch scope: a RESIZABLE, PERSISTENT overlay window. The user places/sizes a
   frame; the eyes capture the screen region under that frame. Reuses the
   draggable-overlay DNA of RecordingOverlay (a positioned, resizable NSWindow);
   capture region = the overlay's current screen rect. NOT full display, not
   focused-window-tracking - an explicit, movable "look here" frame.
3. Context consumption seam: DEFERRED - pick the cleanest seam once Phase 1
   capture+OCR is running (encrypted file vs in-memory bus).

## Emotional spec (the product target, owner's intent)

Shared witnessing in real time: the user can turn to the agent, ask "did you see
that," and the agent did - and responds coherently about what just happened on
screen, without the user having to narrate it. The replay ring buffer (recent
motion, not a single still) is what delivers this; it is the core feature, not a
nicety.

## Blast radius: MEDIUM
New screen-capture subsystem + TCC permission + PHI-bearing frames. Isolated
from the sealed path, but touches a sensitive new capability surface. A
rollback note pairs with this plan before any persistence/permission code lands.

## Out of scope (explicitly)
- Any change to the SEALED capture/dictation path.
- Any cloud model. Any non-ASCII. Any cleartext persistence of frames/text.
