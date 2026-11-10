import Foundation

public enum HeartRateParser {
    /// Bluetooth SIG 2A37: little-endian RR values in units of 1/1024 second.
    public static func parse(_ bytes: [UInt8], at date: Date) throws -> HeartSample {
        guard let flags = bytes.first, flags & 0xE0 == 0 else { throw WakeError.malformedPacket }
        var offset = 1
        func read(_ count: Int) throws -> Int {
            guard offset + count <= bytes.count else { throw WakeError.malformedPacket }
            defer { offset += count }
            return count == 1 ? Int(bytes[offset]) : Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        let bpm = try read(flags & 1 == 0 ? 1 : 2)
        if flags & 8 != 0 { _ = try read(2) }
        var rr: [Double]? = nil
        if flags & 16 != 0 {
            guard offset < bytes.count, (bytes.count - offset).isMultiple(of: 2) else { throw WakeError.malformedPacket }
            rr = []
            while offset < bytes.count { rr?.append(Double(try read(2)) / 1024) }
        }
        guard offset == bytes.count else { throw WakeError.malformedPacket }
        return HeartSample(date: date, bpm: Double(bpm), contact: flags & 4 == 0 ? nil : flags & 2 != 0, rr: rr)
    }
}
