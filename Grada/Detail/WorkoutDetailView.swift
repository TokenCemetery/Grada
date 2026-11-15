import Charts
import MapKit
import SwiftUI

/// Opens one workout's screen.
struct WorkoutRoute: Hashable {
    let workout: WorkoutSummary
}

/// One workout, the way Garmin and Whoop show it: key stats, training effect, heart rate by zone,
/// splits and route. Sections without data are left out.
struct WorkoutDetailView: View {
    let workout: WorkoutSummary
    @Environment(\.healthSource) private var source
    @State private var detail: WorkoutDetail?
    @State private var maxHeartRate: Double?
    @State private var loaded = false

    private var color: Color { WorkoutColors.color(symbol: workout.symbol) }
    private var end: Date { workout.start.addingTimeInterval(workout.duration) }
    private var units: DistanceUnits { DistanceUnits(sport: workout.name) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                DetailSection(title: "Summary") { stats }
                if let detail, let maxHeartRate, !detail.heartRate.isEmpty {
                    let zones = HeartRateZones.time(detail.heartRate, end: end, maxHeartRate: maxHeartRate)
                    DetailSection(title: "Training Effect") { TrainingEffectView(effect: TrainingEffect.aerobic(timeInZones: zones)) }
                    DetailSection(title: "Heart Rate") {
                        HeartRateChart(readings: detail.heartRate, start: workout.start, end: end, maxHeartRate: maxHeartRate)
                        ZoneRows(seconds: zones, maxHeartRate: maxHeartRate)
                    }
                } else if loaded, detail?.heartRate.isEmpty == false {
                    DetailSection(title: "Heart Rate Zones") {
                        Text("Add your birth date in Apple Health to see heart rate zones and training effect.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    let splits = Splits.make(track: detail.distanceTrack, heartRate: detail.heartRate,
                                             start: workout.start, length: units.splitMeters)
                    if splits.count > 1 {
                        DetailSection(title: "Splits") { SplitsTable(splits: splits, units: units) }
                    }
                    if detail.route.count > 1 {
                        DetailSection(title: "Route") { RouteMap(route: detail.route, color: color) }
                    }
                }
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: workout.id) {
            detail = try? await source.workoutDetail(workout)
            maxHeartRate = (try? await HealthProfile.load(from: source))?.maxHeartRate
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: workout.symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 52, height: 52)
                .background(color.opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name).font(.title2.weight(.semibold))
                Text("\(workout.start.formatted(.dateTime.weekday(.wide).day().month(.wide))), \(workout.start.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var stats: some View {
        let whole = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0))
        var items: [(label: String, value: String)] = [("Duration", SnapshotBuilder.hoursMinutes(workout.duration))]
        if let meters = detail?.distance, meters > 0 {
            items.append(("Distance", units.distance(meters)))
            items.append(units.paceOrSpeed(meters: meters, seconds: workout.duration))
        }
        if let kcal = workout.energyKcal { items.append(("Calories", "\(kcal.formatted(whole)) kcal")) }
        if let average = workout.averageHeartRate { items.append(("Avg Heart Rate", "\(average.formatted(whole)) bpm")) }
        if let highest = detail?.maxHeartRate { items.append(("Max Heart Rate", "\(highest.formatted(whole)) bpm")) }
        if let climb = detail?.elevationGain { items.append(("Elevation Gain", units.elevation(climb))) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 12) {
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Text(item.value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Kilometers, or miles in the US. Swims are measured in meters per 100 m (yards per 100 yd in the US),
/// rides by speed.
struct DistanceUnits {
    let sport: String
    var isUS = Locale.current.measurementSystem == .us
    private var isSwim: Bool { sport == "Swim" }

    /// One split, and the length pace is given for.
    var splitMeters: Double {
        isSwim ? (isUS ? 91.44 : 100) : (isUS ? 1_609.344 : 1_000)
    }
    var splitName: String { isSwim ? (isUS ? "100 yd" : "100 m") : (isUS ? "Mile" : "Km") }
    private var paceName: String { isSwim ? (isUS ? "100yd" : "100m") : (isUS ? "mi" : "km") }

    func distance(_ value: Double) -> String {
        if isSwim {
            return isUS ? "\(Int((value / 0.9144).rounded())) yd" : "\(Int(value.rounded())) m"
        }
        return "\((value / splitMeters).formatted(.number.precision(.fractionLength(2)))) \(isUS ? "mi" : "km")"
    }

    func paceOrSpeed(meters value: Double, seconds: TimeInterval) -> (label: String, value: String) {
        if sport == "Ride" {
            let speed = value / splitMeters / (seconds / 3600)
            return ("Avg Speed", "\(speed.formatted(.number.precision(.fractionLength(1)))) \(isUS ? "mph" : "km/h")")
        }
        return ("Avg Pace", "\(pace(meters: value, seconds: seconds)) /\(paceName)")
    }

    /// Time per split length.
    func pace(meters value: Double, seconds: TimeInterval) -> String {
        Self.clock(seconds / (value / splitMeters))
    }

    func elevation(_ value: Double) -> String {
        isUS ? "\(Int((value * 3.280_84).rounded())) ft" : "\(Int(value.rounded())) m"
    }

    /// "5:42" or "1:02:10".
    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "–" }
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Zone colors as Garmin draws them: grey, blue, green, orange, red.
enum ZoneColors {
    static func color(_ zone: Int) -> Color {
        switch zone {
        case 1: .gray
        case 2: .blue
        case 3: .green
        case 4: .orange
        default: .red
        }
    }
}

/// The effect as a big number and word over a 0–5 track, like Garmin's Training Effect.
private struct TrainingEffectView: View {
    let effect: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(effect.formatted(.number.precision(.fractionLength(1))))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Aerobic · \(TrainingEffect.label(effect))").font(.headline).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { zone in
                            Capsule().fill(ZoneColors.color(zone).opacity(Double(zone) <= effect.rounded(.up) ? 1 : 0.25))
                        }
                    }
                    Capsule()
                        .fill(Color.primary)
                        .frame(width: 4, height: 18)
                        .offset(x: max(0, min(proxy.size.width - 4, proxy.size.width * effect / 5 - 2)))
                }
                .frame(height: 18)
                .frame(maxHeight: .infinity)
            }
            .frame(height: 18)
            Text("How much this workout builds aerobic fitness, from time in each heart rate zone. Estimated on your iPhone.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Aerobic training effect \(effect.formatted(.number.precision(.fractionLength(1)))) of 5, \(TrainingEffect.label(effect))")
    }
}

