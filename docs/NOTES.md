# Hard-won macOS permission lessons

Things I lost time on getting the dictation spike to actually run. Future me
(or anyone building a similar Speech-framework + global-hotkey Mac app via
Swift Package Manager) — read this first.

## 1. Bare SwiftPM binary aborts on Speech / Mic access

`swift build` produces a CLI executable with **no Info.plist**. macOS sends
SIGABRT (exit 134) the moment that binary touches `SFSpeechRecognizer`,
`AVAudioEngine`, or anything else gated by a `NS*UsageDescription` key —
**silently**, with no stderr output, no crash log. Symptom: process starts,
exits in <1s, you have no idea why.

**Fix:** wrap the binary in a minimal `.app` bundle:

```
SonarDictate.app/
  Contents/
    Info.plist                # NSMicrophoneUsageDescription, NSSpeechRecognitionUsageDescription, CFBundle*
    MacOS/
      SonarDictate            # the binary, named to match CFBundleExecutable
```

See `Resources/Info.plist` and `scripts/build-app.sh`.

**Launch via `open dist/SonarDictate.app`**, NOT by invoking the binary
directly. The bare binary, even sitting inside the bundle, still SIGABRTs
when run from a path — only `open` (and `launchctl bsexec` to the right
LaunchServices context) associates it with the Info.plist.

## 2. `addGlobalMonitorForEvents` does not request Accessibility

Calling `NSEvent.addGlobalMonitorForEvents(matching:)` for keystroke events
**silently does nothing** if the app isn't trusted by the Accessibility
service, AND **does not register the app in the Accessibility list**. The
user has nothing to grant; the toggle isn't there.

**Fix:** explicitly call `AXIsProcessTrustedWithOptions` with the prompt
option at startup:

```swift
import ApplicationServices

let promptKey = kAXTrustedCheckOptionPrompt.takeRetainedValue() as String
let opts = [promptKey: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
```

This both:
- Surfaces the prompt (or opens System Settings to the right pane)
- Registers the app in the Accessibility list so the user can toggle it on

## 3. Accessibility permission requires app restart to take effect

After the user enables the toggle in System Settings → Privacy & Security →
Accessibility, the **already-running process does NOT start receiving
events**. The OS only checks Accessibility trust at process start (or
specific framework init points). Kill and relaunch:

```bash
pkill -f SonarDictate && open dist/SonarDictate.app
```

## 4. TCC binds permissions to a binary hash, so every rebuild resets them

The unified log shows TCC identifying the app as
`sonar-dictate-<sha-ish-hash>`. The hash changes on every rebuild. For dev
iteration this means re-granting on each build — annoying but expected.

**For production:** sign and notarize the .app properly. Signed apps get a
stable TCC identity tied to the team ID and bundle ID, surviving rebuilds.

## 5. Diagnose Mac app silent failures via the unified log

`log show` is the only place these failures surface. Useful queries:

```bash
# What the app itself logged (NSLog output)
log show --predicate 'process == "SonarDictate"' --last 60s

# TCC daemon decisions — see prompt firing, permission rejections
log show --predicate 'subsystem == "com.apple.TCC"' --last 60s | grep -i SonarDictate

# AUTHREQ_PROMPTING lines confirm prompts actually fired (not lost on a back Space)
```

`--process <name>` is invalid syntax; use `--predicate 'process == "name"'`.

## 6. Build + run cycle

```bash
# rebuild from source
./scripts/build-app.sh debug

# kill any running instance, relaunch fresh
pkill -f SonarDictate && open dist/SonarDictate.app

# watch app-side logs
log stream --predicate 'process == "SonarDictate"' --style compact
```

## 7. Permissions checklist for a fresh machine

1. **Speech Recognition**: prompt fires automatically on first
   `SFSpeechRecognizer.requestAuthorization`. Allow.
2. **Microphone**: prompt fires when `AVAudioEngine.start()` is first called
   with a tap installed. Allow.
3. **Accessibility**: opens System Settings if `AXIsProcessTrustedWithOptions`
   is called with prompt=true. Enable the SonarDictate toggle, then RESTART
   the app.
