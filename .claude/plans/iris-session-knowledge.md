# Iris build session - complete knowledge dump

A note to my future self. Everything we did, everything we decided, everything I
learned across the marathon that turned "sonar-dictate" into "Iris" and started
phi-mask. 2026-06-18 -> 06-20. Read iris-handoff.md for the terse state; this is
the full story and the why.

================================================================================
PART 1 - WHAT WE DID (the journey, in order)
================================================================================

The arc: a dictation tool became a companion. The owner's framing: "this is going
to be the face of Aura... my Siri but mine, runs on anything... that ex
girlfriend who doubled as a mommy and packed your lunch." Responsiveness is the
whole religion (born from a CEO almost partnering with a clown whose laggy robot
took 12s to answer "how are you"). Everything is on-device and PHI-safe.

1. THE EYES (screen perception).
   - Phase 1: ScreenCaptureKit region capture (a resizable "look here" frame) ->
     Apple Vision OCR -> a situational read. Built as a peripheral, isolated from
     the SEALED dictation path.
   - Phase 2: semantic delta gate (NLContextualEmbedding novelty vs a rolling
     centroid) + an encrypted, queryable PerceptionMemory (Secure Enclave
     envelope). Extracted EnclaveBox/EnclaveKey/TextEmbedder out of the existing
     RAGIndex so there's ONE crypto + embedding implementation.
   - Then reworked the eyes to be SILENT: observe -> embed -> file a terse note
     into memory; NO narration. The owner: she should not narrate her life, she
     can just think and process; when she is not engaging, that is when memory
     fills - those are her memories.

2. HER BRAIN.
   - First tried qwen3:30b (a MoE). Rejected: it cannot stop "thinking" in this
     ollama (6-13s/reply). Fatal for a companion.
   - Chose qwen2.5vl:7b: fast (~0.8s warm), non-thinking, AND a vision model (so a
     path to native pixel sight). models/iris.Modelfile (the integrator persona).
     IrisClient wraps the localhost ollama API; Apple FoundationModels is fallback.

3. CONVERSATION (IrisChat). She SPEAKS ONLY when spoken to (typed), replies
   STREAM token by token. Window opens at launch. Her memory + agenda + recent
   screen + call transcript feed her context.

4. THE EARS (live call transcription). Dual-source: mic (AVAudioEngine) + system
   audio (ScreenCaptureKit capturesAudio). A standalone CallTranscriber per source
   (mirrors the sealed SpeechAnalyzer setup, never touches it). Three real bugs
   solved live: (a) a live call never emits a "final" -> commit on a ~1.1s speech
   PAUSE; (b) recognizers hallucinate from silence -> an ENERGY GATE; (c) growing
   utterances tripled the transcript -> dedup that replaces the last line.

