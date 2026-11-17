// SPDX-License-Identifier: MIT
// 헤드리스 코어 검증 (Phase 1): macOS Clang 으로 core/ 를 컴파일해
// Player 를 초기화하고 프레임을 돌려 렌더링·오디오·세이브/로드·MIDI 를 확인한다.
//   사용법: HeadlessCoreTest [gamedir] [frames] [out_prefix]
//   gamedir 에 PC98PLAYER.INI 이 없으면 빈 INI 를 만든다 (플로피 없이 DOS 셸 기동).
#include "../core/cdvirt.h"
#include "../core/floppy.h"
#include "../core/hdimage.h"
#include "../core/player.h"
#include "../core/hostfs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <chrono>
#include <cmath>
#include <vector>

// ---- 테스트용 합성 폰트 (실제 글리프는 Phase 2 의 CoreText 래스터라이저로 대체) ----
// 코드마다 다른 사선 패턴을 그려 텍스트 영역이 확실히 픽셀로 나오게 한다.
static void fk(void*, uint16_t jis, uint8_t out[32]) {
    for (int y = 0; y < 16; y++) {
        uint16_t bits = 0;
        for (int x = 0; x < 16; x++) if ((x + y + (jis >> 8) + jis) % 3 == 0) bits |= (uint16_t)(0x8000u >> x);
        out[y * 2] = (uint8_t)(bits >> 8);
        out[y * 2 + 1] = (uint8_t)bits;
    }
}
static void fa(void*, uint8_t c, uint8_t out[16]) {
    for (int y = 0; y < 16; y++) {
        uint8_t bits = 0;
        for (int x = 0; x < 8; x++) if ((x + y + c) % 3 == 0) bits |= (uint8_t)(0x80u >> x);
        out[y] = bits;
    }
}

// ---- BMP 덤프 (비전 검증용. PPM 과 달리 sips 없이 바로 볼 수 있다) ----
static bool write_bmp(const char* path, const uint32_t* fb, int w, int h) {
    FILE* o = fopen(path, "wb");
    if (!o) return false;
    int pad = (4 - (w * 3) % 4) % 4;
    int row = w * 3 + pad;
    uint32_t sz = 54 + (uint32_t)row * h;
    uint8_t hd[54] = {'B','M'};
    memcpy(hd + 2, &sz, 4); uint32_t off = 54; memcpy(hd + 10, &off, 4);
    uint32_t ihs = 40; memcpy(hd + 14, &ihs, 4);
    memcpy(hd + 18, &w, 4); memcpy(hd + 22, &h, 4);
    uint16_t planes = 1, bpp = 24; memcpy(hd + 26, &planes, 2); memcpy(hd + 28, &bpp, 2);
    fwrite(hd, 1, 54, o);
    std::vector<uint8_t> line(row, 0);
    for (int y = h - 1; y >= 0; y--) {
        for (int x = 0; x < w; x++) {
            uint32_t c = fb[y * w + x];
            line[x * 3 + 0] = (uint8_t)c;
            line[x * 3 + 1] = (uint8_t)(c >> 8);
            line[x * 3 + 2] = (uint8_t)(c >> 16);
        }
        fwrite(line.data(), 1, row, o);
    }
    fclose(o);
    return true;
}

