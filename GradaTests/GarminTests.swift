import Foundation
import HealthKit
import Testing
@testable import Grada

/// Sample data as a Garmin user's looks: nightly HRV only, since Garmin writes no HRV to Apple Health.
private struct OvernightHRVOnlySource: HealthDataSource {
    let base = SampleDataSource()

    func daily(_ metric: QuantityMetric, days: Int) async throws -> [DayValue] {
        try await base.daily(metric, days: days).map { metric == .hrv ? DayValue(day: $0.day, value: nil) : $0 }
    }
    func standHours(days: Int) async throws -> [DayValue] { try await base.standHours(days: days) }
    func overnight(days: Int) async throws -> [OvernightVitals] { try await base.overnight(days: days) }
    func sleepNights(days: Int) async throws -> [SleepNight] { try await base.sleepNights(days: days) }
    func workouts(days: Int) async throws -> [WorkoutSummary] { try await base.workouts(days: days) }
    func heartRate(in interval: DateInterval) async throws -> [TimedValue] { try await base.heartRate(in: interval) }
    func sleepPeriods(in interval: DateInterval) async throws -> [SleepPeriod] { try await base.sleepPeriods(in: interval) }
    func age() async throws -> Int? { try await base.age() }
    func biologicalSex() async throws -> BiologicalSex? { try await base.biologicalSex() }
    func highestHeartRate(days: Int) async throws -> Double? { try await base.highestHeartRate(days: days) }
}

@MainActor
struct OvernightHRVTests {
    @Test func healthStatusRatesNightlyHRVWithoutDailyHRV() async throws {
        let snapshot = try await SnapshotBuilder(source: OvernightHRVOnlySource()).snapshot(for: .healthStatus)
        guard case .vitals(let vitals) = snapshot.detail else { Issue.record("\(snapshot.detail)"); return }
        let hrv = try #require(vitals.first { $0.name == "HRV" })
        #expect(hrv.state == .inRange || hrv.state == .outOfRange)
    }

    @Test func vitalSeriesReadsHRVFromTheNight() async throws {
        let source = OvernightHRVOnlySource()
        let series = try await SnapshotBuilder.vitalSeries(.hrv, days: 7, source: source)
        #expect(series == (try await source.overnight(days: 7)).map { DayValue(day: $0.wakeDay, value: $0.hrv) })
        #expect(series.contains { $0.value != nil })
        #expect(try await SnapshotBuilder.vitalSeries(.restingHeartRate, days: 7, source: source)
                == (try await source.daily(.restingHeartRate, days: 7)))
    }

    @Test func healthStatusDataComesFromOvernightHRV() {
        #expect(CardKind.healthStatus.dataKinds.first == .overnightHRV, "Listed first, as for Recovery")
    }
}

