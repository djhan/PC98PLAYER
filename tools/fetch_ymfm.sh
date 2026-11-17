#!/bin/sh
# ymfm (BSD 3-Clause, Aaron Giles) を third_party/ymfm に取得する（macOS / Linux 用）。
# Windows は tools/fetch_ymfm.cmd を使う。
set -e
DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DEST="$DIR/../third_party/ymfm"
if [ -f "$DEST/src/ymfm_opn.cpp" ]; then
    echo "取得済みです: $DEST"
    exit 0
fi
if ! command -v git >/dev/null 2>&1; then
    echo "git がありません。https://github.com/aaronsgiles/ymfm を $DEST に展開してください。"
    exit 1
fi
mkdir -p "$DIR/../third_party"
git clone --depth 1 https://github.com/aaronsgiles/ymfm.git "$DEST"
echo "Xcode でワークスペースを開き直してビルドしてください。"
