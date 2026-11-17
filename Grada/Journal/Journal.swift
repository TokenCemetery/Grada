import Foundation
import SwiftData

/// Built-in journal tags: only those Grada can calculate with, flag a night with, or fill from health data
/// (#102). The raw value is persisted, so don't rename cases; entries of removed tags are ignored.
nonisolated enum JournalTag: String, CaseIterable, Identifiable {
    case alcohol, caffeine, nap
    case illness
    case travel, nightShift, outdoorTime
    case meditation

    enum Group: CaseIterable {
        case lifestyle, health, situation, recovery

        var title: String {
            switch self {
            case .lifestyle: "Lifestyle"
            case .health: "Health"
            case .situation: "Situation"
            case .recovery: "Recovery"
            }
        }

        var tags: [JournalTag] { JournalTag.allCases.filter { $0.group == self } }
    }

    /// What an amount tag counts, with its unit for one and for several.
    struct Amount {
        let singular: String
        let plural: String
        let step: Double
        let range: ClosedRange<Double>
        let initial: Double

        func formatted(_ value: Double) -> String {
            "\(value.formatted(.number.precision(.fractionLength(0)))) \(value == 1 ? singular : plural)"
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .alcohol: "Alcohol"
        case .caffeine: "Caffeine"
        case .nap: "Nap"
        case .illness: "Illness"
        case .travel: "Travel or jet lag"
        case .nightShift: "Night shift"
        case .outdoorTime: "Outdoor time"
        case .meditation: "Meditation"
        }
    }

    var symbol: String {
        switch self {
        case .alcohol: "wineglass"
        case .caffeine: "cup.and.saucer"
        case .nap: "powersleep"
        case .illness: "facemask"
        case .travel: "airplane"
        case .nightShift: "moon.haze"
        case .outdoorTime: "sun.max"
        case .meditation: "figure.mind.and.body"
        }
    }

    var group: Group {
        switch self {
        case .alcohol, .caffeine, .nap: .lifestyle
        case .illness: .health
        case .travel, .nightShift, .outdoorTime: .situation
        case .meditation: .recovery
        }
    }

    /// Nil for yes/no tags.
    var amount: Amount? {
        switch self {
        case .alcohol: Amount(singular: "drink", plural: "drinks", step: 1, range: 1...20, initial: 1)
        case .caffeine: Amount(singular: "cup", plural: "cups", step: 1, range: 1...10, initial: 1)
        case .nap: Amount(singular: "min", plural: "min", step: 5, range: 5...240, initial: 20)
        default: nil
        }
    }

    /// "Alcohol · 2 drinks", or the title for yes/no tags.
    func label(amount value: Double?) -> String {
        guard let amount, let value else { return title }
        return "\(title) · \(amount.formatted(value))"
    }
}

/// One tag logged for one day. A day's tags belong to the day the behavior happened; later analysis
/// links them to the night after. Defaults on every property and no unique constraints keep it ready for
/// CloudKit sync; `dayKey` plus the tag is the identity used to merge duplicates.
@Model
final class JournalEntry {
    var dayKey: String = ""
    var day: Date = Date.distantPast
    var tagRawValue: String = ""
    var amount: Double?
    var updatedAt: Date = Date.distantPast

    init(day: Date, tag: JournalTag, amount: Double?, calendar: Calendar = .current) {
        self.day = calendar.startOfDay(for: day)
        dayKey = DayKey.make(day, calendar: calendar)
        tagRawValue = tag.rawValue
        self.amount = amount
        updatedAt = .now
    }

    /// Stored values as they are, for moving entries between stores.
    init(dayKey: String, day: Date, tagRawValue: String, amount: Double?) {
        self.dayKey = dayKey
        self.day = day
        self.tagRawValue = tagRawValue
        self.amount = amount
    }

    /// Nil if the stored tag no longer exists in this app version.
    var tag: JournalTag? { JournalTag(rawValue: tagRawValue) }
}

/// Reads and writes one day's journal.
@MainActor
struct JournalStore {
    let context: ModelContext
    var calendar: Calendar = .current

    /// The day's entries by tag; the first wins if iCloud delivered duplicates.
    func entries(on day: Date) -> [JournalTag: JournalEntry] {
        let key = DayKey.make(day, calendar: calendar)
        let entries = (try? context.fetch(FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.dayKey == key }))) ?? []
        var result: [JournalTag: JournalEntry] = [:]
        for entry in entries {
            guard let tag = entry.tag else { continue }
            if result[tag] == nil { result[tag] = entry } else { context.delete(entry) }
        }
        return result
    }

    /// Marks the tag for the day, or removes it if it's already marked.
    func toggle(_ tag: JournalTag, on day: Date) {
        if let entry = entries(on: day)[tag] {
            context.delete(entry)
        } else {
            context.insert(JournalEntry(day: day, tag: tag, amount: tag.amount?.initial, calendar: calendar))
        }
        try? context.save()
    }

    func setAmount(_ amount: Double, for tag: JournalTag, on day: Date) {
        guard let entry = entries(on: day)[tag] else { return }
        entry.amount = amount
        entry.updatedAt = .now
        try? context.save()
    }
}
