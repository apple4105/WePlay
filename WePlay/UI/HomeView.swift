import SwiftUI
import UIKit

/// 主页：照 OpenXPlay iPhone 版的模式——深色底、大状态圆环（连接中显示百分比）、
/// 一句话状态说明、底部大按钮（启动 / 停止 / 连接中… / 断开连接）。
struct HomeView: View {
    @ObservedObject private var state = PipelineState.shared
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showPinInput = false
    @State private var pinCode = ""

    private let controller = LinkController.shared

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        heroRing
                        statusSentence
                        manualJoinCard
                        actionButton
                        pinEntryButton
                        versionLine
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("WePlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 14) {
                        Button("诊断") { showDiagnostics = true }
                        Button("设置") { showSettings = true }
                    }
                    .font(.system(size: 14))
                }
            }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .alert("输入配对码", isPresented: $showPinInput) {
                TextField("车机屏幕上的配对码", text: $pinCode)
                Button("确认") { controller.submitPin(pinCode) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在车机屏幕上查看当前配对码")
            }
            .onChange(of: state.pinRequired) { required in
                if required { showPinInput = true }
            }
            .onAppear {
                controller.start()
                // 后台自动发现拿到过凭证 → 打开 App 直接续连（通知点按路径）
                if controller.autoConnectPending {
                    controller.autoConnectPending = false
                    controller.connectToCar()
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - 状态视觉模型（OpenXPlay 式：圆环 + 中心内容 + 状态词）

    private struct Hero {
        let progress: Double?
        let ring: Color
        let icon: String?
        let center: String?
        let word: String
        let sentence: String
    }

    private var visual: Hero {
        switch state.phaseText {
        case LinkController.Phase.idle.rawValue:
            return Hero(progress: 0, ring: .gray, icon: "circle", center: nil,
                        word: "未启动", sentence: "按下面的「启动」开始连接车机。")
        case LinkController.Phase.identityLoaded.rawValue:
            return Hero(progress: 0.1, ring: .green, icon: "key.fill", center: nil,
                        word: "就绪", sentence: "已就绪。按「启动」搜索并连接车机。")
        case LinkController.Phase.transportReady.rawValue:
            return Hero(progress: 0.1, ring: .green, icon: "car.fill", center: nil,
                        word: "就绪", sentence: "已就绪。按「启动」连接车机。")
        case LinkController.Phase.transportFailed.rawValue:
            return Hero(progress: nil, ring: .red, icon: "exclamationmark.triangle.fill",
                        center: nil, word: "启动失败",
                        sentence: "虚拟 accessory 初始化失败。详见「诊断」里的 [Transport] 日志。")
        case LinkController.Phase.bleScanning.rawValue:
            return Hero(progress: nil, ring: .orange, icon: "iPhone.radiowaves.left.and.right",
                        center: nil, word: "搜索中",
                        sentence: "正在搜索车机的蓝牙广播……请确认车机已打开 CarLink。")
        case LinkController.Phase.carNotFound.rawValue:
            return Hero(progress: 0, ring: .orange, icon: "questionmark.circle", center: nil,
                        word: "未发现车机",
                        sentence: "12 秒内没有发现车机广播。请确认车机已打开 CarLink 后重试。")
        case LinkController.Phase.bleConnected.rawValue:
            return Hero(progress: 0.2, ring: .green, icon: nil, center: "20%",
                        word: "连接车机", sentence: "已连上车机蓝牙，正在拿取网络凭证……")
        case LinkController.Phase.wifiManualJoin.rawValue:
            return Hero(progress: 0.35, ring: .orange, icon: "wifi.exclamationmark",
                        center: nil, word: "等待加入网络",
                        sentence: "请按下方卡片里的名称和密码，在 设置 → Wi-Fi 里连接车机网络。")
        case LinkController.Phase.wifiJoined.rawValue:
            return Hero(progress: 0.45, ring: .green, icon: nil, center: "45%",
                        word: "加入网络", sentence: "已加入车机网络。")
        case LinkController.Phase.wfdNegotiating.rawValue:
            return Hero(progress: 0.7, ring: .green, icon: nil, center: "70%",
                        word: "等待车机连接", sentence: "与车机的投屏会话协商中……")
        case LinkController.Phase.carPlayActive.rawValue:
            return Hero(progress: 1, ring: .green, icon: "checkmark", center: nil,
                        word: "CarPlay 已激活", sentence: "正在向车机投屏。")
        default:
            return Hero(progress: 0, ring: .gray, icon: "circle", center: nil,
                        word: state.phaseText, sentence: "")
        }
    }

    private var heroRing: some View {
        let v = visual
        return ZStack {
            Circle()
                .stroke(Color(white: 0.15), lineWidth: 10)
            if let p = v.progress, p > 0, p < 1, v.center != nil {
                Circle()
                    .trim(from: 0, to: p)
                    .stroke(v.ring, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: p)
            } else {
                Circle()
                    .trim(from: 0, to: 1)
                    .stroke(v.ring.opacity(0.5), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                if v.progress == nil {
                    Circle()
                        .trim(from: 0, to: 0.12)
                        .stroke(v.ring, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        // 简易呼吸动效：进度点绕环（扫描中）
                }
            }
            if let pct = v.center {
                Text(pct)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: v.icon ?? "circle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundColor(v.ring == .gray ? .white : v.ring)
                    Text(v.word)
                        .font(.system(size: 15))
                        .foregroundColor(v.ring == .gray ? .white : v.ring)
                }
            }
        }
        .frame(width: 190, height: 190)
        .frame(maxWidth: .infinity)
    }

    private var statusSentence: some View {
        Text(visual.sentence)
            .font(.system(size: 15))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .minimumScaleFactor(0.9)
    }

    // MARK: - 按钮（OpenXPlay 四态：启动 / 停止 / 连接中… / 断开连接）

    private var actionButton: some View {
        Button {
            switch action.kind {
            case .start: controller.connectToCar()
            case .stopScan: controller.stopScan()
            case .stopAll: controller.stop()
            case .disconnect: controller.stop()
            }
        } label: {
            Text(action.label)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(action.color == .mint ? .black : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(action.color)
                .cornerRadius(28)
        }
        .disabled(!action.enabled)
        .padding(.top, 4)
    }

    private enum ButtonKind { case start, stopScan, stopAll, disconnect }

    /// 手动加入车机 Wi-Fi 的凭证卡片。
    ///
    /// 免费 Apple 账号没有 HotspotConfiguration entitlement，`NEHotspotConfiguration`
    /// 会失败——只能让用户去「设置 → Wi-Fi」手动连一次。凭证必须显眼、可复制，
    /// 否则用户看到"加入网络"却不知道加哪个。
    @ViewBuilder private var manualJoinCard: some View {
        if let join = state.manualJoin {
            VStack(alignment: .leading, spacing: 10) {
                Label("请手动加入车机 Wi-Fi", systemImage: "wifi")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                HStack {
                    Text("网络名称")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(join.ssid)
                        .font(.system(size: 13, design: .monospaced))
                    Button {
                        UIPasteboard.general.string = join.ssid
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                }
                HStack {
                    Text("密码")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(join.psk)
                        .font(.system(size: 13, design: .monospaced))
                    Button {
                        UIPasteboard.general.string = join.psk
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                }
                Text("去 设置 → Wi-Fi 连接「\(join.ssid)」，连好后回到 App 按「连接车机」（凭证已缓存，会直连）")
                    .font(.system(size: 11))
                    .foregroundColor(Color(white: 0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color(white: 0.12))
            .cornerRadius(14)
        }
    }

    /// 手输配对码入口。
    ///
    /// 官方流程里 BLE 建网阶段不需要配对码，但车机屏若真弹出配对码，
    /// 用户得有个地方能填——否则只能干等。连接全程都显示。
    private var pinEntryButton: some View {
        Button {
            showPinInput = true
        } label: {
            Label("车机屏幕显示了配对码？点此输入", systemImage: "keyboard")
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.45))
        }
        .disabled(state.phaseText == LinkController.Phase.idle.rawValue
                  || state.phaseText == LinkController.Phase.carPlayActive.rawValue)
        .padding(.top, -16)
    }

    private var action: (label: String, color: Color, enabled: Bool, kind: ButtonKind) {
        switch state.phaseText {
        case LinkController.Phase.carPlayActive.rawValue:
            return ("断开连接", .red, true, .disconnect)
        case LinkController.Phase.bleScanning.rawValue,
             LinkController.Phase.bleConnected.rawValue,
             LinkController.Phase.wifiManualJoin.rawValue,
             LinkController.Phase.wifiJoined.rawValue,
             LinkController.Phase.wfdNegotiating.rawValue:
            // 连接全程都可停（照 OpenXPlay：进行中 = 停止）
            return ("停止", Color(white: 0.2), true, .stopScan)
        case LinkController.Phase.transportFailed.rawValue:
            return ("重新启动", .mint, true, .start)
        default:
            return ("启动", .mint, true, .start)
        }
    }

    private var versionLine: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Text("v\(v) · 构建 \(b)")
            .font(.system(size: 11))
            .foregroundColor(Color(white: 0.35))
    }
}
