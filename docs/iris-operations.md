# Iris - operations reference

Everything you can turn on, set up, and type. (Display name "Iris"; the app/binary
is still `sonar-dictate`.) Architecture lives in `.claude/plans/iris-*.md`.

## Build + run

```
./scripts/build-app.sh debug
pkill -f dist/SonarDictate.app; open dist/SonarDictate.app
```

## One-time setup: portable recovery (recommended, do it early)

The personal + brain ledger chains are sealed with a recoverable key. Derive that
key from the 1Password passphrase ONCE (it gets cached; later launches need no
`op`). Do this BEFORE much data accumulates, so the chains seal with the
recoverable key from the start:

```
IRIS_LEDGER_PASSPHRASE='op://Personal/iris-ledger-credential/password' \
  op run --account my.1password.com -- open dist/SonarDictate.app
```

Recovery on a new Mac: restore the backup folder (carries the KDF salt) and re-run
the same line. New Mac + that 1Password item + the backup = full restore.

## Environment switches (all opt-in; unset = off)

| Variable | Effect |
|---|---|
| `IRIS_LEDGER_PASSPHRASE` | `op://` ref to the recovery passphrase. Used once to derive + cache the recoverable KEK (see setup above). |
| `IRIS_BACKUP_DIR` | Off-device backup destination - point at a synced folder (iCloud Drive / Dropbox local folder). Replicates the recoverable chains (ciphertext only; company chain never leaves) at launch + every 5 min. |
| `IRIS_INGEST_MESSAGES=1` | Ingest local iMessage/SMS (`chat.db`) into the personal chain. Needs Full Disk Access granted to the app. Off by default. |
| `IRIS_INBOX_DIR=<path>` | Drop-folder ingestion - text files (.txt/.md) dropped there get ingested into the personal chain. |
| `IRIS_PHIMASK_DIR` | Path to the phi-mask package (default `~/code/phi-mask`). |
| `IRIS_VOICE_DIR` | Path to the voice dir (default the repo `voice/`). |

Example - everything on, with recovery:

```
IRIS_LEDGER_PASSPHRASE='op://Personal/iris-ledger-credential/password' \
IRIS_BACKUP_DIR="$HOME/Library/Mobile Documents/com~apple~CloudDocs/iris-backup" \
IRIS_INGEST_MESSAGES=1 \
IRIS_INBOX_DIR="$HOME/iris-inbox" \
  op run --account my.1password.com -- open dist/SonarDictate.app
```

## Chat commands (type in her window)

| Command | What it does |
|---|---|
| `/brain` (`/ledger`) | Ledger chain heights (personal/company/brain) + top themes + recent learnings |
| `/verify` | Walk every chain and report tamper-evidence status + counts |
| `/brief` (`/plan`, "plan my day") | Open agenda ordered by salience |
| `/agenda` (`/list`) | Open agenda items |
| `done <x>` | Complete the matching agenda item |
| `/mute` / `/voice` | Silence / re-enable her spoken replies |

## What happens to what you say/show her

```
in (chat / eyes / ears / messages / drop-folder)
  -> SCRUB (phi-mask, fail-closed)
  -> CLASSIFY by owner (provenance-first; company never relaxes, personal can escalate)
  -> SEAL in the owner chain (company = Enclave/device-bound; personal+brain = recoverable)
  -> ENRICH (topic/about/tags) + DERIVE learnings -> dedup -> her ONE brain
  -> (recoverable chains) backed up off-device as ciphertext
```

The company chain never leaves the device; only abstracted learnings (never raw)
enter her brain; her brain holds no PHI and no raw company data.

## Her voice

She speaks her chat replies in her own blended voice. Re-audition anytime:
`cd voice && source .venv/bin/activate && python iris_audition.py --redo`.
Her current choice lives in `voice/iris_voice.json`.
