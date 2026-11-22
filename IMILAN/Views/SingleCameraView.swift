import SwiftUI

/// 单画面查看（Phase 1 骨架）。
///
/// 手势（与安卓一致）：
///  - 单击画面：隐藏/显示顶部和底部控件；
///  - 双击：退出单画面（点开“放大镜”时双击只复位缩放）；
///  - 双指捏合/单指拖动：只有点开“放大镜”后才启用，页面级缩放已关闭。
/// 云台：默认关闭，点开关才在左下角显示方向盘；按住持续转，松手停
/// （miss 的 cmdMotorReq = 0x112，operation 语义是“保持朝这个方向转”）。
struct SingleCameraView: View {
    var camera: Camera
    @Environment(\.dismiss) private var dismiss
    @State private var controlsHidden = false
    @State private var showPTZ = false
    @State private var magnifier = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Text("\(camera.name) — 单画面占位（TODO）")
                    .foregroundStyle(.white.opacity(0.7))
                Text(camera.streamURLDescription)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
            }
            if showPTZ {
                // 云台方向盘占位：上下左右四向，无斜向（协议只有四个取值）。
                VStack(spacing: 8) {
                    Button("▲") {}
                    HStack(spacing: 24) {
                        Button("◀") {}; Button("▶") {}
                    }
                    Button("▼") {}
                }
                .font(.title)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(24)
            }
        }
        .overlay(alignment: .top) {
            if !controlsHidden {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").frame(minWidth: 44, minHeight: 44)
                    }
                    Spacer()
                    Text(camera.name).foregroundStyle(.white)
                    Spacer()
                    Button { magnifier.toggle() } label: {
                        Image(systemName: "magnifyingglass").frame(minWidth: 44, minHeight: 44)
                    }
                }
                .padding(.horizontal)
                .background(Color.black.opacity(0.4))
            }
        }
        .overlay(alignment: .bottom) {
            if !controlsHidden && camera.isPTZ {
                Button(showPTZ ? "收起云台" : "云台控制") { showPTZ.toggle() }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .padding(.bottom, 24)
            }
        }
        .onTapGesture { controlsHidden.toggle() }
        // TODO (Phase 2): 双击退出、捏合缩放（仅放大镜模式）、PTZ 按住/松手指令。
    }
}
