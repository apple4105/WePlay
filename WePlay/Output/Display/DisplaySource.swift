import Foundation

import Foundation

/// Wi-Fi Display（Miracast 1.0）Source 侧：把 H.264/AAC 推给显示端。
///
/// ## RTSP 流程（M1–M5）
///
/// ```
/// M1  OPTIONS *                            -> 对端回 Public: org.wfa.wfd1.0, ...
/// M2  GET_PARAMETER                        -> 对端回能力：
///                                              wfd_video_formats（AVC）
///                                              wfd_audio_codecs: AAC 0000000F 00
///                                              wfd_uibc_capability: ...SingleTouch;port=none
///                                              wfd_client_rtp_ports: RTP/AVP/UDP;unicast 19000 0
/// M3  SET_PARAMETER                        -> 我们回自己的能力 + 选定的格式 + input 端口
/// M4  SETUP rtsp://<host>/wfd1.0/streamid=0 -> 对端回 RTP 目标地址/端口
/// M5  PLAY                                 -> 开始推流
/// ```
///
/// 输入回传：对端声明 `port=none`，意味着复用 RTSP 连接（见 `InputServer`）。
final class DisplaySource {

    // MARK: - 回调

    var onLog: ((String) -> Void)?
    var onStateChanged: ((DisplaySource.State) -> Void)?

    /// 拿到车机声明的显示参数（W×H/dpi/fps）——用它去回应 Link 的能力协商
    var onDisplayMode: ((CarDisplayMode) -> Void)?

    /// 会话建立，可以开始推流了
    var onReady: ((DisplaySession) -> Void)?

    var onFailure: ((Error) -> Void)?

    // MARK: - 状态

    enum State: Equatable {
        case idle
        case connecting
        case negotiating
        case playing
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { onStateChanged?(state) }
    }

    /// 车机的 RTSP 端点（BLE 握手里拿到的 IP + 端口）
    private var host: String = ""
    private var port: UInt16 = 7236
    private var cseq: Int = 0

    /// 连接（Transport 由调用方给，方便测试时换内存管道）
    private var connection: DisplayTransport?

    /// 车机声明
    private var sinkVideoFormats: String = ""
    private var sinkAudioCodecs: String = ""
    private var sinkInput: String = ""
    private var carDisplayMode: CarDisplayMode?
    private var sinkRTPPorts: String = ""

    init() {}

    // MARK: - 连接

    func connect(host: String, port: UInt16, transport: DisplayTransport? = nil) {
        self.host = host
        self.port = port
        state = .connecting
        onLog?("[Display] 连接 rtsp://\(host):\(port)/wfd1.0")

        let transport = transport ?? TCPTransport(host: host, port: port)
        self.connection = transport
        transport.onData = { [weak self] data in self?.handleReceived(data) }
        transport.onError = { [weak self] error in
            self?.state = .failed(error.localizedDescription)
            self?.onFailure?(error)
        }
        transport.start()

        // M1
        sendOptions()
    }

    func stop() {
        if state == .playing { sendTeardown() }
        connection?.stop()
        connection = nil
        state = .idle
    }

    // MARK: - M1 OPTIONS

    private func sendOptions() {
        state = .negotiating
        sendRequest("OPTIONS * RTSP/1.0", headers: [
            "Require": "org.wfa.wfd1.0",
            "Proxy-Require": "org.wfa.wfd1.0"
        ])
    }

    // MARK: - M2 获取车机能力

    private func sendGetParameter() {
        sendRequest("GET_PARAMETER rtsp://\(host):\(port)/wfd1.0 RTSP/1.0", headers: [
            "Require": "org.wfa.wfd1.0",
            "Content-Type": "text/parameters"
        ], body: [
            "wfd_video_formats",
            "wfd_audio_codecs",
            "wfd_uibc_capability",
            "wfd_car_display_mode",   // 显示端自定义的屏幕参数（宽高/DPI/帧率）
            "wfd_client_rtp_ports",
            "wfd_connector_type"
        ].joined(separator: "\r\n"))
    }

    // MARK: - M3 上报自己的能力 + 选定格式

