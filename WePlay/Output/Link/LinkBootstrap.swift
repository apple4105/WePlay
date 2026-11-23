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

    /// 自己的蓝牙 MAC（PhoneRequest.mac 要用；取不到就填占位并告警）
    private var selfMAC: String = "02:00:00:00:00:00"

    /// 诊断期：每个周围设备只记一次，避免 AllowDuplicates 刷屏
    private var loggedPeripherals = Set<UUID>()

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
    }

    /// 用户在 UI 里输入了配对码后调用。
    ///
    /// 官方流程（oxp-clink ble.rs）确认：**BLE 建网阶段不需要配对码**——PhoneRequest
    /// 直接换 HeadUnitReply。配对码属于后续 Carlink 认证（手机拨 57209）阶段。
    /// 这里先把码存下来并全量打日志，供认证阶段使用和联调对照。
    func submitPinCode(_ code: String) {
        lastPinCode = code
        onLog?("[link] 用户输入配对码：\(code)（长度 \(code.count)）——BLE 阶段不用它，留给 Carlink 认证")
    }

    // MARK: - 内部

    /// 上一次用户手工输入的配对码（BLE 阶段不用，留给 Carlink 认证阶段）
    private var lastPinCode: String?

    /// 描述符是否发现成功（3 秒兜底订阅用）
    private var descriptorDiscovered = false

    /// CCCD 是否已确认启用（启用后要按官方顺序补发请求）
    private var cccdEnabled = false

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

    private func requestCredentials() {
        guard let peripheral, let phoneCharacteristic else {
            onFailure?(LinkError.characteristicMissing("phone \(Link.phoneCharacteristicUUID)"))
            return
        }
        let request = Link.PhoneRequest(
            id: UUID().uuidString,
            name: HostIdentity.deviceName,
            model: UIDevice.current.model,
            band: 0,
            mac: selfMAC,
            type: credentialType
        )
        do {
            // 字段顺序敏感（oxp-clink ble.rs：Kotlin 插入序，type 恒最后）——手工拼，
            // Swift Codable 的键序不保证
            let esc: (String) -> String = { s in
                let d = try! JSONEncoder().encode(s)
                return String(data: d, encoding: .utf8) ?? "\"\(s)\""
            }
            let json = Data("""
            {"id":\(esc(request.id)),"name":\(esc(request.name)),"model":\(esc(request.model)),"band":\(request.band),"mac":\(esc(request.mac.lowercased())),"type":\(request.type)}
            """.utf8)

            // 官方第一件事是 requestMtu(512)；iOS 不暴露该 API，但**写入模式可以绕开
            // Write Response**——车机嵌入式 BLE 栈普遍不回写确认（b57/b65 两次都静默
            // 在第一个 GATT 写入上）。withoutResponse 不等车机 ACK，请求照样送达。
            let maxWithout = peripheral.maximumWriteValueLength(for: .withoutResponse)
            let maxWith = peripheral.maximumWriteValueLength(for: .withResponse)
            let preferWithout = credentialAttempts == 0 && json.count <= maxWithout
            let writeType: CBCharacteristicWriteType = preferWithout ? .withoutResponse : .withResponse

            onLog?("[link] 写入上限：withoutResponse=\(maxWithout) B / withResponse=\(maxWith) B；请求 \(json.count) B")
            onLog?("[link] → PhoneRequest type=\(credentialType) 第\(credentialAttempts + 1)次 \(preferWithout ? "withoutResponse（不等车机 ACK）" : "withResponse")：\(String(data: json, encoding: .utf8) ?? "")")

            replyPending = true
            peripheral.writeValue(json, for: phoneCharacteristic, type: writeType)
            scheduleReplyWatchdog()
        } catch {
            onFailure?(error)
        }
    }

    /// 凭证回复看门狗：6 秒没收到 HeadUnitReply 就换 (type, 写入模式) 重发；
    /// 两轮都失败后**重新发现服务与特征**再试一轮（OpenXPlay 0.4.0/428 同款对策）。
    ///
    ///  ladder：
    ///  - t=0   type=1001 + withoutResponse（绕开车机不回写确认）
    ///  - t=6   type=1002 + withResponse
    ///  - t=12  重新发现服务+特征 → 再发 type=1001 + withoutResponse
    ///  - t=18  两轮都空 → 明确定性
    private func scheduleReplyWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.replyPending else { return }
            // 链路状态 + CCCD 状态一起打：区分"链路死了"和"车机不理"
            let linkState = self.peripheral?.state == .connected ? "已连接" : "非连接(\(self.peripheral?.state.rawValue ?? -1))"
            self.onLog?("[link] 链路状态：\(linkState)；CCCD 已启用：\(self.cccdEnabled)；已补发：\(self.didResendAfterCccd)")
            guard self.credentialAttempts < 1 else {
                // 第二轮也空：OpenXPlay 的对策是重新发现服务（车机 GATT 数据库
                // 可能在连接后被重新发布，旧的 characteristic 句柄已失效）
                guard self.rediscoveryCount < 1 else {
                    self.onLog?("[link] ⚠️ 重新发现后仍无凭证回复。车机对 ATT 读取（服务/特征发现）有响应、对写入与特征值读取无响应——典型原因是车机要求链路配对/加密，或其 BLE 栈不回写确认")
                    return
                }
                self.rediscoveryCount += 1
                self.onLog?("[link] ⚠️ 两次请求均无回复——重新发现服务与特征（OpenXPlay 同款对策）")
                self.rediscoverServices()
                return
            }
            self.credentialAttempts += 1
            self.credentialType = self.credentialType == Link.typeNetworkBootstrap
                ? Link.typeSecondRound : Link.typeNetworkBootstrap
            self.onLog?("[link] ⚠️ 6 秒无凭证回复——换 type=\(self.credentialType) + withResponse 重发")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.requestCredentials()
            }
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

        // 其余设备每个只记一次，避免刷屏；带厂商数据的记厂商数据 hex
        if loggedPeripherals.insert(peripheral.identifier).inserted {
            let svc = serviceUUIDs.map { $0.uuidString }.joined(separator: ",")
            if let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
               !mfr.isEmpty {
                onLog?("[link] 周围设备：\(name) RSSI \(RSSI) 服务[\(svc)] 厂商 \(mfr.prefix(12).map { String(format: "%02x", $0) }.joined())")
            } else {
                onLog?("[link] 周围设备：\(name) RSSI \(RSSI) 服务[\(svc)]")
            }
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
                // 订阅放到 didDiscoverDescriptorsFor / 3 秒兜底里做，这里只记录
            default:
                break
            }
        }

        // 先读一次，拿不到再等通知
        if let headUnitCharacteristic {
            peripheral.readValue(for: headUnitCharacteristic)
            // 部分车机栈必须先 discoverDescriptors 才认 CCCD 写入（iOS 已知怪癖）。
            // 但描述符发现也可能静默失败——3 秒兜底直接订阅，绝不拿它堵死流程。
            peripheral.discoverDescriptors(for: headUnitCharacteristic)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.descriptorDiscovered == false,
                      let c = self.headUnitCharacteristic, c.properties.contains(.notify) else { return }
                self.onLog?("[link] 描述符发现无回调——直接订阅 CCCD（不等了）")
                self.peripheral?.setNotifyValue(true, for: c)
            }
        }

        // 不等 CCCD 确认就发请求。官方顺序虽是"先订阅后写"，但车机栈对写入普遍
        // 不回确认（b57/b65 两次都静默在第一个 GATT 写入上），等它会把整个流程堵死。
        requestCredentials()
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

    /// 描述符发现结果——真正的订阅放这里
    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Link.headUnitCharacteristicUUID else { return }
        descriptorDiscovered = true
        if let error {
            onLog?("[link] 描述符发现失败：\(error.localizedDescription)")
        } else {
            let names = characteristic.descriptors?.map { $0.uuid.uuidString } ?? []
            onLog?("[link] 对端特征描述符：[\(names.joined(separator: ", "))]")
        }
        enableHeadUnitNotifications(on: characteristic, via: peripheral)
    }

    /// 订阅对端特征的通知/指示。
    ///
    /// **先直接写 CCCD = 0x0002（指示 indications）**，不是 `setNotifyValue(true)`：
    /// 1. iOS 的 `setNotifyValue(true)` 固定写 0x0001（notifications），我们无法指定值；
    /// 2. 官方 Android 参考（BleExchange.kt）把收到的数据命名为 `indication(bytes)`，
    ///    Android 侧启用指示写的就是 0x0002；
    /// 3. b68 实机：`setNotifyValue(true)` 之后**收不到任何 CCCD 回调**，而对端特征
    ///    读取被车机以 `CBATTErrorDomain Code=2 "Reading is not permitted"` 明确拒绝
    ///    （属性 16 = notify，只支持订阅，读不了）。
    /// 直接写描述符是 iOS 上唯一能发 0x0002 的途径。
    private func enableHeadUnitNotifications(on characteristic: CBCharacteristic, via peripheral: CBPeripheral) {
        guard let cccd = characteristic.descriptors?.first(where: { $0.uuid == Link.cccdUUID }) else {
            onLog?("[link] 找不到 CCCD 描述符——退回 setNotifyValue(true)")
            peripheral.setNotifyValue(true, for: characteristic)
            return
        }
        onLog?("[link] 直接写 CCCD = 0x0002（启用指示 indications）")
        peripheral.writeValue(Data([0x02, 0x00]), for: cccd)
    }

    /// CCCD 描述符**写入**结果（直接写 0x0002 时走这里）
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        guard descriptor.uuid == Link.cccdUUID else { return }
        // descriptor.value 是 Any?，要先转 Data
        let valueHex = (descriptor.value as? Data)?.hexString ?? "nil"
        if let error {
            onLog?("[link] ❌ CCCD 写入失败：\(error.localizedDescription)——退回 setNotifyValue(true)（0x0001 notifications）")
            if let c = headUnitCharacteristic { peripheral.setNotifyValue(true, for: c) }
        } else {
            onLog?("[link] ✅ CCCD 已启用（值 \(valueHex)）")
            resendRequestAfterSubscription()
        }
    }

    /// CCCD 描述符读取结果
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        guard descriptor.uuid == Link.cccdUUID else { return }
        let valueHex = (descriptor.value as? Data)?.hexString ?? "nil"
        onLog?("[link] CCCD 当前值 = \(valueHex)")
    }

    /// CCCD 订阅结果（setNotifyValue 路径；仅记录 + 补发请求）
    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Link.headUnitCharacteristicUUID else { return }
        if let error {
            onLog?("[link] CCCD 订阅失败：\(error.localizedDescription)（不影响已发出的请求）")
        } else {
            onLog?("[link] CCCD 订阅已确认（isNotifying=\(characteristic.isNotifying)）")
            resendRequestAfterSubscription()
        }
    }

    /// CCCD 启用后按官方顺序补发一次 PhoneRequest。
    ///
    /// 官方顺序（BleExchange.kt）是**先订阅、后写请求**。我们为了不堵流程，
    /// 在订阅确认前就先发了一次——车机很可能因此没处理。订阅一确认就补发，
    /// 且只补发一次（`didResendAfterCccd` 防重）。
    private func resendRequestAfterSubscription() {
        guard !didResendAfterCccd else { return }
        didResendAfterCccd = true
        cccdEnabled = true
        credentialAttempts = 0
        credentialType = Link.typeNetworkBootstrap
        onLog?("[link] 按官方顺序补发 PhoneRequest（订阅已完成）")
        requestCredentials()
    }

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
        if let error {
            onLog?("[link] 写特征失败：\(error.localizedDescription)")
            onFailure?(error)
        } else {
            onLog?("[link] 写特征成功（车机 GATT 回了写确认）——等凭证回复")
        }
    }
}
