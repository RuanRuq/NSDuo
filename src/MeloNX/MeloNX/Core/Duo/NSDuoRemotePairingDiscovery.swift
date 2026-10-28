import Foundation
import Darwin

/// iOS may advertise a different remote-pairing port after reboot. Restrict
/// discovery to this phone's interface addresses, not another nearby device.
@MainActor
final class NSDuoRemotePairingDiscovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var continuation: CheckedContinuation<UInt16, Never>?
    private var timer: Task<Void, Never>?
    private let localAddresses = NSDuoRemotePairingDiscovery.interfaceAddresses()

    static func resolve() async -> UInt16 {
        let discovery = NSDuoRemotePairingDiscovery()
        return await withCheckedContinuation { continuation in
            discovery.continuation = continuation
            discovery.browser.delegate = discovery
            discovery.browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
            discovery.timer = Task { [discovery] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                discovery.finish(49152) // StikJIT's documented default, not proof of connection.
            }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 4)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) { finish(49152) }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard (1...65535).contains(sender.port),
              sender.addresses?.contains(where: { address in
                  address.withUnsafeBytes { bytes in
                      guard let raw = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr>.size else { return false }
                      let pointer = raw.assumingMemoryBound(to: sockaddr.self)
                      return Self.addressString(pointer, length: socklen_t(bytes.count)).map { localAddresses.contains($0) } ?? false
                  }
              }) == true else { return }
        finish(UInt16(sender.port))
    }

    private func finish(_ port: UInt16) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        timer = nil
        browser.stop()
        browser.delegate = nil
        for service in services { service.stop(); service.delegate = nil }
        services.removeAll()
        continuation.resume(returning: port)
    }

    private static func interfaceAddresses() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var addresses = Set<String>()
        var current = head
        while let entry = current {
            if let address = entry.pointee.ifa_addr,
               let value = addressString(address, length: socklen_t(address.pointee.sa_len)) {
                addresses.insert(value)
            }
            current = entry.pointee.ifa_next
        }
        return addresses
    }

    private static func addressString(_ address: UnsafePointer<sockaddr>, length: socklen_t) -> String? {
        guard address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self).split(separator: "%").first.map(String.init)
    }
}