    private func sendSetParameter(videoFormat: String, audioFormat: String) {
        var body: [String] = []
        body.append("wfd_video_formats: \(sourceVideoFormats)")
        body.append("wfd_audio_codecs: \(sourceAudioCodecs)")
        body.append("wfd_uibc_capability: input_category_list=GENERIC;generic_cap_list=Keyboard, Mouse, SingleTouch;hidc_cap_list=none;port=\(InputServer.defaultPort)")
        body.append("wfd_client_rtp_ports: RTP/AVP/UDP;unicast \(RTPPacketizer.defaultVideoPort) \(RTPPacketizer.defaultAudioPort)")
        body.append("wfd_presentation_URL: rtsp://\(host):\(port)/wfd1.0/streamid=0 none")
        body.append("wfd_trigger_method: SETUP")
        body.append("wfd_idr_request_capability: supported")

        sendRequest("SET_PARAMETER rtsp://\(host):\(port)/wfd1.0 RTSP/1.0", headers: [
            "Require": "org.wfa.wfd1.0",
            "Content-Type": "text/parameters"
        ], body: body.joined(separator: "\r\n"))
    }

    // MARK: - M4 SETUP

    private func sendSetup() {
        sendRequest("SETUP rtsp://\(host):\(port)/wfd1.0/streamid=0 RTSP/1.0", headers: [
            "Transport": "RTP/AVP/UDP;unicast;client_port=\(RTPPacketizer.defaultVideoPort)-\(RTPPacketizer.defaultAudioPort)",
            "Require": "org.wfa.wfd1.0"
        ])
    }

    // MARK: - M5 PLAY

    private func sendPlay() {
        sendRequest("PLAY rtsp://\(host):\(port)/wfd1.0/streamid=0 RTSP/1.0", headers: [
            "Require": "org.wfa.wfd1.0",
            "Session": sessionID ?? "00000000"
        ])
    }

    private func sendTeardown() {
        sendRequest("TEARDOWN rtsp://\(host):\(port)/wfd1.0/streamid=0 RTSP/1.0", headers: [
            "Require": "org.wfa.wfd1.0",
            "Session": sessionID ?? "00000000"
        ])
    }

    // MARK: - 收发

    private var sessionID: String?
    private var pendingRequests: [Int: (RTSPResponse) -> Void] = [:]

    private func nextCSeq() -> Int {
        cseq += 1
        return cseq
    }

    private func sendRequest(_ requestLine: String, headers: [String: String], body: String? = nil) {
        var msg = "\(requestLine)\r\nCSeq: \(nextCSeq())\r\n"
        for (k, v) in headers {
            msg += "\(k): \(v)\r\n"
        }
        if let body {
            msg += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        } else {
            msg += "\r\n"
        }
        let seq = cseq
        onLog?("[Display] → \(requestLine.components(separatedBy: " ").first ?? "") (CSeq \(seq))")
        pendingRequests[seq] = { [weak self] response in
            self?.handleResponse(seq: seq, response: response)
        }
        connection?.send(Data(msg.utf8))
    }

    /// 我们（Source）声明的能力
    private var sourceVideoFormats: String {
        // 格式：profile/level 用十进制，参照 Display 规范的 16 字节编码
        "00 00 02 10 0001ffff00000000 00000000 00000000 00 0000 0000 00 none none"
    }

    private var sourceAudioCodecs: String {
        // AAC，与车机声明的 `AAC 0000000F 00` 对齐
        "AAC 0000000F 00"
    }

    // MARK: - 收

    private var receiveBuffer = Data()

    private func handleReceived(_ data: Data) {
        receiveBuffer.append(data)
        // 按 \r\n\r\n 切出完整响应（v1 假设响应不带 body；带 body 的按 Content-Length 处理）
        while let range = receiveBuffer.firstRange(of: Data("\r\n\r\n".utf8)) {
            let head = receiveBuffer.subdata(in: receiveBuffer.startIndex ..< range.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex ... range.upperBound)

            guard let text = String(data: head, encoding: .utf8) else { continue }
            let response = RTSPResponse.parse(text)
            onLog?("[Display] ← \(response.statusLine)")
            if let seq = response.cSeq, let handler = pendingRequests.removeValue(forKey: seq) {
                handler(response)
            }
        }
    }

