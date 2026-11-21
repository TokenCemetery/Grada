import Foundation
import Testing
@testable import Grada

struct JournalSuggestionTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: .now) }
    private func at(_ hours: Double) -> Date { today.addingTimeInterval(hours * 3600) }

    /// Fourteen nights close to `mean`, so its normal range is about the minimum width.
    private func history(_ mean: Double) -> [Double] { (0..<14).map { mean + ($0.isMultiple(of: 2) ? 0.1 : -0.1) } }

    private func vitals(hrv: Double = 60, restingHeartRate: Double = 55, breathing: Double = 14,
                        temperature: Double? = 35.6) -> [JournalSuggestion.Vital] {
        [JournalSuggestion.Vital(kind: .hrv, value: hrv, history: history(60)),
         JournalSuggestion.Vital(kind: .restingHeartRate, value: restingHeartRate, history: history(55)),
         JournalSuggestion.Vital(kind: .breathing, value: breathing, history: history(14)),
         JournalSuggestion.Vital(kind: .temperature, value: temperature, history: history(35.6))]
    }

    @Test func twoVitalsOffSuggestIllness() {
        let suggestion = JournalSuggestion.illness(vitals(restingHeartRate: 65, breathing: 18), alcoholDayBefore: false)
        #expect(suggestion?.tag == .illness)
        #expect(suggestion?.reason == "Resting HR high, breathing fast")
    }

    @Test func oneVitalOffIsNotIllness() {
        #expect(JournalSuggestion.illness(vitals(hrv: 30), alcoholDayBefore: false) == nil)
        #expect(JournalSuggestion.illness(vitals(), alcoholDayBefore: false) == nil)
    }

    @Test func withoutTemperatureTheOtherVitalsStillCount() {
        let suggestion = JournalSuggestion.illness(vitals(hrv: 30, restingHeartRate: 65, temperature: nil), alcoholDayBefore: false)
        #expect(suggestion?.reason == "HRV low, resting HR high")
    }

    @Test func afterAlcoholBreathingOrTemperatureMustBeOff() {
        #expect(JournalSuggestion.illness(vitals(hrv: 30, restingHeartRate: 65), alcoholDayBefore: true) == nil)
        #expect(JournalSuggestion.illness(vitals(restingHeartRate: 65, temperature: 37), alcoholDayBefore: true) != nil)
    }

    @Test func calibratingVitalsAreSkipped() {
        let short = [JournalSuggestion.Vital(kind: .restingHeartRate, value: 65, history: [55, 55]),
                     JournalSuggestion.Vital(kind: .breathing, value: 18, history: history(14))]
        #expect(JournalSuggestion.illness(short, alcoholDayBefore: false) == nil)
    }

    @Test func daytimeSleepIsANapButTheNightIsNot() {
        let night = SleepPeriod(start: at(-1), end: at(7), stage: .core)
        let nap = SleepPeriod(start: at(14), end: at(14.7), stage: .core)
        let suggestion = JournalSuggestion.nap([night, nap], day: today, calendar: calendar)
        #expect(suggestion?.amount == 40, "42 minutes, to the stepper's 5 minutes")
        #expect(suggestion?.reason == "42m of daytime sleep")
        #expect(JournalSuggestion.nap([night], day: today, calendar: calendar) == nil)
    }

    @Test func eveningDozeBeforeBedIsANap() {
        let doze = SleepPeriod(start: at(19), end: at(19.5), stage: nil)
        let night = SleepPeriod(start: at(23), end: at(31), stage: .core)
        #expect(JournalSuggestion.nap([doze, night], day: today, calendar: calendar)?.amount == 30)
    }

    @Test func shortDozeIsNotANap() {
        let night = SleepPeriod(start: at(-1), end: at(7), stage: .core)
        let doze = SleepPeriod(start: at(14), end: at(14.1), stage: .core)
        #expect(JournalSuggestion.nap([night, doze], day: today, calendar: calendar) == nil)
    }

    @Test func meditationAndOutdoorTimeNeedEnoughMinutes() {
        #expect(JournalSuggestion.meditation(60) == nil, "A one-minute Breathe session")
        #expect(JournalSuggestion.meditation(10 * 60)?.reason == "10m of mindful sessions")
        #expect(JournalSuggestion.meditation(nil) == nil)
        #expect(JournalSuggestion.outdoorTime(20 * 60) == nil)
        #expect(JournalSuggestion.outdoorTime(45 * 60)?.reason == "45m in daylight")
    }

    @Test func sampleDataSuggestsOutdoorTime() async throws {
        let suggestions = try await JournalSuggestion.load(day: today, alcoholDayBefore: false, source: SampleDataSource(),
                                                           calendar: calendar)
        #expect(suggestions.contains { $0.tag == .outdoorTime })
        #expect(!suggestions.contains { $0.tag == .nap }, "Sample nights have no daytime sleep")
        #expect(suggestions.first { $0.tag == .caffeine }?.amount == 2)
    }

    @Test func alcoholSuggestsTheLoggedDrinks() {
        #expect(JournalSuggestion.alcohol(nil) == nil)
        #expect(JournalSuggestion.alcohol(0) == nil)
        #expect(JournalSuggestion.alcohol(2)?.amount == 2)
        #expect(JournalSuggestion.alcohol(2)?.reason == "2 drinks logged in Apple Health")
        #expect(JournalSuggestion.alcohol(0.4)?.amount == 1, "Part of a drink still counts")
        #expect(JournalSuggestion.alcohol(35)?.amount == 20, "The tag's largest amount")
    }

    @Test func caffeineBecomesCupsOfBrewedCoffee() {
        #expect(JournalSuggestion.caffeine(nil) == nil)
        #expect(JournalSuggestion.caffeine(0) == nil)
        #expect(JournalSuggestion.caffeine(190)?.amount == 2)
        #expect(JournalSuggestion.caffeine(190)?.reason == "190 mg of caffeine, about 2 cups of coffee at 95 mg each (USDA)")
        #expect(JournalSuggestion.caffeine(34)?.amount == 1, "A can of cola still counts")
        #expect(JournalSuggestion.caffeine(2_000)?.amount == 10, "The tag's largest amount")
    }
}
