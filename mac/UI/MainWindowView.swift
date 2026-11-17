// SPDX-License-Identifier: MIT
// 메인 게임 화면. Phase 1 은 자리 표시이고, Phase 2 에서 PC98MetalView(MTKView 래퍼)가 이 자리를 차지한다.
import SwiftUI

struct MainWindowView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("PC98PLAYER for macOS")
                .font(.title.bold())
            Text("Phase 1: 코어 브릿지 골격 — Metal 렌더러는 Phase 2 에서 연결됩니다")
                .foregroundStyle(.secondary)
            Text("640 x 400 (16:10)")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}
