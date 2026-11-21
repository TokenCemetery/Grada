# Grada Privacy Policy

Effective November 17, 2026

Grada is an iPhone app that summarizes your health data from Apple Health. This policy explains what data Grada uses, where it is kept, and the control you have over it.

## Summary

- Grada reads health data from Apple Health only with your permission, from FIT files only when you choose them, and from Garmin Connect only if you connect it with your own key.
- Your health data stays on your device. App data such as your card layout, goals and journal can sync through your own private iCloud account. The developer never receives any of it.
- Grada has no accounts, no analytics, no advertising and no third-party code, and it does not send your health data over the network to anyone. Its only network calls are to Garmin, if you connect Garmin.
- Grada never writes to, changes or deletes your Apple Health data.

## Data Grada reads

When you grant access, Grada reads these types from Apple Health:

- Heart: heart rate, resting heart rate, heart rate variability and heart rate recovery after workouts.
- Breathing and body: blood oxygen, respiratory rate, wrist temperature during sleep, and VO2 max.
- Activity: steps, active energy, exercise minutes, walking and running distance, flights climbed, and stand hours.
- Sleep: sleep sessions and sleep stages.
- Mindfulness and daylight: mindful sessions and time in daylight, read on your device only to suggest the Meditation and Outdoor time journal tags. Grada doesn't store them.
- Drinks and caffeine: the number of alcoholic drinks and the caffeine logged in Apple Health, read on your device only to suggest the Alcohol and Caffeine journal tags. Grada doesn't store them.
- Workouts: type, time, duration, energy, heart rate, distance (walking, running, cycling and swimming), elevation gain, and the GPS route if the workout recorded one. The route is read only to draw the workout's map on your device; Grada doesn't store or sync it.
- Date of birth and biological sex, for scores that depend on age or sex, such as health age and VO2 max fitness zones.

You choose which types to share in the iOS permission screen. Grada works with whatever you allow and shows no data for the rest.

Data from other apps and devices, such as Garmin or Oura, reaches Grada through Apple Health, under the same permissions, from FIT files you import, or directly from Garmin Connect if you connect it.

## Files you import

In Settings › Import › FIT Files you can choose FIT files, the format Garmin and other watches record in, or a folder of them such as a Garmin data export. Grada reads only the files you choose, on your device, and reads workouts, sleep stages, overnight heart rate variability and resting heart rate from them. It keeps what it read with the rest of its copy, described below, labelled with the device's brand, such as "Garmin (imported)". It also keeps each night's sleep stage timeline, when each stage started and ended, in a file in the app's storage on this device; that file isn't synced between your devices. It doesn't keep the files or send them anywhere.

## Garmin Connect

In Settings › Import › Garmin Connect you can paste a Personal API key you create on Garmin Connect. Grada keeps the key in this iPhone's Keychain only: it isn't synced to iCloud Keychain or restored to another device. Grada sends the key only to Garmin (`personal.connectapi.garmin.com`), directly from your iPhone, to get a short-lived access token, and uses that token to read your own Garmin data: daily summaries (steps, distance, active calories, intensity minutes, resting heart rate, blood oxygen, respiration), sleep stages and times, overnight heart rate variability, workouts, and heart rate through the day. The requests carry only the dates asked for. Grada sends Garmin none of your Apple Health data. What it reads joins the rest of its copy, described below, labelled "Garmin Connect (direct)", except heart rate through the day, which Grada keeps in memory only while it's open. Garmin handles the requests under the [Garmin Privacy Policy](https://www.garmin.com/privacy/connect/).

Disconnecting in the same screen deletes the key from your iPhone; data already read stays in Grada's copy until you delete the app. You can also delete the key on Garmin Connect, which stops Grada's access at once.

## How Grada uses it

Grada uses the data only to show you daily summaries, scores, calendars and trends inside the app. It does not use your data for advertising, marketing, profiling or research. It does not sell, rent or share it.

## Where your data is stored

Grada keeps a copy of daily summaries and workouts in the app's storage on your device, and your card layout, goals, journal and display settings beside it. If you enter a birth date or sex in Settings › Profile, for when Apple Health can't provide them, Grada keeps them in the app's settings on this device. With each day and workout it keeps the names Apple Health gives the apps and devices the data came from, such as "Oura" or "Apple Watch", to show you where your data came from.

For its Home Screen and Lock Screen widgets, Grada also keeps the latest card values, such as your Recovery score or step count, in a file shared only between Grada and its widgets on this device. The file is replaced after each import and isn't synced.

Grada never stores health data in iCloud: daily summaries and workouts stay on the device that imported them. Your card layout, goals and journal can sync between your devices through your private iCloud database. Data in that database belongs to your Apple Account, and only you can access it. The developer cannot read it. Apple stores it under the [Apple Privacy Policy](https://www.apple.com/legal/privacy/).

Grada stores no data on any server run by the developer.

## Your choices

- **Change or revoke access:** open Settings › Privacy & Security › Health › Grada. Grada stops reading any type you turn off.
- **Delete Grada's copy on a device:** delete the app.
- **Delete Grada's iCloud data** (card layout, goals and journal): open Settings › [your name] › iCloud › Manage Storage (on some iOS versions, Manage Account Storage) and delete Grada's data.

Removing Grada never removes anything from Apple Health.

## Crash reports and TestFlight

Grada has no crash reporting of its own. If you turn on sharing with app developers in Settings › Privacy & Security › Analytics & Improvements, Apple may send the developer anonymous crash reports. If you test Grada through TestFlight, Apple shares the feedback, screenshots and crash reports you send, along with your device details. These are covered by Apple's privacy terms.

## Children

Grada is not directed at children under 13 and does not knowingly collect data from them.

## Changes to this policy

Changes to this policy are published in this file, with a new effective date. The file's history on GitHub lists every earlier version.

## Contact

For questions about this policy, open an issue at <https://github.com/TokenCemetery/Grada/issues>.