/// Fixtures follow the shape of real Garmin Personal API responses (#92) with made-up values.
@MainActor
struct GarminTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ text: String) -> Date { GarminData.parseDay(text, calendar: calendar)! }

    private let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJleHAiOjE3OTQ1MDAwMDB9.c2lnbmF0dXJl"

    // MARK: Token

    @Test func tokenIsReadFromBareJWTOrJSON() {
        #expect(GarminClient.token(from: Data(jwt.utf8)) == jwt)
        #expect(GarminClient.token(from: Data("\(jwt)\n".utf8)) == jwt)
        #expect(GarminClient.token(from: Data("\"\(jwt)\"".utf8)) == jwt)
        #expect(GarminClient.token(from: Data(#"{"access_token":"\#(jwt)","expires_in":86400}"#.utf8)) == jwt)
        #expect(GarminClient.token(from: Data("<html>error</html>".utf8)) == nil)
        #expect(GarminClient.token(from: Data(#"{"error":"bad"}"#.utf8)) == nil)
    }

    // MARK: Client

    /// Answers requests from a script and records them. Main-actor isolated, since a window's days are requested in parallel.
    @MainActor private final class FakeGarmin {
        var requests: [URLRequest] = []
        var answer: (URLRequest) -> (Int, String) = { _ in (200, "") }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let (status, body) = answer(request)
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        var tokenRequests: Int { requests.filter { $0.httpMethod == "POST" }.count }
    }

    private func client(_ fake: FakeGarmin, key: String? = "test-key") -> GarminClient {
        GarminClient(key: { key }, transport: fake.send)
    }

    @Test func keyGoesOnlyToTheTokenEndpointAndTokenToDataCalls() async throws {
        let fake = FakeGarmin()
        fake.answer = { $0.httpMethod == "POST" ? (200, self.jwt) : (200, "[]") }
        _ = try await client(fake).get("/sleep-service/sleep/dailySleepSummariesByDate", ["startDate": "2026-11-01", "endDate": "2026-11-02"])

        #expect(fake.requests.allSatisfy { $0.url?.host == GarminClient.host && $0.url?.scheme == "https" })
        #expect(fake.requests[0].url?.path == "/personalapitoken-service/personal-api/personal-api-key/token")
        #expect(fake.requests[0].value(forHTTPHeaderField: "Authorization") == "ApiKey test-key")
        #expect(fake.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")
        #expect(fake.requests[1].url?.query == "endDate=2026-11-02&startDate=2026-11-01")
    }

    @Test func tokenIsReusedAndNoContentMeansNoData() async throws {
        let fake = FakeGarmin()
        fake.answer = { $0.httpMethod == "POST" ? (200, self.jwt) : (204, "") }
        let client = client(fake)
        #expect(try await client.get("/hrv-service/hrv/daily/2025-01-01/2025-01-28") == nil)
        #expect(try await client.get("/hrv-service/hrv/daily/2025-01-29/2025-02-25") == nil)
        #expect(fake.tokenRequests == 1)
    }

    @Test func expiredTokenIsReplacedOnce() async throws {
        let fake = FakeGarmin()
        var dataCalls = 0
        fake.answer = { request in
            if request.httpMethod == "POST" { return (200, self.jwt) }
            dataCalls += 1
            return dataCalls == 1 ? (401, "") : (200, "[]")
        }
        #expect(try await client(fake).get("/activitylist-service/activities/search/activities") == Data("[]".utf8))
        #expect(fake.tokenRequests == 2)
    }

    @Test func refusedKeyAndMissingKeyFail() async {
        let fake = FakeGarmin()
        fake.answer = { _ in (401, "") }
        await #expect(throws: GarminClient.Failure.keyRejected) { try await client(fake).verify() }
        await #expect(throws: GarminClient.Failure.noKey) { try await client(FakeGarmin(), key: nil).verify() }
    }

    /// Only the token endpoint judges the key; a data endpoint's 403 must not ask for a new key (#149).
    @Test func forbiddenDataIsNotARejectedKey() async {
        let fake = FakeGarmin()
        fake.answer = { $0.httpMethod == "POST" ? (200, self.jwt) : (403, "") }
        await #expect(throws: GarminClient.Failure.http(403)) { try await client(fake).get("/hrv-service/hrv/daily/2025-01-01/2025-01-28") }
        fake.answer = { _ in (403, "") }
        await #expect(throws: GarminClient.Failure.keyRejected) { try await client(fake).verify() }
    }

    @Test func rateLimitPausesCalls() async {
        let fake = FakeGarmin()
        fake.answer = { $0.httpMethod == "POST" ? (200, self.jwt) : (429, "") }
        let client = client(fake)
        await #expect(throws: GarminClient.Failure.rateLimited) { try await client.get("/usersummary-service/v2/dailysummaries") }
        let calls = fake.requests.count
        await #expect(throws: GarminClient.Failure.rateLimited) { try await client.get("/usersummary-service/v2/dailysummaries") }
        #expect(fake.requests.count == calls)
    }

    // MARK: Mapping

    private let dailiesJSON = """
    {"data": [
      {"calendarDate": "2026-11-09", "includesWellnessData": false},
      {"calendarDate": "2026-11-10", "includesWellnessData": true,
       "movement": {"steps": {"goal": 8000, "value": 9120, "distanceInMeters": 7300.5}},
       "calories": {"burnedResting": 1700, "burnedActive": 540, "burnedTotal": 2240},
       "heartRate": {"minValue": 48, "maxValue": 151, "restingValue": 52},
       "intensityMinutes": {"goal": 150, "moderate": 20, "vigorous": 15},
       "stress": {"avgLevel": 31},
       "bodyBattery": {"minValue": 20, "maxValue": 85},
       "respiration": {"avgValue": 15, "minValue": 10, "maxValue": 22},
       "pulseOx": {"avgValue": 95, "minValue": 90}}
    ]}
    """

    // 2026-11-09 23:00 to 2026-11-10 07:00 UTC. Nights without sleep come back with a null date, as on a real account.
    private let sleepJSON = """
    [{"id": null, "calendarDate": null, "sleepTimeSeconds": null, "deepSleepSeconds": null},
     {"id": 1, "calendarDate": "2026-11-10", "sleepTimeSeconds": 27000,
      "sleepStartTimestampGMT": 1794265200000, "sleepEndTimestampGMT": 1794294000000,
      "deepSleepSeconds": 5400, "lightSleepSeconds": 15000, "remSleepSeconds": 6600, "awakeSleepSeconds": 1800,
      "averageSpO2Value": 96.5, "averageRespirationValue": 13.5, "avgHeartRate": 55,
      "sleepScores": {"overall": {"value": 82}}}]
    """

    private let hrvJSON = """
    {"hrvSummaries": [{"calendarDate": "2026-11-10", "weeklyAvg": 60, "lastNightAvg": 64, "lastNight5MinHigh": 80,
      "baseline": {"lowUpper": 50, "balancedLow": 55, "balancedUpper": 70, "markerValue": 0.4}, "status": "BALANCED"}],
     "userProfilePk": 1}
    """

    private let activitiesJSON = """
    [{"activityId": 21000000001, "activityName": "Morning Run", "startTimeLocal": "2026-11-10 08:30:00",
      "startTimeGMT": "2026-11-10 07:30:00", "activityType": {"typeId": 1, "typeKey": "running", "parentTypeId": 17},
      "distance": 8000.0, "duration": 2700.5, "calories": 610.0, "averageHR": 148.0, "maxHR": 172.0},
     {"activityId": 21000000002, "startTimeGMT": "2026-11-12 07:30:00", "activityType": {"typeKey": "yoga"}, "duration": 1800.0},
     {"activityId": 21000000003, "startTimeGMT": null, "duration": 600.0}]
    """

    private func mapped() throws -> HealthBatch {
        let decoder = JSONDecoder()
        return GarminData.batch(
            days: DateInterval(start: day("2026-11-09"), end: day("2026-11-11")),
            dailies: try decoder.decode(GarminData.DailySummaries.self, from: Data(dailiesJSON.utf8)).data,
            sleep: try decoder.decode([GarminData.Sleep].self, from: Data(sleepJSON.utf8)),
            hrv: try decoder.decode(GarminData.HRVSummaries.self, from: Data(hrvJSON.utf8)).hrvSummaries,
            activities: try decoder.decode([GarminData.Activity].self, from: Data(activitiesJSON.utf8)),
            calendar: calendar
        )
    }

    @Test func dailySummariesMapToDailyValues() throws {
        let batch = try mapped()
        let tenth = day("2026-11-10")
        #expect(batch.daily[.steps] == [DayValue(day: tenth, value: 9120)])
        #expect(batch.daily[.distance] == [DayValue(day: tenth, value: 7.3005)])
        #expect(batch.daily[.activeEnergy] == [DayValue(day: tenth, value: 540)])
        #expect(batch.daily[.restingHeartRate] == [DayValue(day: tenth, value: 52)])
        #expect(batch.daily[.exerciseMinutes] == [DayValue(day: tenth, value: 35)])
        // Overnight averages win over the day's.
        #expect(batch.daily[.oxygenSaturation] == [DayValue(day: tenth, value: 96.5)])
        #expect(batch.daily[.respiratoryRate] == [DayValue(day: tenth, value: 13.5)])
        #expect(batch.origins[.steps]?[tenth] == [GarminSource.originName])
        // A day the watch wasn't worn adds nothing.
        #expect(batch.origins[.steps]?[day("2026-11-09")] == nil)
    }

    @Test func sleepAndHRVMapToTheNightTheyEnded() throws {
        let batch = try mapped()
        let tenth = day("2026-11-10")
        #expect(batch.sleepNights == [SleepNight(wakeDay: tenth, stages: [.deep: 5400, .core: 15000, .rem: 6600, .awake: 1800], unspecified: 0)])
        #expect(batch.overnight == [OvernightVitals(wakeDay: tenth, hrv: 64,
                                                    bedtime: Date(timeIntervalSince1970: 1_794_265_200),
                                                    wakeTime: Date(timeIntervalSince1970: 1_794_294_000))])
        // Garmin's HRV is RMSSD: it stays out of the daily HRV that Apple Health's SDNN fills.
        #expect(batch.daily[.hrv] == nil)
        #expect(batch.origins[.overnightHRV]?[tenth] == [GarminSource.originName])
        #expect(batch.origins[.sleep]?[tenth] == [GarminSource.originName])
    }

    @Test func activitiesMapToWorkoutsInTheRange() throws {
        let workouts = try mapped().workouts
        #expect(workouts.count == 1)
        let run = try #require(workouts.first)
        #expect(run.id == "garmin-21000000001")
        #expect(run.start == Date(timeIntervalSince1970: 1_794_295_800))
        #expect(run.duration == 2700.5)
        #expect(run.name == WorkoutNames.info(for: .running).name)
        #expect(run.activityType == Int(HKWorkoutActivityType.running.rawValue), "Stored, so it names the run in any language")
        #expect(run.energyKcal == 610 && run.averageHeartRate == 148)
        #expect(run.source == GarminSource.sourceID && run.origin == GarminSource.originName)
    }

    @Test func activityTypesMapToWorkoutTypes() {
        #expect(GarminData.activityType("trail_running") == .running)
        #expect(GarminData.activityType("road_biking") == .cycling)
        #expect(GarminData.activityType("open_water_swimming") == .swimming)
        #expect(GarminData.activityType("strength_training") == .traditionalStrengthTraining)
        #expect(GarminData.activityType("backcountry_skiing") == .crossCountrySkiing)
        #expect(GarminData.activityType("golf") == .other)
        #expect(GarminData.activityType(nil) == .other)
    }

    // MARK: Source

    /// Unsigned test builds can't use the Keychain.
    private final class MemoryKeyStore: GarminKeyStoring {
        var key: String?
        func save(_ key: String) throws { self.key = key }
        func delete() { key = nil }
    }

    private func source(_ fake: FakeGarmin) throws -> (GarminSource, MemoryKeyStore) {
        let store = MemoryKeyStore()
        try store.save("test-key")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return (GarminSource(keyStore: store, transport: fake.send, calendar: calendar, defaults: defaults), store)
    }

    @Test func batchSplitsRequestsWithinGarminLimitsAndPagesActivities() async throws {
        let fake = FakeGarmin()
        fake.answer = { request in
            if request.httpMethod == "POST" { return (200, self.jwt) }
            let path = request.url!.path
            if path.contains("dailysummaries") { return (200, #"{"data": []}"#) }
            if path.contains("activities") {
                let start = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    .queryItems!.first { $0.name == "start" }!.value!)!
                let count = start == 0 ? GarminSource.activityPage : 3
                let page = (0..<count).map { #"{"activityId": \#(start + $0), "startTimeGMT": "2026-10-01 07:00:00", "duration": 60}"# }
                return (200, "[\(page.joined(separator: ","))]")
            }
            if path.contains("hrv") { return (204, "") }
            return (200, "[]")
        }
        let (garmin, store) = try source(fake)
        defer { store.delete() }

        let batch = try await garmin.batch(for: DateInterval(start: day("2026-09-20"), end: day("2026-11-01")))  // 42 days
        let paths = fake.requests.compactMap(\.url?.path)
        #expect(paths.filter { $0.contains("dailysummaries") }.count == 1)
        #expect(paths.filter { $0.contains("dailySleepSummariesByDate") }.count == 2)
        #expect(paths.filter { $0.contains("hrv-service") }.count == 1)
        #expect(paths.filter { $0.contains("activities") }.count == 2)
        #expect(batch.workouts.count == GarminSource.activityPage + 3)
        #expect(garmin.lastSync != nil)
    }

    /// A server that ignores `start` and keeps sending the same full page must not page forever (#153).
    @Test func repeatedActivityPageEndsPaging() async throws {
        let fake = FakeGarmin()
        fake.answer = { request in
            if request.httpMethod == "POST" { return (200, self.jwt) }
            let path = request.url!.path
            if path.contains("dailysummaries") { return (200, #"{"data": []}"#) }
            if path.contains("activities") {
                let page = (0..<GarminSource.activityPage).map { #"{"activityId": \#($0), "startTimeGMT": "2026-10-01 07:00:00", "duration": 60}"# }
                return (200, "[\(page.joined(separator: ","))]")
            }
            return (204, "")
        }
        let (garmin, store) = try source(fake)
        defer { store.delete() }

        let batch = try await garmin.batch(for: DateInterval(start: day("2026-09-20"), end: day("2026-11-01")))
        #expect(fake.requests.compactMap(\.url?.path).filter { $0.contains("activities") }.count == 2)
        #expect(batch.workouts.count == GarminSource.activityPage)
    }

    @Test func dailyHeartRateIsAveragedPerFiveMinutes() throws {
        let start = day("2026-11-01").timeIntervalSince1970 * 1000
        let json = """
        {"heartRateValueDescriptors": [{"key": "heartrate", "index": 1}, {"key": "timestamp", "index": 0}],
         "heartRateValues": [[\(start), 60], [\(start + 120_000), 70], [\(start + 240_000), null], [\(start + 360_000), 80]]}
        """
        let values = GarminData.heartRate(try JSONDecoder().decode(GarminData.DailyHeartRate.self, from: Data(json.utf8)))
        #expect(values == [TimedValue(date: day("2026-11-01"), value: 65),
                           TimedValue(date: day("2026-11-01").addingTimeInterval(300), value: 80)])
    }

    @Test func heartRateIsReadPerDayOnceThePastDayIsFetched() async throws {
        let fake = FakeGarmin()
        fake.answer = { request in
            if request.httpMethod == "POST" { return (200, self.jwt) }
            let date = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "date" }!.value!
            let ms = self.day(date).timeIntervalSince1970 * 1000 + 3_600_000
            return (200, #"{"heartRateValues": [[\#(ms), 55]]}"#)
        }
        let (garmin, store) = try source(fake)
        defer { store.delete() }

        let interval = DateInterval(start: day("2026-10-30"), end: day("2026-11-01"))
        #expect(try await garmin.heartRate(in: interval).map(\.date)
                == [day("2026-10-30").addingTimeInterval(3600), day("2026-10-31").addingTimeInterval(3600)])
        _ = try await garmin.heartRate(in: interval)
        let paths = fake.requests.compactMap(\.url?.path)
        #expect(paths.filter { $0 == "/wellness-service/wellness/dailyHeartRate" }.count == 2)
    }

    @Test func sleepPeriodsAreEachNightFromBedToWakeOnceThePastIsFetched() async throws {
        let fake = FakeGarmin()
        fake.answer = { $0.httpMethod == "POST" ? (200, self.jwt) : (200, self.sleepJSON) }
        let (garmin, store) = try source(fake)
        defer { store.delete() }
        let interval = DateInterval(start: day("2026-11-09"), end: day("2026-11-11"))

        let night = SleepPeriod(start: day("2026-11-09").addingTimeInterval(23 * 3600), end: day("2026-11-10").addingTimeInterval(7 * 3600), stage: nil)
        #expect(try await garmin.sleepPeriods(in: interval) == [night])
        #expect(try await garmin.sleepPeriods(in: DateInterval(start: night.end.addingTimeInterval(60), duration: 60)).isEmpty)
        let paths = fake.requests.compactMap(\.url?.path)
        #expect(paths.filter { $0.contains("dailySleepSummariesByDate") }.count == 1)

        garmin.disconnect()
        #expect(try await garmin.sleepPeriods(in: interval).isEmpty, "Nothing is read while disconnected")
    }

    @Test func failedDayIsLeftOutAndRetriedLater() async throws {
        let fake = FakeGarmin()
        fake.answer = { request in
            if request.httpMethod == "POST" { return (200, self.jwt) }
            let date = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "date" }!.value!
            if date == "2026-10-30" { return (500, "") }
            return (200, #"{"heartRateValues": [[\#(self.day(date).timeIntervalSince1970 * 1000), 55]]}"#)
        }
        let (garmin, store) = try source(fake)
        defer { store.delete() }
        let interval = DateInterval(start: day("2026-10-30"), end: day("2026-11-01"))

        #expect(try await garmin.heartRate(in: interval).map(\.date) == [day("2026-10-31")])
        let sent = fake.requests.count
        _ = try await garmin.heartRate(in: interval)
        #expect(fake.requests.count == sent, "A failed day waits failureRetry before it's asked again")
    }

    @Test func heartRateIsDroppedWhenTheKeyChanges() async throws {
        let fake = FakeGarmin()
        fake.answer = { $0.httpMethod == "POST" ? (200, self.jwt) : (200, #"{"heartRateValues": []}"#) }
        let (garmin, store) = try source(fake)
        defer { store.delete() }
        let interval = DateInterval(start: day("2026-10-30"), end: day("2026-10-31"))

        _ = try await garmin.heartRate(in: interval)
        garmin.disconnect()
        let sent = fake.requests.count
        #expect(try await garmin.heartRate(in: interval).isEmpty)
        #expect(fake.requests.count == sent, "Nothing is fetched while disconnected")

        try await garmin.connect(key: "other-key")
        _ = try await garmin.heartRate(in: interval)
        #expect(fake.requests.compactMap(\.url?.path).filter { $0 == "/wellness-service/wellness/dailyHeartRate" }.count == 2)
    }

    @Test func refusedKeyAsksToReconnect() async throws {
        let fake = FakeGarmin()
        fake.answer = { _ in (401, "") }
        let (garmin, store) = try source(fake)
        defer { store.delete() }
        #expect(garmin.isAvailable)

        await #expect(throws: GarminClient.Failure.keyRejected) {
            try await garmin.batch(for: DateInterval(start: day("2026-11-01"), end: day("2026-11-02")))
        }
        #expect(garmin.needsReconnect)
        #expect(!garmin.isAvailable)
    }

    @Test func failedImportNamesTheRequestAndField() async throws {
        let fake = FakeGarmin()
        fake.answer = { $0.httpMethod == "POST" ? (200, self.jwt) : (200, #"{"data": [{"calendarDate": 5}]}"#) }
        let (garmin, store) = try source(fake)
        defer { store.delete() }

        await #expect(throws: DecodingError.self) {
            try await garmin.batch(for: DateInterval(start: day("2026-11-01"), end: day("2026-11-02")))
        }
        let error = try #require(garmin.lastError)
        #expect(error.hasPrefix("Daily summaries: unexpected data at data.[0].calendarDate"))
        #expect(garmin.lastSync == nil)
    }

    /// A new key that fails to verify leaves the working key in place (#150).
    @Test func failedNewKeyKeepsTheOldOne() async throws {
        let fake = FakeGarmin()
        fake.answer = { $0.value(forHTTPHeaderField: "Authorization") == "ApiKey new-key" ? (401, "") : (200, self.jwt) }
        let (garmin, store) = try source(fake)

        await #expect(throws: GarminClient.Failure.keyRejected) { try await garmin.connect(key: "new-key") }
        #expect(store.key == "test-key")
        #expect(garmin.isConnected)
    }

    @Test func refusedKeyIsNotKept() async throws {
        let fake = FakeGarmin()
        fake.answer = { _ in (401, "") }
        let (garmin, store) = try source(fake)
        defer { store.delete() }
        garmin.disconnect()

        await #expect(throws: GarminClient.Failure.keyRejected) { try await garmin.connect(key: " bad-key ") }
        #expect(store.key == nil)
        #expect(!garmin.isConnected)
        #expect(fake.requests.last?.value(forHTTPHeaderField: "Authorization") == "ApiKey bad-key")
    }
}
