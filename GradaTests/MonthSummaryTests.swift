import Foundation
import Testing
@testable import Grada

struct MonthSummaryTests {
    /// Fourteen days alternating around `mean` by `swing`, so the SD is a little over `swing`.
    private func days(_ mean: Double, swing: Double, count: Int = 14) -> [Double] {
        (0..<count).map { mean + ($0.isMultiple(of: 2) ? swing : -swing) }
    }

    @Test func changeBeyondAFifthOfTheDailySpreadCounts() {
        // Steps vary by about ±1,500 a day, so 0.2 × SD is ~330.
        let row = MonthSummary.row(.steps, current: days(9_000, swing: 1_500), previous: days(8_200, swing: 1_500))
        #expect(row.average == 9_000)
        #expect(row.previous == 8_200)
        #expect(row.change == .changed(800))
    }

    @Test func smallChangeIsSteady() {
        let row = MonthSummary.row(.steps, current: days(8_300, swing: 1_500), previous: days(8_200, swing: 1_500))
        #expect(row.change == .steady)
    }

    @Test func tooFewDaysHaveNoAverageOrChange() {
        let row = MonthSummary.row(.restingHeartRate, current: days(55, swing: 2, count: 13), previous: days(58, swing: 2))
        #expect(row.average == nil, "13 days aren't enough")
        #expect(row.previous == 58)
        #expect(row.days == 13)
        #expect(row.change == .unknown)
    }

    @Test func exerciseIsPerWeek() {
        let row = MonthSummary.row(.exercise, current: days(30, swing: 20), previous: days(20, swing: 20))
        #expect(row.average == 210)
        #expect(row.change == .changed(70), "10 more minutes a day is 70 a week, beyond 0.2 × the weekly spread")
    }

    @Test func vo2MaxNeedsTwoReadings() {
        let row = MonthSummary.row(.vo2Max, current: [47, 48], previous: [45, 45.5])
        #expect(row.average == 47.5)
        #expect(row.change == .changed(2.25))
        #expect(MonthSummary.row(.vo2Max, current: [47], previous: [45, 45]).change == .unknown)
    }

    @Test func standardDeviationIsTheSampleOne() {
        #expect(MonthSummary.standardDeviation([2, 4, 4, 4, 5, 5, 7, 9]) == (32.0 / 7).squareRoot())
        #expect(MonthSummary.standardDeviation([1]) == nil)
    }

    /// Sample data covers every day up to today, so this month has one step value per finished day so far: today's
    /// partial count is left out (#163).
    @Test func sampleDataSplitsDaysByMonth() async throws {
        let calendar = Calendar.current
        let summary = try await MonthSummary.load(month: .now, source: SampleDataSource(), calendar: calendar)
        #expect(summary.month == calendar.dateInterval(of: .month, for: .now)?.start)
        #expect(summary.rows.map(\.metric) == MonthSummary.Metric.allCases)
        let steps = try #require(summary.rows.first { $0.metric == .steps })
        #expect(steps.days == calendar.component(.day, from: .now) - 1)
        let heartRate = try #require(summary.rows.first { $0.metric == .restingHeartRate })
        #expect(heartRate.days == calendar.component(.day, from: .now))
        #expect(steps.previous != nil, "Last month is complete")
    }
}
