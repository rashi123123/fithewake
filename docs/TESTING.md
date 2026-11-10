# Testing

## Core tests and the engine evaluation

No device or Xcode project needed:

```sh
swift test -c release -Xswiftc -enable-testing
swift run -c release night-eval
```

Release mode keeps the simulated-night tests fast. `night-eval` prints the
table in [SMART_WAKE_RESEARCH.md](SMART_WAKE_RESEARCH.md); if you change the
engine, update that table and say why the numbers moved.

## App build

Simulator, no signing:

```sh
xcodebuild -project FitheWake.xcodeproj -scheme FitheWake \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

On an iPhone (iOS 26 or later), first create `Config/Local.xcconfig`, which git
ignores:

```
DEVELOPMENT_TEAM = YOUR_TEAM_ID
BUNDLE_ID_PREFIX = com.yourname
```

Then build, install and launch on the one connected iPhone:

```sh
./scripts/build_and_run.sh
```

Set `FITHEWAKE_DEVICE_ID` if more than one iPhone is connected. `--logs`
streams the app's console, `--debug` starts it paused for a debugger.

## UI tests

The default UI tests only open screens and cancel; they never save an alarm,
connect a wearable or pause monitoring.

Tests that touch real alarms or Bluetooth are skipped unless you opt in, by
prefixing `xcodebuild … test` with `TEST_RUNNER_<NAME>=1`:

| Variable | What it does |
| --- | --- |
| `FITHEWAKE_HARDWARE_QA` | Saves, restores and turns off an alarm (only when none is set), and arms and cancels a separate one-minute test alarm. |
| `FITHEWAKE_CLEAN_PREVIOUS_QA_ALARM` | Lets the test-alarm test cancel a test alarm left by an earlier run. |
| `FITHEWAKE_WEARABLE_QA` | Silences the heart-rate stream once and checks that the app recovers. Needs a wearable sharing heart rate. |
| `FITHEWAKE_OVERNIGHT_QA` | Watches the engine warm up on live heart rate. |
| `FITHEWAKE_MANUAL_AUDIO_QA` | Arms the test alarm for you to listen to. |

```sh
TEST_RUNNER_FITHEWAKE_HARDWARE_QA=1 xcodebuild -project FitheWake.xcodeproj \
  -scheme FitheWake -destination 'platform=iOS,id=YOUR_DEVICE_ID' test
```

## Launch flags

Debug builds accept these launch arguments, which put the app into a
repeatable state for tests and screenshots. Release builds ignore them. They
are defined once in `Shared/LaunchFlag.swift`.

| Argument | Effect |
| --- | --- |
| `--qa-keep-awake` | Keeps the screen on. |
| `--qa-large-type` | Uses an accessibility text size. |
| `--qa-onboarding` / `--qa-skip-onboarding` | Shows or skips onboarding. |
| `--preview-hour=<0..<24>` | Draws the sky at that local hour. |
| `--preview-intro=<0...1>` | Holds the opening animation at one pose. |
| `--qa-intro-probe` | Measures frame pacing during the opening. |
| `--qa-silent-stream-once` | Silences heart rate once, for the recovery test. |

## Before you rely on it

Automated checks confirm that alarms are scheduled; they are not an audio
test. Before trusting FitheWake for a real morning, keep a second alarm and
check by hand:

- The final alarm sounds when the phone is locked, in Silent Mode and in a
  Focus, after a force quit and after a restart.
- Stop and Snooze work, including when an early alarm and the final alarm are
  close together.
- Heart rate keeps arriving overnight, and the app recovers after the wearable
  disconnects.

Testing & diagnostics in the app has a one-minute test alarm and a report you
can export. The report holds events and totals only: no raw heart rate, device
names or IDs.
