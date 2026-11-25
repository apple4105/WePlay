import Foundation
import UIKit
import CoreBluetooth
import UserNotifications

/// 显示端的 BLE 引导：扫描 → 连接 → 拿入网凭证。
///
///   1. 对端开始 BLE 广播（服务 UUID `2ABCC850…9100`）
///   2. 我们作 Central 扫到它、连接、发现服务
///   3. 把 `PhoneRequest` JSON 写到特征 `…101`
///   4. 读/通知特征 `…102`，拿到 `HeadUnitReply`（SSID / PSK / 频段 / 端口 / MAC）
///
/// 之后交给 `WiFiJoiner` 加入对端那个网络，再进 Display 会话。
final class LinkBootstrap: NSObject {

    // MARK: - 输出

    /// 日志
    var onLog: ((String) -> Void)?

    /// 拿到入网凭证
    var onCredentials: ((Link.HeadUnitReply) -> Void)?

    /// 需要用户输入配对码（对端屏幕显示的那个）
    var onPinCodeRequired: ((String) -> Void)?

    /// 失败
    var onFailure: ((Error) -> Void)?

    /// 车机 GATT 已连上（控制器据此切换到"等凭证回复"超时）
    var onConnected: (() -> Void)?

    private(set) var isConnected = false

    // MARK: - 状态

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var phoneCharacteristic: CBCharacteristic?
    private var headUnitCharacteristic: CBCharacteristic?

    /// 配件 MAC（下发给车机）。由 LinkController 按证书派生后注入，
    /// 形如 `02:xx:xx:xx:xx:xx`（本地管理的单播地址，和真实手机实现一致）。
    var accessoryMAC: String = "02:00:00:00:00:00"

    /// Client Info 的 `id`：**6 位十六进制**（真实手机是 "a1b2c3" 这种，不是 UUID）
    var clientID: String = "000001"

    private var selfMAC: String { accessoryMAC }

    /// 已见过的周围设备（只用于计数，不再逐条打日志）
    private var loggedPeripherals = Set<UUID>()
    /// 本轮扫描见过的设备数
    private(set) var scannedDeviceCount = 0