int main(int argc, char** argv) {
    std::string dir = argc >= 2 ? argv[1] : ".";
    int frames = argc >= 3 ? atoi(argv[2]) : 300;
    std::string out = argc >= 4 ? argv[3] : "headless";

    // 빈 INI 로 기동 (플로피·CD 없음 → DOS 셸 프롬프트)
    std::string ini_path = hostfs::join(dir, "PC98PLAYER.INI");
    HostDirEntry st;
    if (!hostfs::stat(ini_path, st)) {
        FILE* f = fopen(ini_path.c_str(), "wb");
        if (f) { fputs("[PC98PLAYER]\nTitle=macOS Headless Test\n", f); fclose(f); }
    }

    FontSource fs;
    fs.kanji = fk; fs.ank = fa; fs.narrow = nullptr; fs.user = nullptr;
    video_set_font(fs);

    extern std::string g_app_dir;
    g_app_dir = dir;

    Ini ini;
    ini.load(ini_path);
    PlayerSettings ps;
    player_settings_from_ini(ini, dir, &ps);
    Player* p = new Player();
    std::string err;
    if (!p->init(ps, &err)) { fprintf(stderr, "NG: init 실패: %s\n", err.c_str()); return 1; }
    fprintf(stderr, "init OK (title=%s, start='%s', boot_fd=%d)\n", ps.title.c_str(), ps.cfg.start.c_str(), ps.cfg.boot_fd);

    // MIDI 싱크: 완결 메시지를 받으면 기록
    static std::vector<std::vector<uint8_t>> g_midi;
    p->midi_sink = [](void*, const uint8_t* msg, int len) { g_midi.push_back(std::vector<uint8_t>(msg, msg + len)); };
    {   // 러닝 스테이터스 포함 1 메시지를 직접 흘려본다
        const uint8_t seq[] = {0x90, 0x40, 0x7F};
        for (uint8_t b : seq) p->midi_feed(b);
    }

    long total_audio = 0; double peak = 0.0;
    auto t0 = std::chrono::steady_clock::now();
    int quit_frame = -1;
    for (int f = 0; f < frames; f++) {
        // 키 입력 통로 점검 (스캔코드 의미는 Phase 3 의 키매퍼에서)
        if (f == 10) machine_key(p->m, 0x1D, true);      // Q
        if (f == 16) machine_key(p->m, 0x1D, false);
        if (f == 20) machine_mouse(p->m, 3, -2, 0);      // 버스 마우스 카운터
        p->run_frame(f == frames - 1, true);
        total_audio += (long)p->audio.size();
        for (size_t i = 0; i + 1 < p->audio.size(); i += 2) {
            double a = fabs(p->audio[i]) + fabs(p->audio[i + 1]);
            if (a > peak) peak = a;
        }
        if (p->m->quit == 2) { quit_frame = f; break; }
    }
    auto t1 = std::chrono::steady_clock::now();
    double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

    // 최종 프레임 화면 점검: 640 x fb_h 의 ARGB
    long lit = 0;
    for (int i = 0; i < 640 * p->fb_h; i++) {
        uint32_t c = p->fb[i];
        if (((c >> 16) & 0xFF) + ((c >> 8) & 0xFF) + (c & 0xFF) > 30) lit++;
    }
    std::string bmp = out + ".bmp";
    bool bmp_ok = write_bmp(bmp.c_str(), p->fb, 640, p->fb_h);

    // 세이브 / 로드 왕복
    std::string serr, lerr;
    bool save_ok = p->save_state(0, &serr);
    bool load_ok = save_ok && p->load_state(0, &lerr);

    fprintf(stderr, "frames=%d quit_at=%d cpu_cycles=%.1fM perf=%.1fms/frame(cpu %.2f audio %.2f)\n",
            frames, quit_frame, p->m->cpu.cycles / 1e6, ms / frames, p->perf_cpu_ms, p->perf_audio_ms);
    fprintf(stderr, "fb_h=%d lit_pixels=%ld/%d audio_samples=%ld peak=%.0f\n",
            p->fb_h, lit, 640 * p->fb_h, total_audio, peak);
    fprintf(stderr, "bmp=%s save=%s(%s) load=%s(%s) midi_msgs=%zu\n",
            bmp_ok ? "ok" : "NG", save_ok ? "ok" : "NG", serr.c_str(),
            load_ok ? "ok" : "NG", lerr.c_str(), g_midi.size());

    // 판정: 프레임이 진행했고, CPU 가 명령을 실행했으며, 화면에 뭔가 그려졌고, 세이브/로드가 성공
    bool ok = p->m->cpu.cycles > 0 && lit > 100 && p->fb_h == 400 && save_ok && load_ok && bmp_ok;
    fprintf(stderr, "%s\n", ok ? "HEADLESS TEST OK" : "HEADLESS TEST NG");
    p->shutdown();
    delete p;
    return ok ? 0 : 1;
}
