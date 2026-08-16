#!/bin/bash
# 编译 RootService（需要在 Mac 上执行）
# 用法: bash build.sh
#
# 编译后部署到手机:
#   scp root_service root@手机IP:/var/mobile/
#   ssh root@手机IP chmod +x /var/mobile/root_service

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$SCRIPT_DIR/root_service"

echo "==> 编译 RootService arm64 二进制..."
clang -arch arm64 "$SCRIPT_DIR/root_service.c" -o "$OUTPUT" -O2 -Wall -Wextra

echo "==> 编译成功: $OUTPUT"
file "$OUTPUT"
echo ""
echo "部署到手机:"
echo "  scp $OUTPUT root@手机IP:/var/mobile/"
echo "  ssh root@手机IP chmod +x /var/mobile/root_service"
echo ""
echo "启动 (NewTerm):"
echo "  su root"
echo "  export DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/ellekit/ellekit.dylib"
echo "  /var/mobile/root_service"