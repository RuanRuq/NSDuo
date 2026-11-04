import Foundation
import Darwin
@_implementationOnly import idevice

/// NS Duo integration code using idevice's MIT API, not StikPair app code.
/// Only pairing runs here; attaching a debugger stays in the separate JIT helper.
@objc(NSDuoPairingRuntime)
@MainActor
public final class NSDuoPairingRuntime: NSObject {
    private static var active: PairingHostSession?

    @objc(startWithProgress:pin:completion:)
    public static func start(progress: @escaping (String) -> Void, pin: @escaping (String) -> Void,
                             completion: @escaping (Data?, NSError?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard active == nil else {
            completion(nil, pairingError("已有配对操作正在运行。"))
            return
        }
        let session = PairingHostSession(progress: progress, pin: pin) { data, error in
            active = nil
            completion(data, error)
        }
        active = session
        do { try session.start() }
        catch { session.finish(data: nil, error: error as NSError) }
    }

    @objc public static func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        active?.cancel("配对已取消，原有配对记录仍保留。")
    }
}

private func pairingError(_ message: String) -> NSError {
    NSError(domain: "NSDuoOnDevicePairing", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
}

private func checkPairingError(_ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
    guard let error else { return }
    defer { idevice_error_free(error) }
    // Upstream diagnostics can contain peer identifiers; present a local message.
    throw pairingError("系统未完成配对（协议错误 \(error.pointee.code)/\(error.pointee.sub_code)）。请确认开发者模式已开启，重新选择 NS Duo 并输入最新验证码。")
}

private final class PairingHostSession: NSObject, NetServiceDelegate, @unchecked Sendable {
    private static let worker = DispatchQueue(label: "com.nsduo.pairing", qos: .userInitiated)
    private var host: OpaquePointer?
    private var hostIRK = [UInt8](repeating: 0, count: 16)
    private var service: NetService?
    private var listeners = [DispatchSourceRead]()
    private var client: Int32 = -1
    private var accepting = false
    private var timer: DispatchWorkItem?
    private var cancelledMessage: String?
    private var completion: ((Data?, NSError?) -> Void)?
    private let progress: (String) -> Void
    private let pin: (String) -> Void

    init(progress: @escaping (String) -> Void, pin: @escaping (String) -> Void,
         completion: @escaping (Data?, NSError?) -> Void) {
        self.progress = progress
        self.pin = pin
        self.completion = completion
    }

    deinit { if let host { pairable_host_free(host) } }

    func start() throws {
        var serviceID: UnsafeMutablePointer<CChar>?
        var txt: UnsafeMutablePointer<UInt8>?
        var count = 0
        let result = "NS Duo".withCString { name in
            "Mac17,7".withCString { model in
                pairable_host_prepare(name, model, false, &host, &serviceID, &txt, &count, &hostIRK)
            }
        }
        defer {
            if let serviceID { idevice_string_free(serviceID) }
            if let txt { idevice_data_free(txt, UInt(count)) }
        }
        try checkPairingError(result)
        guard host != nil, let serviceID, let txt, count > 0,
              let records = try PropertyListSerialization.propertyList(
                from: Data(bytes: txt, count: count), format: nil) as? [String: String] else {
            throw pairingError("内置配对组件返回的数据无效，请更新 NS Duo。")
        }

        // Use a native socket for each family. Do not depend on IPv4-mapped
        // connections reaching an IPv6 socket on every iOS network stack.
        let ipv4 = try Self.makeListener(family: AF_INET, port: 0)
        var owned = [ipv4.fd]
        defer { for fd in owned { close(fd) } }
        let ipv6 = try Self.makeListener(family: AF_INET6, port: ipv4.port)
        owned.append(ipv6.fd)
        for fd in owned {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.acceptConnection(fd) }
            source.setCancelHandler { close(fd) }
            listeners.append(source)
            source.resume()
        }
        owned.removeAll()
        progress("listeningIPv4AndIPv6")

        let service = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.",
                                 name: String(cString: serviceID), port: Int32(ipv4.port))
        service.delegate = self
        guard service.setTXTRecord(NetService.data(fromTXTRecord: records.mapValues { Data($0.utf8) })) else {
            throw pairingError("无法发布本机配对信息。")
        }
        self.service = service
        service.publish()
        let timer = DispatchWorkItem { [weak self] in self?.cancel("配对等待超时，请回到 NS Duo 重新开始。") }
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: timer)
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard completion != nil, !accepting, cancelledMessage == nil else { return }
        progress("published")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        cancel("无法发布配对服务。请允许 NS Duo 访问本地网络，并连接 Wi-Fi 后重试。")
    }

    private func acceptConnection(_ fd: Int32) {
        guard !accepting, completion != nil else { return }
        var address = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let connected = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &size) }
        }
        guard connected >= 0 else {
            let code = errno
            if code != EAGAIN && code != EWOULDBLOCK && code != EINTR {
                progress("acceptFailed:\(code)")
            }
            return
        }
        progress(address.ss_family == sa_family_t(AF_INET) ? "acceptedIPv4" : "acceptedIPv6")
        // Never save a pairing initiated by a different phone on the same LAN.
        let local = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Self.isLocal($0, length: size) }
        }
        guard local else { close(connected); progress("rejectedPeer"); return }
        guard fcntl(connected, F_SETFL, 0) == 0 else {
            close(connected)
            finish(data: nil, error: pairingError("无法接收系统配对连接，请重新开始配对。"))
            return
        }
        var yes: Int32 = 1
        setsockopt(connected, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        accepting = true
        client = connected
        progress("connected")
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        Self.worker.async { [self] in
            let result = Result { try handshake(connected) }
            DispatchQueue.main.async { [self] in
                // Close on the state-owning queue so cancellation can never
                // shutdown a descriptor already recycled by another subsystem.
                close(connected)
                client = -1
                accepting = false
                if let cancelledMessage { finish(data: nil, error: pairingError(cancelledMessage)); return }
                switch result {
                case .success(let data): finish(data: data, error: nil)
                case .failure(let error): finish(data: nil, error: error as NSError)
                }
            }
        }
    }

    private func handshake(_ fd: Int32) throws -> Data {
        var record: OpaquePointer?
        defer { if let record { rp_pairing_file_free(record) } }
        let callback: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { value, context in
            guard let value, let context else { return }
            let code = String(cString: value)
            guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
            let session = Unmanaged<PairingHostSession>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [session] in
                guard session.completion != nil, session.cancelledMessage == nil else { return }
                session.pin(code)
            }
        }
        try checkPairingError(pairable_host_accept_fd(host, fd, callback,
            Unmanaged.passUnretained(self).toOpaque(), nil, &record))
        guard let record else { throw pairingError("系统没有返回配对记录，请重新配对。") }
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        let result = rp_pairing_file_to_bytes(record, &bytes, &count)
        defer { if let bytes { idevice_data_free(bytes, UInt(count)) } }
        try checkPairingError(result)
        guard let bytes, (1...1_048_576).contains(count),
              var plist = try PropertyListSerialization.propertyList(
                from: Data(bytes: bytes, count: count), format: nil) as? [String: Any] else {
            throw pairingError("系统返回的配对记录无效，请重新配对。")
        }
        // Retain our host identity alongside the peer keys, as required by idevice.
        plist["nsduo_host_alt_irk"] = Data(hostIRK)
        return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    }

    func cancel(_ message: String) {
        guard completion != nil else { return }
        cancelledMessage = message
        stopAdvertising()
        if accepting {
            // shutdown affects the fd duplicated by idevice; only the worker closes it.
            if client >= 0 { shutdown(client, SHUT_RDWR) }
        } else { finish(data: nil, error: pairingError(message)) }
    }

    func finish(data: Data?, error: NSError?) {
        stopAdvertising()
        let callback = completion
        completion = nil
        callback?(data, error)
    }

    private func stopAdvertising() {
        timer?.cancel()
        timer = nil
        for listener in listeners { listener.cancel() }
        listeners.removeAll()
        service?.stop()
        service?.delegate = nil
        service = nil
    }

    private static func makeListener(family: Int32, port: UInt16) throws -> (fd: Int32, port: UInt16) {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw pairingError("无法创建本机配对连接。") }
        var transferred = false
        defer { if !transferred { close(fd) } }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        if family == AF_INET6 {
            guard setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes,
                             socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else {
                throw pairingError("无法准备 IPv6 本机配对连接。")
            }
        }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            throw pairingError("无法准备本机配对连接。")
        }
        let bound: Int32
        if family == AF_INET {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            throw pairingError("无法启动本机配对服务，请稍后重试。")
        }
        var address = sockaddr_storage()
        var size = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard named == 0 else { throw pairingError("无法取得本机配对端口。") }
        let actualPort = withUnsafePointer(to: &address) { pointer in
            if family == AF_INET {
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
            }
            return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin6_port) }
        }
        transferred = true
        return (fd, actualPort)
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        guard address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        let value = String(cString: host).split(separator: "%").first.map(String.init) ?? ""
        return value.hasPrefix("::ffff:") ? String(value.dropFirst(7)) : value
    }

    private static func isLocal(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> Bool {
        guard let peer = numericHost(address, length: length) else { return false }
        if peer == "::1" || peer.hasPrefix("127.") { return true }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return false }
        defer { freeifaddrs(head) }
        var current = head
        while let entry = current {
            if let value = entry.pointee.ifa_addr,
               numericHost(value, length: socklen_t(value.pointee.sa_len)) == peer {
                return true
            }
            current = entry.pointee.ifa_next
        }
        return false
    }
}
