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

    /// With 5 nights a side, twice the standard error isn't enough: Student's t for Welch's 8 degrees is 2.306 (#161).
    @Test func fewNightsNeedStudentsT() {
        let row = TagEffect.row(.hrv, with: [10, 11, 12, 13, 14].map { $0 + 2.2 }, without: [10, 11, 12, 13, 14])
        #expect(row.change == .withinVariation)
        #expect(TagEffect.criticalT(8) == 2.306)
        #expect(abs(TagEffect.criticalT(1_000) - 1.962) < 0.001)
    }

    @Test func tooFewNightsShowNothing() {
        let row = TagEffect.row(.hrv, with: values(40, swing: 2, count: 4), without: values(55, swing: 2, count: 40))
        #expect(row.with == nil && row.without == nil)
        #expect(row.nightsWith == 4)
        #expect(row.change == .notEnough)
    }

    /// A drink on day D pairs with the night ending on D + 1; a night after Illness counts on neither side.
    @Test func tagPairsWithTheNightAfterAndIllnessIsLeftOut() throws {
        var logged: [String: Set<JournalTag>] = [:]
        var nights: [Date: [TagEffect.Metric: Double]] = [:]
        for offset in 1...30 {
            let drank = offset <= 6
            if drank { logged[key(-offset)] = [.alcohol] }
            nights[day(-offset + 1)] = [.hrv: drank ? 40 + Double(offset % 2) : 60 + Double(offset % 2)]
        }
        logged[key(-10)] = [.illness]
        nights[day(-9)] = [.hrv: 10]

        let hrv = try #require(TagEffect.effects(logged: logged, nights: nights, calendar: calendar)[.alcohol]?.first)
        #expect(hrv.metric == .hrv)
        #expect(hrv.nightsWith == 6)
        #expect(hrv.nightsWithout == 23, "30 days, less 6 with alcohol and 1 after illness")
        #expect(hrv.with == 40.5)
        guard case .changed(let difference) = hrv.change else { Issue.record("Expected a change"); return }
        #expect(abs(difference + 20) < 0.1, "About 20 ms lower, and the illness night's 10 ms isn't counted")
    }

    @Test func caffeineShowsOnlySleepOutcomes() {
        let caffeine = TagEffect.effects(logged: [:], nights: [:], calendar: calendar)[.caffeine]
        #expect(caffeine?.map(\.metric) == [.sleep, .deep, .awake])
    }

    @Test func captionListsOnlyClearChanges() {
        let rows = [
            TagEffect.Row(metric: .hrv, with: 45, without: 53, nightsWith: 8, nightsWithout: 40, change: .changed(-8)),
            TagEffect.Row(metric: .sleepingHeartRate, with: 55, without: 54, nightsWith: 8, nightsWithout: 40, change: .withinVariation),
            TagEffect.Row(metric: .rem, with: 4_500, without: 5_400, nightsWith: 8, nightsWithout: 40, change: .changed(-900)),
        ]
        #expect(TagEffect.caption(rows) == "Night after: HRV ↓ 8 ms · REM ↓ 15m")
        #expect(TagEffect.caption([rows[1]]) == "Night after: no clear change")
    }

    @Test func captionSaysWhatsMissing() {
        let few = TagEffect.Row(metric: .sleep, with: nil, without: nil, nightsWith: 2, nightsWithout: 40, change: .notEnough)
        #expect(TagEffect.caption([few]) == "Night after: 2 of 5 days logged")
        let noControls = TagEffect.Row(metric: .sleep, with: nil, without: nil, nightsWith: 9, nightsWithout: 3, change: .notEnough)
        #expect(TagEffect.caption([noControls]) == "Night after: needs more nights to compare")
    }

    @Test func nightsComeFromOvernightVitalsAndSleepTotals() async throws {
        let nights = try await TagEffect.nights(source: SampleDataSource())
        let lastNight = try #require(nights[today])
        #expect(lastNight[.hrv] != nil)
        #expect(lastNight[.sleep] != nil)
    }
}
