// SPDX-License-Identifier: MIT
// Phase 1 스모크 테스트: 브릿지를 통해 코어를 초기화하고 프레임을 돌려
// 렌더링·입력·세이브/로드·메모리 접근이 동작하는지 확인한다.
import XCTest

final class PC98BridgeSmokeTests: XCTestCase {

    /// 빈 게임 폴더(플로피 없음 → DOS 셸 기동)를 임시 디렉토리에 만든다
    private func makeTempGameDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pc98mac-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ini = dir.appendingPathComponent("PC98PLAYER.INI")
        try Data("[PC98PLAYER]\nTitle=Swift Test\n".utf8).write(to: ini)
        return dir
    }

    private func makeBridge() throws -> (PC98Bridge, URL) {
        let dir = try makeTempGameDir()
        let bridge = PC98Bridge()
        try bridge.initialize(withIniPath: dir.appendingPathComponent("PC98PLAYER.INI").path)
        XCTAssertEqual(bridge.title, "Swift Test")
        XCTAssertEqual(bridge.gameRoot, dir.path)
        return (bridge, dir)
    }

    func testInitRunFramebuffer() throws {
        let (bridge, dir) = try makeBridge()
        defer { try? FileManager.default.removeItem(at: dir) }
        for _ in 0..<60 { bridge.runFrame(renderVideo: true, renderAudio: true) }
        XCTAssertFalse(bridge.quitRequested, "빈 게임 폴더의 DOS 셸은 곧바로 끝나지 않는다")

        XCTAssertEqual(bridge.framebufferWidth, 640)
        let h = Int(bridge.framebufferHeight)
        XCTAssertTrue(h == 400 || h == 480)
        var fb = [UInt32](repeating: 0, count: 640 * h)
        let rows = bridge.copyFramebuffer(into: &fb, maxPixels: fb.count)
        XCTAssertEqual(Int(rows), h)
        // 참고: 이 테스트에는 폰트가 없어(Phase 2 의 CoreText 래스터라이저가 FontSource 를 채움)
        // 글리프는 비어 있다. 화면에 실제 글자가 그려지는 것은 독립 실행형
        // mac/Tests/HeadlessCoreTest (합성 폰트) 와 Phase 2 이후의 UI 테스트가 검증한다.
        bridge.shutdown()
    }

    func testInputPassthrough() throws {
        let (bridge, dir) = try makeBridge()
        defer { try? FileManager.default.removeItem(at: dir) }
        bridge.keyDown(0x1D)              // Q 에 해당하는 PC-98 스캔코드
        bridge.mouseMove(dx: 1, dy: -1, buttons: 0)
        bridge.keyUp(0x1D)
        bridge.allKeysUp()
        bridge.runFrame(renderVideo: false, renderAudio: true)
        bridge.shutdown()
    }

    func testSaveLoadRoundtrip() throws {
        let (bridge, dir) = try makeBridge()
        defer { try? FileManager.default.removeItem(at: dir) }
        for _ in 0..<30 { bridge.runFrame(renderVideo: false, renderAudio: true) }
        try bridge.saveState(toSlot: 0)
        try bridge.loadState(fromSlot: 0)
        let info = bridge.slotInfo(for: 0)
        XCTAssertNotNil(info)
        XCTAssertTrue(info!.used, "저장한 슬롯은 used 이어야 한다")
        XCTAssertEqual(info!.thumbRGB.count, 160 * 100 * 3)
        bridge.shutdown()
    }

    func testMemoryDumpAndWrite() throws {
        let (bridge, dir) = try makeBridge()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertGreaterThan(Int(bridge.ramSize), 0xA0000, "기본 메모리는 640KB 이상")

        // 0000:0000 근처 덤프
        let dump = bridge.dumpMemory(atAddress: 0, length: 16)
        XCTAssertEqual(dump?.count, 16)
        // 쓰고 다시 읽어 확인
        let pattern = Data([0x11, 0x22, 0x33, 0x44])
        bridge.writeMemory(atAddress: 0x1000, data: pattern)
        let readback = bridge.dumpMemory(atAddress: 0x1000, length: 4)
        XCTAssertEqual(readback, pattern)
        try bridge.saveState(toSlot: 1)
        bridge.shutdown()
    }

    func testMidiSinkCallback() throws {
        let (bridge, dir) = try makeBridge()
        defer { try? FileManager.default.removeItem(at: dir) }
        // onMidiMessage 는 코어가 메시지를 출력할 때만 불린다. 여기서는 블록 설정만 확인.
        var received: [Data] = []
        bridge.onMidiMessage = { received.append($0) }
        bridge.runFrame(renderVideo: false, renderAudio: true)
        bridge.shutdown()
        _ = received
    }
}
