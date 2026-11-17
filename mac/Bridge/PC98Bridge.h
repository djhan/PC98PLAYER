// SPDX-License-Identifier: MIT
//  PC98Bridge.h -- Swift UI ↔ C++ 코어(Player) 사이의 Objective-C++ 브릿지
//
//  스레딩 계약:
//   ・모든 Player 접근(runFrame / 입력 / 세이브 / 메모리 접근)은 내부의 단일 락으로 보호한다.
//     UI 스레드에서 아무 메서드나 불러도 안전하다(에뮬 프레임 1 개분, 수 ms 이하로 대기).
//   ・에뮬레이션 루프(Phase 2 이후)는 runFrame 를 주기적으로 불러 진행한다.
//   ・오디오 샘플은 runFrame 이 내부 FIFO 에 쌓고, 오디오 스레드가 audioSamplesWithCount: 로
//     꺼내 간다(언더런/오버런 방지용 링버퍼 역할). audioFlush 로 즉시 비운다.
//   ・onMidiMessage / askPC9821 블록은 에뮬레이션 스레드에서 호출된다.
//     CoreMIDI 송신(MIDISend)은 스레드 안전하므로 블록 안에서 바로 보내도 된다.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const PC98BridgeErrorDomain;

// 세이브 슬롯 정보(F11 오버레이의 썸네일 그리드용)
@interface PC98SlotInfo : NSObject
@property (nonatomic, readonly) BOOL used;
@property (nonatomic, readonly, copy) NSString *when;      // "2026/09/26 12:34"
@property (nonatomic, readonly, copy) NSData *thumbRGB;    // 160*100*3 (STATE_THUMB_W/H, RGB)
@end

@interface PC98Bridge : NSObject

/// 게임 폴더의 PC98PLAYER.INI 를 읽어 Player 를 초기화한다. root 는 INI 의 부모 폴더.
/// (Swift: try bridge.initialize(withIniPath:) — NSError** 는 throws 로 임포트된다)
- (BOOL)initializeWithIniPath:(NSString *)iniPath error:(NSError **)error;
@property (nonatomic, readonly, copy) NSString *gameRoot;
@property (nonatomic, readonly, copy) NSString *title;

// ---- 프레임 실행 -------------------------------------------------------------
- (void)runFrameRenderVideo:(BOOL)renderVideo renderAudio:(BOOL)renderAudio NS_SWIFT_NAME(runFrame(renderVideo:renderAudio:));
- (void)shutdown;
/// 전원을 다시 켠 것과 같음(들어 있는 플로피는 그대로). (Swift: try bridge.reboot())
- (BOOL)reboot:(NSError **)error;
/// PC98PLAYER.INI 를 다시 읽어 설정을 교체하고 기동한다(설정 창의 반영용)
- (BOOL)rebootWithSettingsReload:(NSError **)error NS_SWIFT_NAME(rebootReloadingSettings());
/// 게임이 끝났는지(셸이 마지막까지 갔는지). m->quit == 2
@property (nonatomic, readonly) BOOL quitRequested;
@property (nonatomic, readonly, copy) NSString *statusText;      // m->status
@property (nonatomic, readonly, copy) NSString *floppyErrorMessage;
@property (nonatomic, readonly, copy) NSString *rhythmInfo;

// ---- 비디오 -------------------------------------------------------------------
/// fb 폭(640 고정). 높이는 framebufferHeight (400 또는 640x480 모드에서 480)
@property (nonatomic, readonly) NSInteger framebufferWidth;
@property (nonatomic, readonly) NSInteger framebufferHeight;     // fb_h
/// 락 안에서 fb 전체(640*fb_h 픽셀, ARGB)를 dst 로 복사한다. 복사한 행 수를 돌려준다.
/// dst 는 최소 framebufferWidth * framebufferHeight 픽셀 이상.
- (NSInteger)copyFramebuffer:(uint32_t *)dst maxPixels:(NSInteger)maxPixels NS_SWIFT_NAME(copyFramebuffer(into:maxPixels:));

// ---- 오디오 (44.1kHz 16bit 인터리브 스테레오) ----------------------------------
@property (nonatomic, readonly) NSInteger audioSampleRate;
/// FIFO 에서 샘플을 꺼낸다. 돌려주는 포인터는 다음 호출까지 유효. *sampleCount 는 int16 개수.
- (const int16_t *)audioSamplesWithCount:(NSInteger *)sampleCount;
/// 잔여 버퍼를 즉시 비운다(일시정지·슬롯 로드 직후 등)
- (void)audioFlush;

// ---- 입력 (PC-98 물리 스캔코드. 키 매핑은 PC98KeyMapper 가 담당) -----------------
- (void)keyDown:(uint8_t)keyCode;
- (void)keyUp:(uint8_t)keyCode;
/// 눌린 키를 모두 뗀다(메뉴를 열 때처럼 앱이 포커스를 잃었을 때)
- (void)allKeysUp;
- (void)mouseMoveDx:(int)dx dy:(int)dy buttons:(int)buttons NS_SWIFT_NAME(mouseMove(dx:dy:buttons:));

// ---- 세이브 / 로드 (게임 폴더의 PC98PLAYER.SAV) --------------------------------
- (BOOL)saveStateToSlot:(int)slot error:(NSError **)error;
- (BOOL)loadStateFromSlot:(int)slot error:(NSError **)error;
- (nullable PC98SlotInfo *)slotInfoForIndex:(int)slot NS_SWIFT_NAME(slotInfo(for:));

// ---- 플로피 -------------------------------------------------------------------
- (BOOL)insertFloppyUnit:(int)unit path:(NSString *)path error:(NSError **)error NS_SWIFT_NAME(insertFloppy(unit:path:));
- (void)ejectFloppyUnit:(int)unit;
- (nullable NSString *)floppyPathForUnit:(int)unit;

// ---- 메모리 에디터 / 치트 -------------------------------------------------------
@property (nonatomic, readonly) uint32_t ramSize;
- (nullable NSData *)dumpMemoryAtAddress:(uint32_t)address length:(uint32_t)length;
- (void)writeMemoryAtAddress:(uint32_t)address data:(NSData *)data;

// ---- 코어 → 호스트 콜백 (에뮬레이션 스레드에서 호출됨) ---------------------------
/// 코어가 완결한 MIDI 메시지(1~3바이트 또는 SysEx F0..F7)
@property (nonatomic, copy, nullable) void (^onMidiMessage)(NSData *message);
/// PC9821= 이 없는데 PC-9821 접근이 있을 때. YES 를 돌려주면 PC-9821 로 계속한다.
@property (nonatomic, copy, nullable) BOOL (^askPC9821)(void);

@end

NS_ASSUME_NONNULL_END