    private func handleResponse(seq: Int, response: RTSPResponse) {
        for (key, value) in response.bodyParameters {
            switch key {
            case "wfd_video_formats": sinkVideoFormats = value
            case "wfd_audio_codecs": sinkAudioCodecs = value
            case "wfd_uibc_capability": sinkInput = value
            case "wfd_car_display_mode":
                if let mode = CarDisplayMode.parse(value) {
                    carDisplayMode = mode
                    onLog?("[Display] 车机显示参数：\(mode.width)×\(mode.height) @\(mode.fps)fps dpi=\(mode.dpi)")
                    onDisplayMode?(mode)
                }
            case "wfd_client_rtp_ports": sinkRTPPorts = value
            default: break
            }
        }

        switch response.statusCode {
        case 200:
            switch seq {
            case 1: sendGetParameter()                       // M1 回完 → M2
            case 2: sendSetParameter(videoFormat: sinkVideoFormats, audioFormat: sinkAudioCodecs)  // M2 回完 → M3
            case 3: sendSetup()                              // M3 回完 → M4
            case 4:
                sessionID = response.session
                sendPlay()                                   // M4 回完 → M5
            case 5:
                state = .playing
                let session = DisplaySession(host: host, port: port, sessionID: sessionID ?? "")
                onReady?(session)
            default: break
            }
        default:
            state = .failed("RTSP \(response.statusCode)")
            onFailure?(DisplaySourceError.badStatus(response.statusCode))
        }
    }
}


struct CarDisplayMode: Equatable {
    var mode: Int
    var width: Int
    var height: Int
    var dpi: Int
    var fps: Int

    /// 解析车机声明的字符串
    static func parse(_ s: String) -> CarDisplayMode? {
        var mode = 0, w = 0, h = 0, dpi = 0, fps = 0
        for part in s.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).trimmingCharacters(in: .whitespaces)
            let value = String(kv[1]).trimmingCharacters(in: .whitespaces)
            switch key {
            case "mode": mode = Int(value) ?? 0
            case "display":
                let wh = value.split(separator: ":")
                if wh.count == 2 {
                    w = Int(wh[0]) ?? 0
                    h = Int(wh[1]) ?? 0
                }
            case "dpi": dpi = Int(value) ?? 0
            case "fps": fps = Int(value) ?? 0
            default: break
            }
        }
        guard w > 0, h > 0 else { return nil }
        return CarDisplayMode(mode: mode, width: w, height: h, dpi: dpi, fps: fps)
    }
}

/// Display 会话建立后的信息
struct DisplaySession {
    var host: String
    var port: UInt16
    var sessionID: String
}

enum DisplaySourceError: Error, CustomStringConvertible {
    case badStatus(Int)
    case transportFailed(String)

    var description: String {
        switch self {
        case .badStatus(let code): return "RTSP 返回 \(code)"
        case .transportFailed(let m): return "传输失败：\(m)"
        }
    }
}

// MARK: - 传输抽象（方便测试时换内存管道）

protocol DisplayTransport {
    var onData: ((Data) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    func start()
    func send(_ data: Data)
    func stop()
}

/// 真机用的 TCP 传输
final class TCPTransport: DisplayTransport {
    var onData: ((Data) -> Void)?
    var onError: ((Error) -> Void)?

    private let host: String
    private let port: UInt16
    private var inputStream: InputStream?
    private var outputStream: OutputStream?
    private var running = false

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
    func start() {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)
        guard let readStream, let writeStream else {
            onError?(DisplaySourceError.transportFailed("建流失败"))
            return
        }
        inputStream = readStream.takeRetainedValue()
        outputStream = writeStream.takeRetainedValue()

        inputStream?.open()
        outputStream?.open()
        running = true

        // 后台读循环（不用 delegate，简单可靠）
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
            defer { buffer.deallocate() }
            while self.running {
                let read = self.inputStream?.read(buffer, maxLength: 64 * 1024) ?? 0
                if read > 0 {
                    self.onData?(Data(bytes: buffer, count: read))
                } else if read < 0 {
                    self.onError?(DisplaySourceError.transportFailed("读失败"))
                    break
                } else {
                    usleep(5_000)
                }
            }
        }
    }

    func send(_ data: Data) {
        outputStream?.write([UInt8](data), maxLength: data.count)
    }

    func stop() {
        running = false
        inputStream?.close()
        outputStream?.close()
    }
}
