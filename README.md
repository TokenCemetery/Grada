# Grada

Grada is an iPhone and iPad app that turns your Apple Health data into a daily summary: a home screen of health cards and a calendar that grades each day.

- **Home:** cards for recovery, sleep, heart and vitals, activity and training. Add, remove and reorder them, and choose today or the last 7 days where both make sense.
- **Calendar:** colors each day by a metric, with a sheet for that day's details.
- **Detail screens:** each metric's trend and breakdown, what it means, and the inputs it's based on.
- **Goals and journal:** start from a goal preset that adjusts every week, and keep a daily journal of habits such as alcohol, caffeine, late meals or travel.

## Data

Grada reads Apple Health. Garmin, Suunto and other devices show up through their own Apple Health sync. Grada never writes to Apple Health.

For data a device's Apple Health sync leaves out, such as Garmin's overnight HRV, **Settings › Import › FIT Files** imports FIT files, or a folder of them such as an unzipped Garmin data export. Grada reads workouts, sleep stages, overnight HRV and resting heart rate from them, on the device, without network access. Data in Apple Health comes first; imported files fill the days it has nothing for. Importing the same files again changes nothing, and files Grada can't read are named.

**Settings › Import › Garmin Connect** reads Garmin data directly with a Personal API key the user creates on Garmin Connect: daily summaries (steps, distance, active calories, intensity minutes, resting heart rate, blood oxygen, respiration), sleep stages, overnight HRV and workouts, the whole history on connecting and new days at most every 15 minutes after that. The key stays in the iPhone's Keychain and goes only to Garmin; there is no server in between. As with files, Apple Health data comes first and Garmin fills what it lacks. When Garmin stops accepting the key, the screen asks for a new one and imported data stays.

Settings › Data Source lists each kind of data Grada reads and the apps and devices it came from, with the last day each sent data. Each metric's detail screen names the same under "Data from". When several apps record the same readings, Grada uses the app with the most days in the last month, and one app per night for sleep.

## Privacy

All calculations run on the device. Grada has no accounts, analytics or advertising, and it sends your data to no one. Its only network calls are to Garmin, if you connect Garmin. App data such as your home layout, goals and journal stays on your devices; syncing it through your private iCloud is ready but switched off until [#20](https://github.com/TokenCemetery/Grada/issues/20). See the [privacy policy](PRIVACY.md).

## Scientific basis

Every calculated metric rests on published research, not invented formulas. Each detail screen lists its sources with links, and marks as "Grada's estimate" anything no study has set. Examples:

- **Recovery and HRV:** your overnight HRV against your own baseline, the method from HRV-guided training studies.
- **Sleep Score:** the National Sleep Foundation's sleep quality consensus.
- **Strain:** Edwards' training load and the acute:chronic workload ratio.
- **Health Age:** published mortality risks for VO₂ max, resting heart rate, steps, sleep and exercise.

Resources (an all-day energy estimate) has no published method behind it and says so.

## Build and run

Requires Xcode 27.2 or later. The app runs on iOS 17 or later.

1. Open `Grada.xcodeproj` and run the `Grada` scheme on an iPhone simulator.
2. Allow Apple Health access.
3. In **Settings › Simulator Data**, add 90 days of sample data. This screen appears only in Debug builds on the simulator.

To skip Apple Health entirely, add the `-SampleData` launch argument to the scheme (Debug builds only). The app then uses built-in sample data.

Run the unit tests (use any iPhone simulator listed by `xcrun simctl list devices available`):

```bash
xcodebuild test -project Grada.xcodeproj -scheme Grada -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:GradaTests CODE_SIGNING_ALLOWED=NO
```

## Release plan

Each version is a [GitHub milestone](https://github.com/TokenCemetery/Grada/milestones).

| Version | Theme | Scope | Status |
|---|---|---|---|
| v1 | Foundation | Apple Health import, iCloud sync, home cards, calendar, metric detail | Built; iCloud sync waits on a paid developer team ([#20](https://github.com/TokenCemetery/Grada/issues/20)) |
| v2 | Personal | Goals, journal, intensity minutes, HRV status, Health Age | Built |
| v3 | Guidance | Morning and evening reports, recommendations, monthly summary | Planned |
| v4 | Scores | Sleep score, training readiness, strain and training load, recovery time | Built |
| v5 | Energy | Resources energy card | Built; a stress card was declined because there's no published way to measure stress from iPhone data |

## License

[Apache License 2.0](LICENSE)