    override init() {
        super.init()
        // 状态恢复标识：App 被系统杀掉后，BLE 事件仍能把它拉回后台
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "weplay.ble.central"])
    }

    // MARK: - 公开动作

    /// 开始扫描（central 上电后自动调用）。
    /// - 前台：全量扫描（诊断期把周围所有广播记下来，命中判断在 didDiscover 里做）
    /// - 后台：**必须带服务过滤**（iOS 后台只把过滤命中的广播递给 App），
    ///   过滤 = 车机广播服务 0000fcfb —— 这是"车机要连了自动唤醒 WePlay"的机制
    func startScanning() {
        guard central.state == .poweredOn else {
            onLog?("[link] 蓝牙未就绪（\(central.state.rawValue)），等回调")
            return
        }
        let background = UIApplication.shared.applicationState != .active
        if background {
            onLog?("[link] 后台扫描（服务过滤 0000fcfb）——等待车机开 ICCOA")
            central.scanForPeripherals(withServices: [Link.vendorUUID], options: nil)
        } else {
            onLog?("[link] 开始全量扫描（命中条件：ICCOA 服务或 DIRECT- 名称）")
            central.scanForPeripherals(withServices: nil, options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true
            ])
        }
    }

    func stop() {
        if central.isScanning { central.stopScan() }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        isConnected = false
        peripheral = nil
        phoneCharacteristic = nil
        headUnitCharacteristic = nil
        loggedPeripherals.removeAll()
        replyPending = false
        credentialAttempts = 0
        credentialType = Link.typeNetworkBootstrap
        descriptorDiscovered = false
        rediscoveryCount = 0
        cccdEnabled = false
        didResendAfterCccd = false
        credentialWriteStarted = false
    }

    /// 用户在 UI 里输入了配对码后调用。
    ///
    /// **BLE 阶段就要用**：Client Info 的 `pinCodeOrAuthentication` 必须带车机屏幕上
    /// 的 6 位配对码（首次配对），车机才会推 Server Info（凭证）。
    /// 依据 ft-app `IccoaClientProfile.kt` 注释「QUICK GATT advertises a trusted
    /// client without replaying an obsolete **six-digit PIN**」——已配对才免码。
    func submitPinCode(_ code: String) {
        lastPinCode = code
        onLog?("[link] 用户输入配对码：\(code)（长度 \(code.count)）——带进 Client Info 重发")
        guard isConnected, credentialWriteStarted else { return }
        // 输码后允许**额外再发一次**（带 pinCodeOrAuthentication），其余重试全部取消
        requestCredentials(forceAfterPin: true)
    }

    // MARK: - 内部

    /// 用户输入的 6 位配对码（写入 Client Info 的 pinCodeOrAuthentication）
    private var lastPinCode: String?

    /// 是否已经拿到配对码（UI 据此决定要不要提前弹框）
    var hasPin: Bool { !(lastPinCode ?? "").isEmpty }

    /// 描述符是否发现成功（3 秒兜底订阅用）
    private var descriptorDiscovered = false

    /// CCCD 是否已确认启用（启用后要按官方顺序补发请求）
    private var cccdEnabled = false

    /// 是否已经发起过 PhoneRequest 写入
    private var credentialWriteStarted = false

    /// 写回调里拿到的 peripheral（委托方法参数，供订阅用）
    private var peripheral_: CBPeripheral?

    /// 是否已经因"CCCD 启用"补发过请求（避免重复发）
    private var didResendAfterCccd = false

    /// 凭证请求重试计数
    private var credentialAttempts = 0

    /// 当前这一轮用的 type（1001 初始 / 1002 二轮）
    private var credentialType: Int = Link.typeNetworkBootstrap

    /// 是否在等凭证回复（看门狗用）
    private var replyPending = false

    /// 已重新发现服务的次数（最多 1 次，避免无限循环）
    private var rediscoveryCount = 0

    /// 是否已经用过"输码后再发一次"的机会
    private var pinRetryUsed = false

    private func requestCredentials(forceAfterPin: Bool = false) {
        // 默认只发一次；只有"用户刚输入配对码"才允许额外一次
        if credentialWriteStarted {
            guard forceAfterPin, !pinRetryUsed else {
                onLog?("[link] 已发过请求，跳过重复发送（避免身份/重试风暴）")
                return
            }
            pinRetryUsed = true
        }
        guard let peripheral, let phoneCharacteristic else {
            onFailure?(LinkError.characteristicMissing("phone \(Link.phoneCharacteristicUUID)"))
            return
        }
        do {
            credentialWriteStarted = true
            // **Client Info 退回"车机会有反应"的那一版，只多带一个配对码。**
            //
            // 依据：b80 用下面这段 JSON 时车机会显示「正在连接 iPhone」；b89 我一次改了
            // 5 个字段（id→6位十六进制、model→WePlay、band→1、mac→派生值、
            // 加 manufactures/channel）后车机完全没反应了。一次改太多无法定位，
            // 而且 `02:00:00:00:00:00` 是手册明确写的隐私占位 MAC（"若双方没有明确
            // 协商真实 Wi-Fi 地址，参考实现使用 02:00:00:00:00:00"）。
            //
            // 唯一新增：`pinCodeOrAuthentication`（首次配对的车机屏幕 6 位码）。
            // 放在 `type` 之前——手册强调 type 恒为最后一项。
            let esc: (String) -> String = { s in
                let d = (try? JSONEncoder().encode(s)) ?? Data()
                return String(data: d, encoding: .utf8) ?? "\"\(s)\""
            }
            var fields: [String] = [
                "\"id\":\(esc(clientID))",
                "\"name\":\(esc(HostIdentity.deviceName))",
                "\"model\":\"iPhone\"",
                "\"band\":0",
                "\"mac\":\"02:00:00:00:00:00\"",
            ]
            if let pin = lastPinCode, !pin.isEmpty {
                fields.append("\"pinCodeOrAuthentication\":\(esc(pin))")
            }
            fields.append("\"type\":\(credentialType)")
            let json = Data(("{" + fields.joined(separator: ",") + "}").utf8)

            // **第一轮用 withResponse**——和官方 Android 的 `gatt.write()`（默认
            // WRITE_TYPE_DEFAULT = 需确认）一致。这一轮最有诊断价值：
            //   · 回 `写特征成功` → 车机确实收到请求，问题在后面
            //   · 回 `写特征失败: <ATT code>` → 直接告诉我们车机拒绝的原因
            //   · 完全静默 → 写入没发出去（队列被堵或链路异常）
            let maxWithout = peripheral.maximumWriteValueLength(for: .withoutResponse)
            let maxWith = peripheral.maximumWriteValueLength(for: .withResponse)
            let writeType: CBCharacteristicWriteType =
                (credentialAttempts == 0 && json.count <= maxWith) ? .withResponse : .withoutResponse

            onLog?("[link] 写入上限：withoutResponse=\(maxWithout) B / withResponse=\(maxWith) B；请求 \(json.count) B")
            onLog?("[link] → PhoneRequest type=\(credentialType) 第\(credentialAttempts + 1)次 \(writeType == .withResponse ? "withResponse（要车机回写确认）" : "withoutResponse（不等 ACK）")：\(String(data: json, encoding: .utf8) ?? "")")

            replyPending = true
            peripheral.writeValue(json, for: phoneCharacteristic, type: writeType)
            scheduleReplyWatchdog()
        } catch {
            onFailure?(error)
        }
    }

    /// 凭证回复看门狗：**只等一次，不再重发**。
    ///
    /// 之前每 6 秒重发、12 秒还要 rediscover，而 `id` 每次都重新随机——
    /// 同一次配对里对车机自称了四五个不同身份，等于中途换了四五台手机
    /// （b91 成功时是一次干净请求、30ms 就回凭证；b97 连灌十几次全是静默）。
    /// 真实手机的时序就是"写一次 Client Info，等车机回"。
    private func scheduleReplyWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.replyPending else { return }
            self.onLog?("[link] 6 秒无凭证回复（本轮不再重发，避免身份反复变化）")
        }
    }

    /// 重新发现服务与特征。
    ///
    /// OpenXPlay 0.4.0/428：「蓝牙找到车机但读不到车机服务时，会重新发现服务」。
    /// 车机 GATT 数据库可能在连接后被重新发布（或首轮发现拿到的是陈旧句柄），
    /// 重新发现能让后续读写落到正确的句柄上。
    private func rediscoverServices() {
        guard let peripheral else { return }
        credentialAttempts = 0
        credentialType = Link.typeNetworkBootstrap
        descriptorDiscovered = false
        cccdEnabled = false
        didResendAfterCccd = false
        phoneCharacteristic = nil
        headUnitCharacteristic = nil
        peripheral.discoverServices([Link.serviceUUID])
    }
}

