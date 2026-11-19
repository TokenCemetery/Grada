# App Store submission

Text to paste into App Store Connect for each Grada submission, and the answers it expects. Keep it in step with the app: if a feature or data flow changes, change this file in the same commit.

## App Review notes

> Grada reads Apple Health and needs no account or login.
>
> To see it with data on a test device: open the Health app, allow Grada to read all types when asked, and add a few days of steps, heart rate and sleep in Health › Browse (Add Data). Without Health data, cards say "No data yet" and what they need, calendar days show as "No data", and the journal still works.
>
> Settings › Import is optional:
> - FIT Files reads workout files the user picks in Files, on the device, with no network access.
> - Garmin Connect reads the user's own Garmin data with a Personal API key the user creates on their Garmin account. The key stays in the device's Keychain and is sent only to Garmin. Reviewers don't need it to use the app.
>
> Grada never writes to Apple Health and stores no health data in iCloud. It is not a medical device: Settings and every metric's detail screen say so, and the Illness journal suggestion says it isn't a diagnosis.
>
> Privacy policy: Settings › Privacy Policy.

## Description lines

Add these to the App Store description, alongside the feature text:

- Grada works with Apple Health: it reads your sleep, heart, activity and workout data, with your permission, and never writes to it.
- Garmin Connect import is optional and uses your own Garmin Personal API key. Grada isn't affiliated with or endorsed by Garmin or Apple.
- Grada isn't a medical device and doesn't diagnose, treat or prevent any condition. Talk to a doctor before making medical decisions.

Screenshots and the icon must not show Garmin logos or Apple's Health app icon.

## App Privacy (nutrition label)

- **Data collection:** Data Not Collected. The developer receives nothing: there are no accounts, analytics, advertising or third-party code. Health data stays on the device. Garmin requests go straight from the device to Garmin with the user's own key.
- **Tracking:** No. This matches `Grada/PrivacyInfo.xcprivacy`.

Review this when iCloud sync of app data turns on (#20). Data in the user's private iCloud database isn't collected by the developer, but check Apple's current label guidance at that point.

## Other answers

- **Privacy Policy URL:** https://github.com/TokenCemetery/Grada/blob/main/PRIVACY.md (the same URL as Settings › Privacy Policy).
- **Category:** Health & Fitness.
- **Age rating:** answer "Medical or Treatment Information" as Infrequent/Mild. The journal logs alcohol but doesn't encourage it.
- **Export compliance:** not asked. `ITSAppUsesNonExemptEncryption` is NO, because Grada uses only HTTPS.
- **Availability:** iPhone and iPad only. Mac and Vision Pro are off because Apple Health isn't there.
- **Languages:** the app is localized into English, Spanish, Simplified Chinese, Hindi, Portuguese, Russian, French, German and Italian. The listing text in this file is English; add translated listings in App Store Connect for the other languages, or they show the English one.

## Before submitting

- Bump `CURRENT_PROJECT_VERSION` for each upload.
