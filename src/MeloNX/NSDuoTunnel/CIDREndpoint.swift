// CIDREndpoint extracted from LocalDevVPN's CIDRValidator.swift.
// Created by Magesh K on 16/08/26. Copyright © 2026 LocalDevVPN.
// Based on LocalDevVPN; see LICENSE.txt and README.md in this directory.

import Foundation

public struct CIDREndpoint: Equatable, Sendable {
    public let raw: String
    public let ip: String
    public let prefix: Int
    public let subnetMask: String

    public var formattedCIDR: String {
        "\(ip)/\(prefix)"
    }

    public init(_ input: String, defaultPrefix: Int = 32) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        self.raw = trimmed
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        
        let ipPart = String(parts.first ?? "").trimmingCharacters(in: .whitespaces)
        self.ip = ipPart.isEmpty ? "0.0.0.0" : ipPart
        
        if parts.count == 2, let parsedPrefix = Int(parts[1].trimmingCharacters(in: .whitespaces)), (0...32).contains(parsedPrefix) {
            self.prefix = parsedPrefix
        } else {
            self.prefix = defaultPrefix
        }
        
        self.subnetMask = Self.prefixToSubnetMask(self.prefix)
    }

    public init(ip: String, prefix: Int, subnetMask: String? = nil, raw: String? = nil) {
        self.ip = ip
        self.prefix = prefix
        self.subnetMask = subnetMask ?? Self.prefixToSubnetMask(prefix)
        self.raw = raw ?? "\(ip)/\(prefix)"
    }

    public static func prefixToMaskRaw(_ prefix: Int) -> UInt32 {
        guard prefix > 0 else { return 0 }
        guard prefix < 32 else { return 0xFFFFFFFF }
        return ~((1 << (32 - prefix)) - 1)
    }

    public static func prefixToSubnetMask(_ prefix: Int) -> String {
        guard (0...32).contains(prefix) else { return "255.255.255.255" }
        let mask = prefixToMaskRaw(prefix)
        let b1 = (mask >> 24) & 0xFF
        let b2 = (mask >> 16) & 0xFF
        let b3 = (mask >> 8) & 0xFF
        let b4 = mask & 0xFF
        return "\(b1).\(b2).\(b3).\(b4)"
    }
}

