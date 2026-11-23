import Foundation
import CoreBluetooth
import Darwin
import CryptoKit

/// 虚拟配件传输层：把本机伪装成一台 CarPlay 车机，让 iPhone 的 CarPlay 栈
/// 主动连上来。
///
/// ## 数据通路（照 CarWithin 的 DirectAccessoryTransport 还原）
///
/// ```
/// iPhone CarPlay 栈
///     │ (iAP2 包)
///     ▼
/// CoreAccessories.createEndpointWithTransportType:… andDataOutHandler:<block>
///     │  block 收到 (connectionUUID, endpointUUID, data)
///     ▼
/// DirectAccessoryTransport ──onData──►  LinkParser ──► 我们的会话层
///
/// 反向（触摸/控制回传）：
/// 会话层 ──processIncomingData:forEndpointWithUUID:──► iPhone
/// ```
///
/// ## 私有框架访问
///
/// `CoreAccessories.framework` 是私有框架，运行时 dlopen + NSClassFromString，
/// 编译期不需要 SDK 符号（Xcode 任何版本都能编）。
/// 调用面见研究文档 4.84：`sharedClient` / `createConnectionWithType:` /
/// `createEndpointWithTransportType:…` / `processIncomingData:` / `destroy…`。
///
/// ## 失败分支（照 CarWithin 的错误字符串，联调时逐条可对）
///
/// - 类查找失败 → "unavailable on this iOS build"
/// - 方法解析失败 → "transport methods are unavailable or have changed"
/// - 连接被拒 → "refused the connection … may lack access to the private transport"
/// - endpoint 发布被拒 → "refused to publish an iAP2 endpoint"
final class DirectAccessoryTransport: NSObject {

    // MARK: - 回调

    /// iPhone → 配件方向的数据（iAP2 包的原始字节）
    var onData: ((Data) -> Void)?

    /// 状态日志（联调诊断核心）
    var onLog: ((String) -> Void)?

    /// endpoint 已发布、通路就绪
    var onReady: (() -> Void)?

    /// 不可恢复失败
    var onFailure: ((String) -> Void)?

    /// MFi 身份（证书 + 私钥）。用于派生配件 MAC 和后续认证。
    /// AccessoryIdentity 是 struct，只能强引用。
    var identity: AccessoryIdentity?

    // MARK: - 常量

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories"
    private static let clientClassName = "ACCTransportClient"

    /// 传输类型枚举值——真机诊断时逐个尝试（错误分支会明说拒绝原因）
    private static let transportTypesToTry: [Int] = [2, 1, 0]

    /// `createEndpoint…andProtocol:` 的取值。
    ///
    /// CarWithin `DirectAccessoryTransport.m` 传的是**整数 4**，不是字符串。
    /// 传字符串协议名时 iOS 会静默拒绝端点——现象是"publish 已调用、isReady=true，
    /// 但永远收不到 dataOutHandler 回调，也收不到任何 iAP2 数据"
    /// （0.0.1-b65 真机实锤：identification 发出去 20 秒零回包）。
    private static let endpointProtocol = 4

    // MARK: - 运行时状态

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var clientInstance: AnyObject?
    private var connectionUUID: String?
    private var endpointUUID: String?
    private var isReady = false

    // MARK: - 启动

    /// 加载私有框架并创建虚拟连接 + endpoint。
    /// 全程动态解析：任何一步失败都会走 onFailure 并带上 CarWithin 同款错误语义。
    func start() {
        // 1. dlopen 私有框架
        guard let handle = dlopen(Self.frameworkPath, RTLD_NOW) else {
            fail("CoreAccessories ACCTransportClient is unavailable on this iOS build.")
            return
        }
        frameworkHandle = handle
        log("CoreAccessories 已加载")

        // 2. NSClassFromString 拿 ACCTransportClient 类
        guard let cls = NSClassFromString(Self.clientClassName) as? NSObject.Type else {
            fail("ACCTransportClient class not found (framework loaded but class missing).")
            return
        }

        // 3. +sharedClient 单例。注意这是**类方法**——必须用 responds(to:)，
        //    instancesRespond(to:) 只查实例方法，会假阴性（0.0.1 联调踩过）。
        let sharedSel = NSSelectorFromString("sharedClient")
        guard cls.responds(to: sharedSel) else {
            fail("sharedClient class-method missing on ACCTransportClient.")
            return
        }
        clientInstance = cls.perform(sharedSel)?.takeUnretainedValue()
        guard let client = clientInstance else {
            fail("sharedClient returned nil — app may lack access to the private transport.")
            return
        }
        log("ACCTransportClient 单例已获取")

        // 4. createConnectionWithType:andIdentifier:（实例方法）
        //    CarWithin 用 configuration.deviceID（MAC 形串）作 identifier；
        // 这里用证书派生的稳定 MAC 串，重开一致。
        let connectionID = accessoryMAC
        connectionUUID = connectionID
        let createConnSel = NSSelectorFromString("createConnectionWithType:andIdentifier:")
        if client.responds(to: createConnSel) {
            // transportType 逐个尝试；v1 先取第一个
            let type = Self.transportTypesToTry[0]
            _ = client.perform(createConnSel, with: type, with: connectionID)
            log("连接已创建 type=\(type) id=\(connectionID)")
        } else {
            fail("createConnectionWithType:andIdentifier: selector missing.")
            return
        }

        // 5. createEndpointWithTransportType:andProtocol:andIdentifier:
        //    andDataOutHandler:forConnectionWithUUID:publishConnection:
        //    endpoint UUID 用返回值，见 publishEndpoint 内说明
        publishEndpoint(client: client, connectionUUID: connectionID)
    }

