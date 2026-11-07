import CZip
import Foundation

public struct ZipEntry: Equatable, Sendable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public enum ZipArchive {
    public static func read(data: Data) throws -> [ZipEntry] {
        guard let eocd = findEOCD(data) else { throw InventoryError.notAZip }
        let count = Int(readU16(data, eocd + 10))
        let directoryOffset = Int(readU32(data, eocd + 16))
        var cursor = directoryOffset
        var entries: [ZipEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 46 <= data.count, readU32(data, cursor) == 0x02014b50 else {
                throw InventoryError.zipCorrupt("centrální adresář")
            }
            let method = readU16(data, cursor + 10)
            let crc = readU32(data, cursor + 16)
            let compressedSize = readU32(data, cursor + 20)
            let uncompressedSize = readU32(data, cursor + 24)
            let nameLength = Int(readU16(data, cursor + 28))
            let extraLength = Int(readU16(data, cursor + 30))
            let commentLength = Int(readU16(data, cursor + 32))
            let localOffset = Int(readU32(data, cursor + 42))
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd + extraLength + commentLength <= data.count else {
                throw InventoryError.zipCorrupt("název položky")
            }
            let name = String(data: data.subdata(in: nameStart..<nameEnd), encoding: .utf8) ?? ""
            cursor = nameEnd + extraLength + commentLength
            if name.hasSuffix("/") { continue }
            if compressedSize == 0xffffffff || uncompressedSize == 0xffffffff {
                throw InventoryError.zipCorrupt("zip64 není podporovaný")
            }
            let payload = try readLocal(data: data, offset: localOffset, compressedSize: Int(compressedSize), uncompressedSize: Int(uncompressedSize), method: method, crc: crc)
            entries.append(ZipEntry(name: name, data: payload))
        }
        return entries
    }

    public static func write(entries: [ZipEntry], date: Date = Date()) throws -> Data {
        var locals = Data()
        var central = Data()
        let (time, day) = dosDateTime(date)
        for entry in entries {
            let nameData = Data(entry.name.utf8)
            guard nameData.count <= Int(UInt16.max) else {
                throw InventoryError.zipCorrupt("příliš dlouhý název")
            }
            let crc = crc32(entry.data)
            let compressed = try deflate(entry.data)
            let useStore = compressed.count >= entry.data.count
            let payload = useStore ? entry.data : compressed
            let method: UInt16 = useStore ? 0 : 8
            let offset = UInt32(locals.count)
            locals.append(localHeader(name: nameData, method: method, time: time, day: day, crc: crc, compressed: UInt32(payload.count), uncompressed: UInt32(entry.data.count)))
            locals.append(payload)
            central.append(centralHeader(name: nameData, method: method, time: time, day: day, crc: crc, compressed: UInt32(payload.count), uncompressed: UInt32(entry.data.count), offset: offset))
        }
        let directoryOffset = UInt32(locals.count)
        var result = locals
        result.append(central)
        var eocd = Data()
        eocd.appendU32(0x06054b50)
        eocd.appendU16(0)
        eocd.appendU16(0)
        eocd.appendU16(UInt16(entries.count))
        eocd.appendU16(UInt16(entries.count))
        eocd.appendU32(UInt32(central.count))
        eocd.appendU32(directoryOffset)
        eocd.appendU16(0)
        result.append(eocd)
        return result
    }

    private static func readLocal(data: Data, offset: Int, compressedSize: Int, uncompressedSize: Int, method: UInt16, crc: UInt32) throws -> Data {
        guard offset + 30 <= data.count, readU32(data, offset) == 0x04034b50 else {
            throw InventoryError.zipCorrupt("lokální hlavička")
        }
        let nameLength = Int(readU16(data, offset + 26))
        let extraLength = Int(readU16(data, offset + 28))
        let start = offset + 30 + nameLength + extraLength
        let end = start + compressedSize
        guard start >= 0, end <= data.count else { throw InventoryError.zipCorrupt("data položky") }
        let compressed = data.subdata(in: start..<end)
        let output: Data
        switch method {
        case 0:
            output = compressed
        case 8:
            if uncompressedSize == 0 {
                output = Data()
            } else {
                output = try inflate(compressed, uncompressedSize: uncompressedSize)
            }
        default:
            throw InventoryError.zipCorrupt("komprese \(method)")
        }
        if crc != 0, crc32(output) != crc {
            throw InventoryError.zipCorrupt("kontrolní součet")
        }
        return output
    }

