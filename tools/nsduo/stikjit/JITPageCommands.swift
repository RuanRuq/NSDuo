// SPDX-License-Identifier: MPL-2.0
// Derived from StikJIT 1.9.0 ScriptRunner; NS Duo preserves all 64 address bits.
enum JITPageCommands {
    static let pageSize: UInt64 = 16_384
    // $M + 16 address digits + ,1:69 + # + two checksum digits.
    static let commandLength = 26

    static func make(startAddress: UInt64, pageCount: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: pageCount * commandLength)
        for page in 0..<pageCount {
            let address = startAddress + UInt64(page) * pageSize
            let start = page * commandLength
            buffer[start] = UInt8(ascii: "$")
            buffer[start + 1] = UInt8(ascii: "M")
            for nibble in 0..<16 {
                let shift = UInt64((15 - nibble) * 4)
                buffer[start + 2 + nibble] = hexDigit(UInt8((address >> shift) & 0xf))
            }
            for (offset, byte) in ",1:69#".utf8.enumerated() {
                buffer[start + 18 + offset] = byte
            }
            let checksum = buffer[(start + 1)..<(start + 23)].reduce(UInt8(0), &+)
            buffer[start + 24] = hexDigit(checksum >> 4)
            buffer[start + 25] = hexDigit(checksum & 0xf)
        }
        return buffer
    }

    static func isSuccessfulReply(_ reply: String?) -> Bool { reply == "OK" }

    private static func hexDigit(_ value: UInt8) -> UInt8 {
        value < 10 ? value + UInt8(ascii: "0") : value - 10 + UInt8(ascii: "a")
    }
}
