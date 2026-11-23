import Foundation
import SwiftData

/// Writes imported health data on its own background context, so a year-long history import's day-by-day merging
/// stays off the main actor. The main context sees each save once it is committed. Saves can't interleave:
/// `save` has no suspension point, and the actor runs one call at a time.
@ModelActor
actor HealthStoreWriter {
    /// Upserts one source's batch: one summary per day, one record per workout. Touches only that
    /// source's rows. Removes duplicates (e.g. from two devices importing the same history) and
    /// workouts deleted from the source. With `merging`, as for file imports that each hold only some
    /// days and kinds of data, values and workouts the batch lacks are kept instead.
    func save(_ batch: HealthBatch, from source: String, merging: Bool, calendar: Calendar) throws {
        let start = batch.days.start, end = batch.days.end
        // A day stored in another time zone starts at a different instant, so look a day either side and match
        // rows by `dayKey`; otherwise an edge day after travel gets a second row (#118).
        let fetchStart = calendar.date(byAdding: .day, value: -1, to: start)!
        let fetchEnd = calendar.date(byAdding: .day, value: 1, to: end)!

        var summaries: [String: DaySummary] = [:]
        let summaryDescriptor = FetchDescriptor<DaySummary>(
            predicate: #Predicate { $0.source == source && $0.day >= fetchStart && $0.day < fetchEnd }
        )
        for summary in try modelContext.fetch(summaryDescriptor) {
            if summaries[summary.dayKey] == nil { summaries[summary.dayKey] = summary } else { modelContext.delete(summary) }
        }

        let sleepByDay = Dictionary(batch.sleepNights.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let overnightByDay = Dictionary(batch.overnight.map { ($0.wakeDay, $0) }, uniquingKeysWith: { first, _ in first })
        let standByDay = Dictionary(batch.standHours.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        let dailyByDay = batch.daily.mapValues { values in
            Dictionary(values.map { ($0.day, $0.value) }, uniquingKeysWith: { first, _ in first })
        }

        func update<Value>(_ new: Value?, keeping old: Value?) -> Value? { merging ? new ?? old : new }

        var day = start
        while day < end {
            let key = DayKey.make(day, calendar: calendar)
            let metrics = dailyByDay.mapValues { $0[day] ?? nil }
            let stand = standByDay[day] ?? nil
            let sleep = sleepByDay[day]
            let overnight = overnightByDay[day]
            let hasData = metrics.values.contains { $0 != nil } || stand != nil || sleep != nil || overnight != nil

            if let summary = summaries[key] ?? (hasData ? DaySummary(day: day, dayKey: key, source: source) : nil) {
                if summaries[key] == nil { modelContext.insert(summary) }
                for (metric, value) in metrics { summary.setValue(update(value, keeping: summary.value(for: metric)), for: metric) }
                summary.standHours = update(stand, keeping: summary.standHours)
                if sleep != nil || !merging { summary.setSleep(sleep) }
                summary.overnightHRV = update(overnight?.hrv, keeping: summary.overnightHRV)
                summary.sleepingHeartRate = update(overnight?.heartRate, keeping: summary.sleepingHeartRate)
                summary.bedtime = update(overnight?.bedtime, keeping: summary.bedtime)
                summary.wakeTime = update(overnight?.wakeTime, keeping: summary.wakeTime)
                let origins: [String: [String]] = batch.origins.reduce(into: [:]) { origins, entry in
                    if let names = entry.value[day], !names.isEmpty { origins[entry.key.rawValue] = names }
                }
                summary.origins = merging ? summary.origins.merging(origins) { Array(Set($0 + $1)).sorted() } : origins
                summary.updatedAt = .now
            }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }

        let fetched = Dictionary(batch.workouts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kept = Set<String>()
        let workoutDescriptor = FetchDescriptor<WorkoutRecord>(
            predicate: #Predicate { $0.source == source && $0.start >= start && $0.start < end }
        )
        for record in try modelContext.fetch(workoutDescriptor) {
            if let workout = fetched[record.healthID] {
                if kept.insert(record.healthID).inserted {
                    record.origin = workout.origin
                    // Workouts stored before their type was kept get it the next time they're read (#196).
                    if let type = workout.activityType { record.activityType = type }
                } else {
                    modelContext.delete(record)
                }
            } else if !merging {
                modelContext.delete(record)
            }
        }
        for var workout in fetched.values where !kept.contains(workout.id) {
            workout.source = source
            modelContext.insert(WorkoutRecord(workout))
        }

        try modelContext.save()
    }
}
