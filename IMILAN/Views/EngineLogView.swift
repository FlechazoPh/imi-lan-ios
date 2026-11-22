import SwiftUI

/// 引擎日志查看（Phase 1 骨架，占位）。
/// 真实日志在沙箱 Application Support/engine/engine.log 与 gateway.log，
/// 权限 600；往外发日志前要删掉配置绝对路径、摄像头 IP、设备 ID。
struct EngineLogView: View {
    @EnvironmentObject private var engine: EngineManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(engine.logLines, id: \.self) { line in
                Text(line).font(.caption).textSelection(.enabled)
            }
            .navigationTitle("引擎日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("重启引擎") { engine.restart() }
                }
            }
            .overlay {
                if engine.logLines.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text",
                                           description: Text("引擎尚未启动"))
                }
            }
        }
    }
}
