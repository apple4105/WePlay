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
        writePending = false
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

    /// 写入是否还挂着（watchdog 用）
    private var writePending = false

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
            type: Link.typeNetworkBootstrap
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

            // 官方第一件事就是 requestMtu(512)。iOS 不暴露 MTU 协商，只能读当前上限——
            // 这条日志是判断"车机到底收没收到"的关键：上限 < 125 时 withResponse 写入
            // 根本发不出去，车机自然不会有任何反应。
            let maxWithResponse = peripheral.maximumWriteValueLength(for: .withResponse)
            let maxWithoutResponse = peripheral.maximumWriteValueLength(for: .withoutResponse)
            onLog?("[link] 写入上限：withResponse=\(maxWithResponse) B / withoutResponse=\(maxWithoutResponse) B；请求 \(json.count) B")

            let writeType: CBCharacteristicWriteType =
                json.count > maxWithResponse ? .withoutResponse : .withResponse
            if writeType == .withoutResponse {
                onLog?("[link] ⚠️ 请求超过 withResponse 上限，降级 withoutResponse（车机可能因 MTU 过小收不全）")
            }

            onLog?("[link] → PhoneRequest (\(json.count) B)：\(String(data: json, encoding: .utf8) ?? "")")
            writePending = true
            peripheral.writeValue(json, for: phoneCharacteristic, type: writeType)
            scheduleWriteWatchdog()
        } catch {
            onFailure?(error)
        }
    }

    /// 写入确认看门狗：`.withResponse` 写入必须由车机回 Write Response。
    /// 8 秒没回说明车机 GATT 根本没处理这次写入（MTU 过小/未订阅/栈忙），
    /// 和"车机收到了但不回凭证"是两种完全不同的故障，必须分开报。
    private func scheduleWriteWatchdog() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.writePending else { return }
            self.onLog?("[link] ⚠️ 写入 8 秒未确认——车机 GATT 未回 Write Response（MTU 过小或车机未处理该特征）")
        }
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
                // 订阅通知，对端有更新立刻推过来
                if c.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: c)
                }
            default:
                break
            }
        }

        // 先读一次，拿不到再等通知
        if let headUnitCharacteristic {
            peripheral.readValue(for: headUnitCharacteristic)
        }

        // 官方流程（oxp-clink BleExchange.kt）：先订阅 CCCD，**等订阅确认后**才写请求。
        // 车机 GATT 栈普遍要求在 CCCD 落好之后才处理手机特征的写入。
        if let headUnitCharacteristic, headUnitCharacteristic.properties.contains(.notify) {
            onLog?("[link] 订阅对端通知（CCCD）…")
            peripheral.setNotifyValue(true, for: headUnitCharacteristic)
        } else {
            requestCredentials()
        }
    }

    /// CCCD 订阅结果——确认后才发 PhoneRequest（官方顺序）
    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Link.headUnitCharacteristicUUID else { return }
        if let error {
            onLog?("[link] CCCD 订阅失败：\(error.localizedDescription)——仍尝试发请求")
        } else {
            onLog?("[link] CCCD 订阅已确认（isNotifying=\(characteristic.isNotifying)）")
        }
        requestCredentials()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Link.headUnitCharacteristicUUID else { return }
        if let error { onFailure?(error); return }
        guard let data = characteristic.value, !data.isEmpty else { return }

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
        writePending = false
        if let error {
            onLog?("[link] 写特征失败：\(error.localizedDescription)")
            onFailure?(error)
        } else {
            onLog?("[link] 写特征成功（车机 GATT 已确认收到）——等凭证回复")
        }
    }
}
