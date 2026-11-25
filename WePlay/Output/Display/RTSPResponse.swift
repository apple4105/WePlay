import Foundation

/// RTSP 字节流拆分器，支持半包、粘包和 Content-Length body。
struct RTSPResponseStreamParser {
    private var buffer = Data()
    private let maxResponseBytes = 4 * 1024 * 1024

    mutating func append(_ chunk: Data) throws -> [RTSPResponse] {
        guard buffer.count + chunk.count <= maxResponseBytes else {
            buffer.removeAll(keepingCapacity: true)
            throw RTSPResponseError.responseTooLarge
        }
        buffer.append(chunk)
        var responses: [RTSPResponse] = []
        let separator = Data("\r\n\r\n".utf8)

        while let range = buffer.range(of: separator) {
            let header = buffer.subdata(in: buffer.startIndex ..< range.lowerBound)
            guard let headerText = String(data: header, encoding: .utf8) else {
                buffer.removeAll(keepingCapacity: true)
                throw RTSPResponseError.invalidEncoding
            }
            guard let contentLength = RTSPResponse.contentLength(in: headerText) else {
                buffer.removeAll(keepingCapacity: true)
                throw RTSPResponseError.invalidContentLength
            }
            let bodyStart = range.upperBound
            guard buffer.count - bodyStart >= contentLength else { return responses }
            let end = bodyStart + contentLength
            let message = buffer.subdata(in: buffer.startIndex ..< end)
            buffer.removeSubrange(buffer.startIndex ..< end)
            guard let text = String(data: message, encoding: .utf8) else {
                throw RTSPResponseError.invalidEncoding
            }
            responses.append(RTSPResponse.parse(text))
        }
        return responses
    }
}

enum RTSPResponseError: Error, Equatable, CustomStringConvertible {
    case responseTooLarge
    case invalidEncoding
    case invalidContentLength

    var description: String {
        switch self {
        case .responseTooLarge: return "RTSP 响应超限"
        case .invalidEncoding: return "RTSP 响应不是 UTF-8"
        case .invalidContentLength: return "RTSP Content-Length 无效"
        }
    }
}

/// RTSP 响应的最小解析。
struct RTSPResponse {
    var statusCode: Int
    var statusLine: String
    var cSeq: Int?
    var session: String?

    /// 响应体里的 `wfd_*` 参数（SET_PARAMETER/GET_PARAMETER 的回复）
    var bodyParameters: [(key: String, value: String)] = []

    static func contentLength(in header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "content-length" else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return Int(value).flatMap { $0 >= 0 ? $0 : nil }
        }
        return 0
    }

    static func parse(_ text: String) -> RTSPResponse {
        let lines = text.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            return RTSPResponse(statusCode: 0, statusLine: text)
        }

        // "RTSP/1.0 200 OK"
        let parts = statusLine.split(separator: " ")
        let code = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0

        var cSeq: Int?
        var session: String?
        var params: [(String, String)] = []

        var inBody = false
        for line in lines.dropFirst() {
            if line.isEmpty {
                inBody = true
                continue
            }
            if !inBody {
                // 头部
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[line.startIndex ..< colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    switch key.lowercased() {
                    case "cseq": cSeq = Int(value)
                    case "session":
                        // "Session: 12345678;timeout=60"
                        session = value.split(separator: ";").first.map(String.init)
                    default: break
                    }
                }
            } else {
                // 响应体：每行一个 "key: value"（text/parameters）
                if let colon = line.firstIndex(of: ":") {
                    let key = String(line[line.startIndex ..< colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    params.append((key, value))
                }
            }
        }

        return RTSPResponse(statusCode: code, statusLine: statusLine, cSeq: cSeq, session: session, bodyParameters: params)
    }
}
