import Foundation
import SwiftData

/// Built-in journal tags. The raw value is persisted, so don't rename cases.
nonisolated enum JournalTag: String, CaseIterable, Identifiable {
    case alcohol, caffeine, lateMeal, hydratedWell, screenBeforeBed, nap
    case illness, stress, headache, medication, melatonin
    case travel, workLate, nightShift, sharedBed, outdoorTime
    case stretching, meditation, sauna, coldExposure

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
        case .lateMeal: "Late meal"
        case .hydratedWell: "Hydrated well"
        case .screenBeforeBed: "Screen before bed"
        case .nap: "Nap"
        case .illness: "Illness"
        case .stress: "Stress"
        case .headache: "Headache"
        case .medication: "Medication"
        case .melatonin: "Melatonin"
        case .travel: "Travel or jet lag"
        case .workLate: "Work late"
        case .nightShift: "Night shift"
        case .sharedBed: "Shared bed"
        case .outdoorTime: "Outdoor time"
        case .stretching: "Stretching"
        case .meditation: "Meditation"
        case .sauna: "Sauna"
        case .coldExposure: "Cold exposure"
        }
    }

    var symbol: String {
        switch self {
        case .alcohol: "wineglass"
        case .caffeine: "cup.and.saucer"
        case .lateMeal: "fork.knife"
        case .hydratedWell: "drop"
        case .screenBeforeBed: "iphone"
        case .nap: "powersleep"
        case .illness: "facemask"
        case .stress: "exclamationmark.triangle"
        case .headache: "brain.head.profile"
        case .medication: "pills"
        case .melatonin: "moon.stars"
        case .travel: "airplane"
        case .workLate: "briefcase"
        case .nightShift: "moon.haze"
        case .sharedBed: "bed.double"
        case .outdoorTime: "sun.max"
        case .stretching: "figure.flexibility"
        case .meditation: "figure.mind.and.body"
        case .sauna: "flame"
        case .coldExposure: "snowflake"
        }
    }

    var group: Group {
        switch self {
        case .alcohol, .caffeine, .lateMeal, .hydratedWell, .screenBeforeBed, .nap: .lifestyle
        case .illness, .stress, .headache, .medication, .melatonin: .health
        case .travel, .workLate, .nightShift, .sharedBed, .outdoorTime: .situation
        case .stretching, .meditation, .sauna, .coldExposure: .recovery
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
