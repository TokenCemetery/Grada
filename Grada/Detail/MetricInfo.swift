import SwiftUI

/// Which blocks a metric's detail screen shows.
enum DetailFamily {
    case total, vital, sleep, training, score
}

/// Where a detail screen was opened: a card for `day`, or for today when `day` is nil.
struct MetricRoute: Hashable {
    let kind: CardKind
    var day: Date?
}

/// Switches to the Calendar tab, optionally with a metric selected. Inside the calendar's day sheet it
/// closes the sheet instead, since the calendar is already showing.
struct OpenCalendarAction {
    let action: (CalendarMetric?) -> Void
    func callAsFunction(_ metric: CalendarMetric? = nil) { action(metric) }
}

extension EnvironmentValues {
    @Entry var openCalendar = OpenCalendarAction { _ in }
    /// The same data source the Home cards use; set once in `RootView`.
    @Entry var healthSource: HealthDataSource = SampleDataSource()
}

extension CardKind {
    /// Workouts Calendar opens the Calendar tab on Training instead of a detail screen.
    var opensCalendar: Bool { self == .last30Days }

    var family: DetailFamily {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .intensityMinutes, .distance, .floors, .standHours, .dayIntensity, .last30Days: .total
        case .heartRate, .restingHeartRate, .hrv, .oxygenSaturation, .respiratoryRate, .wristTemperature, .vo2Max: .vital
        case .sleepDuration, .sleepStages, .sleepNeed, .sleepConsistency: .sleep
        case .lastWorkout, .weeklyTraining, .racePredictor, .trainingReadiness, .loadFocus: .training
        case .healthStatus, .recovery, .resources, .healthAge, .hrvStatus: .score
        }
    }

    /// The Apple Health quantity behind daily-total and vital cards.
    var quantityMetric: QuantityMetric? {
        switch self {
        case .steps: .steps
        case .activeEnergy: .activeEnergy
        case .exerciseMinutes: .exerciseMinutes
        case .distance: .distance
        case .floors: .floors
        case .restingHeartRate, .heartRate: .restingHeartRate
        case .hrv: .hrv
        case .oxygenSaturation: .oxygenSaturation
        case .respiratoryRate: .respiratoryRate
        case .wristTemperature: .wristTemperature
        case .vo2Max, .racePredictor: .vo2Max
        default: nil
        }
    }

    /// The calendar type this metric belongs to.
    var calendarMetric: CalendarMetric {
        switch category {
        case .heart: .health
        case .sleep: .recovery
        case .activity, .training, .history: .training
        case .status: self == .recovery || self == .resources ? .recovery : .health
        }
    }

    /// Scores this metric feeds into.
    var affects: [CardKind] {
        switch self {
        case .hrv: [.healthStatus, .recovery, .hrvStatus]
        case .respiratoryRate: [.healthStatus, .recovery]
        case .restingHeartRate: [.healthStatus, .recovery, .resources, .healthAge, .dayIntensity]
        case .oxygenSaturation, .wristTemperature: [.healthStatus]
        case .heartRate: [.resources, .dayIntensity]
        case .vo2Max: [.racePredictor, .healthAge]
        case .sleepDuration, .sleepStages: [.recovery, .sleepNeed, .resources, .healthAge]
        default: []
        }
    }

    /// Metrics a score is built from.
    var basedOn: [CardKind] {
        switch self {
        case .healthStatus: [.hrv, .restingHeartRate, .respiratoryRate, .oxygenSaturation, .wristTemperature]
        case .recovery: [.hrv, .restingHeartRate, .sleepDuration, .respiratoryRate]
        case .resources: [.heartRate, .restingHeartRate, .sleepStages]
        case .healthAge: [.steps, .sleepDuration, .restingHeartRate, .vo2Max, .exerciseMinutes]
        case .intensityMinutes: [.heartRate, .restingHeartRate, .exerciseMinutes]
        case .dayIntensity: [.heartRate, .restingHeartRate]
        case .hrvStatus: [.hrv]
        default: []
        }
    }

    /// Fixed text for "What it means".
    var explanation: String {
        switch self {
        case .healthStatus:
            "Compares last night's HRV, resting heart rate, breathing rate, blood oxygen and wrist temperature with your own normal range from the last 30 days. Several vitals out of range together often come before illness or follow heavy training, alcohol or poor sleep."
        case .recovery:
            "How ready your body is for strain today. Each input is checked against a published threshold: overnight HRV more than half a standard deviation below your baseline, resting heart rate more than half a standard deviation above it, under 7 hours of sleep, or breathing rate above your normal range. Good: nothing off, a good day to push. Fair: one input off. Poor: two or more; favour easy training and rest."
        case .resources:
            "An estimate of your energy through the day. Sleep and calm rest recharge it; activity and stress, seen as a raised heart rate, drain it. No published method exists for this without beat-to-beat HRV, which iPhone doesn't record through the day, so the charge and drain rates and the colour bands (borrowed from WHOOP) are Grada's own guesses. For measured effort, see Day Intensity."
        case .healthAge:
            "The age your fitness and habits over the last 30 days point to. Each input is compared with a typical adult of your age and sex, or with the guideline, and its link with lifespan from large studies is turned into years: the risk of dying doubles about every 8 years of age. Inputs: VO₂ max and resting heart rate (need your sex in Apple Health), steps, sleep (7–8 hours is the reference) and exercise (150 minutes a week is the reference). Fit people also tend to walk and exercise more, so the inputs overlap and the total is an estimate."
        case .sleepDuration, .sleepStages:
            "Time asleep in the night that ended this morning. Deep sleep restores the body, REM supports memory and mood. Most adults need 7–9 hours."
        case .sleepNeed:
            "How much sleep you need tonight: your sleep goal, or 7 hours, the minimum sleep experts recommend for adults. Sleep debt adds up how far each of the last 14 nights fell short of that. A long night doesn't cancel it: an hour of debt can take several nights of extra sleep to recover, and the bars show each night's shortfall."
        case .sleepConsistency:
            "The Sleep Regularity Index for the last 7 days: how likely you were to be in the same state, asleep or awake, at the same time on consecutive days. 100 means identical days, 0 random ones. In a UK study of 60,000 adults the typical score was 81 and half scored between 74 and 86; the least regular fifth had the highest mortality risk. Green from 81, yellow from 74. Needs sleep records on 5 of the 7 days."
        case .heartRate:
            "Your heart rate through the day. It rises with activity and stress and drops during rest and sleep."
        case .restingHeartRate:
            "Your heart rate at rest. A lower resting heart rate usually means better fitness. A rise above your normal can mean fatigue, stress, illness or alcohol."
        case .hrv:
            "Heart rate variability: the variation between heartbeats. Above your normal usually means you're well recovered. Below can mean stress, illness, alcohol or hard training."
        case .hrvStatus:
            "Your average overnight HRV over the last 7 nights, compared with your baseline from the 2 months before. Balanced: inside your baseline. Unbalanced: above or below it, often after hard training, stress or travel. Low: well below it; favour rest and sleep."
        case .oxygenSaturation:
            "How much oxygen your blood carries. 95–100% is typical; brief dips during sleep are common."
        case .respiratoryRate:
            "Breaths per minute while asleep. It's very stable from night to night, so a rise above your normal is an early sign of illness or strain."
        case .wristTemperature:
            "Your overnight wrist temperature compared with your baseline. Changes follow illness, alcohol, the menstrual cycle and room temperature."
        case .steps:
            "Steps taken during the day. Around 7,000–10,000 a day is linked with better long-term health."
        case .activeEnergy:
            "Calories burned through movement and exercise, on top of what your body uses at rest."
        case .exerciseMinutes:
            "Minutes of brisk activity or more. Health guidelines recommend at least 150 minutes a week."
        case .intensityMinutes:
            "Minutes over the last 7 days with your heart rate at 40–59% of its reserve (moderate) or above (vigorous, counted double). The WHO recommends at least 150 a week. Days without heart rate use exercise minutes instead."
        case .dayIntensity:
            "Your waking time outside workouts by effort, from heart rate as a share of its reserve (max minus resting), in the American College of Sports Medicine's bands: very light below 30%, light 30–39%, moderate 40–59%, vigorous 60% and up. The big number is time at light effort or harder; workouts count in Intensity Minutes instead."
        case .distance:
            "Distance covered walking and running."
        case .floors:
            "Flights of stairs climbed, about 3 metres of height each."
        case .standHours:
            "Hours in which you stood and moved for at least a minute. Breaking up long sitting helps your health."
        case .lastWorkout, .weeklyTraining:
            "Time spent in recorded workouts. Steady weekly volume builds fitness; sudden jumps raise the risk of injury."
        case .vo2Max:
            "The most oxygen your body can use during hard exercise, a key measure of cardio fitness. It changes slowly over weeks of training."
        case .racePredictor:
            "Race times your current VO₂ max points to, assuming you've trained for the distance."
        case .trainingReadiness, .loadFocus:
            "Coming in a later version."
        case .last30Days:
            "Your workouts over the last 30 days."
        }
    }
}

/// A card that opens its detail screen when tapped. Workouts Calendar opens the calendar instead, and a
/// workout card opens that workout.
struct CardLink: View {
    let kind: CardKind
    let snapshot: CardSnapshot?
    /// The day the card shows; nil for today.
    var day: Date?
    @Environment(\.openCalendar) private var openCalendar

    var body: some View {
        if kind.opensCalendar {
            Button { openCalendar(kind.calendarMetric) } label: { CardView(kind: kind, snapshot: snapshot) }
                .buttonStyle(.plain)
        } else if case .workout(let workout) = snapshot?.detail {
            NavigationLink(value: WorkoutRoute(workout: workout)) { CardView(kind: kind, snapshot: snapshot) }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: MetricRoute(kind: kind, day: day)) { CardView(kind: kind, snapshot: snapshot) }
                .buttonStyle(.plain)
        }
    }
}
