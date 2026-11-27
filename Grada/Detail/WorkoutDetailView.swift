import Charts
import MapKit
import SwiftUI

/// Opens one workout's screen.
struct WorkoutRoute: Hashable {
    let workout: WorkoutSummary
}

/// One workout, the way Garmin and Whoop show it: key stats, training load, heart rate by zone,
/// splits and route. Sections without data are left out.
struct WorkoutDetailView: View {
    let workout: WorkoutSummary
    @Environment(\.healthSource) private var source
    @State private var detail: WorkoutDetail?
    @AppStorage(SettingsKey.colorBlindPalette) private var colorBlind = false
    @State private var maxHeartRate: Double?
    @State private var loaded = false

    private var color: Color { WorkoutColors.color(symbol: workout.symbol) }
    private var end: Date { workout.start.addingTimeInterval(workout.duration) }
    private var units: DistanceUnits { DistanceUnits(symbol: workout.symbol) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                DetailSection(title: String(localized: "Summary")) { stats }
                if let effort = detail?.effort {
                    DetailSection(title: String(localized: "Effort")) { EffortView(effort: effort, duration: workout.duration) }
                }
                if let detail, let maxHeartRate, !detail.heartRate.isEmpty {
                    let zones = HeartRateZones.time(detail.heartRate, end: end, maxHeartRate: maxHeartRate)
                    DetailSection(title: String(localized: "Training Load")) { TrainingLoadView(timeInZones: zones) }
                    DetailSection(title: String(localized: "Heart Rate")) {
                        HeartRateChart(readings: detail.heartRate, start: workout.start, end: end, maxHeartRate: maxHeartRate)
                        ZoneRows(seconds: zones, maxHeartRate: maxHeartRate)
                    }
                } else if loaded, detail?.heartRate.isEmpty == false {
                    DetailSection(title: String(localized: "Heart Rate Zones")) {
                        Text("Add your birth date in Apple Health to see heart rate zones and training load.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                if let detail {
                    let splits = Splits.make(track: detail.distanceTrack, heartRate: detail.heartRate,
                                             start: workout.start, length: units.splitMeters)
                    if splits.count > 1 {
                        DetailSection(title: String(localized: "Splits")) { SplitsTable(splits: splits, units: units) }
                    }
                    if detail.route.count > 1 {
                        DetailSection(title: String(localized: "Route")) { RouteMap(route: detail.route, color: color) }
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
        var items: [(label: String, value: String)] = [(String(localized: "Duration"), SnapshotBuilder.hoursMinutes(workout.duration))]
        if let meters = detail?.distance, meters > 0 {
            items.append((String(localized: "Distance"), units.distance(meters)))
            items.append(units.paceOrSpeed(meters: meters, seconds: workout.duration))
        }
        if let kcal = workout.energyKcal { items.append((String(localized: "Calories"), String(localized: "\(kcal.formatted(whole)) kcal", comment: "Energy in kilocalories"))) }
        if let average = workout.averageHeartRate { items.append((String(localized: "Avg Heart Rate"), String(localized: "\(average.formatted(whole)) bpm", comment: "Heart rate in beats per minute"))) }
        if let highest = detail?.maxHeartRate { items.append((String(localized: "Max Heart Rate"), String(localized: "\(highest.formatted(whole)) bpm", comment: "Heart rate in beats per minute"))) }
        if let climb = detail?.elevationGain { items.append((String(localized: "Elevation Gain"), units.elevation(climb))) }
        // Colored like the Heart Rate Recovery card: orange at or below Cole's cut-off (#131).
        var colors: [String: Color] = [:]
        if let recovery = detail?.heartRateRecovery {
            let label = String(localized: "HR Recovery", comment: "Heart rate fall in the minute after the workout")
            items.append((label, String(localized: "\(recovery.formatted(whole)) bpm", comment: "Heart rate in beats per minute")))
            colors[label] = HeartRateRecovery.rating(recovery).text(colorBlind: colorBlind)
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), alignment: .leading, spacing: 12) {
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Text(item.value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        .foregroundStyle(colors[item.label] ?? .primary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Kilometers, or miles in the US. Swims are measured in meters per 100 m (yards per 100 yd in the US),
/// rides by speed.
struct DistanceUnits {
    /// The workout's SF Symbol, which names the sport in any language; stored names follow the import's language.
    let symbol: String
    var isUS = Locale.current.measurementSystem == .us
    private var isSwim: Bool { symbol == "figure.pool.swim" }

    /// One split, and the length pace is given for.
    var splitMeters: Double {
        isSwim ? (isUS ? 91.44 : 100) : (isUS ? 1_609.344 : 1_000)
    }
    var splitName: String { isSwim
            ? (isUS ? String(localized: "100 yd", comment: "Split length: 100 yards") : String(localized: "100 m", comment: "Split length: 100 meters"))
            : (isUS ? String(localized: "Mile", comment: "Split length: one mile") : String(localized: "Km", comment: "Split length: one kilometer")) }
    private var paceName: String { isSwim
            ? (isUS ? String(localized: "100yd", comment: "Pace unit: per 100 yards") : String(localized: "100m", comment: "Pace unit: per 100 meters"))
            : (isUS ? String(localized: "mi", comment: "Unit: miles") : String(localized: "km", comment: "Unit: kilometers")) }

    func distance(_ value: Double) -> String {
        if isSwim {
            return isUS
                ? String(localized: "\(Int((value / 0.9144).rounded())) yd", comment: "Distance in yards")
                : String(localized: "\(Int(value.rounded())) m", comment: "Distance in meters")
        }
        let miles = (value / splitMeters).formatted(.number.precision(.fractionLength(2)))
        return isUS
            ? String(localized: "\(miles) mi", comment: "Distance in miles")
            : String(localized: "\(miles) km", comment: "Distance in kilometers")
    }

    func paceOrSpeed(meters value: Double, seconds: TimeInterval) -> (label: String, value: String) {
        if symbol == "figure.outdoor.cycle" {
            let speed = value / splitMeters / (seconds / 3600)
            let formatted = speed.formatted(.number.precision(.fractionLength(1)))
            return (String(localized: "Avg Speed"),
                    isUS ? String(localized: "\(formatted) mph", comment: "Speed in miles per hour")
                         : String(localized: "\(formatted) km/h", comment: "Speed in kilometers per hour"))
        }
        return (String(localized: "Avg Pace"), String(localized: "\(pace(meters: value, seconds: seconds)) /\(paceName)", comment: "Pace: time per distance unit, e.g. 5:00 /km"))
    }

    /// Time per split length.
    func pace(meters value: Double, seconds: TimeInterval) -> String {
        Self.clock(seconds / (value / splitMeters))
    }

    func elevation(_ value: Double) -> String {
        isUS
            ? String(localized: "\(Int((value * 3.280_84).rounded())) ft", comment: "Elevation in feet")
            : String(localized: "\(Int(value.rounded())) m", comment: "Elevation in meters")
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

/// The effort rating out of 10, whose it is, and the session-RPE load it makes with the workout's minutes (#134).
private struct EffortView: View {
    let effort: WorkoutEffort
    let duration: TimeInterval

    var body: some View {
        // The load uses the score as shown, so the two always multiply out.
        let shown = effort.score.rounded()
        let score = shown.formatted(.number.precision(.fractionLength(0)))
        let load = Int(SessionRPE.load(effort: shown, duration: duration).rounded())
        let whose = effort.isEstimate ? String(localized: "Apple's estimate") : String(localized: "Your rating")
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(score)/10", comment: "Workout effort rating out of 10")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(whose).font(.headline).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Effort Load").font(.caption).foregroundStyle(.secondary)
                    Text("\(load)").font(.headline).monospacedDigit()
                }
            }
            Text("Effort load is the rating times the workout's minutes (session RPE). In one study (Foster et al. 2001) it rose and fell with heart rate load (TRIMP) over steady and interval cycling and basketball, on a higher scale of its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effort \(score) out of 10, \(whose), effort load \(load)"))
    }
}

/// Edwards TRIMP as a big number over a bar split by how much each heart rate zone added.
private struct TrainingLoadView: View {
    let timeInZones: [TimeInterval]

    var body: some View {
        let byZone = TrainingLoad.edwardsTRIMPByZone(timeInZones: timeInZones)
        let total = byZone.reduce(0, +)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(total.rounded()))")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("TRIMP").font(.headline).foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(byZone.indices.filter { byZone[$0] > 0 }, id: \.self) { index in
                        Capsule().fill(ZoneColors.color(index + 1))
                            .frame(width: max(proxy.size.width * byZone[index] / max(total, 1) - 2, 4))
                    }
                }
            }
            .frame(height: 12)
            Text("Minutes in each heart rate zone weighted 1 to 5 and added up (Edwards TRIMP). A higher number is a harder workout; compare it with your other workouts, as there's no published scale for what a score means.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training load \(Int(total.rounded())) TRIMP")
    }
}

/// Heart rate across the workout over its zone bands, the line colored by the zone it was in.
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
        Chart {
            // Each zone's band behind the line, cut to the plotted range so the axis isn't stretched to fit.
            ForEach(HeartRateZones.lowerBounds.indices, id: \.self) { index in
                let bandLow = max(HeartRateZones.lowerBounds[index] * maxHeartRate, domain.lowerBound)
                let bandHigh = index + 1 < HeartRateZones.lowerBounds.count
                    ? min(HeartRateZones.lowerBounds[index + 1] * maxHeartRate, domain.upperBound) : domain.upperBound
                if bandLow < bandHigh {
                    RectangleMark(yStart: .value("Low", bandLow), yEnd: .value("High", bandHigh))
                        .foregroundStyle(ZoneColors.color(index + 1).opacity(0.15))
                        .accessibilityHidden(true)
                }
            }
            ForEach(readings, id: \.date) { reading in
                LineMark(x: .value("Time", reading.date), y: .value("Heart rate", reading.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .foregroundStyle(LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top))
            }
        }
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
                        Text("Zone \(zone)").font(.subheadline.weight(.semibold)).foregroundStyle(ZoneColors.color(zone))
                        Text("\(low)–\(high) bpm").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(width: 84, alignment: .leading)
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(ZoneColors.color(zone).opacity(0.2))
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
                Text("Time", comment: "Splits table column: time for the split")
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
