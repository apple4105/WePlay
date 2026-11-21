import SwiftUI
import UIKit

/// 设置页：Wi-Fi 加入方式 / 音频路由 / 诊断
struct SettingsView: View {
    @AppStorage("wifi_auto_join") var wifiAutoJoin = false
    @AppStorage("audio_route") var audioRoute = "bluetooth"
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Wi-Fi 加入") {
                    Toggle("自动加入车机网络", isOn: $wifiAutoJoin)
                    if wifiAutoJoin {
                        Text("需要付费开发者账号的 HotspotConfiguration entitlement，否则自动加入会失败并回退到手动模式。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("每次连接时需要手动在 设置→Wi-Fi 里加入车机网络。iOS 会记住该网络，之后自动连。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("音频路由") {
                    Picker("输出方式", selection: $audioRoute) {
                        Text("蓝牙（推荐）").tag("bluetooth")
                        Text("Wi-Fi 同传").tag("wifi")
                    }
                    .pickerStyle(.inline)
                    Text("蓝牙路由：iPhone 通过蓝牙连车机，车机音源切蓝牙。WiFi 同传：音频随画面一起传输，无需蓝牙。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (构建 \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                            .foregroundColor(.secondary)
                    }
                    HStack { Text("目标系统"); Spacer(); Text("iOS 16.0+") }
                    HStack { Text("投屏协议"); Spacer(); Text("WFD 1.0") }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// 诊断日志页：实时显示所有模块日志，可导出
struct DiagnosticsView: View {
    @Environment(\.dismiss) var dismiss
    @State private var logText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("导出") {
                        let activity = UIActivityViewController(
                            activityItems: [Diagnostics.shared.exportText()],
                            applicationActivities: nil
                        )
                        UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .flatMap { $0.windows }
                            .first { $0.isKeyWindow }?
                            .rootViewController?
                            .present(activity, animated: true)
                    }
                }
            }
            .onAppear {
                logText = Diagnostics.shared.exportText()
                Diagnostics.shared.onUpdate = { line in
                    logText += line + "\n"
                }
            }
        }
    }
}
