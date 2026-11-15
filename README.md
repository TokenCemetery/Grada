# Grada

Grada is an iPhone and iPad app that turns your Apple Health data into a daily summary: a home screen of health cards and a calendar that grades each day.

- **Data:** reads Apple Health only. Garmin, Suunto and other devices show up through their own Apple Health sync.
- **Privacy:** all calculations run on the device. App data stays on your devices.

## Build and run

Requires Xcode 27.2 or later. The app runs on iOS 17 or later.

1. Open `Grada.xcodeproj` and run the `Grada` scheme on an iPhone simulator.
2. Allow Apple Health access.
3. In **Settings › Simulator Data**, add 90 days of sample data. This screen appears only in Debug builds on the simulator.

Run the unit tests (use any iPhone simulator listed by `xcrun simctl list devices available`):

```bash
xcodebuild test -project Grada.xcodeproj -scheme Grada -destination "platform=iOS Simulator,name=iPhone 15" -only-testing:GradaTests CODE_SIGNING_ALLOWED=NO
```

## License

[Apache License 2.0](LICENSE)
