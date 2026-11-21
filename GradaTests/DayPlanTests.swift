import Foundation
import Testing
@testable import Grada

struct DayPlanTests {
    private let today = Date(timeIntervalSince1970: 1_794_787_200)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// One suite per test: Swift Testing runs tests in parallel, and a shared suite gets cleared mid-test.
    private func freshDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "DayPlanTests.\(name)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func readiness(_ rating: DayRating) -> TrainingReadiness.Result {
        TrainingReadiness.Result(rating: rating, measured: 4, inRange: 2, reason: "Poor sleep")
    }

    private func workout(minutes: Double, heartRate: Double?) -> WorkoutSummary {
        WorkoutSummary(id: UUID().uuidString, start: today.addingTimeInterval(8 * 3600), duration: minutes * 60, name: "Run",
                       symbol: "figure.run", energyKcal: nil, averageHeartRate: heartRate)
    }

    // MARK: - Training suggestion

    @Test func bodyWarningsComeFirst() {
        var input = TrainingPlan.Input()
        input.readiness = readiness(.good)
        input.bodyWarning = "Resting heart rate is up."
        input.workouts = 0
        input.workoutsGoal = 3
        #expect(TrainingPlan.suggest(input) == TrainingPlan.Suggestion(level: .easy, reason: "Resting heart rate is up.", isPriority: true),
                "Easy even with readiness high and workouts behind")
        input.readiness = readiness(.poor)
        #expect(TrainingPlan.suggest(input).level == .rest, "A warning with low readiness is a rest day")
    }

    @Test func loadAndRecoveryHoldTrainingBack() {
        var input = TrainingPlan.Input()
        input.readiness = readiness(.good)
        input.loadRatio = Strain.dangerRatio
        #expect(TrainingPlan.suggest(input).level == .rest)
        input.loadRatio = 1.4
        #expect(TrainingPlan.suggest(input).level == .easy, "Above the sweet spot")
        input.loadRatio = 1
        input.recoveredAt = today.addingTimeInterval(18 * 3600)
        #expect(TrainingPlan.suggest(input).level == .easy, "Still recovering")
        input.recoveredAt = nil
        input.readiness = readiness(.poor)
        #expect(TrainingPlan.suggest(input).level == .easy)
    }

    @Test func weeklyGoalBehindMakesTrainingTheFocus() {
        var input = TrainingPlan.Input()
        input.readiness = readiness(.good)
        input.workouts = 1
        input.workoutsGoal = 3
        let hard = TrainingPlan.suggest(input)
        #expect(hard.level == .hard && hard.isPriority)
        #expect(hard.reason == "Training readiness is high. 1 of 3 workouts in the last 7 days.")
        input.readiness = readiness(.fair)
        #expect(TrainingPlan.suggest(input).level == .moderate)

        input.workouts = 3
        input.intensityMinutes = 100
        input.intensityGoal = 150
        let intensity = TrainingPlan.suggest(input)
        #expect(intensity.isPriority, "Intensity minutes behind count too")
        #expect(intensity.reason == "100 of 150 intensity minutes in the last 7 days.")
    }

    @Test func goalsMetKeepsTheSessionABonus() {
        var input = TrainingPlan.Input()
        input.readiness = readiness(.good)
        input.workouts = 3
        input.workoutsGoal = 3
        let met = TrainingPlan.suggest(input)
        #expect(met.level == .moderate && !met.isPriority, "No hard session the week doesn't need")
        input.readiness = nil
        #expect(TrainingPlan.suggest(input).level == .easy)
    }

    @Test func noWeeklyDataIsNeverCalledMet() {
        var input = TrainingPlan.Input()
        input.readiness = readiness(.good)
        input.intensityGoal = 150
        let unknown = TrainingPlan.suggest(input)
        #expect(unknown.reason == "A comfortable session keeps you moving.", "No workouts goal and no intensity minutes")
        #expect(!unknown.isPriority)
        #expect(ReportText.tomorrow(workouts: 0, workoutsGoal: nil, intensityMinutes: nil, intensityGoal: 150) == nil)
    }

    // MARK: - Follow-up

    @Test func easyDayHoldsWithoutHardWorkouts() {
        #expect(FollowUp.training(.easy, workouts: [], maxHeartRate: 190) == .followed)
        #expect(FollowUp.training(.rest, workouts: [workout(minutes: 40, heartRate: 130)], maxHeartRate: 190) == .followed)
        #expect(FollowUp.training(.easy, workouts: [workout(minutes: 40, heartRate: 165)], maxHeartRate: 190) == .missed,
                "Average in the threshold zone")
        #expect(FollowUp.training(.easy, workouts: [workout(minutes: 40, heartRate: nil)], maxHeartRate: 190) == nil,
                "Can't tell without heart rate")
        #expect(FollowUp.training(.easy, workouts: [workout(minutes: 40, heartRate: 130)], maxHeartRate: nil) == nil)
    }

    @Test func sessionNeedsAWorkoutLongEnough() {
        #expect(FollowUp.training(.hard, workouts: [workout(minutes: 45, heartRate: nil)], maxHeartRate: nil) == .followed)
        #expect(FollowUp.training(.moderate, workouts: [workout(minutes: 10, heartRate: nil)], maxHeartRate: nil) == .missed)
        #expect(FollowUp.training(.moderate, workouts: [], maxHeartRate: nil) == .missed)
    }

    @Test func bedtimeAndStepsFollowUps() {
        let planned = today.addingTimeInterval(22.5 * 3600)
        #expect(FollowUp.bedtime(planned: planned, actual: planned.addingTimeInterval(15 * 60)) == .followed, "Within the leeway")
        #expect(FollowUp.bedtime(planned: planned, actual: planned.addingTimeInterval(16 * 60)) == .missed)
        #expect(FollowUp.bedtime(planned: planned, actual: nil) == nil, "No night, nothing said")
        #expect(FollowUp.steps(goal: 8_000, steps: 8_000) == .followed)
        #expect(FollowUp.steps(goal: 8_000, steps: 7_999) == .missed)
        #expect(FollowUp.steps(goal: 8_000, steps: nil) == nil)
    }

    // MARK: - Saved plans

    @Test func morningPlanIsSavedOnceAndBedtimeEachTime() throws {
        let defaults = try freshDefaults()
        let first = DayPlanStore.saveMorning(DayPlan(focus: .steps, training: .easy, stepsGoal: 8_000), for: today,
                                             defaults: defaults, calendar: calendar)
        let second = DayPlanStore.saveMorning(DayPlan(focus: .training, training: .hard), for: today,
                                              defaults: defaults, calendar: calendar)
        #expect(second == first, "A report reloaded later in the day keeps the morning's plan")
        let bedtime = today.addingTimeInterval(23 * 3600)
        DayPlanStore.saveBedtime(today.addingTimeInterval(22 * 3600), for: today, defaults: defaults, calendar: calendar)
        DayPlanStore.saveBedtime(bedtime, for: today, defaults: defaults, calendar: calendar)
        let saved = try #require(DayPlanStore.plan(for: today, defaults: defaults, calendar: calendar))
        #expect(saved.bedtime == bedtime && saved.focus == .steps)
    }

    @Test func aLaterBodyWarningReplacesTheMorningPlanOnce() throws {
        let defaults = try freshDefaults()
        DayPlanStore.saveMorning(DayPlan(focus: .steps, training: .hard, bodyWarning: false), for: today,
                                 defaults: defaults, calendar: calendar)
        let warned = DayPlanStore.saveMorning(DayPlan(focus: .training, training: .easy, bodyWarning: true), for: today,
                                              defaults: defaults, calendar: calendar)
        #expect(warned.training == .easy && warned.focus == .training, "Last night's HRV arrived later and was low")
        let again = DayPlanStore.saveMorning(DayPlan(focus: .training, training: .rest, bodyWarning: true), for: today,
                                             defaults: defaults, calendar: calendar)
        #expect(again == warned, "Only the first warning replaces it")
    }

    @Test func oldPlansAreDropped() throws {
        let defaults = try freshDefaults()
        for offset in 0..<10 {
            DayPlanStore.saveBedtime(today, for: today.addingTimeInterval(Double(offset) * 86_400), defaults: defaults, calendar: calendar)
        }
        #expect(DayPlanStore.plan(for: today, defaults: defaults, calendar: calendar) == nil)
        #expect(DayPlanStore.plan(for: today.addingTimeInterval(9 * 86_400), defaults: defaults, calendar: calendar) != nil)
        #expect(DayPlanStore.plan(for: today.addingTimeInterval(3 * 86_400), defaults: defaults, calendar: calendar) != nil,
                "The last \(DayPlanStore.keptDays) days stay")
    }

    @Test func followUpOrderPutsTheFocusFirst() {
        #expect(DailyReport.followUpOrder(.training) == [.training, .bedtime])
        #expect(DailyReport.followUpOrder(nil) == [.bedtime])
    }

    // MARK: - Text

    @Test func wordingStaysAllDayAndChangesTheNext() {
        let options = ["A", "B"]
        let morning = ReportText.pick(options, day: today, calendar: calendar)
        #expect(ReportText.pick(options, day: today.addingTimeInterval(20 * 3600), calendar: calendar) == morning)
        #expect(ReportText.pick(options, day: today.addingTimeInterval(86_400), calendar: calendar) != morning)
    }

    @Test func resourcesRecapNamesTheBiggestDrainsAndGains() {
        let recap = ReportText.resources([.workout: -30, .awake: -22, .raisedHeartRate: -5, .sleep: 40, .rest: 0.4])
        #expect(recap == "What drained you today: Workouts (-30%) and Being awake (-22%). What recharged you: Sleep (+40%).")
        #expect(ReportText.resources([.rest: 0.3]) == nil, "Nothing worth saying")
    }

    @Test func tomorrowSaysWhatTheWeekStillNeeds() {
        #expect(ReportText.tomorrow(workouts: 1, workoutsGoal: 3, intensityMinutes: nil, intensityGoal: 150)
                == "Tomorrow: your week still needs 2 more workouts. A good night tonight sets them up.")
        #expect(ReportText.tomorrow(workouts: 3, workoutsGoal: 3, intensityMinutes: 120, intensityGoal: 150)
                == "Tomorrow: your week still needs 30 intensity minutes. A good night tonight sets them up.")
        #expect(ReportText.tomorrow(workouts: 3, workoutsGoal: 3, intensityMinutes: 160, intensityGoal: 150)?
            .hasSuffix("goals are met, so it can be whatever feels right.") == true)
    }

    // MARK: - Check-in

    @Test func checkInOnlyWhenTheGoalIsStillReachable() {
        #expect(CheckIn.walkMinutes(left: 0) == nil, "Goal reached: silent")
        #expect(CheckIn.walkMinutes(left: 2_450) == 25)
        #expect(CheckIn.walkMinutes(left: 9_001) == nil, "Over \(CheckIn.longestWalkMinutes) minutes: waits for tomorrow")
    }
}
