import Foundation
import HealthKit

/// What FIT files the user picked add to Grada: workouts from activity files, and sleep stages, overnight
/// HRV and resting heart rate from a watch's daily files. Read on the device; nothing is uploaded.
nonisolated struct FITImport {
    /// Stored with every value imported from files, so it must never change.
    static let sourceID = "fitFiles"

    struct Failure: Equatable {
        let file: String
        let reason: String
    }

    var workouts: [WorkoutSummary] = []
    var sleepNights: [SleepNight] = []
    var overnight: [OvernightVitals] = []
    var restingHeartRate: [DayValue] = []
    var origins: [DataKind: [Date: [String]]] = [:]
    var filesRead = 0
    var failures: [Failure] = []

    var isEmpty: Bool { workouts.isEmpty && sleepNights.isEmpty && overnight.isEmpty && restingHeartRate.isEmpty }

    /// Everything in the files as one batch, spanning the first to the last day found.
    func batch(calendar: Calendar) -> HealthBatch? {
        let days = workouts.map { calendar.startOfDay(for: $0.start) } + sleepNights.map(\.wakeDay)
            + overnight.map(\.wakeDay) + restingHeartRate.map(\.day)
        guard let first = days.min(), let last = days.max() else { return nil }
        var batch = HealthBatch(days: DateInterval(start: first, end: calendar.date(byAdding: .day, value: 1, to: last)!))
        batch.workouts = workouts
        batch.sleepNights = sleepNights
        batch.overnight = overnight
        batch.daily[.restingHeartRate] = restingHeartRate
        batch.origins = origins
        return batch
    }

    /// Reads every FIT file in `urls`, looking inside folders such as an unzipped Garmin export.
    /// The same night, reading or workout found in several files counts once.
    @concurrent static func read(_ urls: [URL], calendar: Calendar) async -> FITImport {
        var reader = Reader(calendar: calendar)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?
                    .compactMap { $0 as? URL } ?? []
                for file in files.sorted(by: { $0.path < $1.path }) {
                    switch file.pathExtension.lowercased() {
                    case "fit": reader.read(file)
                    case "zip": reader.result.failures.append(Failure(file: file.lastPathComponent, reason: "Unzip it in the Files app first."))
                    default: break
                    }
                }
            } else {
                reader.read(url)
            }
        }
        return reader.finish()
    }

    /// FIT message and field numbers from the FIT SDK profile.
    private enum Message {
        static let fileID = 0, session = 18, monitoringHeartRate = 211, sleepLevel = 275
        static let hrvStatusSummary = 370, hrvValue = 371
    }

    private struct Reader {
        let calendar: Calendar
        var result = FITImport()
        var workouts: [String: WorkoutSummary] = [:]
        /// Keyed by start, so a night found in two files counts once.
        var sleep: [Date: (period: SleepPeriod, device: String)] = [:]
        var hrvReadings: [Date: (value: Double, device: String)] = [:]
        var hrvSummaries: [Date: (value: Double, device: String)] = [:]
        var restingHeartRate: [Date: (time: Date, value: Double, device: String)] = [:]

        mutating func read(_ file: URL) {
            let messages: [FITMessage]
            do {
                messages = try FITDecoder.decode(Data(contentsOf: file))
            } catch let error as FITError {
                let reason = switch error {
                case .notFIT: "Not a FIT file."
                case .truncated: "The file is incomplete."
                case .badChecksum, .undefinedMessage: "The file is damaged."
                }
                result.failures.append(Failure(file: file.lastPathComponent, reason: reason))
                return
            } catch {
                result.failures.append(Failure(file: file.lastPathComponent, reason: error.localizedDescription))
                return
            }
            result.filesRead += 1

            let manufacturer = messages.first { $0.number == Message.fileID }?.fields[1]
            let device = FITImport.brand(manufacturer).map { "\($0) (imported)" } ?? "Imported FIT file"
            var levels: [(time: Date, level: Int64)] = []
            for message in messages {
                switch message.number {
                case Message.session:
                    if let workout = FITImport.workout(message, device: device) { workouts[workout.id] = workout }
                case Message.sleepLevel:
                    if let time = message.timestamp, let level = message.fields[0] { levels.append((time, level)) }
                case Message.hrvValue:
                    if let time = message.timestamp, let value = message.fields[0] { hrvReadings[time] = (Double(value) / 128, device) }
                case Message.hrvStatusSummary:
                    if let time = message.timestamp, let value = message.fields[1] { hrvSummaries[time] = (Double(value) / 128, device) }
                case Message.monitoringHeartRate:
                    if let time = message.timestamp, let value = message.fields[1] ?? message.fields[0] {
                        let day = calendar.startOfDay(for: time)
                        if time >= restingHeartRate[day]?.time ?? .distantPast { restingHeartRate[day] = (time, Double(value), device) }
                    }
                default: break
                }
            }
            // Each sleep level lasts until the next one; the last only marks the end.
            levels.sort { $0.time < $1.time }
            for (current, next) in zip(levels, levels.dropFirst()) {
                guard let stage = FITImport.stage(current.level), next.time > current.time else { continue }
                sleep[current.time] = (SleepPeriod(start: current.time, end: next.time, stage: stage), device)
            }
        }

        mutating func finish() -> FITImport {
            result.workouts = workouts.values.sorted { $0.start > $1.start }

            let periods = sleep.values.sorted { $0.period.start < $1.period.start }
            let nights = Dictionary(grouping: periods) { SleepNight.wakeDay(forEnd: $0.period.end, calendar: calendar) }
            var vitals: [Date: OvernightVitals] = [:]
            for (day, periods) in nights {
                var stages: [SleepStage: TimeInterval] = [:]
                for (period, _) in periods { stages[period.stage!, default: 0] += period.end.timeIntervalSince(period.start) }
                guard stages.keys.contains(where: { $0 != .awake }) else { continue }
                result.sleepNights.append(SleepNight(wakeDay: day, stages: stages, unspecified: 0))
                result.origins[.sleep, default: [:]][day] = Array(Set(periods.map(\.device))).sorted()
                let asleep = periods.map(\.period).filter { $0.stage != .awake }
                vitals[day] = OvernightVitals(wakeDay: day, bedtime: asleep.map(\.start).min(), wakeTime: asleep.map(\.end).max())
            }

            // Nightly HRV: the average of the night's readings, else the watch's own nightly average.
            var hrv: [Date: (values: [Double], device: String)] = [:]
            for (time, reading) in hrvReadings {
                hrv[SleepNight.wakeDay(forEnd: time, calendar: calendar), default: ([], reading.device)].values.append(reading.value)
            }
            for (time, summary) in hrvSummaries {
                let day = SleepNight.wakeDay(forEnd: time, calendar: calendar)
                if hrv[day] == nil { hrv[day] = ([summary.value], summary.device) }
            }
            for (day, night) in hrv {
                vitals[day, default: OvernightVitals(wakeDay: day)].hrv = Baseline.average(night.values)
                result.origins[.overnightHRV, default: [:]][day] = [night.device]
            }
            result.overnight = vitals.values.sorted { $0.wakeDay < $1.wakeDay }
            result.sleepNights.sort { $0.wakeDay < $1.wakeDay }

            result.restingHeartRate = restingHeartRate.map { DayValue(day: $0.key, value: $0.value.value) }.sorted { $0.day < $1.day }
            for (day, reading) in restingHeartRate { result.origins[.restingHeartRate, default: [:]][day] = [reading.device] }
            return result
        }
    }

    /// A FIT `session` as a workout; its ID is its start time, which is the same in every copy of the file.
    private static func workout(_ session: FITMessage, device: String) -> WorkoutSummary? {
        guard let seconds = session.fields[8] ?? session.fields[7], seconds > 0 else { return nil }
        let duration = TimeInterval(seconds) / 1000
        guard let start = session.date(2) ?? session.timestamp?.addingTimeInterval(-duration) else { return nil }
        let info = WorkoutNames.info(for: activityType(sport: session.fields[5], subSport: session.fields[6]))
        return WorkoutSummary(
            id: "fit-\(Int(start.timeIntervalSince(FITMessage.epoch)))",
            start: start,
            duration: duration,
            name: info.name,
            symbol: info.symbol,
            energyKcal: session.fields[11].map(Double.init),
            averageHeartRate: session.fields[16].map(Double.init),
            source: sourceID,
            origin: device
        )
    }

    /// FIT `sport` and `sub_sport` values Grada names; others become a generic workout.
    private static func activityType(sport: Int64?, subSport: Int64?) -> HKWorkoutActivityType {
        switch (sport, subSport) {
        case (1, _): .running
        case (2, _), (21, _): .cycling
        case (5, _): .swimming
        case (11, _): .walking
        case (17, _): .hiking
        case (15, _), (4, 14): .rowing
        case (4, 15): .elliptical
        case (12, _): .crossCountrySkiing
        case (13, _): .downhillSkiing
        case (10, 20): .traditionalStrengthTraining
        case (10, 43): .yoga
        case (10, 70): .highIntensityIntervalTraining
        default: .other
        }
    }

    /// FIT `sleep_level`: 1 awake, 2 light, 3 deep, 4 REM; 0 (unmeasurable) is skipped.
    private static func stage(_ level: Int64) -> SleepStage? {
        switch level {
        case 1: .awake
        case 2: .core
        case 3: .deep
        case 4: .rem
        default: nil
        }
    }

    /// FIT `manufacturer` values of brands whose watches and bike computers export FIT files.
    private static func brand(_ manufacturer: Int64?) -> String? {
        switch manufacturer {
        case 1: "Garmin"
        case 23: "Suunto"
        case 32: "Wahoo"
        case 123: "Polar"
        case 260: "Zwift"
        case 267: "Bryton"
        case 289: "Hammerhead"
        case 294: "COROS"
        default: nil
        }
    }
}
