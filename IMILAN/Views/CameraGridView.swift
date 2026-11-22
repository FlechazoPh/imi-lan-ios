import SwiftUI

/// 摄像头网格（Phase 1 骨架）：竖屏 iPhone 适配。
///
///  - 竖屏：1列（单路大图）或 2列（2×2），由 Picker 切换，默认 2列；
///  - 横屏：3列；
///  - 卡片最小触摸目标 44pt，布局用 LazyVGrid 自适应，不用固定像素宽。
struct CameraGridView: View {
    @EnvironmentObject private var store: CameraStore
    @EnvironmentObject private var engine: EngineManager
    @State private var columns: Int = 2
    @State private var showQRLogin = false
    @State private var selectedCamera: Camera?

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let count = isLandscape ? 3 : columns
            let grid = Array(repeating: GridItem(.flexible(), spacing: 12), count: count)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("列数", selection: $columns) {
                            Text("单列").tag(1)
                            Text("双列").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                        Spacer()
                        Text(engine.state.rawValue)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal)

                    if let error = store.lastError {
                        // 刷新失败时显示真实原因（引擎未通 / 未登录 / 账号下无设备 / 网络错误）。
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    if store.cameras.isEmpty {
                        ContentUnavailableView(
                            "还没有摄像头",
                            systemImage: "video.slash",
                            description: Text("点右上角扫码登录，再添加摄像头")
                        )
                    } else {
                        LazyVGrid(columns: grid, spacing: 12) {
                            ForEach(store.cameras) { camera in
                                CameraCardView(camera: camera)
                                    .onTapGesture { selectedCamera = camera }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showQRLogin = true } label: {
                    Label("扫码登录", systemImage: "qrcode.viewfinder")
                }
            }
        }
        .sheet(isPresented: $showQRLogin) { QRLoginView() }
        .fullScreenCover(item: $selectedCamera) { camera in
            SingleCameraView(camera: camera)
        }
        .task {
            // 进入页面时引擎已 running 就拉一次设备列表。
            if engine.state == .running {
                await store.refreshFromEngine()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("IMILoginDidSucceed"))) { _ in
            // 扫码登录成功后再刷新一次（此时才有 userID 可拉设备）。
            Task { await store.refreshFromEngine() }
        }
        .onChange(of: engine.state) { _, newState in
            // 引擎后启动（比页面晚）时也拉一次，避免列表一直为空。
            if newState == .running {
                Task { await store.refreshFromEngine() }
            }
        }
    }
}
