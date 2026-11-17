import Foundation

/// Turns raw Apple Health data into card snapshots. All calculations run on the device.
nonisolated struct SnapshotBuilder {
    let source: HealthDataSource
    var calendar: Calendar = .current
    var now: Date = .now
    var usesMetric: Bool = Locale.current.measurementSystem != .us
    /// The user's goals; cards for goal metrics compare with the goal in effect on the shown day.
    var goals = GoalHistory()

    /// History used for personal normal ranges.
    let baselineDays = 30

    /// Cards with a single variant ignore `variant`. `@concurrent`, so reading and scoring never run on the main actor.
    @concurrent func snapshot(for kind: CardKind, variant: CardVariant = .current) async throws -> CardSnapshot {
        switch kind {
        case .healthStatus: try await healthStatus()
        case .recovery: try await recovery(variant)
        case .resources: try await resources()
        case .healthAge: try await healthAge()
        case .sleepNeed: try await sleepNeed()
        case .sleepConsistency: try await sleepConsistency()
        case .sleepScore: try await sleepScore()
        case .racePredictor: try await racePredictor()
        case .trainingReadiness: try await trainingReadiness()
        case .loadFocus: try await loadFocus()
        case .heartRate: try await heartRate()
        case .sleepDuration: try await sleep(withStages: false, variant)
        case .sleepStages: try await sleep(withStages: true, .current)
        case .restingHeartRate: try await vital(.restingHeartRate, variant)
        case .hrv: try await vital(.hrv, variant)
        case .hrvStatus: try await hrvStatus(variant)
        case .oxygenSaturation: try await vital(.oxygenSaturation, .current)
        case .respiratoryRate: try await vital(.respiratoryRate, .current)
        case .wristTemperature: try await wristTemperature(variant)
        case .steps: try await cumulative(.steps, goal: .steps, variant)
        case .activeEnergy: try await cumulative(.activeEnergy, goal: .activeEnergy, variant)
        case .exerciseMinutes: try await cumulative(.exerciseMinutes, variant)
        case .intensityMinutes: try await intensityMinutes()
        case .dayIntensity: try await dayIntensity()
        case .distance: try await cumulative(.distance, variant)
        case .floors: try await cumulative(.floors, goal: .floors, variant)
        case .standHours: totals(try await source.standHours(days: 8), decimals: 0, unit: "h", variant: variant)
        case .lastWorkout: try await lastWorkout()
        case .weeklyTraining: try await weeklyTraining()
        case .strain: try await strain()
        case .recoveryTime: try await recoveryTime()
        case .vo2Max: try await vo2Max()
        case .last30Days: try await last30Days()
        }
    }

    // MARK: - Helpers

    /// Start of each of the last `count` days, oldest first, ending today.
    func lastDays(_ count: Int) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().map { calendar.date(byAdding: .day, value: -$0, to: today)! }
    }

    /// False when building a past day's cards for the calendar, where "Today" would be wrong.
    var isToday: Bool { calendar.isDateInToday(now) }
    var todayLabel: String { isToday ? "Today" : "That day" }
    var tonightLabel: String { isToday ? "Tonight" : "That night" }
    var lastNightLabel: String { isToday ? "Last night" : "Night before" }
    /// Resources at the end of a past day.
    var nowLabel: String { isToday ? "Now" : "End of day" }
    var yesterdayLabel: String { dayLabel(calendar.date(byAdding: .day, value: -1, to: now)!) }

    func dayLabel(_ date: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return todayLabel }
        if isToday, let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    func format(_ value: Double, _ decimals: Int, signed: Bool = false) -> String {
        value.formatted(.number.precision(.fractionLength(decimals))
            .sign(strategy: signed ? .always(includingZero: false) : .automatic))
    }

    /// "−1,580 of 10,000", or "Goal reached" at or above it.
    static func goalComparison(_ value: Double, goal: Double, decimals: Int) -> String {
        guard value < goal else { return "Goal reached" }
        let style = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(decimals))
        return "−\((goal - value).formatted(style)) of \(goal.formatted(style))"
    }

    static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m" : "\(minutes)m"
    }

    /// "24:10" under an hour, "1:51:20" above.
    static func raceTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    static func signedMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        let sign = minutes > 0 ? "+" : (minutes < 0 ? "−" : "±")
        return sign + hoursMinutes(Double(abs(minutes)) * 60)
    }
}
