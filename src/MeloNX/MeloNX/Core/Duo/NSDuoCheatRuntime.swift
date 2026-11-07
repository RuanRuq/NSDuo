import Foundation

@_silgen_name("nsduo_cheat_request")
nonisolated private func requestNativeCheats(_ json: UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
@_silgen_name("nsduo_free_cheat_response")
nonisolated private func freeNativeCheatResponse(_ response: UnsafeMutablePointer<CChar>)

nonisolated struct NSDuoCheatRuntimeInfo: Decodable, Sendable {
    let titleID: String
    let buildIDs: [String]
}

nonisolated struct NSDuoCheatRuntimeEntry: Codable, Sendable {
    let id: String
    let name: String
    let instructions: [String]
    let enabled: Bool
}

nonisolated struct NSDuoCheatRuntimeGroup: Codable, Sendable {
    let buildID: String
    let entries: [NSDuoCheatRuntimeEntry]
}

nonisolated enum NSDuoCheatRuntime {
    static func info() throws -> NSDuoCheatRuntimeInfo {
        let response = try request(Request(action: "info", titleID: nil, groups: nil))
        guard !response.titleID.isEmpty, !response.buildIDs.isEmpty else {
            throw RuntimeError(message: "当前游戏的 Build ID 尚未准备好。")
        }
        return NSDuoCheatRuntimeInfo(titleID: response.titleID, buildIDs: response.buildIDs)
    }

    static func apply(titleID: String, groups: [NSDuoCheatRuntimeGroup]) throws {
        _ = try request(Request(action: "apply", titleID: titleID, groups: groups))
    }

    private struct Request: Encodable {
        let action: String
        let titleID: String?
        let groups: [NSDuoCheatRuntimeGroup]?
    }

    private struct Response: Decodable {
        let success: Bool
        let message: String
        let titleID: String
        let buildIDs: [String]
    }

    private struct RuntimeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func request(_ request: Request) throws -> Response {
        let data = try JSONEncoder().encode(request)
        let json = String(decoding: data, as: UTF8.self)
        let dataResponse: Data = try json.withCString { pointer in
            guard let response = requestNativeCheats(pointer) else {
                throw RuntimeError(message: "金手指运行接口暂不可用。")
            }
            defer { freeNativeCheatResponse(response) }
            return Data(bytes: response, count: strlen(response))
        }
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: dataResponse)
        } catch {
            throw RuntimeError(message: "无法读取金手指运行状态。")
        }
        guard response.success else {
            throw RuntimeError(message: response.message.isEmpty ? "金手指设置失败。" : response.message)
        }
        return response
    }
}
