# Architecture

FitheWake has two parts: a Swift package with everything that can be tested on
a Mac, and a SwiftUI app that connects it to AlarmKit, CoreBluetooth and the
screen.

```
Sources/FitheWakeCore     alarm rules, the alarm lifecycle, the Smart Wake engine, heart-rate parsing
Sources/NightLab          synthetic nights and the engine evaluation
Sources/night-eval        prints the evaluation table
Tests/FitheWakeCoreTests  core tests (no device needed)
App/                      the iOS app, one folder per feature
Shared/                   files compiled into more than one target
Widgets/                  the alarm Live Activity
UITests/                  UI tests; hardware tests are opt-in
scripts/                  project generator and device build script
Config/                   signing settings
```

## Core (`Sources/FitheWakeCore`)

- **Models.swift.** `WakeOptions` (Smart Wake on or off, window, snooze,
  gentle sound), `WakeSchedule` (time, repeat days, options) and `WakePlan`
  (one armed morning). `HeartSample` holds one reading and decides whether it
  is fresh and usable.
- **AlarmLifecycle.swift.** Owns the saved session: the current morning, the
  later mornings already armed, and an optional early alarm. It talks to
  AlarmKit only through the `AlarmScheduling` protocol, so tests use a fake.
- **NightEngine.swift.** The Smart Wake engine, `hr-night-3.0`. It reads one
  night of heart rate and decides, inside the wake window, whether now is a
  good moment to ring early. The design and its sources are in
  [SMART_WAKE_RESEARCH.md](SMART_WAKE_RESEARCH.md).
- **HeartRateParser.swift** reads the standard Bluetooth Heart Rate
  Measurement (2A37). **HeartRateRecovery.swift** notices a connection that
  stays up but has stopped sending readings.

## The rules that keep the alarm safe

1. **The final alarm is a plain AlarmKit alarm.** It rings at the set time
   even if the app is closed, the wearable is gone or the engine never runs.
2. **Smart Wake only adds an alarm.** When the engine fires, the app arms a
   second AlarmKit alarm a few seconds ahead. It never moves or cancels the
   final alarm. After an early wake, the person can turn off that morning's
   final alarm themselves.
3. **Intent is saved before scheduling.** The session is written to disk
   before any AlarmKit call, so a crash can never leave an alarm the app
   doesn't know about. A replacement is checked with AlarmKit before the old
   alarms are removed.
4. **A missing alarm is never silently re-created.** It may have been turned
   off on purpose in the system UI.
5. **Each repeating morning is its own one-time alarm.** About a week of
   mornings stays armed, so each one rings without the app, and one morning can
   be skipped. AlarmKit's weekly repeat can't skip a single day.

## App (`App/`)

- **AppModel.swift** holds the app's alarm and Smart Wake state and is the
  only place that changes alarms. Views read it and call its intents (`setAlarm`, `skipNext`,
  …), each of which returns the problem, if any, for that view to show.
- **Alarm/**: `NativeAlarmScheduler` (the app's only AlarmKit calls, and the
  on-disk session store),
  `AlarmForm` (the alarm being edited, shared by the editor and onboarding),
  `AlarmEditor`.
- **Fitbit/**: `FitbitCentral` (Bluetooth connection with state restoration,
  which keeps the app running overnight; views call its start and pause
  directly) and the Fitbit tab.
- **Home/**, **Onboarding/**: the screens.
- **Design/**: the sky colors for the local hour (`Atmosphere`), shared
  components, and the Crown Glass rings.
- **Diagnostics/**: a local test report and a one-minute test alarm. The report
  stores events and totals, never raw heart rate, device names or IDs.

`Shared/WakeMetadata.swift` is compiled into the app and the widget, because
AlarmKit matches an alarm to its Live Activity by that type.
`Shared/LaunchFlag.swift` is compiled into the app and the UI tests, so both
spell the launch arguments the same way.

## The Xcode project

`FitheWake.xcodeproj` is generated. After adding, moving or removing a file, run:

```sh
python3 scripts/generate_project.py
```

It also writes both Info.plist files and the Dawn alarm sound.