/// Heart rate across the workout, colored by the zone it was in.
private struct HeartRateChart: View {
    let readings: [TimedValue]
    let start: Date
    let end: Date
    let maxHeartRate: Double

    var body: some View {
        let low = min((readings.map(\.value).min() ?? 60) - 10, maxHeartRate * 0.5)
        let domain = low...max(maxHeartRate, readings.map(\.value).max() ?? 0)
        // Gradient stops at the zone bounds, so the line changes color where it crosses into a zone. The
        // gradient spans the line's own bounds, lowest to highest reading, not the chart's.
        let lowest = readings.map(\.value).min() ?? 0
        let span = max((readings.map(\.value).max() ?? 0) - lowest, 1)
        let stops = [Gradient.Stop(color: ZoneColors.color(1), location: 0)] + HeartRateZones.lowerBounds.enumerated().flatMap { index, bound in
            let location = max(0, min(1, (bound * maxHeartRate - lowest) / span))
            return [Gradient.Stop(color: ZoneColors.color(max(index, 1)), location: location),
                    Gradient.Stop(color: ZoneColors.color(index + 1), location: location)]
        }
        Chart(readings, id: \.date) { reading in
            LineMark(x: .value("Time", reading.date), y: .value("Heart rate", reading.value))
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .foregroundStyle(LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top))
        .chartYScale(domain: domain)
        .chartXScale(domain: start...end)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(height: 160)
        .accessibilityLabel("Heart rate during the workout")
    }
}

/// Time in each zone, zone 5 first, with a bar for its share of the workout.
private struct ZoneRows: View {
    let seconds: [TimeInterval]
    let maxHeartRate: Double

    var body: some View {
        let total = max(seconds.reduce(0, +), 1)
        VStack(spacing: 8) {
            ForEach((1...seconds.count).reversed(), id: \.self) { zone in
                let share = seconds[zone - 1] / total
                let low = Int((HeartRateZones.lowerBounds[zone - 1] * maxHeartRate).rounded())
                let high = zone < seconds.count ? Int((HeartRateZones.lowerBounds[zone] * maxHeartRate).rounded()) - 1 : Int(maxHeartRate.rounded())
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Zone \(zone)").font(.subheadline.weight(.semibold))
                        Text("\(low)–\(high) bpm").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(width: 84, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(.tertiarySystemFill))
                            Capsule().fill(ZoneColors.color(zone)).frame(width: proxy.size.width * share)
                        }
                    }
                    .frame(height: 10)
                    Text(DistanceUnits.clock(seconds[zone - 1]))
                        .font(.subheadline).monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                    Text("\(Int((share * 100).rounded()))%")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Zone \(zone), \(DistanceUnits.clock(seconds[zone - 1])), \(Int((share * 100).rounded())) percent")
            }
        }
        .padding(.top, 8)
    }
}

private struct SplitsTable: View {
    let splits: [Splits.Split]
    let units: DistanceUnits

    var body: some View {
        let fastest = splits.filter { $0.meters >= units.splitMeters }.map { $0.duration }.min()
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text(units.splitName)
                Text("Time")
                Text("Pace").gridColumnAlignment(.trailing)
                Text("Avg HR").gridColumnAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            Divider()
            ForEach(splits.indices, id: \.self) { index in
                let split = splits[index]
                let isPartial = split.meters < units.splitMeters
                GridRow {
                    Text(isPartial ? (split.meters / units.splitMeters).formatted(.number.precision(.fractionLength(2))) : "\(index + 1)")
                    Text(DistanceUnits.clock(split.duration))
                    Text(units.pace(meters: split.meters, seconds: split.duration))
                        .fontWeight(split.duration == fastest && !isPartial ? .bold : .regular)
                    Text(split.averageHeartRate.map { "\(Int($0.rounded()))" } ?? "–")
                }
                .font(.subheadline).monospacedDigit()
            }
        }
    }
}

/// The GPS route as a line on a map, start and finish marked.
private struct RouteMap: View {
    let route: [RoutePoint]
    let color: Color

    var body: some View {
        let coordinates = route.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        Map(initialPosition: .automatic, interactionModes: []) {
            MapPolyline(coordinates: coordinates).stroke(color, lineWidth: 4)
            if let first = coordinates.first {
                Annotation("Start", coordinate: first) {
                    Circle().fill(.green).stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                }
            }
            if let last = coordinates.last {
                Annotation("Finish", coordinate: last) {
                    Circle().fill(.red).stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityLabel("Route map")
    }
}
