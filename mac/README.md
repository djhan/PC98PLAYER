# PC98PLAYER macOS 포팅 (mac/)

Windows 전용(Win32/DirectX/GDI) 앱을 macOS 네이티브(SwiftUI + Metal)로 옮기는 작업.
전체 계획은 `../PORTING_PLAN_MACOS.md`, 사용 설명서는 `../README.md` 를 따른다.

## 구성

```
mac/
├── Bridge/       PC98Bridge (Obj-C++): Swift ↔ core/ 의 Player. core/ 는 무수정
├── UI/           SwiftUI (PC98App, MainWindowView …)
├── Tests/        HeadlessCoreTest.cpp — 독립 실행형 헤드리스 검증 (합성 폰트)
├── TestsSwift/   XCTest — 브릿지 스모크 테스트
├── project.yml   xcodegen 프로젝트 정의
└── build_headless.sh  헤드리스 검증 한 번에 돌리기
```

## 빌드

```sh
# 1) ymfm (BSD 3-Clause) 받기 — gitignored
tools/fetch_ymfm.sh

# 2) Xcode 프로젝트 생성 (project.yml 이 바뀔 때만 다시)
cd mac && xcodegen generate

# 3) 빌드 / 테스트
xcodebuild -project PC98PlayerMac.xcodeproj -scheme PC98PlayerMac build
xcodebuild -project PC98PlayerMac.xcodeproj -scheme PC98PlayerMac test

# 헤드리스 코어 검증 (화면 BMP 까지 남김)
sh mac/build_headless.sh   # 결과: out/headless/headless.bmp
```

- 배포 타깃: macOS 14.0 (arm64). 서명은 로컬용 ad-hoc (`CODE_SIGN_IDENTITY=-`).
- 링크: `-liconv` (core/hostfs.cpp 의 Shift_JIS 변환에 필요).
- 전처리 정의: `GMPV3_WITH_YMFM` (CMakeLists.txt 와 동일).

## 진행 상황 (Phase 별)

- [x] **Phase 1** 빌드 인프라 & C++ 코어 브릿지 — `fetch_ymfm.sh`, `PC98Bridge.h/mm`,
      Xcode 프로젝트. macOS Clang 코어 컴파일 + 헤드리스 300 프레임 + XCTest 5 개 통과.
- [ ] **Phase 2** 비디오(Metal) & 폰트 래스터라이저 (CoreText)
- [ ] **Phase 3** 오디오(CoreAudio), MIDI(CoreMIDI) & 입력(키/마우스/패드)
- [ ] **Phase 4** F11 오버레이 & 세이브/로드 UI
- [ ] **Phase 5** 설정 / 메모리 에디터 / 코드 에디터 / 설치 어시스턴트
- [ ] **Phase 6** 통합 테스트 & 품질 점검

## 코어가 쓰는 호스트 콜백 정리 (브릿지에서 처리)

- `g_app_dir` (player.cpp): PC98PLAYER.EXE 폴더 대신 게임 폴더를 넣어둔다.
- `Player.midi_sink`: 코어가 완결한 MIDI 메시지를 호스트로 넘긴다 → `PC98Bridge.onMidiMessage`.
- `Player.ask_pc9821`: `PC9821=` 이 없는데 PC-9821 접근이 있을 때 물어본다 → `PC98Bridge.askPC9821`.
- `FontSource` (machine.h): 글리프 공급. Phase 2 의 `PC98FontRasterizer`(CoreText)가 채운다.
