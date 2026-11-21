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
                controller.onPhaseChanged = { p in
                    DispatchQueue.main.async { state.phaseText = p.rawValue }
                }
            }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.phaseText.contains("CarPlay") ? Color.green : Color.orange)
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
            if state.phaseText == LinkController.Phase.carPlayActive.rawValue {
                controller.stop()
            } else {
                controller.connectToCar()
            }
        } label: {
            Text(state.phaseText == LinkController.Phase.carPlayActive.rawValue ? "断开连接" :
                 state.phaseText == LinkController.Phase.idle.rawValue ? "连接车机" : "连接中…")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(state.phaseText == LinkController.Phase.carPlayActive.rawValue ? Color.red : Color.blue)
                .cornerRadius(12)
        }
        .disabled(state.phaseText != LinkController.Phase.idle.rawValue && state.phaseText != LinkController.Phase.carPlayActive.rawValue)
    }
}
