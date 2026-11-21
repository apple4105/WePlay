import SwiftUI
import UIKit

struct HomeView: View {
    @ObservedObject private var state = PipelineState.shared
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showPinInput = false
    @State private var pinCode = ""

    private let controller = LinkController.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    actionButton
                    versionLine
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
                Button("确认") { controller.bleBootstrap?.submitPinCode(pinCode) }
                Button("取消", role: .cancel) {}
            } message: {
                Text("请在车机屏幕上查看当前配对码")
            }
            .onAppear {
                controller.start()
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.phaseText.contains("CarPlay") ? Color.green :
                          state.phaseText.contains("失败") ? Color.red : Color.orange)
                    .frame(width: 10, height: 10)
                Text(state.phaseText)
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 6) {
                stepRow("MFi 身份", done: state.phaseText != LinkController.Phase.idle.rawValue)
                stepRow("虚拟 accessory", done: state.phaseText != LinkController.Phase.idle.rawValue && state.phaseText != LinkController.Phase.identityLoaded.rawValue)
                stepRow("BLE 连接车机", done: state.phaseText == LinkController.Phase.bleConnected.rawValue)
                stepRow("加入车机网络", done: state.phaseText == LinkController.Phase.wifiJoined.rawValue)
                stepRow("WFD 协商", done: state.phaseText == LinkController.Phase.wfdNegotiating.rawValue)
                stepRow("CarPlay 投屏", done: state.phaseText == LinkController.Phase.carPlayActive.rawValue)
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

    private var actionButton: some View {
        Button {
            switch connectState.action {
            case .stop:
                controller.stop()
            case .stopScan:
                controller.stopScan()
            case .connect:
                controller.connectToCar()
            }
        } label: {
            Text(connectState.label)
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(connectState.color)
                .cornerRadius(12)
        }
        .disabled(!connectState.enabled)
    }

    /// 按钮四态（照 OpenXPlay 的模式：过程态都能停）：
    /// 待机/就绪/失败/未发现车机 = 蓝"连接车机"；搜索中 = 红"停止"（可取消）；
    /// 握手进行中 = 灰"连接中…"；已激活 = 红"断开连接"。
    private var connectState: (label: String, color: Color, enabled: Bool,
                               action: HomeView.ButtonAction) {
        switch state.phaseText {
        case LinkController.Phase.carPlayActive.rawValue:
            return ("断开连接", .red, true, .stop)
        case LinkController.Phase.bleScanning.rawValue:
            return ("停止", .red, true, .stopScan)
        case LinkController.Phase.bleConnected.rawValue,
             LinkController.Phase.wifiJoined.rawValue,
             LinkController.Phase.wfdNegotiating.rawValue:
            return ("连接中…", Color.gray, false, .connect)
        default:
            return ("连接车机", .blue, true, .connect)
        }
    }

    private enum ButtonAction { case connect, stopScan, stop }

    /// 版本行——真机上区分装的是哪个构建
    private var versionLine: some View {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Text("v\(v) · 构建 \(b)")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }
}
