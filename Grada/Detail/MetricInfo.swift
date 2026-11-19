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
        case .sleepDuration, .sleepStages, .sleepNeed, .sleepConsistency, .sleepScore: .sleep
        case .lastWorkout, .weeklyTraining, .strain, .recoveryTime, .racePredictor, .trainingReadiness, .loadFocus: .training
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
        case .heartRate: [.resources, .dayIntensity, .strain]
        case .vo2Max: [.racePredictor, .healthAge]
        case .sleepDuration, .sleepStages: [.recovery, .sleepNeed, .sleepScore, .resources, .healthAge]
        case .sleepNeed, .sleepConsistency: [.sleepScore]
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
        case .sleepScore: [.sleepStages, .sleepNeed, .sleepConsistency]
        case .strain: [.heartRate]
        case .loadFocus: [.lastWorkout]
        case .trainingReadiness: [.sleepScore, .recoveryTime, .hrvStatus, .strain, .sleepNeed]
        case .recoveryTime: [.lastWorkout, .recovery]
        default: []
        }
    }

    /// The imported data a card is built from, for "Data from" on its detail screen. Heart rate through
    /// the day is read live from Apple Health rather than imported, so it has no stored origin.
    var dataKinds: [DataKind] {
        var kinds: [DataKind] = switch self {
        case .heartRate: []
        case .sleepDuration, .sleepStages, .sleepNeed, .sleepConsistency: [.sleep]
        case .standHours: [.standHours]
        case .lastWorkout, .weeklyTraining: [.workouts]
        case .recovery, .hrvStatus, .healthStatus: [.overnightHRV]
        default: quantityMetric.map { [DataKind($0)] } ?? []
        }
        for kind in basedOn.flatMap(\.dataKinds) where !kinds.contains(kind) { kinds.append(kind) }
        return kinds
    }

    /// The cards a detail screen links to: what this score is based on, or else what this metric affects.
    /// Retired inputs link to their replacement, which also lists what the retired card affected.
    var related: (title: String, kinds: [CardKind]) {
        let shown = { (kinds: [CardKind]) -> [CardKind] in
            var seen: Set<CardKind> = [self]
            return kinds.compactMap { $0.isRetired ? $0.replacement : $0 }
                .filter { ($0 == .healthStatus || CardKind.gallery.contains($0)) && seen.insert($0).inserted }
        }
        let basedOn = shown(basedOn)
        if !basedOn.isEmpty { return (String(localized: "Based on"), basedOn) }
        let retired = CardKind.allCases.filter { $0.replacement == self }
        return (String(localized: "Affects"), shown(affects + retired.flatMap(\.affects)))
    }

    /// Fixed text for "What it means".
    var explanation: String {
        switch self {
        case .healthStatus:
            String(localized: "Compares last night's HRV, resting heart rate, breathing rate, blood oxygen and wrist temperature with your own normal range from the last 30 days. Several vitals out of range together often come before illness or follow heavy training, alcohol or poor sleep.")
        case .recovery:
            String(localized: "How ready your body is for strain today. Each input is checked against a published threshold: overnight HRV more than half a standard deviation below your baseline, resting heart rate more than half a standard deviation above it, under 7 hours of sleep, or breathing rate above your normal range. Good: nothing off, a good day to push. Fair: one input off. Poor: two or more; favour easy training and rest.")
        case .resources:
            String(localized: "An estimate of your energy through the day. Sleep and calm rest recharge it; activity and stress, seen as a raised heart rate, drain it. No published method exists for this without beat-to-beat HRV, which iPhone doesn't record through the day, so the charge and drain rates and the colour bands (borrowed from WHOOP) are Grada's own guesses. For measured effort, see Day Intensity.")
        case .healthAge:
            String(localized: "The age your fitness and habits over the last 30 days point to. Each input is compared with a typical adult of your age and sex, or with the guideline, and its link with lifespan from large studies is turned into years: the risk of dying doubles about every 8 years of age. Inputs: VO₂ max and resting heart rate (need your sex in Apple Health), steps, sleep (7–8 hours is the reference) and exercise (150 minutes a week is the reference). Fit people also tend to walk and exercise more, so the inputs overlap and the total is an estimate.")
        case .sleepDuration, .sleepStages:
            String(localized: "Time asleep in the night that ended this morning. Deep sleep restores the body, REM supports memory and mood. Most adults need 7–9 hours.")
        case .sleepNeed:
            String(localized: "How much sleep you need tonight: your sleep goal, or 7 hours, the minimum sleep experts recommend for adults of any age. Sleep debt adds up how far each of the last 14 nights fell short of that. A long night doesn't cancel it: an hour of debt can take several nights of extra sleep to recover, and the bars show each night's shortfall.")
        case .sleepConsistency:
            String(localized: "The Sleep Regularity Index for the last 7 days: how likely you were to be in the same state, asleep or awake, at the same time on consecutive days. 100 means identical days, 0 random ones. In a UK study of 60,000 adults the typical score was 81 and half scored between 74 and 86; the least regular fifth had the highest mortality risk. Green from 81, yellow from 74. Needs sleep records on 5 of the 7 days.")
        case .sleepScore:
            String(localized: "How well you slept last night: the share of good-sleep indicators the night met, each counting the same. Four come from the National Sleep Foundation's expert consensus: asleep at least 85% of the time from falling asleep to waking up, no more than 20 minutes awake in between (30 from age 65), and at most one awakening longer than 5 minutes (two from age 65). The other two are enough sleep for your Sleep Need and a Sleep Regularity Index above the least regular quarter of adults. The experts found no agreement on sleep stages as a sign of good sleep, so they aren't scored. Green with every indicator met, yellow with one missed, red with two or more. Needs sleep stages from your watch and sleep records on 5 of the last 7 days.")
        case .heartRate:
            String(localized: "Your heart rate through the day. It rises with activity and stress and drops during rest and sleep.")
        case .restingHeartRate:
            String(localized: "Your heart rate at rest. A lower resting heart rate usually means better fitness. A rise above your normal can mean fatigue, stress, illness or alcohol.")
        case .hrv:
            String(localized: "Heart rate variability: the variation between heartbeats. Above your normal usually means you're well recovered. Below can mean stress, illness, alcohol or hard training.")
        case .hrvStatus:
            String(localized: "Your average overnight HRV over the last 7 nights, compared with your baseline from the 2 months before. Balanced: inside your baseline. Unbalanced: above or below it, often after hard training, stress or travel. Low: well below it; favour rest and sleep.")
        case .oxygenSaturation:
            String(localized: "How much oxygen your blood carries. 95–100% is typical; brief dips during sleep are common.")
        case .respiratoryRate:
            String(localized: "Breaths per minute while asleep. It's very stable from night to night, so a rise above your normal is an early sign of illness or strain.")
        case .wristTemperature:
            String(localized: "Your overnight wrist temperature compared with your baseline. Changes follow illness, alcohol, the menstrual cycle and room temperature.")
        case .steps:
            String(localized: "Steps taken during the day. Around 7,000–10,000 a day is linked with better long-term health.")
        case .activeEnergy:
            String(localized: "Calories burned through movement and exercise, on top of what your body uses at rest.")
        case .exerciseMinutes:
            String(localized: "Minutes of brisk activity or more. Health guidelines recommend at least 150 minutes a week.")
        case .intensityMinutes:
            String(localized: "Minutes over the last 7 days with your heart rate at 40–59% of its reserve (moderate) or above (vigorous, counted double). The WHO recommends at least 150 moderate or 75 vigorous minutes a week, so a vigorous minute counts as two. Days without heart rate use exercise minutes instead.")
        case .dayIntensity:
            String(localized: "Your waking time outside workouts by effort, from heart rate as a share of its reserve (max minus resting), in the American College of Sports Medicine's bands: very light below 30%, light 30–39%, moderate 40–59%, vigorous 60% and up. The big number is time at light effort or harder; workouts count in Intensity Minutes instead.")
        case .distance:
            String(localized: "Distance covered walking and running.")
        case .floors:
            String(localized: "Flights of stairs climbed, about 3 metres of height each.")
        case .standHours:
            String(localized: "Hours in which you stood and moved for at least a minute. Breaking up long sitting helps your health.")
        case .lastWorkout, .weeklyTraining:
            String(localized: "Time spent in recorded workouts. Steady weekly volume builds fitness; sudden jumps raise the risk of injury.")
        case .strain:
            String(localized: "Today's training load: minutes with your heart rate in each zone (50–60% of max counts 1 per minute, up to 90% and above counting 5), Edwards' TRIMP, over the whole day, so workouts and busy days both count. The ratio compares your average daily load over the last 7 days with the last 28. In studies of athletes, injuries were least common at ratios of 0.8–1.3 (green) and most common from 1.5 (red); below 0.8 or between 1.3 and 1.5 is yellow. Those studies were of team sports and the link is debated, so read the ratio as how fast your load is changing. Needs 21 of the last 28 days with heart rate.")
        case .recoveryTime:
            String(localized: "Hours until your heart's rest-and-recover system is back to normal after your recent workouts. A review of studies on heart rate variability after exercise (Stanley, Peake and Buchheit 2013) found it recovers within 24 hours after easy exercise, in 24–48 hours after threshold effort and in at least 48 hours after hard effort; the length of the session mattered less. Each workout counts by its average heart rate: easy below 82% of your max heart rate (24 hours), threshold from 82% (36 hours, the middle of its range) and hard from 88% (48 hours). Workouts without heart rate count as easy. Your overnight HRV and resting heart rate measure that recovery directly: if you woke up still recovering and this morning's Recovery isn't Good, recovery runs on to tomorrow morning. Fitter people recover faster, so treat the hours as a guide.")
        case .vo2Max:
            String(localized: "The most oxygen your body can use during hard exercise, a key measure of cardio fitness. It changes slowly over weeks of training. The zones compare it with lab-measured VO₂ max of adults your age and sex in the US FRIEND registry: Poor below the bottom quarter, Fair up to the middle, Good from the middle, Excellent from the top quarter and Superior from the top tenth.")
        case .racePredictor:
            String(localized: "Race times your current VO₂ max points to, assuming you've trained for the distance.")
        case .trainingReadiness:
            String(localized: "Whether today suits hard training, from the same inputs Garmin uses, each checked against the threshold its own card uses: last night's Sleep Score (off when red), Recovery Time (off while it's still counting down), HRV Status (off when not Balanced), the acute:chronic load ratio from Strain (off above 1.3, where studies saw injuries rise), and your last 3 nights against your Sleep Need. Garmin also uses all-day stress, which needs beat-to-beat heart rate variability that iPhone doesn't record, so it's left out. Garmin doesn't publish how it weighs these and no study has tested a weighting, so each counts the same. High: nothing off. Moderate: one off. Low: two or more; favour easy training. Needs at least 3 inputs.")
        case .loadFocus:
            String(localized: "How your workout time over the last 4 weeks splits by intensity, from heart rate as a share of your max: low below 82%, threshold from 82% and high from 88%, the boundaries between the first and second ventilatory thresholds in Seiler's zones. Studies of successful endurance athletes found about 80% of their training at low intensity and most of the rest at high intensity, so green means at least 80% low. Counted by heart rate time rather than sessions, the low share is higher still: elite skiers spent 96% of their training time at low intensity, though 87% of their sessions were low. Too little low-intensity work, often from making every session moderately hard, shows yellow.")
        case .last30Days:
            String(localized: "Your workouts over the last 30 days.")
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
