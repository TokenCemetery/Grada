import Foundation
import Testing
@testable import DailyHealth

@MainActor
struct HomeLayoutTests {
    @Test func squaresPairUpAndWideCardsFillARow() {
        let rows = HomeLayout.rows(for: [.sleepStages, .restingHeartRate, .hrv, .steps, .lastWorkout, .activeEnergy])
        #expect(rows == [[.sleepStages], [.restingHeartRate, .hrv], [.steps], [.lastWorkout], [.activeEnergy]])
    }

    @Test func defaultSetLayout() {
        let rows = HomeLayout.rows(for: CardKind.defaultSet)
        #expect(rows == [[.sleepStages], [.restingHeartRate, .hrv], [.steps, .activeEnergy], [.lastWorkout], [.last30Days]])
    }
}

@MainActor
struct BaselineTests {
    @Test func calibratingUntilSevenDays() {
        #expect(Baseline.normalRange(history: [50, 52, 51, 49, 50, 51], minimumHalfWidth: 1) == nil)
    }

    @Test func rangeIsMeanPlusMinusTwoStandardDeviations() throws {
        let range = try #require(Baseline.normalRange(history: [48, 50, 52, 48, 50, 52, 50], minimumHalfWidth: 0))
        // Mean 50, sample SD ≈ 1.633.
        #expect(abs(range.lowerBound - 46.73) < 0.01)
        #expect(abs(range.upperBound - 53.27) < 0.01)
    }

    @Test func rangeNeverNarrowerThanMinimum() throws {
        let range = try #require(Baseline.normalRange(history: Array(repeating: 54, count: 10), minimumHalfWidth: 3))
        #expect(range == 51...57)
    }
}

@MainActor
struct SnapshotBuilderTests {
    @Test func durationFormatting() {
        #expect(SnapshotBuilder.hoursMinutes(7 * 3600 + 42 * 60) == "7h 42m")
        #expect(SnapshotBuilder.hoursMinutes(45 * 60) == "45m")
        #expect(SnapshotBuilder.signedMinutes(18 * 60) == "+18m")
        #expect(SnapshotBuilder.signedMinutes(-75 * 60) == "−1h 15m")
    }

    @Test func everyCardBuildsFromSampleData() async throws {
        let builder = SnapshotBuilder(source: SampleDataSource())
        for kind in CardKind.allCases {
            let snapshot = try await builder.snapshot(for: kind)
            #expect(snapshot.value != nil, "\(kind) has no value")
        }
    }
}
