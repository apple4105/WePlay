import SwiftUI

/// 主页：状态卡片 + 连接按钮 + 简要日志。
struct HomeView: View {
    @State private var phase: LinkController.Phase = .idle
    @State private var statusText = "未启动"
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showPinInput = false
    @State private var pinCode = ""

    private let controller = (UIApplication.shared.delegate as! AppDelegate).carPlay

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    actionButton
                    if phase.rawValue != LinkController.Phase.idle.rawValue {
                        stepIndicator
                    }
                }
                .padding(.horizontal, 16)
            }
            .navigationTitle("WePlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
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
                Button("确认") { controller?.bleBootstrap?.submitPinCode(pinCode) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在车机屏幕上查看当前配对码")
            }
            .onAppear {
                controller?.onPhaseChanged = { p in
                    DispatchQueue.main.async {
                        phase = p
                        statusText = p.rawValue
                    }
                }
                controller?.start()
            }
        }
    }

    // MARK: - 状态卡片

    private var statusCard: some View {
        VStack(spacing: 8) {
            // 状态圆点
            HStack(spacing: 6) {
                Circle()
                    .fill(phase == .carPlayActive ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.headline)
            }

            // 各阶段步骤指示
            VStack(alignment: .leading, spacing: 6) {
                stepRow("MFi 身份", done: phase.rawValue >= LinkController.Phase.identityLoaded.rawValue)
                stepRow("虚拟 accessory", done: phase.rawValue >= LinkController.Phase.transportReady.rawValue)
                stepRow("BLE 连接车机", done: phase.rawValue >= LinkController.Phase.bleConnected.rawValue)
                stepRow("加入车机网络", done: phase.rawValue >= LinkController.Phase.wifiJoined.rawValue)
                stepRow("WFD 协商", done: phase.rawValue >= LinkController.Phase.wfdNegotiating.rawValue)
                stepRow("CarPlay 投屏", done: phase == .carPlayActive)
            }
            .font(.system(size: 13))
            .foregroundColor(.secondary)
        }
        .padding(16)
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }

    private func stepRow(_ label: String, done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundColor(done ? .green : .gray)
                .font(.system(size: 12))
            Text(label)
        }
    }

    // MARK: - 按钮

    private var actionButton: some View {
        Button {
            handleAction()
        } label: {
            Text(buttonLabel)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(buttonColor)
                .cornerRadius(12)
        }
        .disabled(phase != .idle && phase != .carPlayActive)
    }

    private var buttonLabel: String {
        switch phase {
        case .idle: return "连接车机"
        case .carPlayActive: return "断开连接"
        default: return "连接中…"
        }
    }

    private var buttonColor: Color {
        switch phase {
        case .idle: return .blue
        case .carPlayActive: return .red
        default: return .gray
        }
    }

    private func handleAction() {
        switch phase {
        case .idle:
            controller?.connectToCar()
        case .carPlayActive:
            controller?.stop()
        default:
            break
        }
    }
}
