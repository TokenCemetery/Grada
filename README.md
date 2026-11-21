# Grada

Grada is an iPhone and iPad app that turns your Apple Health data into a daily summary: a home screen of health cards and a calendar that grades each day.

- **Home:** cards for recovery, sleep, heart and vitals, activity, training and body. Add, remove and reorder them, and choose today or the last 7 days where both make sense.
- **Calendar:** colors each day by a metric, with a sheet for that day's details.
- **Widgets:** any single-value card, such as Recovery, Sleep Score, Resources or Training Readiness, on the Home Screen (small, medium) or Lock Screen (circular, rectangular). Touch and hold a widget, then Edit Widget to pick the card. A widget shows the same value and color as the card on Home, updates after each Apple Health import, and clears at midnight until the next one. The app writes the finished cards to a file in an App Group container on the device (`Shared/WidgetCards.swift`), and the widget reads only that file.
- **Detail screens:** each metric's trend and breakdown, what it means, and the inputs it's based on. Some show today's recommendation with its reason: steps left to the goal as minutes of walking (or a congratulation once it's reached), a bedtime for your usual wake-up, or easing off when resting heart rate, HRV or training load is out of range.
- **Goals and journal:** start from a goal preset that adjusts every week, and keep a daily journal of habits such as alcohol, caffeine, naps or travel.
- **Cycle:** with Female as your sex in Apple Health (or, without one there, in Settings › Profile), Calendar gets a Cycle type: period days logged in Apple Health by Cycle Tracking, Clue, Flo or another app, the cycle day under each date, and each month's sleeping wrist temperature. A day's sheet shows its flow, cycle day and the app that logged it, and Journal shows the cycle day. A cycle starts on a day the logging app marks as a start, or on a period day after a week without one. Grada only reads this data, never stores or predicts anything, and nothing is logged in Grada.
- **Reports:** each day in Journal opens with two reports, side by side on iPad. The morning report has last night's sleep, Recovery, Health Status and Training Readiness. The evening report has the day's steps, active energy, intensity minutes, training and strain against your goals. Below them, Recommendations collects both reports' advice, including tonight's bedtime. **Settings › Profile › Sleep Schedule** sets your bedtime and wake-up (your usual ones from the last 14 nights, or your own) and can send each report as a notification: the morning one once last night's sleep is recorded, never before your wake-up, and the evening one a chosen time before bedtime. The month summary button in Journal's toolbar shows the month's average steps, exercise, resting heart rate, overnight HRV, sleep and VO₂ max, and how each changed from the month before; a change counts only when it's bigger than a fifth of how much your days vary, and a month needs 14 days with data (2 VO₂ max readings). Under Alcohol and Caffeine, Journal shows how the night after changes compared with other nights in the last 90 days: HRV, sleeping heart rate, sleep and REM for alcohol; sleep, deep sleep and awake time for caffeine. Nights after Illness or Night shift are left out, each side needs 5 nights, and a change shows only when it's clearly bigger than how much your nights vary. Journal also suggests tags from your health data, kept only when you tap them: Illness when at least two of HRV, resting heart rate, breathing and wrist temperature are outside your normal range (breathing or temperature after a day with alcohol), Nap from daytime sleep of 10 minutes or more, Meditation from 5 minutes of mindful sessions, Outdoor time from 30 minutes in daylight, Alcohol with the number of drinks logged in Apple Health, and Caffeine from the caffeine logged there, as cups of brewed coffee at 95 mg each (USDA FoodData Central).

Grada speaks English, Spanish, Simplified Chinese, Hindi, Portuguese, Russian, French, German and Italian, following the iPhone's language. The text lives in `Grada/Localizable.xcstrings`, and the Apple Health permission text in `Grada/InfoPlist.xcstrings`. SwiftUI literals such as `Text("Steps")` are picked up automatically; text built as a `String` in model code goes through `String(localized:)`, with plural variants in the catalog wherever a count changes the wording.

## Data

Grada reads Apple Health. Garmin, Suunto and other devices show up through their own Apple Health sync. Grada never writes to Apple Health.

For data a device's Apple Health sync leaves out, such as Garmin's overnight HRV, **Settings › Import › FIT Files** imports FIT files, or a folder of them such as an unzipped Garmin data export. Grada reads workouts, sleep stages, overnight HRV and resting heart rate from them, on the device, without network access, and keeps each night's stage timeline on the device for Sleep Score. Data in Apple Health comes first; imported files fill the days it has nothing for. Importing the same files again changes nothing, and files Grada can't read are named.

**Settings › Import › Garmin Connect** reads Garmin data directly with a Personal API key the user creates on Garmin Connect: daily summaries (steps, distance, active calories, intensity minutes, resting heart rate, blood oxygen, respiration), sleep stages, overnight HRV and workouts, the whole history on connecting and new days at most every 15 minutes after that. Without heart rate in Apple Health, Resources and Strain read Garmin's heart rate through the day, kept in memory only. The key stays in the iPhone's Keychain and goes only to Garmin; there is no server in between. As with files, Apple Health data comes first and Garmin fills what it lacks. When Garmin stops accepting the key, the screen asks for a new one and imported data stays.

Settings › Data Source lists each kind of data Grada reads and the apps and devices it came from, with the last day each sent data. Each metric's detail screen names the same under "Data from". When several apps record the same readings, Grada uses the app with the most days in the last month, and one app per night for sleep.

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

Run the unit tests (use any iPhone simulator listed by `xcrun simctl list devices available`). The tests check English text, so the command pins the language whatever the simulator is set to:

```bash
xcodebuild test -project Grada.xcodeproj -scheme Grada -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:GradaTests -testLanguage en -testRegion US CODE_SIGNING_ALLOWED=NO
```

## Release plan

Each version is a [GitHub milestone](https://github.com/TokenCemetery/Grada/milestones).

| Version | Theme | Scope | Status |
|---|---|---|---|
| v1 | Foundation | Apple Health import, iCloud sync, home cards, calendar, metric detail | Built; iCloud sync waits on a paid developer team ([#20](https://github.com/TokenCemetery/Grada/issues/20)) |
| v2 | Personal | Goals, journal, intensity minutes, HRV status, Health Age | Built |
| v3 | Guidance | Morning and evening reports, recommendations, monthly summary | Built |
| v4 | Scores | Sleep score, training readiness, strain and training load, recovery time | Built |
| v5 | Energy | Resources energy card | Built; a stress card was declined because there's no published way to measure stress from iPhone data |

## License

[Apache License 2.0](LICENSE)
