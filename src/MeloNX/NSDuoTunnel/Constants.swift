// Based on LocalDevVPN by SideStore Team, Stossy11 and Magesh K.
// See LICENSE.txt and README.md in this directory.

enum TunnelConstants {
    static let interfaceAddress = "10.7.1.1/32"
    static let peerAddress = "10.7.0.1/32"
    static let peerBytes: [UInt8] = [10, 7, 0, 1]
}
