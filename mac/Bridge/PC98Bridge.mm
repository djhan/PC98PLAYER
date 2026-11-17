// SPDX-License-Identifier: MIT
//  PC98Bridge.mm -- PC98Bridge 구현. core/player.h 의 Player 를 감싼다.
//  core/ 는 한 글자도 고치지 않는다. macOS 고유의 것은 이 파일과 mac/ 아래에만 둔다.
#import "PC98Bridge.h"
#include "../core/player.h"
#include "../core/floppy.h"
#include "../core/hostfs.h"
#include <mutex>
#include <string>
#include <vector>

// player.cpp 에 정의된 앱 폴더(리듬 ROM 등을 찾을 때 쓴다). 헤더에는 없으므로 여기서 선언만.
extern std::string g_app_dir;

NSString * const PC98BridgeErrorDomain = @"PC98BridgeErrorDomain";

// ---- 내부 상태 -----------------------------------------------------------------
namespace {

struct AudioFifo {
    std::mutex mu;
    std::vector<int16_t> buf;      // 인터리브 스테레오
    size_t pos = 0;                // 다음으로 읽을 위치(꺼낸 뒤 압축)
    void push(const int16_t* d, size_t n) {
        std::lock_guard<std::mutex> lk(mu);
        if (pos > 0 && pos == buf.size()) { buf.clear(); pos = 0; }
        if (pos > 0) buf.erase(buf.begin(), buf.begin() + (std::ptrdiff_t)pos), pos = 0;
        buf.insert(buf.end(), d, d + n);
        // 오버런 방지: 1 초치(44100*2)를 넘으면 오래된 것부터 버린다
        const size_t cap = (size_t)44100 * 2;
        if (buf.size() > cap) { size_t drop = buf.size() - cap; buf.erase(buf.begin(), buf.begin() + (std::ptrdiff_t)drop); }
    }
    // n 개를 꺼내 dst 에 복사하고 실제 개수를 돌려준다
    size_t drain(int16_t* dst, size_t n) {
        std::lock_guard<std::mutex> lk(mu);
        size_t have = buf.size() - pos;
        size_t take = have < n ? have : n;
        if (take) { memcpy(dst, &buf[pos], take * sizeof(int16_t)); pos += take; }
        if (pos == buf.size()) { buf.clear(); pos = 0; }
        return take;
    }
    void flush() {
        std::lock_guard<std::mutex> lk(mu);
        buf.clear(); pos = 0;
    }
};

AudioFifo g_audio_fifo;

void midi_sink_trampoline(void* user, const uint8_t* msg, int len) {
    @autoreleasepool {
        PC98Bridge* self = (__bridge PC98Bridge*)user;
        if (self.onMidiMessage && len > 0) self.onMidiMessage([NSData dataWithBytes:msg length:(NSUInteger)len]);
    }
}

bool ask_pc9821_trampoline(void* user) {
    @autoreleasepool {
        PC98Bridge* self = (__bridge PC98Bridge*)user;
        return self.askPC9821 ? self.askPC9821() : false;
    }
}

// 에러를 채우고 항상 NO 를 돌려준다(실패 경로에서 return fail_out(...) 로 쓴다)
BOOL fail_out(NSError** error, NSInteger code, NSString* msg) {
    if (error) *error = [NSError errorWithDomain:PC98BridgeErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
    return NO;
}

std::string ns_to_std(NSString* s) { return s ? std::string(s.UTF8String ? s.UTF8String : "") : std::string(); }
NSString* std_to_ns(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }

// NSString 접두사 + 코어의 UTF-8 문자열
NSString* err_msg(NSString* prefix, const std::string& detail) {
    return [NSString stringWithFormat:@"%@%@", prefix, std_to_ns(detail)];
}

}  // namespace

// ---- PC98SlotInfo ---------------------------------------------------------------
@implementation PC98SlotInfo {
    SlotInfo _info;
}
- (nullable)initWithCoreInfo:(const SlotInfo&)info {
    if (!(self = [super init])) return nil;
    _info = info;
    return self;
}
- (BOOL)used { return _info.used; }
- (NSString *)when { return std_to_ns(_info.when); }
- (NSData *)thumbRGB { return [NSData dataWithBytes:_info.thumb.data() length:_info.thumb.size()]; }
@end

// ---- PC98Bridge -----------------------------------------------------------------
@implementation PC98Bridge {
    Player* _p;                    // initialize 성공 후 유효
    std::recursive_mutex _mu;      // Player 로의 모든 접근을 직렬화
    std::string _root;
    std::vector<uint32_t> _fb_copy;   // copyFramebuffer 스크래치
    std::vector<int16_t> _audio_scratch;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _p = nullptr;
    return self;
}

- (BOOL)initializeWithIniPath:(NSString *)iniPath error:(NSError **)error {
    std::lock_guard<std::recursive_mutex> lk(_mu);
    if (_p) return fail_out(error, 1, @"이미 초기화되어 있습니다");

    std::string ini = ns_to_std(iniPath);
    if (ini.empty()) return fail_out(error, 2, @"INI 경로가 비어 있습니다");
    // root = INI 의 부모 폴더
    size_t slash = ini.find_last_of("/\\");
    _root = slash == std::string::npos ? "." : ini.substr(0, slash);

    HostDirEntry st;
    if (!hostfs::stat(ini, st)) return fail_out(error, 3, @"PC98PLAYER.INI 를 찾을 수 없습니다");

    Ini core_ini;
    core_ini.load(ini);
    PlayerSettings ps;
    player_settings_from_ini(core_ini, _root, &ps);

    g_app_dir = _root;   // 코어가 리듬 ROM 등을 찾을 때 쓰는 앱 폴더

    Player* p = new Player();
    std::string err;
    if (!p->init(ps, &err)) {
        p->shutdown();
        delete p;
        return fail_out(error, 4, err_msg(@"Player 초기화 실패: ", err));
    }
    p->midi_sink = midi_sink_trampoline;
    p->midi_user = (__bridge void*)self;
    p->ask_pc9821 = ask_pc9821_trampoline;
    p->ask_pc9821_user = (__bridge void*)self;
    _p = p;
    return YES;
}

- (void)dealloc {
    [self shutdown];
}

- (NSString *)gameRoot {
    std::lock_guard<std::recursive_mutex> lk(_mu);
    return std_to_ns(_root);
}

- (NSString *)title {
    std::lock_guard<std::recursive_mutex> lk(_mu);
    return _p ? std_to_ns(_p->ps.title) : @"";
}

#define LOCKED() std::lock_guard<std::recursive_mutex> _lk(_mu)

// ---- 프레임 실행 -----------------------------------------------------------------
- (void)runFrameRenderVideo:(BOOL)renderVideo renderAudio:(BOOL)renderAudio {
    LOCKED();
    if (!_p) return;
    _p->run_frame(renderVideo != NO, renderAudio != NO);
    if (!_p->audio.empty()) g_audio_fifo.push(_p->audio.data(), _p->audio.size());
}

- (void)shutdown {
    LOCKED();
    if (!_p) return;
    _p->shutdown();
    delete _p;
    _p = nullptr;
    g_audio_fifo.flush();
}

- (BOOL)reboot:(NSError **)error {
    LOCKED();
    if (!_p) return fail_out(error, 10, @"초기화되지 않았습니다");
    std::string err;
    if (!_p->reboot(&err)) return fail_out(error, 11, err_msg(@"재기동 실패: ", err));
    return YES;
}

- (BOOL)rebootWithSettingsReload:(NSError **)error {
    LOCKED();
    if (!_p) return fail_out(error, 10, @"초기화되지 않았습니다");
    Ini core_ini;
    core_ini.load(hostfs::join(_root, "PC98PLAYER.INI"));
    PlayerSettings ps;
    player_settings_from_ini(core_ini, _root, &ps);
    std::string err;
    if (!_p->reboot(ps, &err)) return fail_out(error, 11, err_msg(@"재기동 실패: ", err));
    return YES;
}

- (BOOL)quitRequested {
    LOCKED();
    return _p && _p->m->quit == 2;
}

- (NSString *)statusText {
    LOCKED();
    return _p ? std_to_ns(_p->m->status) : @"";
}

- (NSString *)floppyErrorMessage {
    LOCKED();
    return _p ? std_to_ns(_p->floppy_error) : @"";
}

- (NSString *)rhythmInfo {
    LOCKED();
    return _p ? std_to_ns(_p->rhythm_info) : @"";
}

// ---- 비디오 -----------------------------------------------------------------------
- (NSInteger)framebufferWidth { return 640; }

- (NSInteger)framebufferHeight {
    LOCKED();
    return _p ? _p->fb_h : 400;
}

- (NSInteger)copyFramebuffer:(uint32_t *)dst maxPixels:(NSInteger)maxPixels {
    LOCKED();
    if (!_p || !dst) return 0;
    NSInteger n = 640 * (NSInteger)_p->fb_h;
    if (maxPixels < n) return 0;
    memcpy(dst, _p->fb, (size_t)n * sizeof(uint32_t));
    return _p->fb_h;
}

// ---- 오디오 -------------------------------------------------------------------------
- (NSInteger)audioSampleRate { return 44100; }

- (const int16_t *)audioSamplesWithCount:(NSInteger *)sampleCount {
    // 오디오 스레드에서 부른다. Player 락을 잡지 않는다(FIFO 가 이미 분리해 두었음).
    size_t want = 44100 / 30 * 2 * 8;   // 한 번에 최대 8 프레임치
    _audio_scratch.resize(want);
    size_t got = g_audio_fifo.drain(_audio_scratch.data(), want);
    if (sampleCount) *sampleCount = (NSInteger)got;
    return _audio_scratch.data();
}

- (void)audioFlush {
    g_audio_fifo.flush();
}

// ---- 입력 ---------------------------------------------------------------------------
- (void)keyDown:(uint8_t)keyCode {
    LOCKED();
    if (_p) machine_key(_p->m, keyCode, true);
}

- (void)keyUp:(uint8_t)keyCode {
    LOCKED();
    if (_p) machine_key(_p->m, keyCode, false);
}

- (void)allKeysUp {
    LOCKED();
    if (!_p) return;
    for (int k = 0; k < 128; k++)
        if (_p->m->kb_down[k]) machine_key(_p->m, (uint8_t)k, false);
}

- (void)mouseMoveDx:(int)dx dy:(int)dy buttons:(int)buttons {
    LOCKED();
    if (_p) machine_mouse(_p->m, dx, dy, buttons);
}

// ---- 세이브 / 로드 --------------------------------------------------------------------
- (BOOL)saveStateToSlot:(int)slot error:(NSError **)error {
    LOCKED();
    if (!_p) return fail_out(error, 20, @"초기화되지 않았습니다");
    std::string err;
    if (!_p->save_state(slot, &err)) return fail_out(error, 21, std_to_ns(err));
    return YES;
}

- (BOOL)loadStateFromSlot:(int)slot error:(NSError **)error {
    LOCKED();
    if (!_p) return fail_out(error, 20, @"초기화되지 않았습니다");
    std::string err;
    if (!_p->load_state(slot, &err)) return fail_out(error, 21, std_to_ns(err));
    return YES;
}

- (PC98SlotInfo *)slotInfoForIndex:(int)slot {
    LOCKED();
    if (!_p) return nil;
    SlotInfo info;
    if (!state_slot_info(_p->ps.cfg.root, slot, &info)) return nil;
    return [[PC98SlotInfo alloc] initWithCoreInfo:info];
}

// ---- 플로피 ---------------------------------------------------------------------------
- (BOOL)insertFloppyUnit:(int)unit path:(NSString *)path error:(NSError **)error {
    LOCKED();
    if (!_p) return fail_out(error, 30, @"초기화되지 않았습니다");
    std::string err;
    if (!floppy::insert_unit(unit, ns_to_std(path), &err)) {
        _p->floppy_error = "플로피를 넣을 수 없습니다: " + ns_to_std(path) + "（" + err + "）";
        return fail_out(error, 31, std_to_ns(_p->floppy_error));
    }
    _p->floppy_error.clear();
    return YES;
}

- (void)ejectFloppyUnit:(int)unit {
    LOCKED();
    floppy::eject_unit(unit);
}

- (NSString *)floppyPathForUnit:(int)unit {
    LOCKED();
    return std_to_ns(floppy::current_path_unit(unit));
}

// ---- 메모리 에디터 / 치트 ---------------------------------------------------------------
- (uint32_t)ramSize {
    LOCKED();
    return _p && _p->m ? _p->m->ram_size : 0;
}

- (NSData *)dumpMemoryAtAddress:(uint32_t)address length:(uint32_t)length {
    LOCKED();
    if (!_p || !_p->m || !_p->m->ram) return nil;
    uint32_t size = _p->m->ram_size;
    if (address >= size) return [NSData data];
    uint32_t n = length < size - address ? length : size - address;
    return [NSData dataWithBytes:_p->m->ram + address length:n];
}

- (void)writeMemoryAtAddress:(uint32_t)address data:(NSData *)data {
    LOCKED();
    if (!_p || !_p->m || !_p->m->ram || !data.length) return;
    uint32_t size = _p->m->ram_size;
    if (address >= size) return;
    uint32_t n = (uint32_t)data.length < size - address ? (uint32_t)data.length : size - address;
    memcpy(_p->m->ram + address, data.bytes, n);
}

@end
