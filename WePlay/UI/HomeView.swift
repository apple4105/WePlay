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
                        actionButton
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
                Button("确认") { controller.bleBootstrap?.submitPinCode(pinCode) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在车机屏幕上查看当前配对码")
            }
            .onAppear {
                controller.start()
            }
            .preferredColorScheme(.dark)
        }
    }

    // MARK: - 状态视觉模型（OpenXPlay 式：圆环 + 中心内容 + 状态词）

    private var visual: (progress: Double?, ring: Color, icon: String,
                         center: String?, word: String, sentence: String) {
        switch state.phaseText {
        case LinkController.Phase.idle.rawValue:
            return (0, .gray, "circle", nil, "未启动", "按下面的「启动」开始连接车机。")
        case LinkController.Phase.identityLoaded.rawValue:
            return (0.1, .green, "key.fill", nil, "准备中", "配件身份已装载，正在启动虚拟 accessory……")
        case LinkController.Phase.transportReady.rawValue:
            return (0.1, .green, "car.fill", nil, "就绪", "已就绪。按「启动」连接车机。")
        case LinkController.Phase.transportFailed.rawValue:
            return (nil, .red, "exclamationmark.triangle.fill", nil, "启动失败",
                    "虚拟 accessory 初始化失败。详见「诊断」里的 [Transport] 日志。")
        case LinkController.Phase.bleScanning.rawValue:
            return (nil, .orange, "iPhone.radiowaves.left.and.right", nil, "搜索中",
                    "正在搜索车机的蓝牙广播……请确认车机已打开 CarLink。")
        case LinkController.Phase.carNotFound.rawValue:
            return (0, .orange, "questionmark.circle", nil, "未发现车机",
                    "12 秒内没有发现车机广播。请确认车机已打开 CarLink 后重试。")
        case LinkController.Phase.bleConnected.rawValue:
            return (0.2, .green, nil, "20%", "连接车机", "已连上车机蓝牙，正在拿取网络凭证……")
        case LinkController.Phase.wifiJoined.rawValue:
            return (0.45, .green, nil, "45%", "加入网络", "已加入车机网络。")
        case LinkController.Phase.wfdNegotiating.rawValue:
            return (0.7, .green, nil, "70%", "等待车机连接", "与车机的投屏会话协商中……")
        case LinkController.Phase.carPlayActive.rawValue:
            return (1, .green, "checkmark", nil, "CarPlay 已激活", "正在向车机投屏。")
        default:
            return (0, .gray, "circle", nil, state.phaseText, "")
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
                    Image(systemName: v.icon)
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

    private var action: (label: String, color: Color, enabled: Bool, kind: ButtonKind) {
        switch state.phaseText {
        case LinkController.Phase.carPlayActive.rawValue:
            return ("断开连接", .red, true, .disconnect)
        case LinkController.Phase.bleScanning.rawValue,
             LinkController.Phase.bleConnected.rawValue,
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
