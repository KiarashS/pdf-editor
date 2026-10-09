import Foundation

/// CRC-32 (IEEE 802.3) as used by ZIP archives.
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// Minimal ZIP writer that stores entries uncompressed.
///
/// Office Open XML packages (.xlsx, .pptx) are ZIP files; readers accept
/// stored (method 0) entries, which keeps this writer dependency-free.
public struct ZipWriter {
    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var entries: [Entry] = []
    private var body = Data()
    private let dosTime: UInt16
    private let dosDate: UInt16

    public init(date: Date = Date()) {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((components.year ?? 1980) - 1980, 0)
        dosDate = UInt16(truncatingIfNeeded: (year << 9) | ((components.month ?? 1) << 5) | (components.day ?? 1))
        dosTime = UInt16(truncatingIfNeeded: ((components.hour ?? 0) << 11) | ((components.minute ?? 0) << 5) | ((components.second ?? 0) / 2))
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func addFile(path: String, string: String) {
        addFile(path: path, data: Data(string.utf8))
    }

    public mutating func addFile(path: String, data: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(truncatingIfNeeded: body.count)

        body.appendUInt32(0x0403_4B50)        // local file header signature
        body.appendUInt16(10)                 // version needed to extract
        body.appendUInt16(0x0800)             // flags: UTF-8 names
        body.appendUInt16(0)                  // method: stored
        body.appendUInt16(dosTime)
        body.appendUInt16(dosDate)
        body.appendUInt32(crc)
        body.appendUInt32(UInt32(truncatingIfNeeded: data.count))
        body.appendUInt32(UInt32(truncatingIfNeeded: data.count))
        body.appendUInt16(UInt16(truncatingIfNeeded: name.count))
        body.appendUInt16(0)                  // extra field length
        body.append(name)
        body.append(data)

        entries.append(Entry(name: name, crc: crc, size: UInt32(truncatingIfNeeded: data.count), offset: offset))
    }

    public func finalize() -> Data {
        var output = body
        let directoryOffset = UInt32(truncatingIfNeeded: output.count)
        var directory = Data()
        for entry in entries {
            directory.appendUInt32(0x0201_4B50)   // central directory signature
            directory.appendUInt16(20)            // version made by
            directory.appendUInt16(10)            // version needed
            directory.appendUInt16(0x0800)
            directory.appendUInt16(0)
            directory.appendUInt16(dosTime)
            directory.appendUInt16(dosDate)
            directory.appendUInt32(entry.crc)
            directory.appendUInt32(entry.size)
            directory.appendUInt32(entry.size)
            directory.appendUInt16(UInt16(truncatingIfNeeded: entry.name.count))
            directory.appendUInt16(0)             // extra
            directory.appendUInt16(0)             // comment
            directory.appendUInt16(0)             // disk number
            directory.appendUInt16(0)             // internal attributes
            directory.appendUInt32(0)             // external attributes
            directory.appendUInt32(entry.offset)
            directory.append(entry.name)
        }
        output.append(directory)
        output.appendUInt32(0x0605_4B50)          // end of central directory
        output.appendUInt16(0)
        output.appendUInt16(0)
        output.appendUInt16(UInt16(truncatingIfNeeded: entries.count))
        output.appendUInt16(UInt16(truncatingIfNeeded: entries.count))
        output.appendUInt32(UInt32(truncatingIfNeeded: directory.count))
        output.appendUInt32(directoryOffset)
        output.appendUInt16(0)
        return output
    }
}

extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendUInt16(UInt16(value & 0xFFFF))
        appendUInt16(UInt16((value >> 16) & 0xFFFF))
    }
}

/// Escapes text for inclusion in XML element content or attribute values.
public func xmlEscaped(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"": result += "&quot;"
        case "'": result += "&apos;"
        default:
            // XML 1.0 forbids most control characters.
            if scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r" { continue }
            if scalar.value == 0xFFFE || scalar.value == 0xFFFF { continue }
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