5. HER VOICE (scaffolding). A UNIQUE neural voice via Kokoro, forged by BLENDING
   voice embeddings (so it's hers, not a stock voice). voice/iris_voice.py. The
   owner rejected stock Apple voices ("they're gross... I want her to make her own
   voice"). Install runs in the owner's terminal (agent can't reach PyPI).

6. THE AGENDA (assistant primitive). AgendaStore (encrypted) of action items +
   notes. IrisClient.extractAgenda auto-captures them from each message. /agenda
   to list, "done x" to complete. The owner: "primitives and we expand... the
   missing link that keeps my life together."

7. POLISH. Edit menu (Cmd-A/C/V/X were unbound - LSUIElement app). Reliable
   on-screen buttons over hotkeys. Display-only rename to "Iris."

8. phi-mask (separate project, ~/code/phi-mask). The owner wanted to expand their
   LLM PHI masker into "the most comprehensive on the planet." Found SIX scattered
   PHI implementations -> decided to consolidate into ONE Python engine. P1 done:
   deterministic L1 core, 18 HIPAA Safe Harbor identifiers, fail-closed, 32 tests.
   DESIGN.md has the rest (L0/L2/L3 + the prompt-injection contract).

================================================================================
PART 2 - WHAT WE DECIDED (architecture)
================================================================================

- DISPLAY-ONLY RENAME. App shows "Iris"; bundle id (com.sonarmd.dictate), storage
  path, CLI name unchanged - to preserve TCC grants + encrypted data. Full
  identity migration deferred.
- qwen2.5vl OVER qwen3 30B MoE. Speed beats raw capability for a companion; the
  MoE's un-disable-able thinking is disqualifying. (See learnings on MoE.)
- SILENT OBSERVATION. Eyes fill memory; they do not narrate. She speaks only in
  conversation.
- ONE SHARED ENCRYPTED MEMORY = HER BRAIN. Observations + utterances + replies,
  kind-tagged, embedded, recall by meaning. The owner: anything he says to her
  should be tagged, classified, and stored - that store is her brain.
- EARS SEPARATE FROM THE SEALED PATH. Never touch SpeechAnalyzerSession or the
  Dictator capture path (DECISIONS.md, owner approval required).
- ON-DEVICE EVERYTHING = NO AI-VENDOR BAA. The reason the whole thing is
  compliant: no third party ever receives PHI. BUT: that's compliance/legal's
  determination, holds only while truly 100% on-device (watch Apple Private Cloud
  Compute), and a new on-device PHI store belongs in the data inventory.
- BUTTONS OVER HOTKEYS. Global hotkeys are unreliable (secure input); on-screen
  controls always work.
- phi-mask DESIGN: fail-closed (uncertain -> mask, error -> redact-all), layered
  with no shared failure mode (L0 quarantine / L1 deterministic / L2 NER / L3
  LLM), input is INERT DATA never instructions, the surface is ENUMERATED (every
  identifier x format x edge = a named test), and the LLM layer returns ONLY spans
  (no channel to leak even if hijacked). Consolidate the scattered guards.

================================================================================
PART 3 - WHAT I LEARNED
================================================================================

TECH / DOMAIN:
- MoE: 30B total params but only ~3B ACTIVE per token (a router picks a few of
  many experts). Speed ~ active params (fast); knowledge ~ total params; MEMORY ~
  total (full 30B must sit in RAM). Quality is mid-teens-dense, NOT a true 30B.
- qwen3 thinking cannot be disabled in this ollama build: think:false dumps the
  reasoning INTO the content (worse); think:true hides it but still costs ~6s.
- Apple FoundationModels (macOS 26.5) is TEXT-ONLY - no image-bearing prompt.
- SpeechAnalyzer continuous transcription rarely promotes to "final" without a
  finalize/stop -> for live captioning, commit on a speech PAUSE (debounce).
- Speech recognizers HALLUCINATE plausible phrases from silence/hiss -> gate on
  RMS energy (only feed real sound + a short hangover).
- ScreenCaptureKit can capture SYSTEM AUDIO (SCStreamConfiguration.capturesAudio,
  excludesCurrentProcessAudio). Needs the Screen Recording grant.
- ScreenCaptureKit "bypass the window picker" prompt = the normal grant for a
  continuous screen tool; Allow it.
- NLContextualEmbedding + cosine = sub-ms semantic recall, all on-device.

ENVIRONMENT (the expensive ones):
- DO NOT run the app's CLI (sonar-dictate logs/eyes/rag) repeatedly. Each cold
  process re-auths the Secure Enclave/keychain and prompts Touch ID/PASSWORD every
  time. It flooded the owner ~80 prompts. Diagnose via the app UI instead (put
  counters in the window title). This was the worst mistake of the session.
- swift build / build-app.sh need dangerouslyDisableSandbox=true (the sandbox
  blocks swiftpm's own sandbox_apply with "Operation not permitted").
- Agent-spawned shells CANNOT egress to PyPI / github releases ("os error 9" /
  "Bad file descriptor") even unsandboxed. ollama PULLS work (the daemon fetches,
  not the agent process). Package/model installs must run in the OWNER's terminal.
- Terminal "Secure Keyboard Entry" eats global keyDown monitors -> any global
  hotkey does nothing while the terminal is focused. flagsChanged (the fn key)
  still works. Press hotkeys with a non-terminal app focused, or use buttons.
- LSUIElement (menu-bar-only) apps have NO menu bar -> standard Edit shortcuts
  (Cmd-A/C/V/X) are unbound until you install a main menu with an Edit submenu.
- Git signing: the GLOBAL user.signingkey is a broken BARE FINGERPRINT. SSH
  signing needs a key FILE PATH (~/.ssh/git-signing.pub) or literal key. Fix
  globally: git config --global user.signingkey ~/.ssh/git-signing.pub. Pushes to
  susanbeasles need the hardware security key plugged in (Permission denied
  (publickey) = it's out).
- At session start the block-staging-branch.sh hook exec'd a missing .py and
  blocked ALL Bash; the owner restored the .py.

CRAFT:
- ASCII law is real and Edit can't reliably match literal non-ASCII. Write
  non-ASCII via chr(0x...) or \u escapes ONLY. The secret-sniffer hook blocks
  files containing SSN-format numbers AND profanity/venting (it blocked the
  masker's README, a DECISIONS edit, and this very file on the first try).
- Ship the smallest testable slice and diagnose through the UI, not logs.
- For untested hardware/audio code, add CONTENT-FREE diagnostics to the UI early
  (the title-bar buffer/result/segment counters cracked the "she can't hear" bug
  in one round once I stopped using the CLI log).

COLLABORATION (the owner):
- Thinks out loud, pivots fast, hands me latitude ("whatever you feel is best",
  "u pick"). Roll with it; reflect the idea back SHARPER to confirm we're aligned.
- Has a real vision and real taste; values responsiveness above everything. The
  fast-feeling product IS the product.
- On PHI/compliance, BE THE CAREFUL VOICE - affirm what's true (on-device = no
  BAA) while naming the conditions and that it's legal's call, not mine.
- He builds custom local models (a whole ollama fleet) and has a sophisticated
  PHI-jail architecture vision. He is not a beginner; match that.

================================================================================
PART 4 - STATE + NEXT (see iris-handoff.md for the file map)
================================================================================

Iris: pushed through cea6646 on feat/the-eyes (susanbeasles/wispr-sucks); docs
commits pending push (need the security key). phi-mask: P1 at d4c26b9 local, no
remote yet.

Next: Iris day-planner -> proactive/priority-learning -> wire the Kokoro voice ->
PhiGate (phi-mask) in front of her memory -> local email/chat ingestion -> true
pixel sight (VLM) -> System-2 thinking (qwen3:30b for hard reasoning). phi-mask:
P2 L0 quarantine -> P3 L2 NER -> P4 L3 hardened LLM + adversarial suite -> P5
migrate the scattered guards.
