import Foundation
import Testing
@testable import Grada

/// Builds FIT files for tests: little-endian, unsigned integer fields sized 1, 2 or 4 bytes.
struct FITWriter {
    private var records: [UInt8] = []

    /// Defines `local` as message `number` with fields of the given numbers and sizes.
    mutating func define(local: UInt8, number: Int, fields: [(number: Int, size: Int)]) {
        records += [0x40 | local, 0, 0, UInt8(number & 0xFF), UInt8(number >> 8), UInt8(fields.count)]
        for field in fields {
            let baseType: UInt8 = switch field.size { case 1: 0x02; case 2: 0x84; default: 0x86 }
            records += [UInt8(field.number), UInt8(field.size), baseType]
        }
    }

    /// A data message for `local`; with `timeOffset`, under a compressed timestamp header.
    mutating func data(local: UInt8, sizes: [Int], values: [Int64], timeOffset: UInt8? = nil) {
        records.append(timeOffset.map { 0x80 | local << 5 | $0 & 0x1F } ?? local)
        for (size, value) in zip(sizes, values) {
            records += (0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
        }
    }

    /// Defines local message 0 and writes one message with it.
    mutating func message(_ number: Int, _ fields: [(number: Int, size: Int, value: Int64)]) {
        define(local: 0, number: number, fields: fields.map { ($0.number, $0.size) })
        data(local: 0, sizes: fields.map(\.size), values: fields.map(\.value))
    }

    mutating func fileID(manufacturer: Int64 = 1) {
        message(0, [(0, 1, 4), (1, 2, manufacturer)])
    }

    static func time(_ date: Date) -> Int64 { Int64(date.timeIntervalSince(FITMessage.epoch)) }

    var bytes: Data {
        let size = records.count
        var file: [UInt8] = [14, 0x20, 0x93, 0x08] + (0..<4).map { UInt8(truncatingIfNeeded: size >> (8 * $0)) } + Array(".FIT".utf8)
        let headerCRC = FITDecoder.crc(file)
        file += [UInt8(headerCRC & 0xFF), UInt8(headerCRC >> 8)] + records
        let crc = FITDecoder.crc(file)
        return Data(file + [UInt8(crc & 0xFF), UInt8(crc >> 8)])
    }
}

struct FITImportTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-11-10 00:00 UTC.
    private let midnight = Date(timeIntervalSince1970: 1_794_268_800)

    private func files(_ files: [String: Data]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        return folder
    }

    private func read(_ files: [String: Data]) async throws -> FITImport {
        await FITImport.read([try self.files(files)], calendar: calendar)
    }

    static func activity(start: Date, sport: Int64 = 1) -> Data {
        var writer = FITWriter()
        writer.fileID()
        writer.message(18, [(2, 4, FITWriter.time(start)), (8, 4, 1_800_000), (5, 1, sport), (11, 2, 300), (16, 1, 140)])
        return writer.bytes
    }

    static func hrv(_ readings: [(Date, Double)]) -> Data {
        var writer = FITWriter()
        writer.fileID()
        for (time, value) in readings { writer.message(371, [(253, 4, FITWriter.time(time)), (0, 2, Int64(value * 128))]) }
        return writer.bytes
    }

    @Test func activityBecomesAWorkout() async throws {
        let start = midnight.addingTimeInterval(7 * 3600)
        let result = try await read(["run.fit": Self.activity(start: start)])
        let workout = try #require(result.workouts.first)
        #expect(workout.start == start)
        #expect(workout.duration == 1800)
        #expect(workout.name == "Run")
        #expect(workout.energyKcal == 300)
        #expect(workout.averageHeartRate == 140)
        #expect(workout.source == FITImport.sourceID)
        #expect(workout.origin == "Garmin (imported)")
    }

    @Test func sleepLevelsBecomeANight() async throws {
        let hour: TimeInterval = 3600
        let bed = midnight.addingTimeInterval(-hour)
        var writer = FITWriter()
        writer.fileID()
        // Light, deep, REM, awake, light, then awake at 07:00 marking the end.
        for (offset, level) in [(0, 2), (2 * hour, 3), (3 * hour, 4), (4 * hour, 1), (4 * hour + 600, 2), (8 * hour, 1)] as [(TimeInterval, Int64)] {
            writer.message(275, [(253, 4, FITWriter.time(bed + offset)), (0, 1, level)])
        }
        let result = try await read(["sleep.fit": writer.bytes])
        let night = try #require(result.sleepNights.first)
        #expect(night.wakeDay == midnight)
        #expect(night.stages == [.core: 2 * hour + 4 * hour - 600, .deep: hour, .rem: hour, .awake: 600])
        #expect(result.overnight.first?.bedtime == bed)
        #expect(result.overnight.first?.wakeTime == bed + 8 * hour)
        #expect(result.origins[.sleep]?[midnight] == ["Garmin (imported)"])
    }

