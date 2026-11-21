import Foundation

/// RTSP 响应的最小解析。
struct RTSPResponse {
    var statusCode: Int
    var statusLine: String
    var cSeq: Int?
    var session: String?

    /// 响应体里的 `wfd_*` 参数（SET_PARAMETER/GET_PARAMETER 的回复）
    var bodyParameters: [(key: String, value: String)] = []

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
