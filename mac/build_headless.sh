#!/bin/sh
# Phase 1 검증: macOS Clang 으로 core/ 를 직접 컴파일해 헤드리스 프레임 실행을 확인한다.
#   tools/fetch_ymfm.sh 로 ymfm 을 받아둔 다음 실행할 것.
# 결과 BMP 는 out/headless/ 에 남는다 (부팅 화면을 눈으로 확인할 수 있다).
set -e
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$DIR/.." && pwd)
cd "$ROOT"
mkdir -p out/headless
clang++ -std=c++17 -O2 -DGMPV3_WITH_YMFM -Icore -Ithird_party/ymfm/src \
    core/*.cpp \
    third_party/ymfm/src/ymfm_opn.cpp third_party/ymfm/src/ymfm_adpcm.cpp third_party/ymfm/src/ymfm_ssg.cpp \
    mac/Tests/HeadlessCoreTest.cpp \
    -o out/headless/HeadlessCoreTest -liconv
cd out/headless
./HeadlessCoreTest . 300 headless
