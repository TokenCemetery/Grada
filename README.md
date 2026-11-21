# Grada

**Your Health data as daily cards and a calendar that grades each day.**

![Grada's Home, Calendar and Journal on iPhone](docs/screenshots/social-preview.png)

Grada runs on iPhone and iPad and reads Apple Health.

- **Home:** starts with the cards for Health, Recovery or Training, picked on first launch; then add, remove and reorder cards for recovery, sleep, heart and vitals, activity, training and body, showing today or the last 7 days where both apply.
- **Calendar:** colors days by Health or Recovery, marks Training days by sport, or shows your Cycle, with a sheet per day.
- **Widgets:** any single-value card, such as Recovery or Training Readiness, on the Home Screen (small, medium) or Lock Screen (circular, rectangular); pick it via touch and hold › Edit Widget. It matches the Home card's value and color, updates after each Apple Health import, and clears at midnight until the next. The widget reads only the finished cards the app writes to an on-device App Group file (`Shared/WidgetCards.swift`).
- **Detail screens:** each metric's trend, breakdown, meaning and inputs. Some add today's advice and why: steps left to the goal as walking minutes (or congratulations once reached), a bedtime for your usual wake-up, or easing off when resting heart rate, HRV or training load is out of range.
- **Goals and journal:** goal presets that adjust weekly, and a daily journal of habits such as alcohol, caffeine, naps or travel.
- **Cycle:** for Female users, Calendar shows period days logged to Apple Health (Cycle Tracking, Clue, Flo…), the cycle day and sleeping wrist temperature. After 3 cycles it predicts the next period as a range. Ovulation is marked only from a positive LH test or a sustained temperature rise (three-over-six rule), never ahead. No fertile window; not for birth control or pregnancy planning. Grada only reads this data and never stores it.
- **Reports:** each Journal day opens with a morning report and an evening one, plus recommendations. The morning report plans the day: how yesterday's advice went, today's focus and a training suggestion (rest, easy, moderate or hard, from readiness, recovery, load and the weekly goals). The evening report checks in on that focus, says what drained and restored Resources, what the week still needs, and tonight's bedtime. Follow-ups are judged only from health data, in a friendly voice with no scores or streaks. Both keep their sleep, Recovery and Training Readiness or activity and training cards. **Settings › Profile › Sleep Schedule** can send both as notifications, plus an afternoon check-in that comes only when a goal is behind but still reachable. Journal also has a month summary, how alcohol and caffeine affect the next night, and tags suggested from health data.

Grada follows the iPhone's language: English, Spanish, Simplified Chinese, Hindi, Portuguese, Russian, French, German or Italian. Strings live in `Grada/Localizable.xcstrings`, Health permission text in `Grada/InfoPlist.xcstrings`. SwiftUI literals like `Text("Steps")` are picked up automatically; model-code `String`s use `String(localized:)`, with plural variants where counts change wording.

## Data

Grada reads Apple Health, never writes to it, and sees Garmin, Suunto and other devices through their own Health sync.

**Settings › Import › FIT Files** imports FIT files or folders (e.g. an unzipped Garmin export) for data a sync leaves out, such as Garmin's overnight HRV: workouts, sleep stages, overnight HRV and resting heart rate, read offline on the device. Files fill only days Apple Health lacks; re-importing changes nothing, and unreadable files are named.

**Settings › Import › Garmin Connect** fetches daily summaries, sleep, overnight HRV and workouts with a Personal API key from Garmin Connect, every 15 minutes at most. The key stays in the Keychain and goes only to Garmin. Apple Health data still comes first.

Settings › Data Source lists each data type with its source apps and devices and the last day each sent data; detail screens name them under "Data from". When several apps record the same readings, Grada picks the one with the most days last month (for sleep, one app per night).

## Privacy

All calculations run on the device. Grada has no accounts, analytics or advertising, and it sends your data to no one. Its only network calls are to Garmin, if you connect Garmin. Health data stays on the device and never goes to iCloud, as App Review requires. App data such as your home layout, goals and journal is kept in a separate store that can sync through your private iCloud; that sync is ready but switched off until [#20](https://github.com/TokenCemetery/Grada/issues/20). See the [privacy policy](PRIVACY.md), also linked from Settings. Grada isn't a medical device: Settings and every detail screen say so, and the Illness suggestion says it isn't a diagnosis.

## Scientific basis

Every calculated metric rests on published research, not invented formulas. Each detail screen lists its sources with links, and marks as "Grada's estimate" anything no study has set. Examples:

- **Recovery and HRV:** your overnight HRV against your own baseline, the method from HRV-guided training studies.
- **Sleep Score:** the National Sleep Foundation's sleep quality consensus.
- **Strain:** Edwards' training load and the acute:chronic workload ratio. The detail screen also charts Foster's training monotony and strain over 7 days of load, calls out weeks with monotony above 2, and then suggests mixing hard and easy days. On iOS 18 and later, workouts rated for effort in Apple Health (or estimated by Apple Watch) show the rating and their session-RPE load (rating × minutes, Foster et al. 2001), and the Strain detail screen compares the effort load of workouts you rated with their heart rate load.
- **Health Age:** published mortality risks for VO₂ max, resting heart rate, steps, sleep and exercise.
- **Weight:** the latest weight with its body mass index (BMI) and WHO adult class, and the 30-day trend, in kilograms or pounds; the detail screen adds body fat, lean body mass and BMI over time, and says BMI doesn't tell fat from muscle.
- **Blood Pressure:** the latest day's cuff reading saved to Apple Health (averaged when there were several) and the average of the last 30 days' readings, coloured by the 2017 ACC/AHA categories (a reading over a week old shows uncoloured); the detail screen trends systolic and diastolic and lists each day's reading. Grada estimates nothing and says it isn't a medical device.
- **Mobility:** iPhone's walking speed averaged over the last 7 days, with Apple's Walking Steadiness class (OK, Low, Very Low) labelled as Apple's; from age 65 the average is coloured by Studenski et al.'s survival bands (1.0, 0.8 and 0.6 m/s) as a fitness marker, not a diagnosis. The detail screen trends speed, Walking Steadiness, step length and asymmetry.
- **Heart Rate Recovery:** how far heart rate falls in the minute after a workout, from Apple Watch's own measurement or the heart rate around the workout's end, shown on the workout screen and as a card with a 90-day trend. A fall of 12 bpm or less is marked, Cole et al.'s cut-off, as a fitness marker rather than a diagnosis.

Resources (an all-day energy estimate) has no published method behind it and says so.

## Build and run

Requires Xcode 27.2 or later. The app runs on iOS 17 or later.

1. Open `Grada.xcodeproj` and run the `Grada` scheme on an iPhone simulator.
2. Allow Apple Health access.
3. In **Settings › Simulator Data**, add 90 days of sample data. This screen appears only in Debug builds on the simulator.

To skip Apple Health entirely, add the `-SampleData` launch argument to the scheme (Debug builds only). The app then uses built-in sample data.

Run the unit tests (use any iPhone simulator listed by `xcrun simctl list devices available`). The tests check English text, so the shared `Grada` scheme runs them in English whatever the simulator's language. This applies to ⌘U in Xcode too. The command also pins the region, so the results match CI:

```bash
xcodebuild test -project Grada.xcodeproj -scheme Grada -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:GradaTests -testLanguage en -testRegion US CODE_SIGNING_ALLOWED=NO
```

## Roadmap

[docs/ROADMAP.md](docs/ROADMAP.md) lists what each release shipped and what was declined.

## License

[Apache License 2.0](LICENSE)
