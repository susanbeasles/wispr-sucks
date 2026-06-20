# Iris - handoff notes (continuity for next session)

Last updated: 2026-06-19. Branch: feat/the-eyes on remote `susanbeasles`
(susanbeasles/wispr-sucks), pushed through commit cea6646. The app was renamed
to "Iris" (display only).

## What Iris IS today (all on-device, PHI-safe)

- EYES: watches a resizable screen region SILENTLY (no narration), embeds + files
  a terse note into encrypted memory on meaningful change. Files: EyeCapture
  (ScreenCaptureKit), ScreenText (Vision OCR), Eye (3s loop + semantic novelty
  gate), EyeOverlay (the "look here" frame: drag to move, corner grip to resize,
  X to close), EyeSignals (bus; title-only status, never content).
- EARS: dual-source live call transcription, SEPARATE from the sealed dictation
  path. CallListener (mic via AVAudioEngine + system audio via ScreenCaptureKit
  capturesAudio), CallTranscriber (standalone SpeechAnalyzer; commits on ~1.1s
  speech PAUSE since a live call has no push-to-talk "final"; energy gate so
  silence does NOT hallucinate phantom text). Surfaced in IrisChat.
- MEMORY (her brain): PerceptionMemory (encrypted vector store, EnclaveBox) +
  AgendaStore (encrypted action-items/notes). One memory holds observations,
  utterances, replies, agenda. Recall by meaning. CLI: `sonar-dictate eyes recall`
  (BUT see CLI WARNING below).
- MIND: IrisClient -> local ollama model `iris` (Modelfile in models/iris.Modelfile,
  built on qwen2.5vl:7b - fast ~0.8s, non-thinking; the qwen3 30B MoE was rejected
  because it can't stop thinking, 6-13s/reply). Apple FoundationModels is fallback.
- CONVERSATION: IrisChat window (opens at launch). She SPEAKS ONLY when spoken to
  (typed). Replies STREAM. Auto-captures agenda items ([+task]/[+note]). Commands:
  `/agenda`, "what's on my list", "done <x>". The call transcript + agenda +
  recent screen feed her context.
- AGENDA: the assistant primitive. IrisClient.extractAgenda pulls action items/
  notes from each message (conservative).
- VOICE (pending install): voice/iris_voice.py - a UNIQUE neural voice via Kokoro,
  forged by BLENDING voice embeddings (IRIS_BLEND in the file). Needs the user to
  run the install in THEIR terminal (agent shells can't reach PyPI):
    cd ~/code/sonar-dictate && source voice/.venv/bin/activate
    uv pip install kokoro-onnx soundfile numpy
    python voice/iris_voice.py "Hi, I'm Iris."
  Then tune the blend by ear; wire into IrisChat replies after.

## Controls

- Ctrl-Opt-E: start/stop watching (+ opens chat). Ctrl-Opt-I: open chat.
  Ctrl-Opt-J: toggle call listening. ALL hotkeys are eaten by a terminal with
  Secure Keyboard Entry - press them with a NON-terminal app focused (or use the
  on-screen buttons). The chat has a "Listen" button (reliable, no hotkey).
- The eye frame: drag border to move, corner grip to resize, X to close.
- Cmd-A/C/V/X work in her window (an Edit menu was added; LSUIElement apps have no
  menu bar otherwise).

## HARD-WON GOTCHAS (do not relearn these)

1. DO NOT run `sonar-dictate logs` (or other CLI) repeatedly. Each cold CLI process
   re-auths to the Secure Enclave/keychain and prompts Touch ID/PASSWORD every
   time - it flooded the user with ~80 prompts. Diagnose via the app UI (window
   title indicators), NOT the CLI log.
2. swift build / build-app.sh need dangerouslyDisableSandbox=true (the Claude
   sandbox blocks swiftpm's own sandbox_apply and PyPI/github egress). Build:
   `./scripts/build-app.sh debug` then relaunch (pkill -f dist/SonarDictate.app;
   open dist/SonarDictate.app). Minimize relaunches - a fresh launch can prompt
   for the keychain once.
3. Git signing: the GLOBAL user.signingkey is a broken bare fingerprint. Fix:
   `git config --global user.signingkey ~/.ssh/git-signing.pub` (offered; confirm
   with user). Push needs the hardware security key plugged in (Permission denied
   (publickey) = key not present).
4. ASCII law: write non-ASCII via chr(0x...) / \u escapes, never literals (Edit
   can't match literal non-ASCII reliably anyway). The secret-sniffer hook blocks
   files containing SSN-format numbers and profanity - keep examples non-SSN.
5. Network: agent-spawned shells CANNOT reach PyPI/github releases (os error 9).
   Package/model installs run in the USER's terminal. ollama pulls work (daemon
   does the fetch, not the agent process).
6. SEALED (DECISIONS.md, owner approval required): SpeechAnalyzerSession.swift
   (entire) + the Dictator capture path in main.swift. The eyes/ears/agenda are
   all SEPARATE peripherals; never touch the sealed path.

## Open next steps (Iris)

- Day-planner: sequence the agenda into an itinerary.
- Proactive / priority-learning: she surfaces "it's Friday, you said you'd ship X"
  and learns priorities from tags over time (the "packs your lunch" part).
- Wire her voice (Kokoro) into chat replies once the install + blend are done.
- PhiGate: the screen-and-mask layer in front of her memory (use phi-mask) - the
  prerequisite for "she reads my email/chats." See phi-mask handoff below.
- True pixel sight: a VLM (qwen2.5vl/qwen3-vl already pulled) reading screenshots,
  not just OCR text. Stage 3 of the eyes.
- System-2 thinking brain: route hard reasoning to the local qwen3:30b.
- Local email/chat ingestion (on-device: Messages chat.db, Mail) THROUGH phi-mask.

## phi-mask (separate project: ~/code/phi-mask)

The canonical PHI masking engine, consolidating the scattered guards
(inbox-manager/phi_guard.py, candidate-inbox/phi_guard.py, agent-pi/redact.py,
nomos phi-patterns.json, credential-manager/redaction.ts, frontend-patient-app/
phiLeakReporter.ts). Python, fail-closed, on-device. Committed locally (d4c26b9),
NO remote yet (user picks the home).

- DONE (P1): L1 deterministic core - 18 HIPAA Safe Harbor identifiers, Unicode
  normalization, Luhn cards/NPI, stable tokens, content-free report, 32 stdlib
  tests (python3 -m unittest discover -s tests -t .). See DESIGN.md.
- NEXT: P2 L0 structured-file quarantine + masking modes + vault + CI eval gate ->
  P3 L2 on-device NER -> P4 L3 hardened LLM (the prompt-injection contract:
  spans-only output, input-is-inert-data, fail-closed, canary) + the adversarial
  injection suite -> P5 migrate the scattered guards onto it.
- Compliance note: on-device + nothing-leaves-the-box is the reason no AI-vendor
  BAA is needed - but that determination is SonarMD legal/compliance's call, and
  ingesting email/chat creates a new on-device PHI store that belongs in the data
  inventory. Get compliance to bless the masker scope before real ingestion.