    /// 发布 endpoint：把 dataOutHandler 闭包传给 CoreAccessories。
    /// handler 收到的 (NSString, NSString, NSData) = (connectionUUID, endpointUUID, 数据)。
    private func publishEndpoint(client: AnyObject, connectionUUID: String) {
        let sel = NSSelectorFromString(
            "createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:"
        )
        guard client.responds(to: sel) else {
            fail("createEndpointWithTransportType:… selector missing.")
            return
        }

        let dataOutHandler: @convention(block) (NSString, NSString, Data) -> Void = {
            [weak self] _connectionUUID, _endpointUUID, data in
            self?.onData?(data)
        }
        let block = unsafeBitCast(dataOutHandler, to: AnyObject.self)

        // CarWithin：andProtocol = 整数 4，andIdentifier = nil。
        // 传字符串协议名 iOS 会静默拒绝——表现为"publish 已调用但永远收不到回调"。
        let type = Self.transportTypesToTry[0]
        let result = sendEndpointCreate(
            to: client, sel: sel,
            type: type,
            protocolNumber: Self.endpointProtocol,
            handler: block,
            connectionUUID: connectionUUID,
            publish: true
        )

        // **返回值就是 endpoint UUID**，必须拿来后续注数据用；自己编 UUID 会打空
        guard let endpointID = result as? String, !endpointID.isEmpty else {
            fail("createEndpoint 未返回 endpoint UUID——iOS 拒绝了 iAP2 端点（protocol=\(Self.endpointProtocol)）")
            return
        }
        endpointUUID = endpointID
        isReady = true
        log("publish 成功（endpoint=\(endpointID)）")
        onReady?()
    }

    // MARK: - 数据注入（配件 → iPhone）

    /// 把我们的数据（触摸/控制回传）喂给 iPhone。
    /// 对应 CarWithin 的 `processIncomingData:forEndpointWithUUID:`。
    func sendToPhone(_ data: Data) {
        guard isReady, let client = clientInstance, let uuid = endpointUUID else {
            fail("Direct transport is not open.")
            return
        }
        let sel = NSSelectorFromString("processIncomingData:forEndpointWithUUID:")
        if client.responds(to: sel) {
            _ = client.perform(sel, with: data, with: uuid)
        }
    }

    /// 拆除
    func stop() {
        if let client = clientInstance, let uuid = endpointUUID {
            _ = client.perform(NSSelectorFromString("destroyEndpointWithUUID:"), with: uuid)
        }
        if let client = clientInstance, let conn = connectionUUID {
            _ = client.perform(NSSelectorFromString("destroyConnectionWithUUID:"), with: conn)
        }
        if let handle = frameworkHandle { dlclose(handle) }
        frameworkHandle = nil
        clientInstance = nil
        isReady = false
    }

    // MARK: - 内部

    /// 配件 MAC：从 MFi 证书派生的稳定 6 字节值，格式化成 `AA:BB:CC:DD:EE:FF`。
    ///
    /// iAP2 identification 的蓝牙传输组 param 3 和连接 identifier 都用它。
    /// iOS 拿不到真实 Wi-Fi MAC，用证书派生可保证重开一致（CarWithin 同样用
    /// deviceID 当 MAC 串）。
    var accessoryMAC: String {
        if let cached = cachedMAC { return cached }
        var source = Data()
        if let cert = identity?.leafCertificate { source = cert }
        let digest = SHA256.hash(data: source)
        let bytes = Array(digest.prefix(6))
        // 首字节清掉多播/本地位，看起来像正常 MAC
        let first = bytes[0] & 0xFC
        var all = [first] + Array(bytes.dropFirst())
        // 全零（没证书时）给个固定值，避免格式非法
        if all.allSatisfy({ $0 == 0 }) { all = [0x02, 0x00, 0x00, 0x00, 0x00, 0x01] }
        let mac = all.map { String(format: "%02X", $0) }.joined(separator: ":")
        cachedMAC = mac
        return mac
    }
    private var cachedMAC: String?

    private func log(_ msg: String) {
        onLog?("[Transport] \(msg)")
    }

    private func fail(_ msg: String) {
        onLog?("[Transport] ❌ \(msg)")
        onFailure?(msg)
    }
}

// MARK: - Obj-C runtime 桥接

/// `createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:
/// forConnectionWithUUID:publishConnection:` 的多参直调。
///
/// **参数语义照 CarWithin `DirectAccessoryTransport.m`（该 App 已发布可用）**：
/// - `andProtocol:` 是**整数 4**，不是字符串（传字符串 iOS 会静默拒绝，表现为
///   "publish 已调用但永远收不到 dataOutHandler 回调、也收不到任何 iAP2 数据"）
/// - `andIdentifier:` 传 **nil**
/// - **返回值就是 endpoint UUID**（NSString），必须拿来当后续
///   `processIncomingData:forEndpointWithUUID:` / `destroyEndpointWithUUID:` 的 UUID——
///   自己编 UUID 会让数据注入打空
func sendEndpointCreate(
    to client: AnyObject, sel: Selector, type: Int,
    protocolNumber: Int,
    handler: AnyObject, connectionUUID: String, publish: Bool
) -> AnyObject? {
    // 参数顺序：transportType(Int), protocol(Int), identifier(nil),
    //          handler(block), connectionUUID(NSString), publish(BOOL)
    let fn = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend"),
        to: (@convention(c) (AnyObject, Selector, Int, Int, AnyObject?,
                            AnyObject, NSString, Bool) -> AnyObject?).self
    )
    return fn(client, sel, type, protocolNumber, nil, handler,
              connectionUUID as NSString, publish)
}
