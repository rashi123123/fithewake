# Smart Wake research and the hr-night-3.0 engine

Research date: 10 November 2026. This document explains how the official
Fitbit Smart Wake is documented to behave, what sleep science says about
heart-rate-only wake timing, and how FitheWake's engine was designed from it.

**Honest scope.** The official algorithm is not public. FitheWake receives far
less data than a Fitbit's own firmware. The engine's test results come from
synthetic, literature-shaped nights. They prove that the safety rules behave as
designed. They do not prove accuracy on a real sleeper. That needs nights
recorded against EEG or PSG.

## 1. What Fitbit documents about Smart Wake

| Fact | Status | Source |
|---|---|---|
| The window opens 30 minutes before the alarm time | Documented | Google Health help [1] |
| It "avoids waking you during deep sleep" | Documented | [1] |
| If it can't find a good moment, the alarm rings at the set time | Documented | [1] |
| It can only ring early, never late | Third-party | Community and reviews [6] |
| At launch (2019) it targeted light **or REM** sleep | Documented | Google blog [2] |
| On Fitbit Air it uses "sleep movement and heart rate" | Documented | Google Store [7] |
| Features, thresholds, epoch length, model | **Not public** | No document or patent found [24] |
| The decision runs on the wearable, not the phone | Inferred | A moderator said Bluetooth doesn't affect it [5] |

**The sleep stages shown in the app cannot drive Smart Wake.** Fitbit computes
stages in the cloud after you sync in the morning [20][21]. Its staging paper
is explicitly retrospective and uses features that look into the future [13].
Smart Wake therefore has to use a separate, lightweight, real-time model on the
device.

**FitheWake gets much less data.** The Fitbit Air's heart-rate sharing
broadcasts about one bpm value per second. Reverse-engineering saw no RR
intervals and no contact field [31][32]. FitheWake has no accelerometer. In
Fitbit's own study, staging from heart-rate features alone reached only
kappa 0.25–0.3 [13].

## 2. What the science says (heart rate only)

