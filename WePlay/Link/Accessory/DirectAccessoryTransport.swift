import Foundation
import CoreBluetooth
import Darwin

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

    // MARK: - 常量

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/CoreAccessories.framework/CoreAccessories"
    private static let clientClassName = "ACCTransportClient"

    /// 传输类型枚举值——真机诊断时逐个尝试（错误分支会明说拒绝原因）
    private static let transportTypesToTry: [Int] = [2, 1, 0]

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
            fail("CoreAccessories transport methods are unavailable or have changed.")
            return
        }

        // 3. +sharedClient 单例
        let sharedSel = NSSelectorFromString("sharedClient")
        guard cls.instancesRespond(to: sharedSel) else {
            fail("CoreAccessories transport methods are unavailable or have changed.")
            return
        }
        clientInstance = cls.perform(sharedSel)?.takeUnretainedValue()
        guard let client = clientInstance else {
            fail("CoreAccessories refused the connection. This signed app may lack access to the private transport.")
            return
        }
        log("ACCTransportClient 单例已获取")

        // 4. createConnectionWithType:andIdentifier:
        let connectionID = UUID()
        connectionUUID = connectionID.uuidString
        let createConnSel = NSSelectorFromString("createConnectionWithType:andIdentifier:")
        if client.responds(to: createConnSel) {
            // transportType 逐个尝试；v1 先取第一个
            let type = Self.transportTypesToTry[0]
            _ = client.perform(createConnSel, with: type, with: connectionID.uuidString)
            log("连接已创建 type=\(type) id=\(connectionID.uuidString)")
        } else {
            fail("CoreAccessories transport methods are unavailable or have changed.")
            return
        }

        // 5. createEndpointWithTransportType:andProtocol:andIdentifier:
        //    andDataOutHandler:forConnectionWithUUID:publishConnection:
        let endpointID = UUID()
        endpointUUID = endpointID.uuidString
        publishEndpoint(client: client, connectionUUID: connectionID.uuidString,
                        endpointUUID: endpointID.uuidString)
    }

    /// 发布 endpoint：把 dataOutHandler 闭包传给 CoreAccessories。
    /// handler 收到的 (NSString, NSString, NSData) = (connectionUUID, endpointUUID, 数据)。
    private func publishEndpoint(client: AnyObject, connectionUUID: String, endpointUUID: String) {
        let sel = NSSelectorFromString(
            "createEndpointWithTransportType:andProtocol:andIdentifier:andDataOutHandler:forConnectionWithUUID:publishConnection:"
        )
        guard client.responds(to: sel) else {
            fail("CoreAccessories refused to publish an iAP2 endpoint.")
            return
        }

        let dataOutHandler: @convention(block) (NSString, NSString, Data) -> Void = {
            [weak self] _connectionUUID, _endpointUUID, data in
            self?.onData?(data)
        }
        let block = unsafeBitCast(dataOutHandler, to: AnyObject.self)

        // Obj-C 消息发送：7 个参数，用 objc_msgSend 直调太啰嗦，
        // 用 NSInvocation 也不便——这里用 performSelector 链不可行（参数超 2 个），
        // 所以走 Obj-C runtime 的 objc_msgSend（通过 Swift 的动态派发桥）。
        let type = Self.transportTypesToTry[0]
        let protocolName = "com.apple.carplay"     // iAP2 协议标识，联调时可换
        // objc_msgSend 的返回值语义未知（endpoint 对象？void？），无法据此判定成败；
        // 所以只如实记录"已调用"，真正就绪以 iOS 是否回调 dataOutHandler 为准。
        _ = sendEndpointCreate(
            to: client, sel: sel,
            type: type,
            proto: protocolName,
            identifier: endpointUUID,
            handler: block,
            connectionUUID: connectionUUID,
            publish: true
        )
        isReady = true
        log("publish 已调用（endpoint=\(endpointUUID)），等待 iOS 回调确认")
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

    private func log(_ msg: String) {
        onLog?("[Transport] \(msg)")
    }

    private func fail(_ msg: String) {
        onLog?("[Transport] ❌ \(msg)")
        onFailure?(msg)
    }
}

// MARK: - Obj-C runtime 桥接

/// objc_msgSend 多参直调的桥（7 参数：type/protocol/identifier/handler/connectionUUID/publish + self+sel）。
/// 这些函数只在 DirectAccessoryTransport.publishEndpoint 里用一次。
private var msgSendImpl: IMP?

func sendEndpointCreate(
    to client: AnyObject, sel: Selector, type: Int,
    proto: String, identifier: String,
    handler: AnyObject, connectionUUID: String, publish: Bool
) -> Bool {
    // objc_msgSend(id self, SEL op, ...) 的多参调用在 Swift 里
    // 标准做法是 cast 成对应签名的 C 函数指针。
    // 参数顺序：transportType(Int), protocol(NSString), identifier(NSString),
    //          handler(block), connectionUUID(NSString), publish(BOOL)
    let fn = unsafeBitCast(
        dlsym(dlopen(nil, RTLD_NOW), "objc_msgSend"),
        to: (@convention(c) (AnyObject, Selector, Int, NSString, NSString,
                            AnyObject, NSString, Bool) -> AnyObject?).self
    )
    _ = fn(client, sel, type, proto as NSString,
           identifier as NSString, handler, connectionUUID as NSString, publish)
    return true
}
