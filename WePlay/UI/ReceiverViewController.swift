import UIKit

/// 根视图：状态显示 + 模块进度 + 诊断导出按钮。
///
/// v1 用最朴素的 UIKit 手写（不引 SwiftUI，减少 Xcode 14.2 上的变量）。
/// 后面 M6 再换成 SwiftUI。
final class ReceiverViewController: UIViewController {

    private let textView = UITextView()
    private let statusLabel = UILabel()
    private let logButton = UIButton(type: .system)

    private var logLines: [String] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        statusLabel.textColor = .systemGreen
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.text = "WePlay v0.1"

        logButton.setTitle("导出诊断报告", for: .normal)
        logButton.addTarget(self, action: #selector(exportLog), for: .touchUpInside)

        textView.backgroundColor = .black
        textView.textColor = .lightGray
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isEditable = false
        textView.alwaysBounceVertical = true

        let stack = UIStackView(arrangedSubviews: [statusLabel, logButton, textView])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            textView.heightAnchor.constraint(equalTo: stack.heightAnchor, multiplier: 0.8)
        ])

        appendLog("status:")
        appendLog("  core          ok")
        appendLog("  credentials   ok")
        appendLog("  link protocol ok (transport pending)")
        appendLog("  media session pending")
        appendLog("  display output pending")
    }

    func setStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
            self.appendLog(text)
        }
    }

    func appendLog(_ line: String) {
        logLines.append(line)
        textView.text = logLines.joined(separator: "\n")
        let bottom = NSMakeRange(textView.text.count - 1, 1)
        textView.scrollRangeToVisible(bottom)
    }

    @objc private func exportLog() {
        let report = """
        WePlay 诊断报告
        ==================
        系统: \(UIDevice.current.systemVersion)
        机型: \(UIDevice.current.model)
        Bundle: \(Bundle.main.bundleIdentifier ?? "-")

        日志:
        \(logLines.joined(separator: "\n"))
        """
        let activity = UIActivityViewController(
            activityItems: [report],
            applicationActivities: nil
        )
        if let popover = activity.popoverPresentationController {
            popover.sourceView = logButton
        }
        present(activity, animated: true)
    }
}
