import Foundation

nonisolated extension SnapshotBuilder {
    // MARK: - Training

    /// Race times from the latest VO₂ max, and their trend against the reading about 4 weeks before it.
    func racePredictor() async throws -> CardSnapshot {
        let readings = try await source.daily(.vo2Max, days: 90).filter { $0.value != nil }
        guard let latest = readings.last, let vo2Max = latest.value else { return .noData(period: String(localized: "Latest")) }
        let monthBefore = calendar.date(byAdding: .day, value: -28, to: latest.day)!
        let earlier = readings.last(where: { $0.day <= monthBefore }) ?? (readings.count > 1 ? readings.first : nil)
        return CardSnapshot(
            period: dayLabel(latest.day),
            value: earlier?.value.map { RacePredictor.trend(from: $0, to: vo2Max) } ?? String(localized: "First estimate"),
            comparison: String(localized: "From VO₂ max \(format(vo2Max, 1))"),
            detail: .stats(RacePredictor.distances.map {
                (value: Self.raceTime(RacePredictor.time(meters: $0.meters, vo2Max: vo2Max)), label: $0.name)
            })
        )
    }

    /// Today's load so far, with the 7-day against 28-day ratio and the last 7 days' loads.
    func strain() async throws -> CardSnapshot {
        guard let days = try await strainDays(7) else {
            return CardSnapshot(period: todayLabel, value: String(localized: "Calibrating"),
                                comparison: String(localized: "Needs your age or max heart rate"))
        }
        guard let today = days.last, let load = today.load else { return .noData(period: todayLabel) }
        var snapshot = CardSnapshot(period: todayLabel, value: format(load, 0), unit: "TRIMP",
                                    chart: .bars(days.map { $0.load ?? 0 }))
        if let ratio = today.ratio {
            snapshot.comparison = String(localized: "\(Strain.word(ratio.value)) · ratio \(format(ratio.value, 2))")
            snapshot.rating = Strain.rating(ratio.value)
            snapshot.tone = Self.tone(Strain.rating(ratio.value))
            snapshot.recommendation = isToday ? Recommendations.load(ratio: ratio.value) : nil
        } else {
            snapshot.comparison = String(localized: "Ratio needs \(Strain.minimumChronicDays) days")
        }
        return snapshot
    }

    /// Each of the last `count` days' load (nil without heart rate) and its acute:chronic ratio, oldest first.
    /// Nil altogether without a max heart rate to set the zones.
    func strainDays(_ count: Int) async throws -> [(day: Date, load: Double?, ratio: Strain.Ratio?)]? {
        guard let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                        highestRecorded: try await source.highestHeartRate(days: 365))
        else { return nil }
        let days = lastDays(count + Strain.chronicDays - 1)
        let heartRate = try await source.heartRate(in: DateInterval(start: days[0], end: max(now, days[0])))
        let byDay = Dictionary(grouping: heartRate) { calendar.startOfDay(for: $0.date) }
        let loads = days.map { day in
            byDay[day].map { Strain.load(heartRate: $0, end: min(now, calendar.date(byAdding: .day, value: 1, to: day)!),
                                         maxHeartRate: maxHeartRate) }
        }
        return (days.count - count..<days.count).map { (days[$0], loads[$0], Strain.ratio(loads: loads, endingAt: $0)) }
    }

    /// Hours left until recovered from the last few days' workouts, counting down with the clock.
    func recoveryTime() async throws -> CardSnapshot {
        guard let status = try await recoveryTimeStatus() else {
            return CardSnapshot(period: nowLabel, value: String(localized: "Calibrating"),
                                comparison: String(localized: "Needs your age or max heart rate"))
        }
        guard let recovered = status.recoveredAt, let lastEnd = status.lastWorkoutEnd else {
            if status.lastWorkoutEnd == nil, try await source.workouts(days: 30).isEmpty { return .noData(period: nowLabel) }
            return CardSnapshot(period: nowLabel, value: String(localized: "Recovered"),
                                comparison: String(localized: "Ready for hard training"),
                                tone: .good, rating: .good, chart: .progress(value: 1, goal: 1))
        }
        let left = recovered.timeIntervalSince(now)
        let total = recovered.timeIntervalSince(lastEnd)
        let time = recovered.formatted(date: .omitted, time: .shortened)
        let until = calendar.isDate(recovered, inSameDayAs: now)
            ? String(localized: "Until \(time)")
            : String(localized: "Until \(recovered.formatted(.dateTime.weekday(.abbreviated))) \(time)")
        return CardSnapshot(
            period: nowLabel,
            value: "\(Int((left / 3600).rounded(.up)))",
            unit: String(localized: "h", comment: "Unit: hours"),
            comparison: until,
            rating: .fair,
            chart: .progress(value: total - left, goal: total)
        )
    }

    /// When recovery from the last 3 days' workouts ends (nil once recovered) and when the latest workout ended
    /// (nil without workouts). Nil altogether without a max heart rate to set the zones.
    func recoveryTimeStatus() async throws -> (recoveredAt: Date?, lastWorkoutEnd: Date?)? {
        guard let maxHeartRate = Resources.maxHeartRate(age: try await source.age(),
                                                        highestRecorded: try await source.highestHeartRate(days: 365))
        else { return nil }
        let workouts = try await source.workouts(days: 4)
            .map { RecoveryTime.Workout(end: $0.start.addingTimeInterval($0.duration), averageHeartRate: $0.averageHeartRate) }
            .filter { $0.end <= now }
        guard let lastEnd = workouts.map(\.end).max() else { return (nil, nil) }
        let today = calendar.startOfDay(for: now)
        let wake = try await source.overnight(days: 1).last.flatMap { $0.wakeDay == today ? $0.wakeTime : nil }
        let morning = try await recoveryDays(1).last?.result?.rating
        return (RecoveryTime.recoveredAt(workouts: workouts, maxHeartRate: maxHeartRate, now: now,
                                         wake: wake, morningRecovery: morning), lastEnd)
    }

    func lastWorkout() async throws -> CardSnapshot {
        guard let workout = try await source.workouts(days: 30).first else { return .noData(period: String(localized: "Last 30 days")) }
        return workoutSnapshot(workout)
    }

    /// A Last Workout card for one workout.
    func workoutSnapshot(_ workout: WorkoutSummary) -> CardSnapshot {
        CardSnapshot(
            period: String(localized: "\(dayLabel(workout.start)), \(workout.start.formatted(date: .omitted, time: .shortened))"),
            value: Self.hoursMinutes(workout.duration),
            comparison: workout.name,
            detail: .workout(workout)
        )
    }

    func weeklyTraining() async throws -> CardSnapshot {
        let recent = try await source.workouts(days: 7)
        let workouts = recent.count
        guard workouts > 0 else { return .noData(period: String(localized: "Last 7 days")) }
        let minutes = workoutMinutesPerDay(recent, days: 7)
        let goal = goals.value(.workouts, on: calendar.startOfDay(for: now))
        let count = workouts == 1 ? String(localized: "1 workout") : String(localized: "\(workouts) workouts")
        return CardSnapshot(
            period: String(localized: "Last 7 days"),
            value: Self.hoursMinutes(minutes.reduce(0, +) * 60),
            comparison: goal.map { goal in
                workouts == 1 ? String(localized: "1 workout of \(format(goal, 0))")
                    : String(localized: "\(workouts) workouts of \(format(goal, 0))")
            } ?? count,
            rating: goal.map { DayRatings.goal(Double(workouts), goal: $0) },
            chart: .bars(minutes)
        )
    }

    func last30Days() async throws -> CardSnapshot {
        let workouts = try await source.workouts(days: 30)
        // The count sits in the period line, so the calendar gets the card's height; the value isn't drawn.
        return CardSnapshot(
            period: workouts.isEmpty ? String(localized: "No workouts")
                : workouts.count == 1 ? String(localized: "1 workout") : String(localized: "\(workouts.count) workouts"),
            value: "\(workouts.count)",
            unit: workouts.count == 1 ? String(localized: "workout") : String(localized: "workouts"),
            detail: .days(workoutDays(workouts, days: 30))
        )
    }

    /// Each of the last `days` days' workouts by sport, oldest first.
    private func workoutDays(_ workouts: [WorkoutSummary], days: Int) -> [WorkoutDay] {
        let byDay = WorkoutDay.byDay(workouts, calendar: calendar)
        return lastDays(days).map { byDay[$0] ?? WorkoutDay() }
    }

    private func workoutMinutesPerDay(_ workouts: [WorkoutSummary], days: Int) -> [Double] {
        let dayStarts = lastDays(days)
        var minutes = Array(repeating: 0.0, count: days)
        for workout in workouts {
            if let index = dayStarts.firstIndex(of: calendar.startOfDay(for: workout.start)) {
                minutes[index] += workout.duration / 60
            }
        }
        return minutes
    }
}