- **Deep sleep (N3) is not a low-heart-rate state.** Mean heart rate in N3 is
  about the same as in N2 (51.5 vs 51.6 bpm in Herzig 2018). What marks N3 is
  **stability**: low slow variability (LF power half of N2's, low SDNN). REM
  runs about 2 bpm higher with roughly double the variability.
  Sources: Herzig 2018, doi:10.3389/fphys.2017.01100; Boudreau 2013,
  doi:10.5665/sleep.3230; Trinder 2001, doi:10.1046/j.1365-2869.2001.00263.x.
- **Stability is the best heart-rate-only deep-sleep marker.**
  - Long 2017 (doi:10.1109/JBHI.2015.2487446) and Yoon 2018
    (doi:10.1109/JBHI.2017.2712861) reached kappa of about 0.56–0.57 for deep
    vs not-deep.
  - Consumer wearables label 22–48% of N3 as "light" (Schyvens 2025). That is
    the dangerous direction for an alarm.
- **Arousals and awakenings are the clearest events.**
  - Arousals: +6–14 bpm for 10–15 s, then a dip (Nalivaiko 2007,
    doi:10.1152/ajpregu.00642.2006).
  - Awakenings: +25–35 bpm, sustained for more than a minute (Griefahn 2008,
    doi:10.1093/sleep/31.4.569).
- **The heart changes before the brain.** Cardiac changes lead EEG changes by
  about 5–12 minutes (Brandenberger 2001, Jurysta 2003). So a moment that just
  looked deep is not safe yet, even if it now looks lighter.
- **Changes towards lighter sleep are the easy ones to see.** Heart rate rises
  abruptly on deep-to-light transitions, while the way into deep sleep is
  gradual (Staudacher 2005, Viola 2002).
- **The benefit is modest, so the fallback matters.**
  - Grogginess after waking from N3 is worse mainly in the first ~10 minutes.
  - The one controlled smart-alarm trial found no main effect, and no RCT
    shows a benefit.
  - REM is not clearly better than N3 to wake from (Stephan 2025, a single
    study, doi:10.1016/j.cub.2025.06.064).
  - Most of the protection comes from N3 being rare in the last hour of a
    normal night.

## 3. What competing apps do, and what users complain about

- **Window and fallback:** every major smart alarm uses a 10–45 minute window
  and always falls back to the set time (Sleep Cycle, Pillow, Rise, Apple
  Watch apps).
- **Window shown as a range:** Sleep Cycle presents the window as "between
  7:15 and 7:45".
- **Top complaints:**
  - It rings at the very start of the window.
  - It always rings at the end of the window (Sleep Cycle has a support
    article about this).
  - It rings while you are already awake.
- **Nightly re-setting comes from limits, not choice:**
  - Sleep Cycle tracks with the phone, so you press Start each night.
  - Apple Watch smart alarms are scheduled one session at a time.

## 4. The hr-night-3.0 engine (`Sources/FitheWakeCore/NightEngine.swift`)

The design goal is to never wake you in deep sleep, find lighter sleep when it
is clearly there, and otherwise ring at your time.

- **Learns your night.**
  - Needs 2 hours of sleep data before it will act, so its reference is your
    sleep, not your evening.
  - The reference is the last 4 hours: your typical level and spread
    (median, MAD), and the full spread of your stability values.
- **Stability per 30-second epoch:** the SD of detrended 5-second block means
  over the last 5 minutes. This is a 1 Hz stand-in for LF power and SDNN.
- **Deep-sleep veto:**
  - An epoch looks deep when its stability is in your steadiest 30% (or 15%)
    and the level is not clearly awake.
  - After anything deep-like there is a **10-minute lockout**, because the
    heart leads the brain.
  - The level veto is loose on purpose. N3 runs at the N2 rate, and the
    morning circadian rise lifts both. Erring towards "deep" only delays a
    wake.
- **Ways it may ring early, all inside your window:**
  1. **Awake already:** +15 bpm sustained for a minute, every value raised.
     This bypasses the lockout, because you are already up.
  2. **Arousal:** a brief surge well beyond the moment's own variability. The
     bar is stricter in the first half of the window.
  3. **Ascending step:** the last 3 minutes are clearly above the 10 before,
     at middle stability. The top 15% "REM-like" variability is excluded.
  4. **Quiet light sleep:** 3 of the last 4 epochs at middle stability, only
     in the second half of the window.
- **Refuses to guess:**
  - A flat or saturated stream is reported as "unstable", and the alarm rings
    at your time.
  - Invalid or stale samples block decisions.
  - A Bluetooth gap needs 10 fresh minutes before any decision. The night's
    history survives short gaps; a gap over 2 hours starts a new night.
- **One early attempt per morning.** The final alarm is never cancelled by
  the engine.

### Synthetic evaluation (release build, 100 nights per row)

The nights are generated by `NightSimulation.swift`, with stage effects taken
from the papers above:

- N3 at the N2 rate but steadier.
- REM +2 bpm and twice as variable.
- Arousal surges, a circadian drift, and optional Fitbit-like smoothing.
- Weaker stage separation, to stress the engine.

| Scenario | Rang early | In N3 | Within 3 min after N3 | Outside window |
|---|---|---|---|---|
| hr-trend-2.0 (old), morning | 52 / 100 | — | — | — |
| hr-trend-2.0 (old), alarm 3 h into the night | 7 / 100 | — | — | — |
| hr-night-3.0, morning, raw / smoothed | 100 / 100 | 0 | 0 | 0 |
| hr-night-3.0, 3 h in, raw / smoothed | 99 / 100 | 0 | 0 | 0 |
| hr-night-3.0, 3 h in, stage separation ×0.5 | 93 / 100 | 0 | 0 | 0 |
| hr-night-3.0, 3 h in, stage separation ×0.25 | 84 / 100 | 0 | 0 | 0 |
| hr-night-3.0, 3 h in, no arousals | 95 / 100 | 0 | 0 | 0 |

- **Morning:** wakes mostly land in REM, because the synthetic morning is
  mostly REM, which matches real late-night sleep. They come 18–22 minutes
  before the final alarm on average.
- **3 hours in:** about half of wakes land in N1/N2 and half in REM.
- **Reproduce:**

  ```sh
  swift test -c release -Xswiftc -enable-testing --filter EngineEvaluationTests
  ```

## 5. What would actually validate it

1. **Log your own Air's flags byte** to confirm whether RR intervals or
   contact are ever present.
2. **Record a few nights** with FitheWake running next to a validated sleep
   stager (for example an EEG headband). Compare the engine's decisions with
   the scored stages.
3. **Add a morning feeling rating (1–5).** Track whether early wakes feel
   better than final-alarm wakes. The literature says the effect is small, so
   this needs many mornings.

## Sources

Fitbit and Google: [1] support.google.com/googlehealth/answer/14226604 ·
[2] blog.google (Fitbit OS update, 2019) · [5][6] community.fitbit.com Smart
Wake threads · [7] store.google.com/magazine/google-fitbit-air ·
[13] Beattie 2017, doi:10.1088/1361-6579/aa9047 ·
[20] support.google.com/googlehealth/answer/14236712 · [21] blog.google health
AI sleep · [24] patentforecast.com 2020 smart-alarm landscape ·
[31] pub.dev/packages/fitbit_air · [32] github.com/ThoreKoritzius/fitbit-air.

Physiology: Herzig 2018; Boudreau 2013; Trinder 2001; Long 2017; Yoon 2018;
Schyvens 2025 (doi:10.1093/sleepadvances/zpaf021); Nalivaiko 2007;
Griefahn 2008; Brandenberger 2001 (doi:10.1016/s1388-2457(01)00507-7);
Jurysta 2003 (doi:10.1016/s1388-2457(03)00215-3); Staudacher 2005;
Viola 2002 (doi:10.1177/0748730402238236); Stephan 2025
(doi:10.1016/j.cub.2025.06.064).
