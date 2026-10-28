#!/usr/bin/env bash
#
# harmony.sh — 在纯 ASCII 临时目录构建 / 测试本工程。
#
# 背景：本仓库目录名可能含非 ASCII（如「解析」），hvigor CLI 会拒绝该路径
# （报 00306003 Invalid project path）。本脚本把工程同步到 ASCII 临时目录后再跑 hvigor。
#
# 用法：
#   scripts/harmony.sh build    # 构建 App（assembleApp）
#   scripts/harmony.sh test     # 构建测试 HAP、安装并在设备上运行单测
#   scripts/harmony.sh clean    # 清理 ASCII 临时目录
#
# 可用环境变量覆盖：DEVECO_HOME / DEVECO_SDK_HOME / JAVA_HOME / HARMONY_ASCII_DIR / DEVICE
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DST="${HARMONY_ASCII_DIR:-/tmp/harmonyrss-build}"
DEVECO_HOME="${DEVECO_HOME:-/Applications/DevEco-Studio.app/Contents}"
# 环境里可能残留无效的 DEVECO_SDK_HOME / JAVA_HOME（如 /sdk），校验目录有效性后再回退。
if [ -z "${DEVECO_SDK_HOME:-}" ] || [ ! -d "$DEVECO_SDK_HOME" ]; then
  DEVECO_SDK_HOME="$DEVECO_HOME/sdk"
fi
if [ -z "${JAVA_HOME:-}" ] || [ ! -d "$JAVA_HOME" ]; then
  JAVA_HOME="$DEVECO_HOME/jbr/Contents/Home"
fi
export DEVECO_SDK_HOME
export JAVA_HOME
NODE="$DEVECO_HOME/tools/node/bin/node"
HVIGOR="$DEVECO_HOME/tools/hvigor/bin/hvigorw.js"
HDC="$DEVECO_SDK_HOME/default/openharmony/toolchains/hdc"
DEVICE="${DEVICE:-}"
BUNDLE="com.xiaohuihu.rss"
TEST_MODULE="entry_test"

hvigor() {
  "$NODE" "$HVIGOR" "$@" --no-daemon
}

sync_src() {
  mkdir -p "$DST"
  rsync -a --delete \
    --exclude 'build' --exclude '.hvigor' --exclude '.cache' \
    --exclude '.git' --exclude '.deveco' \
    "$SRC/" "$DST/"
}

hdc_t() {
  if [ -n "$DEVICE" ]; then
    "$HDC" -t "$DEVICE" "$@"
  else
    "$HDC" "$@"
  fi
}

cmd_build() {
  sync_src
  ( cd "$DST" && hvigor --mode project -p product=default assembleApp -p buildMode=debug )
}

cmd_test() {
  sync_src
  ( cd "$DST" && hvigor --mode module -p module=entry@ohosTest -p product=default assembleHap -p buildMode=debug )
  local hap="$DST/entry/build/default/outputs/ohosTest/entry-ohosTest-signed.hap"
  hdc_t install -r "$hap"
  hdc_t shell aa force-stop "$BUNDLE" || true
  hdc_t shell aa test -b "$BUNDLE" -m "$TEST_MODULE" -s unittest OpenHarmonyTestRunner -s timeout 60000 \
    | grep -E "OHOS_REPORT_RESULT|stream=Error" || true
}

cmd_clean() {
  rm -rf "$DST"
  echo "removed $DST"
}

case "${1:-build}" in
  build) cmd_build ;;
  test) cmd_test ;;
  clean) cmd_clean ;;
  *) echo "usage: $0 {build|test|clean}" >&2; exit 2 ;;
esac
