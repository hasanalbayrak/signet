#!/usr/bin/env bash
set -euo pipefail

# Script to build standalone zsign for macOS
# Statically links OpenSSL (libssl.a and libcrypto.a) from Homebrew

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
OUTPUT_BIN="$PROJECT_ROOT/Sources/Signet/Resources/bin/zsign"
BUILD_TMP="/tmp/zsign-build-tmp"

echo "==> Building standalone zsign..."

if ! command -v brew >/dev/null 2>&1; then
    echo "Error: Homebrew is required to locate OpenSSL static libraries."
    exit 1
fi

OPENSSL_DIR="$(brew --prefix openssl@3 2>/dev/null || brew --prefix openssl 2>/dev/null)"
if [ ! -d "$OPENSSL_DIR" ]; then
    echo "Error: OpenSSL not found via brew. Run: brew install openssl@3"
    exit 1
fi

rm -rf "$BUILD_TMP"
git clone --depth 1 https://github.com/zhlynn/zsign.git "$BUILD_TMP"

cd "$BUILD_TMP/build/macos"
make clean
# Compile object files
make

# Statically link libssl.a and libcrypto.a
mkdir -p "$(dirname "$OUTPUT_BIN")"
g++ -std=c++11 -O3 \
    .build/*.o \
    .build/common/*.o \
    .build/zlib/*.o \
    .build/minizip/*.o \
    "$OPENSSL_DIR/lib/libssl.a" \
    "$OPENSSL_DIR/lib/libcrypto.a" \
    -o "$OUTPUT_BIN"

chmod +x "$OUTPUT_BIN"
echo "==> Successfully built standalone zsign at: $OUTPUT_BIN"
otool -L "$OUTPUT_BIN"
"$OUTPUT_BIN" -v
