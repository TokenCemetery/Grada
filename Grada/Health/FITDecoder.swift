import Foundation

/// One decoded FIT message: its global message number and its integer fields, already free of the
/// "invalid" placeholder values. Strings, floats and array fields are left out; Grada doesn't use them.
nonisolated struct FITMessage: Equatable {
    let number: Int
    let fields: [Int: Int64]

    /// FIT counts seconds from 1989-12-31 00:00 UTC.
    static let epoch = Date(timeIntervalSince1970: 631_065_600)

    func date(_ field: Int) -> Date? {
        fields[field].map { Self.epoch.addingTimeInterval(TimeInterval($0)) }
    }

    var timestamp: Date? { date(253) }
}

nonisolated enum FITError: Error, Equatable {
    case notFIT, truncated, badChecksum, undefinedMessage
}

/// Reads the binary FIT format (Garmin's FIT SDK "Protocol" document): a header, definition messages
/// that describe the layout of the data messages after them, and a CRC. Several FIT files can be chained.
nonisolated enum FITDecoder {
    static func decode(_ data: Data) throws -> [FITMessage] {
        let bytes = [UInt8](data)
        var messages: [FITMessage] = []
        var offset = 0
        repeat {
            messages += try decodeFile(bytes, at: &offset)
        } while offset < bytes.count
        return messages
    }

    private struct Definition {
        let number: Int
        let bigEndian: Bool
        let fields: [(number: Int, size: Int, baseType: UInt8)]
        /// Developer fields are skipped; only their total size matters.
        let developerSize: Int
    }

    private static func decodeFile(_ bytes: [UInt8], at offset: inout Int) throws -> [FITMessage] {
        let start = offset
        guard bytes.count - start >= 12 else { throw FITError.notFIT }
        let headerSize = Int(bytes[start])
        guard headerSize >= 12, bytes[(start + 8)..<(start + 12)].elementsEqual(".FIT".utf8) else { throw FITError.notFIT }
        let dataSize = Int(bytes[start + 4]) | Int(bytes[start + 5]) << 8 | Int(bytes[start + 6]) << 16 | Int(bytes[start + 7]) << 24
        let end = start + headerSize + dataSize
        guard end + 2 <= bytes.count else { throw FITError.truncated }
        // The CRC of a file followed by its own CRC is 0.
        guard crc(bytes[start..<(end + 2)]) == 0 else { throw FITError.badChecksum }

        var definitions: [Int: Definition] = [:]
        var messages: [FITMessage] = []
        var lastTimestamp: Int64 = 0
        var position = start + headerSize

        func read(_ count: Int) throws -> ArraySlice<UInt8> {
            guard position + count <= end else { throw FITError.truncated }
            defer { position += count }
            return bytes[position..<(position + count)]
        }

        while position < end {
            let header = try read(1).first!
            if header & 0x80 != 0 {
                // Compressed timestamp header: a data message whose time is a 5-bit offset from the last timestamp.
                guard let definition = definitions[Int(header >> 5 & 0x03)] else { throw FITError.undefinedMessage }
                let offset = Int64(header & 0x1F)
                var timestamp = lastTimestamp & ~0x1F | offset
                if offset < lastTimestamp & 0x1F { timestamp += 0x20 }
                lastTimestamp = timestamp
                var message = try readData(definition, read)
                if message.fields[253] == nil {
                    var fields = message.fields
                    fields[253] = timestamp
                    message = FITMessage(number: message.number, fields: fields)
                }
                messages.append(message)
            } else if header & 0x40 != 0 {
                let local = Int(header & 0x0F)
                let fixed = Array(try read(5))
                let bigEndian = fixed[1] == 1
                let number = bigEndian ? Int(fixed[2]) << 8 | Int(fixed[3]) : Int(fixed[3]) << 8 | Int(fixed[2])
                var fields: [(number: Int, size: Int, baseType: UInt8)] = []
                for _ in 0..<fixed[4] {
                    let field = Array(try read(3))
                    fields.append((Int(field[0]), Int(field[1]), field[2]))
                }
                var developerSize = 0
                if header & 0x20 != 0 {
                    for _ in 0..<(try read(1).first!) { developerSize += Int(Array(try read(3))[1]) }
                }
                definitions[local] = Definition(number: number, bigEndian: bigEndian, fields: fields, developerSize: developerSize)
            } else {
                guard let definition = definitions[Int(header & 0x0F)] else { throw FITError.undefinedMessage }
                let message = try readData(definition, read)
                if let timestamp = message.fields[253] { lastTimestamp = timestamp }
                messages.append(message)
            }
        }
        offset = end + 2
        return messages
    }

    private static func readData(_ definition: Definition, _ read: (Int) throws -> ArraySlice<UInt8>) throws -> FITMessage {
        var fields: [Int: Int64] = [:]
        for field in definition.fields {
            let raw = try read(field.size)
            if let value = integer(raw, baseType: field.baseType, bigEndian: definition.bigEndian) {
                fields[field.number] = value
            }
        }
        _ = try read(definition.developerSize)
        return FITMessage(number: definition.number, fields: fields)
    }

    /// A single integer value, or nil for invalid values, arrays and non-integer types.
    private static func integer(_ raw: ArraySlice<UInt8>, baseType: UInt8, bigEndian: Bool) -> Int64? {
        let (size, signed, invalid): (Int, Bool, UInt64)
        switch baseType & 0x1F {
        case 0x00, 0x02, 0x0D: (size, signed, invalid) = (1, false, 0xFF)        // enum, uint8, byte
        case 0x01: (size, signed, invalid) = (1, true, 0x7F)                     // sint8
        case 0x0A: (size, signed, invalid) = (1, false, 0)                       // uint8z
        case 0x03: (size, signed, invalid) = (2, true, 0x7FFF)                   // sint16
        case 0x04: (size, signed, invalid) = (2, false, 0xFFFF)                  // uint16
        case 0x0B: (size, signed, invalid) = (2, false, 0)                       // uint16z
        case 0x05: (size, signed, invalid) = (4, true, 0x7FFF_FFFF)              // sint32
        case 0x06: (size, signed, invalid) = (4, false, 0xFFFF_FFFF)             // uint32
        case 0x0C: (size, signed, invalid) = (4, false, 0)                       // uint32z
        default: return nil
        }
        guard raw.count == size else { return nil }
        let ordered = bigEndian ? Array(raw) : raw.reversed()
        let bits = ordered.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard bits != invalid else { return nil }
        guard signed else { return Int64(bits) }
        let shift = UInt64(64 - size * 8)
        return Int64(bitPattern: bits << shift) >> Int64(shift)
    }

    /// CRC-16 as the FIT SDK computes it.
    static func crc(_ bytes: some Sequence<UInt8>) -> UInt16 {
        let table: [UInt16] = [0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
                               0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400]
        var crc: UInt16 = 0
        for byte in bytes {
            var tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte & 0xF)]
            tmp = table[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ table[Int(byte >> 4 & 0xF)]
        }
        return crc
    }
}
