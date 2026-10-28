// Based on LocalDevVPN's PacketTunnelProvider.swift by Stossy11.
// Copyright (c) 2025 SideStore Team. See LICENSE.txt and README.md.

import NetworkExtension

// NetworkExtension calls across queues. All mutable state belongs to packetQueue.
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private let packetQueue = DispatchQueue(label: "NSDuoTunnel.packets")
    private var running = false
    private var generation = 0

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = ProviderCompletion(completionHandler)
        packetQueue.async {
            let interface = CIDREndpoint(TunnelConstants.interfaceAddress)
            let peer = CIDREndpoint(TunnelConstants.peerAddress)
            let ipv4 = NEIPv4Settings(addresses: [interface.ip], subnetMasks: [interface.subnetMask])
            ipv4.includedRoutes = [NEIPv4Route(destinationAddress: peer.ip, subnetMask: peer.subnetMask)]
            ipv4.excludedRoutes = [.default()]
            let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: peer.ip)
            settings.ipv4Settings = ipv4
            // Deliberately no DNS, IPv6 or default included route: only 10.7.0.1/32.
            self.generation += 1
            let attempt = self.generation
            self.setTunnelNetworkSettings(settings) { error in
                self.packetQueue.async {
                    guard self.generation == attempt else {
                        completion.call(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
                        return
                    }
                    guard error == nil else {
                        completion.call(error)
                        return
                    }
                    self.running = true
                    self.readPackets(generation: attempt)
                    completion.call(nil)
                }
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = ProviderCompletion<Void> { _ in completionHandler() }
        packetQueue.async {
            self.running = false
            self.generation += 1
            completion.call(())
        }
    }

    private func readPackets(generation attempt: Int) {
        guard running, generation == attempt else { return }
        packetFlow.readPackets { [weak self] packets, families in
            guard let self else { return }
            self.packetQueue.async {
                guard self.running, self.generation == attempt else { return }
                var reflectedPackets: [Data] = []
                var reflectedFamilies: [NSNumber] = []
                for (packet, family) in zip(packets, families) {
                    guard family.int32Value == AF_INET,
                          packet.count >= 20,
                          packet[0] >> 4 == 4,
                          Int(packet[0] & 0x0f) * 4 >= 20,
                          Int(packet[0] & 0x0f) * 4 <= packet.count,
                          Array(packet[16..<20]) == TunnelConstants.peerBytes else { continue }
                    var reflected = packet
                    // Swapping both addresses preserves the IPv4 and transport
                    // pseudo-header checksum. Byte access avoids alignment assumptions.
                    for offset in 0..<4 {
                        reflected[12 + offset] = packet[16 + offset]
                        reflected[16 + offset] = packet[12 + offset]
                    }
                    reflectedPackets.append(reflected)
                    reflectedFamilies.append(family)
                }
                if !reflectedPackets.isEmpty {
                    self.packetFlow.writePackets(reflectedPackets, withProtocols: reflectedFamilies)
                }
                self.readPackets(generation: attempt)
            }
        }
    }
}

// The legacy completion signatures are not annotated Sendable. The provider
// transfers each once and invokes it only on packetQueue, as permitted by NE.
private struct ProviderCompletion<Value>: @unchecked Sendable {
    let call: (Value) -> Void

    init(_ call: @escaping (Value) -> Void) { self.call = call }
}