// MARK: - CBCentralManagerDelegate

extension LinkBootstrap: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onLog?("[link] 蓝牙状态：\(central.state.rawValue)")
        if central.state == .poweredOn { startScanning() }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "(无名)"
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // 命中条件（oxp-clink ble.rs）：广播服务=0000fcfb（advertisement）或
        // 2abcc850（GATT，部分固件直接广播）或名字 DIRECT- 前缀
        let hasGATTService = serviceUUIDs.contains(Link.serviceUUID)
        let hasAdvService = serviceUUIDs.contains(Link.vendorUUID)
        let looksLikeCar = hasGATTService || hasAdvService || name.hasPrefix("DIRECT-")

        if looksLikeCar {
            let kind = hasGATTService ? "GATT服务" : hasAdvService ? "广播服务fcfb" : "DIRECT名字"
            onLog?("[link] ✅ 发现车机（\(kind)）：\(name) RSSI \(RSSI)")
            if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
                Diagnostics.shared.hex("BLE", "厂商数据", mfr)
            }
            central.stopScan()
            loggedPeripherals.removeAll()
            self.peripheral = peripheral
            peripheral.delegate = self
            central.connect(peripheral, options: nil)
            return
        }

        // **其余设备不再逐条打印**：附近几十个智能灯/网关会把日志冲满，
        // 把真正重要的行（凭证、认证、RTSP）挤出缓冲。只累计计数，等超时/找不到车机时
        // 由 LinkController 打一行汇总。崩溃现场已改用系统 .ips，不需要长日志。
        if loggedPeripherals.insert(peripheral.identifier).inserted {
            scannedDeviceCount += 1
        }
    }

    /// 系统恢复蓝牙状态（App 被杀后 BLE 事件把它拉回后台时走这里）
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        onLog?("[link] 系统已恢复蓝牙状态（后台自动发现运行中）")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        onLog?("[link] 已连接，发现服务")
        onConnected?()
        logWiFiState()
        peripheral.discoverServices([Link.serviceUUID])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        onFailure?(error ?? LinkError.notConnected)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        isConnected = false
        onLog?("[link] 连接断开：\(error?.localizedDescription ?? "用户取消")")
        self.peripheral = nil
        phoneCharacteristic = nil
        headUnitCharacteristic = nil
        if let error { onFailure?(error) }
    }
}

