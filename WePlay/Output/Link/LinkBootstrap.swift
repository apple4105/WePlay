import Foundation
import UIKit
import CoreBluetooth

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

    // MARK: - 状态

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var phoneCharacteristic: CBCharacteristic?
    private var headUnitCharacteristic: CBCharacteristic?

    /// 自己的蓝牙 MAC（PhoneRequest.mac 要用；取不到就填占位并告警）
    private var selfMAC: String = "02:00:00:00:00:00"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - 公开动作

    /// 开始扫描（central 上电后自动调用）
    func startScanning() {
        guard central.state == .poweredOn else {
            onLog?("[link] 蓝牙未就绪（\(central.state.rawValue)），等回调")
            return
        }
        onLog?("[link] 开始扫描 \(Link.serviceUUID)")
        central.scanForPeripherals(withServices: [Link.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: true
        ])
    }

    func stop() {
        if central.isScanning { central.stopScan() }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        phoneCharacteristic = nil
        headUnitCharacteristic = nil
    }

    /// 用户在 UI 里输入了配对码后调用（具体怎么用待真机确认）
    func submitPinCode(_ code: String) {
        onLog?("[link] 用户输入配对码：\(code)（长度 \(code.count)）")
        // TODO: 真机确认配对码走哪个变体/特征后接进来
    }

    // MARK: - 内部

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
            let json = try request.encode()
            onLog?("[link] → PhoneRequest (\(json.count) B)：\(String(data: json, encoding: .utf8) ?? "")")
            peripheral.writeValue(json, for: phoneCharacteristic, type: .withResponse)
        } catch {
            onFailure?(error)
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
        onLog?("[link] 发现对端：\(name)  RSSI \(RSSI)")

        // 第一个就是它（对端只会广播一个 ICCOA 服务）；停扫描去连
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onLog?("[link] 已连接，发现服务")
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
                onLog?("[link] 手机特征就绪 \(c.uuid)")
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
        } catch {
            onFailure?(error)
        }
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
            onLog?("[link] 写特征成功")
        }
    }
}
