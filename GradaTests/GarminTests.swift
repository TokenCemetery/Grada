import Foundation
import HealthKit
import Testing
@testable import Grada

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

    /// Answers requests from a script and records them.
    private final class FakeGarmin {
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
