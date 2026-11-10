# Contributing

Thanks for helping. Start with [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
then:

1. **Never weaken the final alarm.** Smart Wake may add an earlier alarm; it
   must not move, cancel or depend on the final one. The rules are in
   [ARCHITECTURE.md](docs/ARCHITECTURE.md#the-rules-that-keep-the-alarm-safe).
2. **Run the core tests** before a pull request:
   `swift test -c release -Xswiftc -enable-testing`.
3. **Engine changes** need the evaluation: run `swift run -c release night-eval`,
   update the table in [SMART_WAKE_RESEARCH.md](docs/SMART_WAKE_RESEARCH.md) and
   explain the change in numbers.
4. **Adding or moving files**: run `python3 scripts/generate_project.py` and
   commit the regenerated project.
5. **No personal data in commits**: your team ID and bundle prefix go in
   `Config/Local.xcconfig`, which git ignores. Don't commit test reports,
   device IDs or screenshots with personal details.

[docs/TESTING.md](docs/TESTING.md) covers device builds, UI tests and the
opt-in hardware tests.
