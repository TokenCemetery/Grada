# Roadmap

What Grada has shipped, release by release, from its [Git tags](https://github.com/TokenCemetery/Grada/tags) and closed issues. Planned work lives in [open issues](https://github.com/TokenCemetery/Grada/issues).

## Themes

Each theme is a [GitHub milestone](https://github.com/TokenCemetery/Grada/milestones).

| Version | Theme | Scope | Shipped in | Notes |
|---|---|---|---|---|
| v1 | Foundation | Apple Health import, iCloud sync, home cards, calendar, metric detail | 0.1.0 | iCloud sync covers only app data (home layout, goals, journal), since Apple doesn't allow health data in iCloud; it's built but off and low priority ([#20](https://github.com/TokenCemetery/Grada/issues/20)) |
| v2 | Personal | Goals, journal, intensity minutes, HRV status, Health Age | 0.2.0 | |
| v3 | Guidance | Morning and evening reports, recommendations, monthly summary | 0.5.0 | |
| v4 | Scores | Sleep score, training readiness, strain and training load, recovery time | 0.4.0 | |
| v5 | Energy | Resources energy card | 0.1.0 | A stress card was declined ([#34](https://github.com/TokenCemetery/Grada/issues/34)) |

## Releases

### 0.6.0 (2026-11-21)

- Home Screen and Lock Screen widgets for any single-value card ([#129](https://github.com/TokenCemetery/Grada/issues/129))
- Nine languages: English, Spanish, Simplified Chinese, Hindi, Portuguese, Russian, French, German, Italian ([#139](https://github.com/TokenCemetery/Grada/issues/139))
- Weight and body composition ([#132](https://github.com/TokenCemetery/Grada/issues/132)), Blood Pressure ([#135](https://github.com/TokenCemetery/Grada/issues/135)), Mobility ([#136](https://github.com/TokenCemetery/Grada/issues/136)) and Heart Rate Recovery ([#131](https://github.com/TokenCemetery/Grada/issues/131)) cards
- Training monotony and strain ([#133](https://github.com/TokenCemetery/Grada/issues/133)); workout effort ratings and session-RPE load ([#134](https://github.com/TokenCemetery/Grada/issues/134))
- Menstrual cycle on the Calendar ([#137](https://github.com/TokenCemetery/Grada/issues/137)), with next-period prediction and ovulation from evidence ([#138](https://github.com/TokenCemetery/Grada/issues/138))
- Journal suggests Alcohol and Caffeine from drinks and caffeine in Apple Health ([#130](https://github.com/TokenCemetery/Grada/issues/130))
- One Appearance screen for light/dark and the color-blind palette ([#180](https://github.com/TokenCemetery/Grada/issues/180))

Fixes:

- Health import: history after access was first denied, days missed while closed, overwritten recent days, repeated workouts, data loss on a failed first save, travel across time zones ([#141](https://github.com/TokenCemetery/Grada/issues/141)–[#147](https://github.com/TokenCemetery/Grada/issues/147))
- Garmin and FIT: one endpoint's 403 disconnecting everything, a failed key change deleting the key, endless paging, trailing bytes, paused time, hidden macOS files ([#149](https://github.com/TokenCemetery/Grada/issues/149)–[#151](https://github.com/TokenCemetery/Grada/issues/151), [#153](https://github.com/TokenCemetery/Grada/issues/153)–[#155](https://github.com/TokenCemetery/Grada/issues/155)); a crafted FIT file expanding far beyond its size ([#152](https://github.com/TokenCemetery/Grada/issues/152), security)
- Goals, Journal and reports: daylight-saving times, weeks with missing data, catch-up, duplicate adjustments, midnight rollover, noisy tag effects, today's partial day in the month summary, recommendation order ([#156](https://github.com/TokenCemetery/Grada/issues/156)–[#163](https://github.com/TokenCemetery/Grada/issues/163), [#181](https://github.com/TokenCemetery/Grada/issues/181))
- Charts, cards and Calendar: weekday placement, gauge rounding, Customize reloads and empty rows, stale snapshots, made-up birth dates, Calendar heart rate and type switching, intensity minutes, Health Age wear days, Health Status spinner ([#164](https://github.com/TokenCemetery/Grada/issues/164)–[#173](https://github.com/TokenCemetery/Grada/issues/173), [#178](https://github.com/TokenCemetery/Grada/issues/178))
- Apple Health permission timing out on iPad ([#177](https://github.com/TokenCemetery/Grada/issues/177)), translations ([#140](https://github.com/TokenCemetery/Grada/issues/140), [#179](https://github.com/TokenCemetery/Grada/issues/179)), metric explanations and docs ([#174](https://github.com/TokenCemetery/Grada/issues/174)–[#176](https://github.com/TokenCemetery/Grada/issues/176))
- Clean builds and tests in any region ([#182](https://github.com/TokenCemetery/Grada/issues/182)–[#185](https://github.com/TokenCemetery/Grada/issues/185))

### 0.5.0 (2026-11-17)

- Pluggable data sources with one copy of duplicates ([#82](https://github.com/TokenCemetery/Grada/issues/82)): FIT file import ([#84](https://github.com/TokenCemetery/Grada/issues/84)), Garmin Connect with a Personal API key ([#92](https://github.com/TokenCemetery/Grada/issues/92)), and a Data Source screen showing where each kind of data came from ([#86](https://github.com/TokenCemetery/Grada/issues/86))
- Morning report ([#26](https://github.com/TokenCemetery/Grada/issues/26)), evening report ([#27](https://github.com/TokenCemetery/Grada/issues/27)), rule-based recommendations ([#28](https://github.com/TokenCemetery/Grada/issues/28)) and monthly summary ([#40](https://github.com/TokenCemetery/Grada/issues/40))
- Journal keeps only tags Grada can use ([#102](https://github.com/TokenCemetery/Grada/issues/102)), shows how Alcohol and Caffeine change the next night ([#103](https://github.com/TokenCemetery/Grada/issues/103)), suggests tags from health data ([#104](https://github.com/TokenCemetery/Grada/issues/104)) and always lists every tag ([#105](https://github.com/TokenCemetery/Grada/issues/105))
- Birth date and sex in Settings when Apple Health lacks them ([#99](https://github.com/TokenCemetery/Grada/issues/99))
- App Store readiness: medical disclaimer ([#107](https://github.com/TokenCemetery/Grada/issues/107)), privacy policy link ([#108](https://github.com/TokenCemetery/Grada/issues/108)), accurate permission text ([#87](https://github.com/TokenCemetery/Grada/issues/87), [#109](https://github.com/TokenCemetery/Grada/issues/109)), privacy manifest ([#110](https://github.com/TokenCemetery/Grada/issues/110)), health data kept out of CloudKit ([#111](https://github.com/TokenCemetery/Grada/issues/111)), export compliance ([#112](https://github.com/TokenCemetery/Grada/issues/112)), iPhone and iPad only ([#113](https://github.com/TokenCemetery/Grada/issues/113)), App Review notes ([#114](https://github.com/TokenCemetery/Grada/issues/114)), Garmin API terms ([#115](https://github.com/TokenCemetery/Grada/issues/115)), first launch without Health data ([#116](https://github.com/TokenCemetery/Grada/issues/116))

Fixes:

- Garmin and FIT data merged with Apple Health: overnight HRV, all-day heart rate, workout heart rate, Sleep Score, FIT sleep timelines ([#91](https://github.com/TokenCemetery/Grada/issues/91), [#95](https://github.com/TokenCemetery/Grada/issues/95)–[#98](https://github.com/TokenCemetery/Grada/issues/98), [#100](https://github.com/TokenCemetery/Grada/issues/100))
- Naps added to the previous night ([#101](https://github.com/TokenCemetery/Grada/issues/101)), slow or stale Calendar ([#90](https://github.com/TokenCemetery/Grada/issues/90), [#94](https://github.com/TokenCemetery/Grada/issues/94)), duplicate days after a time-zone change ([#118](https://github.com/TokenCemetery/Grada/issues/118)), background delivery ([#120](https://github.com/TokenCemetery/Grada/issues/120)), permission never asked again ([#128](https://github.com/TokenCemetery/Grada/issues/128)), sample data removal ([#89](https://github.com/TokenCemetery/Grada/issues/89)), main-actor isolation ([#88](https://github.com/TokenCemetery/Grada/issues/88))
- Refactoring: store and scoring work off the main actor, one data path for Home and Calendar, import split from live reads, shared settings keys, simpler startup, smaller files with tests ([#117](https://github.com/TokenCemetery/Grada/issues/117), [#121](https://github.com/TokenCemetery/Grada/issues/121)–[#125](https://github.com/TokenCemetery/Grada/issues/125))

### 0.4.0 (2026-11-16)

- Sleep Score ([#29](https://github.com/TokenCemetery/Grada/issues/29)), Strain and training load ([#30](https://github.com/TokenCemetery/Grada/issues/30)), Training Readiness ([#31](https://github.com/TokenCemetery/Grada/issues/31)), Load Focus ([#32](https://github.com/TokenCemetery/Grada/issues/32)) and Recovery Time ([#33](https://github.com/TokenCemetery/Grada/issues/33))
- Recovery and Resources detail shows how each input moves them ([#41](https://github.com/TokenCemetery/Grada/issues/41)); Health Age charts stored daily values ([#42](https://github.com/TokenCemetery/Grada/issues/42))
- Every calculated metric lists its studies ([#80](https://github.com/TokenCemetery/Grada/issues/80)), each saying what Grada uses it for ([#81](https://github.com/TokenCemetery/Grada/issues/81))
- Home leads with Recovery, Resources and Strain ([#78](https://github.com/TokenCemetery/Grada/issues/78)), with 3 columns on iPad ([#36](https://github.com/TokenCemetery/Grada/issues/36))

Fixes: Home and Calendar in landscape ([#77](https://github.com/TokenCemetery/Grada/issues/77)), links from retired inputs ([#79](https://github.com/TokenCemetery/Grada/issues/79)).

### 0.3.0 (2026-11-15)

- Calendar types: Health, Recovery and Training, each with its own day sheet ([#58](https://github.com/TokenCemetery/Grada/issues/58))
- Workout screen with stats, heart rate zones, training effect, splits and route ([#60](https://github.com/TokenCemetery/Grada/issues/60))
- Current and 7-day card variants ([#35](https://github.com/TokenCemetery/Grada/issues/35)), VO₂ max zones and sport colors ([#57](https://github.com/TokenCemetery/Grada/issues/57)), card values colored red, yellow and green
- Each Settings group on its own screen ([#66](https://github.com/TokenCemetery/Grada/issues/66))

Fixes:

- Invented formulas replaced with published ones or labelled as Grada's estimate: max heart rate, HRV Status, Recovery, Resources, Sleep Need, Sleep Regularity Index, Health Age, Training Effect, women's VO₂ max zones ([#67](https://github.com/TokenCemetery/Grada/issues/67)–[#74](https://github.com/TokenCemetery/Grada/issues/74))
- Day sheet stuck loading ([#63](https://github.com/TokenCemetery/Grada/issues/63)), swim splits per 100 m ([#64](https://github.com/TokenCemetery/Grada/issues/64)), Training day sheet reads ([#65](https://github.com/TokenCemetery/Grada/issues/65))

### 0.2.0 (2026-11-15)

- Goals that set and adjust themselves ([#22](https://github.com/TokenCemetery/Grada/issues/22)), Calendar days rated against them ([#37](https://github.com/TokenCemetery/Grada/issues/37)), goal progress on Steps, Exercise and Sleep ([#38](https://github.com/TokenCemetery/Grada/issues/38))
- Journal with daily tags ([#23](https://github.com/TokenCemetery/Grada/issues/23))
- Intensity minutes over the last 7 days ([#24](https://github.com/TokenCemetery/Grada/issues/24), [#47](https://github.com/TokenCemetery/Grada/issues/47)) and HRV status ([#25](https://github.com/TokenCemetery/Grada/issues/25))
- Privacy policy ([#43](https://github.com/TokenCemetery/Grada/issues/43))

Fixes: Journal save feedback and day picker ([#45](https://github.com/TokenCemetery/Grada/issues/45), [#46](https://github.com/TokenCemetery/Grada/issues/46)).

### 0.1.0 (2026-11-15)

- Customizable Home backed by Apple Health ([#1](https://github.com/TokenCemetery/Grada/issues/1)): full history import ([#2](https://github.com/TokenCemetery/Grada/issues/2)), background updates ([#3](https://github.com/TokenCemetery/Grada/issues/3)), intraday heart rate, sleep timing and overnight vitals ([#5](https://github.com/TokenCemetery/Grada/issues/5))
- Calendar colored by metric with a day sheet ([#7](https://github.com/TokenCemetery/Grada/issues/7)), metric detail with trends ([#8](https://github.com/TokenCemetery/Grada/issues/8)), read-only health profile ([#9](https://github.com/TokenCemetery/Grada/issues/9))
- Health Age ([#15](https://github.com/TokenCemetery/Grada/issues/15)), Race Predictor ([#16](https://github.com/TokenCemetery/Grada/issues/16)), Recovery ([#17](https://github.com/TokenCemetery/Grada/issues/17)), Sleep Need and Sleep Consistency ([#18](https://github.com/TokenCemetery/Grada/issues/18)) and Resources ([#19](https://github.com/TokenCemetery/Grada/issues/19)) cards
- SwiftData store prepared for iCloud sync ([#4](https://github.com/TokenCemetery/Grada/issues/4))
- App icon ([#54](https://github.com/TokenCemetery/Grada/issues/54)), simulator sample data ([#12](https://github.com/TokenCemetery/Grada/issues/12)), rename to Grada ([#13](https://github.com/TokenCemetery/Grada/issues/13)), repository basics and README ([#14](https://github.com/TokenCemetery/Grada/issues/14), [#21](https://github.com/TokenCemetery/Grada/issues/21))

Fixes: sleep counted toward the wrong day ([#6](https://github.com/TokenCemetery/Grada/issues/6)), baselines off the main actor ([#10](https://github.com/TokenCemetery/Grada/issues/10)), unknown age ([#11](https://github.com/TokenCemetery/Grada/issues/11)), CI and release notes ([#48](https://github.com/TokenCemetery/Grada/issues/48), [#50](https://github.com/TokenCemetery/Grada/issues/50), [#52](https://github.com/TokenCemetery/Grada/issues/52)).

## Declined

- Stress card ([#34](https://github.com/TokenCemetery/Grada/issues/34)): no published method for all-day stress from Apple Health data; a heart-rate-only version shipped in 0.4.0 and was removed.
- Change arrows on cards ([#39](https://github.com/TokenCemetery/Grada/issues/39)): cards already show direction and amount where it means something.
- Custom journal tags ([#44](https://github.com/TokenCemetery/Grada/issues/44)): Grada can't calculate anything from a tag with no evidence behind it; built-in tags were made to count instead.
- Travel or jet lag from a time-zone change ([#106](https://github.com/TokenCemetery/Grada/issues/106)): needs new stored state for a tag nothing calculates with.
- Saving partial import batches ([#119](https://github.com/TokenCemetery/Grada/issues/119)): failures are mostly transient, and the import resumes on the next launch.
- Keeping recent days after access to one data type is revoked ([#148](https://github.com/TokenCemetery/Grada/issues/148)).
