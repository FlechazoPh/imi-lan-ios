import SwiftUI

/// 根视图（Phase 1 骨架）：竖屏 iPhone 适配优先。
///
/// 布局：
///  - Tab 1「监控」：CameraGridView（竖屏 1列/2列，横屏 3列）
///  - Tab 2「设置」：SettingsView（引擎模式/地址/扫码登录/日志）
/// 全屏单画面由 CameraGridView 的 NavigationLink / fullScreenCover 推出。
struct ContentView: View {
    @EnvironmentObject private var engine: EngineManager
    @EnvironmentObject private var store: CameraStore

    var body: some View {
        TabView {
            NavigationStack {
                CameraGridView()
                    .navigationTitle("米家监控")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("监控", systemImage: "video.fill") }

            NavigationStack {
                SettingsView()
                    .navigationTitle("设置")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        // 底部 Tab 不遮挡内容：用 safeAreaInset 而不是 overlay，灵动岛区域不放按钮。
        .tint(.blue)
        .task { engine.startIfNeeded() }
    }
}
