# Plan: encrypt the diagnostic log at rest

## Problem
`~/Library/Logs/SonarDictate.log` is a plaintext, 0644, unencrypted file. stderr
(where every NSLog writes) is redirected into it via `freopen` (main.swift:1192).
Confirmed PHI-at-rest leak: 5040 lines of `classified -> dictate(<first 40 chars
of the utterance>)` in cleartext. The transcript-content interpolation is already
fixed in Triggers.swift (logs now carry route + length only), but:
  1. the existing 5040-line plaintext file still holds cleartext PHI, and
  2. the user wants the log ENCRYPTED at rest going forward, not deleted.

## Decision
Add an in-process encrypted log sink. Reuse the EXISTING crypto, do not invent:
- Key: `KeychainStore.loadOrCreateDBKey()` -> AES-256-GCM SymmetricKey. This is the
  same key the corpus DB uses. Chosen over the SecureStore Secure-Enclave key
  because KeychainStore is explicitly background-context safe (no Touch ID prompts);
  the sink installs at app launch, possibly background.
- On-disk: `~/Library/Logs/SonarDictate.log.enc`, 0600, completeFileProtection.
- Format: append-only framed records `[4-byte BE length N][N bytes AES.GCM.combined]`.
  Each record is an independent GCM seal (random nonce per record). A partial
  trailing record from a crash is detected by the length prefix and ignored on read.

## Steps
1. New file `Sources/SonarDictate/EncryptedLog.swift`:
   - `install()`: load key; migrate any existing plaintext log into one encrypted
     record then remove the plaintext; create a Pipe; `dup2` its write end onto
     STDERR_FILENO so NSLog/stderr flow in; `readabilityHandler` seals each chunk
     and appends a framed record on a serial queue. FAIL SAFE: if the key is
     unavailable, do NOT fall back to plaintext - diagnostics go to the unified log
     only. (Retain the Pipe in a static to keep fds open.)
   - `readAll() -> String`: iterate framed records, GCM-open each, concatenate.
   - `follow() -> Never`: print existing, then poll the file (~0.3s) and decrypt new
     complete records as they are appended (record boundaries are atomic-append safe).
   - Never call NSLog inside append()/the handler (would recurse into the pipe).
2. main.swift startup: replace the `logPath`/`freopen`/launch-NSLog block with
   `EncryptedLog.install()`.
3. main.swift runCLI: add `case "logs"` -> `--follow`/`-f` calls `follow()`, else
   `readAll()` to stdout. Update the `help` text with a `diagnostics:` section.
4. Rebuild via scripts/build-app.sh (codesign), launch once to trigger migration,
   verify: plaintext log gone, `*.log.enc` present at 0600, `sonar-dictate logs`
   decrypts and includes migrated history, new launch lines appear encrypted.

## Out of scope / notes
- True secure-erase of the old plaintext is not achievable at app level on APFS
  (copy-on-write/SSD wear-leveling). We truncate-then-remove; report this honestly.
- Once encrypted, `tail`/`grep` no longer work on the log; `sonar-dictate logs
  [--follow]` is the replacement and also the way to capture the still-open
  swallow-bug diagnostics live.
- Do not entangle with `reset`; no `logs --wipe` for now (minimal diff).
- The unverified swallow root cause is unchanged by this work.
