// SPDX-License-Identifier: MPL-2.0
// StikJIT 1.9.0, modified by NS Duo: full-width addresses and checked page replies.
import Foundation
import JavaScriptCore
@_implementationOnly import idevice

final class ScriptRunner {

    private static let jitPageSize: UInt64 = 16384
    private static let commandsPerBatch = 128

    private let targetPID: Int32
    private let debugProxy: OpaquePointer
    private let script: StikJIT.Script
    private let progress: (String) -> Void
    private var context: JSContext?
    private var executionError: StikJITError?

    init(targetPID: Int32, debugProxy: OpaquePointer, script: StikJIT.Script, progress: @escaping (String) -> Void) {
        self.targetPID = targetPID
        self.debugProxy = debugProxy
        self.script = script
        self.progress = progress
    }

    func run() throws {
        let source = try BundledScript.source(for: script)

        guard let context = JSContext() else { throw StikJITError.scriptUnavailable }
        self.context = context

        context.exceptionHandler = { [weak self] _, value in
            let detail = value?.toString() ?? "unknown JavaScript exception"
            self?.recordExecutionError(.scriptExecution(detail))
        }

        let getPID: @convention(block) () -> Int = { [targetPID] in Int(targetPID) }
        let send: @convention(block) (String?) -> String = { [weak self] command in
            guard let self, let command else { return "" }
            return self.sendCommand(command) ?? ""
        }
        let prepare: @convention(block) (Double, Double) -> String = { [weak self] address, length in
            guard let self else { return "" }
            return self.prepareMemoryRegion(UInt64(address), length: UInt64(length)) ?? ""
        }
        let log: @convention(block) (JSValue?) -> Void = { [weak self] value in
            self?.progress(value?.toString() ?? "")
        }

        context.setObject(getPID,  forKeyedSubscript: "get_pid" as NSString)
        context.setObject(send,    forKeyedSubscript: "send_command" as NSString)
        context.setObject(prepare, forKeyedSubscript: "prepare_memory_region" as NSString)
        context.setObject(log,     forKeyedSubscript: "log" as NSString)

        progress("Running \(script.name) against pid \(targetPID)…")
        context.evaluateScript(source)
        if let executionError { throw executionError }
        progress("JIT script finished (region blessed, detached).")
    }

    private func sendCommand(_ command: String) -> String? {
        guard let handle = command.withCString({ debugserver_command_new($0, nil, 0) }) else { return nil }
        defer { debugserver_command_free(handle) }
        var response: UnsafeMutablePointer<CChar>?
        if let error = debug_proxy_send_command(debugProxy, handle, &response) {
            recordExecutionError(IdeviceFFI.consume(error, fallback: "send_command"))
            return nil
        }
        guard let response else { return "" }
        defer { idevice_string_free(response) }
        return String(cString: response)
    }

    private func prepareMemoryRegion(_ address: UInt64, length: UInt64) -> String? {
        guard length > 0 else { return "OK" }
        let pageCount = Int((length - 1) / Self.jitPageSize + 1)

        let commandBuffer = JITPageCommands.make(startAddress: address, pageCount: pageCount)

        for batchStart in stride(from: 0, to: pageCount, by: Self.commandsPerBatch) {
            let commandsInBatch = min(Self.commandsPerBatch, pageCount - batchStart)
            let byteOffset = batchStart * JITPageCommands.commandLength
            let byteCount = commandsInBatch * JITPageCommands.commandLength

            let sendError = commandBuffer.withUnsafeBytes { rawBuffer -> UnsafeMutablePointer<IdeviceFfiError>? in
                let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
                return debug_proxy_send_raw(debugProxy, base.advanced(by: byteOffset), UInt(byteCount))
            }
            if let sendError {
                recordExecutionError(IdeviceFFI.consume(sendError, fallback: "debug_proxy_send_raw"))
                return nil
            }

            var pageWriteFailed = false
            for _ in 0..<commandsInBatch {
                var response: UnsafeMutablePointer<CChar>?
                let readError = debug_proxy_read_response(debugProxy, &response)
                let reply = response.map { String(cString: $0) }
                if let response { idevice_string_free(response) }
                if let readError {
                    recordExecutionError(IdeviceFFI.consume(readError, fallback: "debug_proxy_read_response"))
                    return nil
                }
                if !JITPageCommands.isSuccessfulReply(reply) {
                    // Do not claim ready after E14/empty/unexpected RSP replies.
                    // The script must stop before it asks the core to execute.
                    recordExecutionError(.scriptExecution("JIT 内存页准备失败，设备未确认写入。请重新打开 NS Duo 后重试。"))
                    // Drain this batch so a subsequent detach sees its own reply.
                    pageWriteFailed = true
                }
            }
            if pageWriteFailed { return nil }
        }

        progress("Blessed \(pageCount) JIT page(s) at 0x\(String(address, radix: 16))")
        return "OK"
    }

    private func recordExecutionError(_ error: StikJITError) {
        if executionError == nil {
            executionError = error
            progress(error.localizedDescription)
        }
    }

}
