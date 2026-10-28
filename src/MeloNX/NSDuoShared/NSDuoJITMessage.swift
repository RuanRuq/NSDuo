import Foundation

// Shared by the host and its helper; no App Group or file URL crosses the IPC boundary.
nonisolated enum NSDuoJITMessage {
    // Keep this value in sync with NSDuoJITExtensionBridge.m.
    static let payloadKey = "com.nsduo.jit.message"
    static let maximumPayloadBytes = 4 * 1024 * 1024
    static let maximumPairingBytes = 2 * 1024 * 1024
    static let maximumScriptBytes = 256 * 1024
}

nonisolated struct NSDuoJITRequest: Codable, Sendable {
    enum Operation: String, Codable, Sendable {
        case enable
        case prepare
        case resetDDI
    }

    let requestID: UUID
    let operation: Operation
    let targetPID: Int32
    let pairingData: Data?
    let scriptBase64: String?
    let rsdPort: UInt16?
    let requiresScript: Bool

    init(requestID: UUID = UUID(), operation: Operation, targetPID: Int32,
         pairingData: Data? = nil, scriptBase64: String? = nil, rsdPort: UInt16? = nil, requiresScript: Bool = false) {
        self.requestID = requestID
        self.operation = operation
        self.targetPID = targetPID
        self.pairingData = pairingData
        self.scriptBase64 = scriptBase64
        self.rsdPort = rsdPort
        self.requiresScript = requiresScript
    }
}

nonisolated struct NSDuoJITResponse: Codable, Sendable {
    let requestID: UUID
    let success: Bool
    let message: String
    let txmPresent: Bool?
}
