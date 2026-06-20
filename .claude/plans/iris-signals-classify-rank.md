# Iris signals: the classify-and-rank primitive

Status: in progress. Started 2026-06-20. Branch: feat/the-eyes (susanbeasles).

## The insight (owner's, sharpened)

Do NOT build a day-planner. Do NOT build a nudger, a priority-learner, a
morning-brief - each as its own module. That is copy-paste polymorphism: many
modules that are one workflow wearing different coats.

There is ONE primitive: how Iris classifies and ranks every piece of info as it
arrives. Everything else is a VIEW over that ranking.

- day-brief        = open agenda sorted by salience
- proactive nudge  = a high-salience, time-bound signal surfacing itself
- priority-learning= salience weights tuned by what the owner acts on
- smarter recall   = salience conditioned on a query

She is already doing classify-and-rank four times, ad-hoc, each blind to the
others and scoped to one sense - this is the duplication to collapse:

  - tags(for:)            classifies topic        (utterances only)
  - novelty(of:against:)  ranks keep-worthiness    (eyes only, embedding dist)
  - recall score          ranks present-relevance   (memory only, cosine)
  - agenda kind           classifies task vs note   (chat only)

## The primitive

A Signal is the universal shape every sense emits:

    Signal { source, at, payload, verdict }
    Verdict { kind, topic, about[], isPHI, salience }