// MARK: - CBPeripheralDelegate

extension LinkBootstrap: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { onFailure?(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Link.serviceUUID }) else {
            onFailure?(LinkError.characteristicMissing("service"))
            return
        }
        onLog?("[link] 发现服务，找特征")
        peripheral.discoverCharacteristics(
            [Link.phoneCharacteristicUUID, Link.headUnitCharacteristicUUID],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error { onFailure?(error); return }
        guard let characteristics = service.characteristics else { return }

        for c in characteristics {
            switch c.uuid {
            case Link.phoneCharacteristicUUID:
                phoneCharacteristic = c
                onLog?("[link] 手机特征就绪 \(c.uuid)（属性 \(c.properties.rawValue)）")
            case Link.headUnitCharacteristicUUID:
                headUnitCharacteristic = c
                onLog?("[link] 对端特征就绪 \(c.uuid)（属性 \(c.properties.rawValue)）")
            default:
                break
            }
        }

        // ⚠️ 这里**不再 readValue(…102)**：车机对该特征读取一律回
        // CBATTErrorDomain Code=2 "Reading is not permitted"，失败操作还会冲刷队列。
        //
        // **先写 Client Info，订阅留到最后**（见 didWriteValueFor 的说明）。
        requestCredentials()
        if let headUnitCharacteristic {
            peripheral.discoverDescriptors(for: headUnitCharacteristic)
        }
    }

    /// 连接建立时的 Wi-Fi 状态诊断。
    ///
    /// OpenXPlay 0.4.0/428 明确记录：**iPhone 还连着之前的车机 Wi-Fi 时，车机会
    /// 连续拒绝连接**。他们的对策是提示用户关闭后重开 Wi-Fi。iOS 读不到当前 SSID
    /// （需要定位授权），但能判断"是否在某个 Wi-Fi 上"——这足以给用户 actionable 提示。
    private func logWiFiState() {
        if let ip = WiFiJoiner.currentLocalIPv4() {
            onLog?("[link] ⚠️ iPhone 当前已连接 Wi-Fi（本机地址 \(ip)）。若这是之前那台车机的 Wi-Fi，车机可能连续拒绝连接——OpenXPlay 的对策是关闭 Wi-Fi 后重开，再试")
        } else {
            onLog?("[link] iPhone 当前未连接 Wi-Fi（连接车机前的推荐状态）")
        }
    }

    /// 描述符发现结果——只记日志。订阅放到写入之后（见 didWriteValueFor）。
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Link.headUnitCharacteristicUUID else { return }
        descriptorDiscovered = true
        if let error {
            onLog?("[link] 描述符发现失败：\(error.localizedDescription)——直接写 PhoneRequest")
            requestCredentials()
            return
        }
        let names = characteristic.descriptors?.map { $0.uuid.uuidString } ?? []
        onLog?("[link] 对端特征描述符：[\(names.joined(separator: ", "))]")

        // ⚠️ **绝不用 `peripheral.writeValue(_:for: CBDescriptor)` 直接写 CCCD。**
        // b77 与 b85 两次都在这一行之后立刻闪退；b78 删掉"重复 selector 的委托方法"
        // 后仍然崩——所以根因就是描述符写本身（在 didDiscoverDescriptorsFor 回调里
        // 直接写 CBDescriptor 会崩）。
        //
        // 只记录。订阅放到写入之后（见 didWriteValueFor）。
    }

    /// 订阅对端特征的通知（标准 API）。
    private func enableHeadUnitNotifications(on characteristic: CBCharacteristic, via peripheral: CBPeripheral) {
        if characteristic.properties.contains(.notify) {
            onLog?("[link] setNotifyValue(true)（订阅通知，CCCD 0x0001）")
            peripheral.setNotifyValue(true, for: characteristic)
        } else {
            onLog?("[link] 对端特征无 notify 属性（属性 \(characteristic.properties.rawValue)），无法订阅；直接写 Client Info")
            requestCredentials()
        }
    }

    /// 描述符读/写结果（setNotifyValue 不走这里，仅记录直接写描述符的情况）
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard descriptor.uuid == Link.cccdUUID else { return }
        let valueHex = (descriptor.value as? Data)?.hexString ?? "nil"
        onLog?("[link] CCCD 值 = \(valueHex)（0x0100=notify / 0x0200=indicate）")
    }

    /// CCCD 订阅结果（setNotifyValue 路径；仅记录 + 补发请求）
    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Link.headUnitCharacteristicUUID else { return }
        if let error {
            onLog?("[link] CCCD 订阅失败：\(error.localizedDescription)——仍写 Client Info（凭证可能收不到）")
            requestCredentials()
        } else {
            onLog?("[link] ✅ CCCD 订阅已确认（isNotifying=\(characteristic.isNotifying)）")
            cccdEnabled = characteristic.isNotifying
            // 先写一次 Client Info。**不带码时就能回凭证 = 已配对过**（quick 路径），
            // 那就永远不用输码；只有车机不回、看门狗超时之后才弹配对码框。
            requestCredentials()
        }
    }

    /// CCCD 启用后按官方顺序补发一次 PhoneRequest。
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Link.headUnitCharacteristicUUID else { return }
        if let error { onFailure?(error); return }
        guard let data = characteristic.value, !data.isEmpty else { return }

        replyPending = false
        credentialAttempts = 0
        let raw = String(data: data, encoding: .utf8) ?? data.hexString
        onLog?("[link] ← HeadUnitReply (\(data.count) B)：\(raw)")

        do {
            let reply = try Link.HeadUnitReply.parse(data)
            onLog?("[link] 凭证：SSID=\(reply.ssid) freq=\(reply.freq) port=\(reply.port) MAC=\(reply.mac) type=\(reply.type)")
            onCredentials?(reply)
            // 后台自动发现：凭证到手 → 通知用户 + 置自动续连标志（打开 App 直接续连）
            if UIApplication.shared.applicationState != .active {
                LinkController.shared.autoConnectPending = true
                Self.postReadyNotification(reply)
            }
        } catch {
            onFailure?(error)
        }
    }

    /// 后台凭证到手时的本地通知（用户点一下即回到 App 完成连接）
    static func postReadyNotification(_ reply: Link.HeadUnitReply) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "车机已就绪"
        content.body = "发现 CarLink 车机（\(reply.ssid)）。打开 WePlay 按「启动」即可投屏。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "weplay.car.ready",
                                            content: content, trigger: nil)
        center.add(request)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Link.phoneCharacteristicUUID else { return }
        peripheral_ = peripheral
        if let error {
            onLog?("[link] 写特征失败：\(error.localizedDescription)")
            onFailure?(error)
            return
        }
        onLog?("[link] 写特征成功（车机 GATT 回了写确认）")
        // **写成功之后才订阅**（顺序刻意放最后）：
        // 车机的 GATT server 对描述符写**从不回 ATT Write Response**（CarBridge 注释 +
        // b89 日志双证：setNotifyValue 一调，后面的写就再也拿不到确认）。
        // 所以订阅放在最后——它可能挂死，但此时已经没有任何 GATT 操作需要它让路；
        // 若车机在订阅成立时推送 Server Info，我们仍能收到。
        if !cccdEnabled, let c = headUnitCharacteristic, let p = peripheral_ {
            cccdEnabled = true
            enableHeadUnitNotifications(on: c, via: p)
        }
    }
}
