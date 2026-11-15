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
    /// Last 30 days opens the Calendar tab instead of a detail screen.
    var opensCalendar: Bool { self == .last30Days }

    var family: DetailFamily {
        switch self {
        case .steps, .activeEnergy, .exerciseMinutes, .intensityMinutes, .distance, .floors, .standHours, .last30Days: .total
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

    /// The calendar colouring for this metric, if the calendar has one.
    var calendarMetric: CalendarMetric? {
        switch self {
        case .healthStatus: .healthStatus
        case .sleepDuration, .sleepStages: .sleep
        case .steps: .steps
        case .hrv: .hrv
        case .restingHeartRate: .restingHeartRate
        default: nil
        }
    }

    /// Scores this metric feeds into.
    var affects: [CardKind] {
        switch self {
        case .hrv: [.healthStatus, .recovery, .hrvStatus]
        case .respiratoryRate: [.healthStatus, .recovery]
        case .restingHeartRate: [.healthStatus, .recovery, .resources, .healthAge]
        case .oxygenSaturation, .wristTemperature: [.healthStatus]
        case .heartRate: [.resources]
        case .vo2Max: [.racePredictor, .healthAge]
        case .sleepDuration, .sleepStages: [.recovery, .sleepNeed, .resources, .healthAge]
        case .sleepNeed: [.recovery]
        case .sleepConsistency: [.healthAge]
        default: []
        }
    }

    /// Metrics a score is built from.
    var basedOn: [CardKind] {
        switch self {
        case .healthStatus: [.hrv, .restingHeartRate, .respiratoryRate, .oxygenSaturation, .wristTemperature]
        case .recovery: [.hrv, .restingHeartRate, .sleepDuration, .sleepNeed, .respiratoryRate]
        case .resources: [.heartRate, .restingHeartRate, .sleepStages]
        case .healthAge: [.steps, .sleepDuration, .sleepConsistency, .restingHeartRate, .vo2Max, .exerciseMinutes]
        case .intensityMinutes: [.heartRate, .restingHeartRate, .exerciseMinutes]
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
            "How ready your body is for strain today, from overnight HRV and heart rate against your baseline, sleep against your sleep need, and breathing rate. High: a good day to push. Low: favour easy training and rest."
        case .resources:
            "An estimate of your energy through the day. Sleep and calm rest recharge it; activity and stress, seen as a raised heart rate, drain it."
        case .healthAge:
            "The age your habits and fitness point to, from steps, sleep, resting heart rate, VO₂ max and exercise over the last 30 days. Pace shows whether it's moving faster or slower than time."
        case .sleepDuration, .sleepStages:
            "Time asleep in the night that ended this morning. Deep sleep restores the body, REM supports memory and mood. Most adults need 7–9 hours."
        case .sleepNeed:
            "How much sleep you need tonight: your baseline, plus part of any sleep debt, plus extra after a hard training day."
        case .sleepConsistency:
            "How regular your bed and wake times were over the last 4 nights. A steady rhythm improves sleep quality, even on weekends."
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
            "Minutes this week with your heart rate at 40–59% of its reserve (moderate) or above (vigorous, counted double). The WHO recommends at least 150 a week. Days without heart rate use exercise minutes instead."
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

/// A card that opens its detail screen when tapped; Last 30 days opens the calendar instead.
struct CardLink: View {
    let kind: CardKind
    let snapshot: CardSnapshot?
    /// The day the card shows; nil for today.
    var day: Date?
    @Environment(\.openCalendar) private var openCalendar

    var body: some View {
        if kind.opensCalendar {
            Button { openCalendar() } label: { CardView(kind: kind, snapshot: snapshot) }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: MetricRoute(kind: kind, day: day)) { CardView(kind: kind, snapshot: snapshot) }
                .buttonStyle(.plain)
        }
    }
}