    private static func localHeader(name: Data, method: UInt16, time: UInt16, day: UInt16, crc: UInt32, compressed: UInt32, uncompressed: UInt32) -> Data {
        var data = Data()
        data.appendU32(0x04034b50)
        data.appendU16(20)
        data.appendU16(0x0800)
        data.appendU16(method)
        data.appendU16(time)
        data.appendU16(day)
        data.appendU32(crc)
        data.appendU32(compressed)
        data.appendU32(uncompressed)
        data.appendU16(UInt16(name.count))
        data.appendU16(0)
        data.append(name)
        return data
    }

    private static func centralHeader(name: Data, method: UInt16, time: UInt16, day: UInt16, crc: UInt32, compressed: UInt32, uncompressed: UInt32, offset: UInt32) -> Data {
        var data = Data()
        data.appendU32(0x02014b50)
        data.appendU16(20)
        data.appendU16(20)
        data.appendU16(0x0800)
        data.appendU16(method)
        data.appendU16(time)
        data.appendU16(day)
        data.appendU32(crc)
        data.appendU32(compressed)
        data.appendU32(uncompressed)
        data.appendU16(UInt16(name.count))
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU16(0)
        data.appendU32(0)
        data.appendU32(offset)
        data.append(name)
        return data
    }

    private static func inflate(_ data: Data, uncompressedSize: Int) throws -> Data {
        var output = Data(count: uncompressedSize)
        let rc: Int32 = output.withUnsafeMutableBytes { rawOut in
            data.withUnsafeBytes { rawIn in
                var written = 0
                return keo_inflate_raw(
                    rawIn.bindMemory(to: UInt8.self).baseAddress,
                    data.count,
                    rawOut.bindMemory(to: UInt8.self).baseAddress,
                    uncompressedSize,
                    &written
                )
            }
        }
        guard rc == 0 else { throw InventoryError.zipCorrupt("inflate") }
        return output
    }

    private static func deflate(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        var capacity = data.count + data.count / 5 + 64
        for _ in 0..<6 {
            var output = Data(count: capacity)
            var written = 0
            let rc: Int32 = output.withUnsafeMutableBytes { rawOut in
                data.withUnsafeBytes { rawIn in
                    keo_deflate_raw(
                        rawIn.bindMemory(to: UInt8.self).baseAddress,
                        data.count,
                        rawOut.bindMemory(to: UInt8.self).baseAddress,
                        capacity,
                        &written
                    )
                }
            }
            if rc == 0 {
                output.removeSubrange(written..<output.count)
                return output
            }
            capacity *= 2
        }
        throw InventoryError.zipCorrupt("deflate")
    }

    private static func crc32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            keo_crc32(raw.bindMemory(to: UInt8.self).baseAddress, data.count)
        }
    }

    private static func findEOCD(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lower = max(0, data.count - 22 - 65535)
        var index = data.count - 22
        while index >= lower {
            if readU32(data, index) == 0x06054b50 {
                let comment = Int(readU16(data, index + 20))
                if index + 22 + comment == data.count { return index }
            }
            if index == 0 { break }
            index -= 1
        }
        return nil
    }

    private static func readU16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = UInt16(max(1980, parts.year ?? 1980) - 1980)
        let month = UInt16(parts.month ?? 1)
        let day = UInt16(parts.day ?? 1)
        let hour = UInt16(parts.hour ?? 0)
        let minute = UInt16(parts.minute ?? 0)
        let second = UInt16((parts.second ?? 0) / 2)
        let dosTime = (hour << 11) | (minute << 5) | second
        let dosDate = (year << 9) | (month << 5) | day
        return (dosTime, dosDate)
    }
}

private extension Data {
    mutating func appendU16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendU32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
