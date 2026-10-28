//
//  NSDuoPackageInspector.swift
//  MeloNX
//

import Foundation

nonisolated struct NSDuoPackageContent: Codable, Sendable {
    let kind: String
    let titleID: String
    let applicationID: String
    let version: UInt32
    let displayVersion: String?
    let ncaPath: String?
}

nonisolated enum NSDuoPackageInspector {
    private struct Response: Decodable {
        let contents: [NSDuoPackageContent]
        let error: String?
    }

    private enum InspectionError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message): return message
            }
        }
    }

    // Call only on the serial library worker while emulation is stopped. The
    // caller owns the file's security scope/coordination for this entire call.
    static func inspect(_ url: URL) throws -> [NSDuoPackageContent] {
        guard url.isFileURL, ["xci", "nsp"].contains(url.pathExtension.lowercased()) else {
            throw InspectionError.message("请选择 XCI 或 NSP 游戏包。")
        }

        let pointer = url.path.withCString { nsduo_inspect_package($0) }
        guard let pointer else {
            throw InspectionError.message("无法分配游戏包检测结果，请稍后重试。")
        }
        defer { nsduo_free_package_inspection(pointer) }

        guard let json = String(validatingCString: pointer) else {
            throw InspectionError.message("游戏包检测结果不是有效的 UTF-8 数据。")
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(json.utf8))
        } catch {
            throw InspectionError.message("无法解析游戏包检测结果：\(error.localizedDescription)")
        }
        if let error = response.error {
            throw InspectionError.message(error)
        }
        guard !response.contents.isEmpty,
              response.contents.allSatisfy({ content in
                  ["application", "patch", "dlc"].contains(content.kind) &&
                  isTitleID(content.titleID) && isTitleID(content.applicationID) &&
                  (content.kind != "dlc" || content.ncaPath?.hasPrefix("/") == true)
              }) else {
            throw InspectionError.message("游戏包检测结果缺少有效的内容元数据。")
        }
        return response.contents
    }

    private static func isTitleID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        } && UInt64(value, radix: 16) != 0
    }
}

@_silgen_name("nsduo_inspect_package")
private nonisolated func nsduo_inspect_package(_ path: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?

@_silgen_name("nsduo_free_package_inspection")
private nonisolated func nsduo_free_package_inspection(_ pointer: UnsafeMutablePointer<CChar>)
