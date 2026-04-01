#!/bin/sh

set -eu

PROJECT_ROOT="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
RUNTIME_DIR="${PROJECT_ROOT}/ffmpeg-appstore"
RUNTIME_LIB_DIR="${RUNTIME_DIR}/lib"
WEBP_LIB_DIR="$(pkg-config --variable=libdir libwebp)"

if [ ! -d "${RUNTIME_LIB_DIR}" ]; then
    echo "error: runtime lib directory not found at ${RUNTIME_LIB_DIR}" >&2
    exit 1
fi

for dylib in "${WEBP_LIB_DIR}"/libwebp*.dylib "${WEBP_LIB_DIR}"/libsharpyuv*.dylib; do
    [ -e "${dylib}" ] || continue
    ditto "${dylib}" "${RUNTIME_LIB_DIR}/$(basename "${dylib}")"
    chmod 755 "${RUNTIME_LIB_DIR}/$(basename "${dylib}")" 2>/dev/null || true
done

find "${RUNTIME_LIB_DIR}" -maxdepth 1 -type f -name '*.dylib' -print | while IFS= read -r dylib; do
    install_name_tool -change "@rpath/libsharpyuv.0.dylib" "@loader_path/libsharpyuv.0.dylib" "${dylib}" 2>/dev/null || true
done

find "${RUNTIME_LIB_DIR}" -maxdepth 1 -type f -name '*.dylib' -print | sort | while IFS= read -r dylib; do
    codesign --force --sign - --timestamp=none "${dylib}"
done

codesign --force --sign - --timestamp=none "${RUNTIME_DIR}/ffmpeg"

echo "Fixed App Store ffmpeg runtime at ${RUNTIME_DIR}"