    @Test func napStaysOutOfTheNight() async throws {
        let hour: TimeInterval = 3600
        func sleep(from start: TimeInterval, to end: TimeInterval) -> Data {
            var writer = FITWriter()
            writer.fileID()
            writer.message(275, [(253, 4, FITWriter.time(midnight + start)), (0, 1, 2)])
            writer.message(275, [(253, 4, FITWriter.time(midnight + end)), (0, 1, 1)])
            return writer.bytes
        }
        let result = try await read(["night.fit": sleep(from: -hour, to: 7 * hour), "nap.fit": sleep(from: 14 * hour, to: 15 * hour)])
        #expect(result.sleepNights.map(\.stages) == [[.core: 8 * hour]])
        #expect(result.overnight.first?.bedtime == midnight - hour)
        #expect(result.overnight.first?.wakeTime == midnight + 7 * hour)
    }

    @Test func hrvAveragesTheNightOrFallsBackToTheWatchSummary() async throws {
        let nextMidnight = midnight.addingTimeInterval(86_400)
        var summary = FITWriter()
        summary.fileID()
        summary.message(370, [(253, 4, FITWriter.time(nextMidnight.addingTimeInterval(6 * 3600))), (1, 2, 60 * 128)])
        let result = try await read([
            "hrv.fit": Self.hrv([(midnight.addingTimeInterval(2 * 3600), 40), (midnight.addingTimeInterval(3 * 3600), 50)]),
            "status.fit": summary.bytes,
        ])
        #expect(result.overnight.map(\.wakeDay) == [midnight, nextMidnight])
        #expect(result.overnight.map(\.hrv) == [45, 60])
    }

    @Test func restingHeartRateUsesTheDaysValue() async throws {
        var writer = FITWriter()
        writer.fileID()
        writer.message(211, [(253, 4, FITWriter.time(midnight.addingTimeInterval(3600))), (0, 1, 52), (1, 1, 48)])
        let result = try await read(["monitor.fit": writer.bytes])
        #expect(result.restingHeartRate == [DayValue(day: midnight, value: 48)])
    }

    @Test func compressedTimestampsCountFromTheLastTimestamp() throws {
        var writer = FITWriter()
        let time = FITWriter.time(midnight) // A multiple of 32, so offsets 0...31 add directly.
        writer.define(local: 0, number: 371, fields: [(253, 4), (0, 2)])
        writer.data(local: 0, sizes: [4, 2], values: [time, 40 * 128])
        writer.define(local: 1, number: 371, fields: [(0, 2)])
        writer.data(local: 1, sizes: [2], values: [42 * 128], timeOffset: 5)
        writer.data(local: 1, sizes: [2], values: [44 * 128], timeOffset: 2) // Rolled over past 31.
        let messages = try FITDecoder.decode(writer.bytes)
        #expect(messages.map(\.timestamp) == [midnight, midnight + 5, midnight + 34])
    }

    /// Padding after the last file doesn't discard what was read (#151); a second chained file is still read.
    @Test func trailingBytesAfterTheLastFileAreIgnored() throws {
        var writer = FITWriter()
        writer.fileID()
        let file = writer.bytes
        #expect(try FITDecoder.decode(file + Data([0, 0, 0])).count == 1)
        #expect(try FITDecoder.decode(file + file + Data(repeating: 0, count: 20)).count == 2)
    }

    /// Zero-size fields and empty messages are dropped, so a crafted file can't multiply into far more messages
    /// than it has bytes (#152).
    @Test func emptyMessagesAreDropped() throws {
        var writer = FITWriter()
        writer.define(local: 0, number: 20, fields: Array(repeating: (0, 0), count: 255))
        for _ in 0..<100 { writer.data(local: 0, sizes: [], values: []) }
        writer.fileID()
        #expect(try FITDecoder.decode(writer.bytes).map(\.number) == [0])
    }

    @Test func sameFileTwiceCountsOnce() async throws {
        let run = Self.activity(start: midnight)
        let result = try await read(["a.fit": run, "b.fit": run])
        #expect(result.filesRead == 2)
        #expect(result.workouts.count == 1)
    }

    @Test func namesFilesItCannotRead() async throws {
        var damaged = Self.activity(start: midnight)
        damaged[damaged.count - 3] ^= 0xFF
        let result = try await read([
            "damaged.fit": damaged,
            "notes.fit": Data("hello, not a FIT file".utf8),
            "cut.fit": Self.activity(start: midnight).prefix(30),
            "export.zip": Data([0x50, 0x4B]),
            "summary.json": Data("{}".utf8),
        ])
        #expect(result.filesRead == 0)
        #expect(result.failures == [
            .init(file: "cut.fit", reason: "The file is incomplete."),
            .init(file: "damaged.fit", reason: "The file is damaged."),
            .init(file: "export.zip", reason: "Unzip it in the Files app first."),
            .init(file: "notes.fit", reason: "Not a FIT file."),
        ])
    }
}
