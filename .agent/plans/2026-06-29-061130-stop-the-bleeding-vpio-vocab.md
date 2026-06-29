---
name: stop-the-bleeding-vpio-vocab
status: done
blast_radius: low
owner_approved: yes (owner picked "Stop the bleeding first"; approved CLI signing + live refresh)
---

## OUTCOME (2026-06-29)

Done and compiling (swift build -c release clean; app+CLI signed, DRs match):
- VPIO opt-in/default-OFF (main.swift bootstrap).
- Plaintext diag write removed (main.swift bootstrap).
- Correction weight: flat +3 -> correctionBoost 14 (drives bias to formula cap);
  routed EditWatcher through learnCorrection (DictionaryStore.swift, EditWatcher.swift).
- Live vocab refresh: EditWatcher.onLearned -> Dictator.refreshVocabularyModel so a
  correction biases THIS session, not just next launch (EditWatcher.swift, main.swift).
- Keychain prompt flood fixed: build-app.sh now signs the standalone CLI binary with
  the SAME identifier+cert as the .app, so both share one designated requirement
  (identifier com.sonarmd.dictate + Apple Development: Anthony Vespoli XMX9T4F86F).
  One "Always Allow" now sticks across rebuilds. No DB wipe, no key rotation.

Sentry bumped once via CLI before the keychain blocked the rest; the new correction
policy + live refresh now max it on the next in-app correction.

Owner validation pending: relaunch dist/SonarDictate.app, click "Always Allow" once
on the keychain prompt, say "Sentry", confirm it lands; confirm normal + Bluetooth
dictation restored.

NEXT (owner: "and then replace VPIO"): AEC integration - separate plan.

# Stop the bleeding: VPIO off-default, kill plaintext diag, make jargon win

## Context

Owner reports degraded dictation. Specific symptom: "Sentry" transcribes as
"century". Forensics (this session):

- Git fully intact. No reverts, no lost commits, no stashes. Reflog clean.
- The OWN NLMS echo canceller lives in poc/aec (untracked POC). It was built in
  /tmp in a god-mode session, reaped on reboot, recovered 2026-06-27. NEVER wired
  into the app. App has always used Apple VPIO. AEC integration is parked:
  .claude/plans/2026-06-24-053629-own-echo-canceller.md.
- Vocab pipeline is INTACT and correctly wired: prepareVocabulary builds a custom
  LM (SpeechAnalyzerSession.swift:95), start() attaches it via
  .customizedLanguage (line 182), setContext applies it (line 261). Not reverted.
- Two real regressions:
  1. VPIO flipped to default-ON (commit 5f5c701, main.swift:141 `!= "0"`). VPIO
     ducks music, breaks on Bluetooth, and degrades the no-music common case.
     Degraded audio makes the recognizer trust the acoustic guess ("century")
     over the personal bias. Timing matches "all of a sudden".
  2. Plaintext diag file write (commit a22bcaa, main.swift:142-156) to
     ~/Library/Logs/SonarDictate-vpio.txt. No PHI/transcript (audio-format strings
     only) but a cleartext file on a PHI machine that bypasses the encrypted log.
- Sentry bias is too weak: count = base 20 + weight 2 * perWeight 6 = 32. A
  proper noun at 32 loses to the general LM prior for "century". Owner never says
  "century"; the personal LM must overrule the generic corpus prior.

## SEAL note (DECISIONS.md 2026-06-14)

SpeechAnalyzerSession.swift is fully sealed; the Dictator capture path in
main.swift is sealed. bootstrap() (where the VPIO enable lives) is NOT in the
sealed list, and the owner explicitly authorized this corrective pass. I am NOT
modifying SpeechAnalyzerSession.swift. Changes are confined to the bootstrap VPIO
block in main.swift (owner-approved) and dictionary DATA (open per the seal).

## Steps

1. main.swift:141 - VPIO opt-IN: `!= "0"` -> `== "1"`. Rewrite the comment block
   (137-140) to state opt-in and WHY (ducks music, breaks BT, degrades no-music
   case incl. proper-noun bias). Keep graceful-degrade do/catch.
2. main.swift:142-158 - remove the plaintext writeDiag path + its two calls; keep
   the NSLog lines (encrypted log). Restructure do/catch cleanly.
3. Reinforce "Sentry" in the dictionary so it wins even on marginal audio. Bump
   its weight (targeted, owner-intended mechanism; does NOT touch the global base
   that could over-bias every common word). Target count ~80+ (weight ~10).
4. Rebuild (scripts/build-app.sh per repo), relaunch. Owner validates on-device:
   say "Sentry", confirm it lands; confirm normal + Bluetooth dictation restored.
5. If Sentry still loses, calibrate via IRIS_VOCAB_BIAS_BASE/PER_WEIGHT/CAP
   (no rebuild needed) before considering a formula default change.

## Out of scope (separate, parked)

Wiring the poc/aec NLMS canceller in to replace VPIO. That is the real long-term
fix for dictating over music / over Bluetooth without ducking. Tracked separately
after this corrective pass lands and is validated.

## Rollback

git revert of the corrective commit restores prior behavior. Dictionary weight
bump is reversible via `sonar-dictate dict` editing. blast_radius low.
