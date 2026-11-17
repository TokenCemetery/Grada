import Foundation
import Testing
@testable import Grada

struct TagEffectTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: .now) }
    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today)! }
    private func key(_ offset: Int) -> String { DayKey.make(day(offset), calendar: calendar) }

    /// `count` values alternating around `mean` by `swing`.
    private func values(_ mean: Double, swing: Double, count: Int) -> [Double] {
        (0..<count).map { mean + ($0.isMultiple(of: 2) ? swing : -swing) }
    }

    @Test func clearDifferenceCounts() {
        let row = TagEffect.row(.hrv, with: values(45, swing: 5, count: 8), without: values(55, swing: 5, count: 40))
        #expect(row.with == 45)
        #expect(row.without == 55)
        #expect(row.change == .changed(-10))
    }

    @Test func differenceInsideTheNoiseIsWithinVariation() {
        let row = TagEffect.row(.hrv, with: values(52, swing: 10, count: 6), without: values(55, swing: 10, count: 40))
        #expect(row.change == .withinVariation)
    }

    @Test func tooFewNightsShowNothing() {
        let row = TagEffect.row(.hrv, with: values(40, swing: 2, count: 4), without: values(55, swing: 2, count: 40))
        #expect(row.with == nil && row.without == nil)
        #expect(row.nightsWith == 4)
        #expect(row.change == .notEnough)
    }

    /// A drink on day D pairs with the night ending on D + 1; a night after Illness counts on neither side.
    @Test func tagPairsWithTheNightAfterAndIllnessIsLeftOut() {
        var logged: [String: [JournalTag: Double]] = [:]
        var nights: [Date: [TagEffect.Metric: Double]] = [:]
        for offset in 1...30 {
            let drank = offset <= 6
            if drank { logged[key(-offset)] = [.alcohol: 2] }
            nights[day(-offset + 1)] = [.hrv: drank ? 40 + Double(offset % 2) : 60 + Double(offset % 2)]
        }
        logged[key(-10)] = [.illness: 1]
        nights[day(-9)] = [.hrv: 10]

        let alcohol = TagEffect.sections(logged: logged, nights: nights, calendar: calendar)[0]
        #expect(alcohol.tag == .alcohol && alcohol.dose == nil)
        let hrv = alcohol.rows[0]
        #expect(hrv.nightsWith == 6)
        #expect(hrv.nightsWithout == 23, "30 days, less 6 with alcohol and 1 after illness")
        #expect(hrv.with == 40.5)
        guard case .changed(let difference) = hrv.change else { Issue.record("Expected a change"); return }
        #expect(abs(difference + 20) < 0.1, "About 20 ms lower, and the illness night's 10 ms isn't counted")
    }

    @Test func doseSectionsShowOnlyWhenEveryDoseHasEnoughNights() {
        var logged: [String: [JournalTag: Double]] = [:]
        var nights: [Date: [TagEffect.Metric: Double]] = [:]
        for offset in 1...40 {
            if offset <= 5 { logged[key(-offset)] = [.alcohol: 1] }
            if (6...9).contains(offset) { logged[key(-offset)] = [.alcohol: 4] }
            nights[day(-offset + 1)] = [.hrv: 50 + Double(offset % 3)]
        }
        #expect(TagEffect.sections(logged: logged, nights: nights, calendar: calendar).map(\.dose) == [nil, nil], "Alcohol and Caffeine")

        logged[key(-10)] = [.alcohol: 3]
        let doses = TagEffect.sections(logged: logged, nights: nights, calendar: calendar).filter { $0.tag == .alcohol }.map(\.dose)
        #expect(doses == [nil, "1–2 drinks", "3 or more drinks"])
    }

    @Test func caffeineShowsOnlySleepOutcomes() {
        let caffeine = TagEffect.sections(logged: [:], nights: [:], calendar: calendar).first { $0.tag == .caffeine }
        #expect(caffeine?.rows.map(\.metric) == [.sleep, .deep, .awake])
    }

    @Test func nightsComeFromOvernightVitalsAndSleepTotals() async throws {
        let nights = try await TagEffect.nights(source: SampleDataSource())
        let lastNight = try #require(nights[today])
        #expect(lastNight[.hrv] != nil)
        #expect(lastNight[.sleep] != nil)
    }
}