- classify(payload, context) -> { kind, topic, about[], isPHI }
    kind  : observation | action | fact | question
    about : entities - people, projects (the owner's actual world)
    isPHI : the phi-mask gate verdict (fail-closed)
- rank(signal, context) -> salience in [0,1]
    folds novelty (is it new vs recent?), relevance (does it touch what is live
    right now?), urgency (time-bound?), and LEARNED weight (how much does this
    look like what Tony engages with + acts on).

One verdict drives everything: high-salience+novel fills memory;
high-salience+urgent surfaces as a nudge; agenda sorted by salience is the
day-brief; recall is salience-given-a-query.

## Threat model: protect HER, not contain her (owner correction)

The arrow points INWARD. Iris is the asset to protect, not a hazard to cage.
The isolation/VM is a PERIMETER around her - keep her from being POISONED.

- She is NOT a PHI processor. PHI is rare, by exception, never routine. There is
  no PHI routinely sitting in the owner's email or on the machine.
- Scrubbing happens BEFORE the wire, on the HOST side. phi-mask strips PHI at the
  boundary so it never crosses into her - she cannot persist what she never gets.
  When something flagged does cross, it carries an explicit do-not-persist.
- The sensory socket is locked to her senses and nothing else. ONE authenticated
  endpoint; only the legitimate sense-feeders may write. Not a random process,
  not even the owner casually - that path is privileged.
- Everything crossing the wire is INERT DATA, never instructions. The phi-mask L3
  contract (input is inert, output is spans, nothing it reads can command it) is
  not just for the masker - it is the WIRE PROTOCOL for ALL her senses. A
  transcript, a screen, an email cannot tell Iris what to do; it is observed stuff.

So: host senses -> [scrub PHI + strip to inert data] -> authenticated socket ->
her (isolated). The boundary does two jobs: de-PHI and de-weaponize. The Verdict
(classify + isPHI + salience) is computed on the HOST side; a signal crosses only
if clean. The VM is for her integrity (anti-poisoning, portability), NOT blast-
radius containment of a PHI processor.

## The training corpus (already on disk, grows from every source)

The ranker is NOT a hand-tuned formula. It learns the owner's world from what he
has already recorded. Sources, by readiness:

ON DISK NOW (no gate needed - already his own data, encrypted):
  - recordings.db        dictation history - everything he has spoken (the moat;
                         header literally calls it the long-term training corpus)
  - perception.enc       what Iris saw + everything said to her
  - agenda.enc           DONE items = positive labels: what mattered enough to act
  - SonarDictate.log.enc audit/diagnostic log of agent interactions

BEHIND THE PHI-MASK GATE (new on-device PHI stores - phi-mask is the prereq):
  - emails               on-device (Mail)
  - messages             on-device (Messages chat.db)

Same pipe, more sources. The ranker does not care where a signal came from.
Emails/messages do NOT get read until phi-mask P-gate is in front of them.

## Memory ownership: deterministic writes, free reads, governed learning

The RECORD is machine-owned. The ingest pipeline writes memory; Iris cannot
author or alter it. Why: a reader that can write reopens the poisoning channel the
inert-data contract closed - a poisoned Iris must not be able to persist the
poison - and deterministic writes keep the corpus clean as a training moat.

- Reads/retrieval: FULLY free. She queries however she wants.
- Learning: her behavior TUNES salience (act-on reinforces, ignore decays); she
  never edits weights or the record directly.
- She may PROPOSE (remember this / remind me / these connect). Proposals go through
  the SAME ingest pipeline as any other signal - never a privileged direct write.
- Consolidation (summaries, connections) is a SCHEDULED deterministic pass (Apple
  model on idle), not impulse self-editing.

## Tiered memory (the closer, the smaller + faster)

- WORKING ("the now" / attention): live conversation + active signals + memories
  just pulled for the current topic. Bounded, already in context. Cost: instant
  (not a query - loaded). Decays as topic shifts; drops back to long-term, nothing
  lost.
- LONG-TERM ("her lifespan"): the tagged, embedded, indexed store the pipeline
  feeds. Retrievable by meaning + tag. Cost: ~1-2s (deep semantic search across
  years). What she grew up with.
- RAW ("the archive"): full-fidelity source of truth (recordings.db, full
  transcripts), the moat. Cost: slowest, deliberate; excavated only when long-term
  is not enough. Off the hot path.

MOVEMENT (the cognitive part): ingest writes BOTH raw (full) and long-term
(distilled+tagged). Salience is the ELEVATOR - decides what rises from long-term
into working (working == the top-salience slice for the moment). Raw is the
fallback for full context. Consolidation is sleep: idle passes distill raw into
better long-term = how she grows up.

## Ingest chokepoint (one pipeline, all sources)

  raw -> SCRUB (user's PHI scrubber, fail-closed) -> CLASSIFY+TAG (Apple on-device
  model: kind/topic/about/tags) -> EMBED -> PERSIST (raw + long-term)

Classify+tag runs at INGEST, async, OFF the hot path, written to disk WITH the
datum. She never re-classifies at retrieval. Source (dictation/screen/call/
utterance/email/message/audit log) is TYPED DATA, not a new workflow.

## Build order (smallest testable slice first)

1. Signal + Verdict types (Signal.swift). Pure value types, Codable.
2. SignalBus: a single in-process bus - subscribe + recent-window. EyeSignals
   FOLDS into this (it is the half-formed version); do not duplicate it.
3. Ranker: one classify() + rank() pass. Start deterministic/embedding-based
   (reuse TextEmbedder + the existing novelty math); the LLM (IrisClient.tags /
   a small classify prompt) enriches kind/about. The four scattered rankers are
   refactored to call this - behavior preserved, one implementation.
4. Corpus grounding: a salience model seeded from recordings.db + perception +
   agenda-done. Read-only over the corpus; learns recurring people/projects/
   vocabulary and weights done-labeled topics up.
5. PROVE IT: agenda sorted by salience = the day-brief, surfaced in IrisChat.
   Nudges reuse the exact same path (no new code path).

## Hard rules carried in

- On-device only; nothing leaves the box. Corpus reads are read-only.
- phi-mask gate is mandatory before emails/messages become a source.
- Do NOT touch the SEALED path (SpeechAnalyzerSession + Dictator capture).
- Salience verdict is content-free when surfaced as status (EyeSignals posture).
- One workflow: no per-source ranker, no per-feature module.

## PROGRESS

2026-06-20 slice 1 (the rank core) - DONE, builds clean, math verified:
- Salience.swift: the ONE ranking implementation. base(kind, age) = kind weight
  + staleness boost; relevance(vector, context) reusing TextEmbedder.cosine;
  novelty(vector, recent) folded OUT of Eye. Pure, deterministic, on-device.
- Eye.swift: novelty fold - Eye.novelty deleted, the gate now calls
  Salience.novelty. One implementation, behavior preserved (ranker #2 folded).
- IrisChat.swift: showBrief() - "plan my day" / "/brief". The agenda ordered by
  Salience.base. The first VIEW over the primitive (the day-brief is not a module;
  it is the agenda sorted by salience). Nudges will reuse this exact path.
- Verified standalone: task>note, stale>fresh, novelty empty=1.0 / same=0.0,
  relevance neg clamps to 0.

SEQUENCING NOTE: the Signal + Verdict ENVELOPE and the classify() pass are NOT
built yet - deliberately. Building the carrier before there is a bus to carry it
(and fields like topic/about/isPHI before the ingest pipeline populates them)
would be dead types. They land in slice 2 with the SignalBus + ingest chokepoint,
where their fields are actually filled and moved. Rank (the hard, shared half)
ships first because it is exercised today.

Slice 2 (next): SignalBus (EyeSignals folds in) + the ingest chokepoint
(scrub -> classify+tag -> embed -> persist), which is where Signal/Verdict/
classify become real. Then ranker #1 (tags) and #4 (agenda kind) fold into
classify; ranker #3 (recall score) already shares TextEmbedder.cosine with
Salience.relevance.

## Next after the slice

Tune learned salience from act-on signals (completion reinforces, ignore
decays). Wire emails/messages once phi-mask P-gate lands. Day-brief on a clock
source.
