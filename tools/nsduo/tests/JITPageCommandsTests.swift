import Foundation

@main
struct JITPageCommandsTests {
    static func main() {
        // Actual crash addresses, the old 36-bit boundary, and a full-width address.
        let addresses: [UInt64] = [0x8000, 0xffffff000, 0x1000000000,
                                   0x7000008000, 0x7020000000, 0xf123456789abc000]
        var checked = 0
        for base in addresses {
            for count in [1, 128, 129] {
                let bytes = JITPageCommands.make(startAddress: base, pageCount: count)
                precondition(bytes.count == count * JITPageCommands.commandLength)
                for page in 0..<count {
                    let offset = page * JITPageCommands.commandLength
                    let packet = Array(bytes[offset..<(offset + JITPageCommands.commandLength)])
                    let text = String(decoding: packet, as: UTF8.self)
                    let addressText = String(text.dropFirst(2).prefix(16))
                    precondition(UInt64(addressText, radix: 16) == base + UInt64(page) * 16384,
                                 "JIT address was truncated: \(text)")
                    precondition(text.hasPrefix("$M") && text.contains(",1:69#"))
                    let body = packet[1..<23]
                    precondition(UInt8(text.suffix(2), radix: 16) == body.reduce(UInt8(0), &+))
                    checked += 1
                }
            }
        }
        precondition(JITPageCommands.isSuccessfulReply("OK"))
        for invalid: String? in [nil, "", "E14", "E01", "+", "T05thread:1;"] {
            precondition(!JITPageCommands.isSuccessfulReply(invalid))
        }
        print("PASS: \(checked) JIT page addresses/checksums, batch boundaries, and reply validation")
    }
}
