// SPDX-License-Identifier: MIT
// PC98PLAYER macOS 앱 진입점 (Phase 1: 최소 골격. 게임 화면은 Phase 2 의 Metal 뷰)
import SwiftUI

@main
struct PC98App: App {
    var body: some Scene {
        WindowGroup {
            MainWindowView()
        }
    }
}
