#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)"
SOURCE_DIR="${FFMPEG_SOURCE_DIR:-${PROJECT_ROOT}/ffmpeg-8.1}"
OUTPUT_DIR="${FFMPEG_OUTPUT_DIR:-${PROJECT_ROOT}/ffmpeg-appstore}"
BUILD_DIR="${OUTPUT_DIR}/build"
WORK_SOURCE_DIR="${OUTPUT_DIR}/source"
PREFIX_DIR="${OUTPUT_DIR}/prefix"
RUNTIME_FFMPEG="${OUTPUT_DIR}/ffmpeg"
RUNTIME_LIB_DIR="${OUTPUT_DIR}/lib"
CLEAN_PKGCONFIG_DIR="${BUILD_DIR}/pkgconfig"

if [ ! -x "${SOURCE_DIR}/configure" ]; then
    echo "error: FFmpeg source tree not found at ${SOURCE_DIR}" >&2
    exit 1
fi

find_pkgconfig_file() {
    package_name="$1"

    for candidate in \
        "/opt/homebrew/opt/${package_name}/lib/pkgconfig/${package_name}.pc" \
        "/opt/homebrew/lib/pkgconfig/${package_name}.pc" \
        "/usr/local/opt/${package_name}/lib/pkgconfig/${package_name}.pc" \
        "/usr/local/lib/pkgconfig/${package_name}.pc"
    do
        if [ -f "${candidate}" ]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

prepare_clean_pkgconfig_dir() {
    mkdir -p "${CLEAN_PKGCONFIG_DIR}"

    for package in libwebp libsharpyuv dav1d SvtAv1Enc; do
        source_pc="$(find_pkgconfig_file "${package}" || true)"
        if [ -z "${source_pc}" ]; then
            echo "error: missing pkg-config file for ${package}" >&2
            exit 1
        fi

        ditto "${source_pc}" "${CLEAN_PKGCONFIG_DIR}/$(basename "${source_pc}")"
    done

    export PKG_CONFIG_LIBDIR="${CLEAN_PKGCONFIG_DIR}"
    unset PKG_CONFIG_PATH
}

mkdir -p "${OUTPUT_DIR}"
rm -rf "${BUILD_DIR}" "${WORK_SOURCE_DIR}" "${PREFIX_DIR}" "${RUNTIME_FFMPEG}" "${RUNTIME_LIB_DIR}"
mkdir -p "${BUILD_DIR}" "${PREFIX_DIR}" "${RUNTIME_LIB_DIR}"
ditto "${SOURCE_DIR}" "${WORK_SOURCE_DIR}"

prepare_clean_pkgconfig_dir

WEBP_LIB_DIR="$(pkg-config --variable=libdir libwebp)"

for package in libwebp libsharpyuv dav1d SvtAv1Enc; do
    if ! pkg-config --exists "${package}"; then
        echo "error: missing pkg-config package ${package}" >&2
        exit 1
    fi
done

rewrite_runtime_links() {
    binary_path="$1"

    otool -L "${binary_path}" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
        case "${dependency}" in
            /System/*|/usr/lib/*|@*)
                continue
                ;;
        esac

        dependency_name="$(basename "${dependency}")"
        if [ "${binary_path}" = "${RUNTIME_FFMPEG}" ]; then
            install_name_tool -change "${dependency}" "@executable_path/lib/${dependency_name}" "${binary_path}"
        else
            install_name_tool -change "${dependency}" "@loader_path/${dependency_name}" "${binary_path}"
        fi
    done
}

bundle_runtime_dependency_tree() {
    queue_file="$(mktemp)"
    seen_file="$(mktemp)"
    trap 'rm -f "${queue_file}" "${seen_file}"' EXIT INT TERM

    printf '%s\n' "${RUNTIME_FFMPEG}" > "${queue_file}"

    while IFS= read -r current; do
        [ -n "${current}" ] || continue
        if grep -Fqx "${current}" "${seen_file}" 2>/dev/null; then
            continue
        fi

        printf '%s\n' "${current}" >> "${seen_file}"

        if [ "${current}" != "${RUNTIME_FFMPEG}" ]; then
            install_name_tool -id "@rpath/$(basename "${current}")" "${current}"
        fi

        otool -L "${current}" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
            case "${dependency}" in
                /System/*|/usr/lib/*|@*)
                    continue
                    ;;
            esac

            dependency_name="$(basename "${dependency}")"
            bundled_dependency="${RUNTIME_LIB_DIR}/${dependency_name}"
            if [ ! -f "${bundled_dependency}" ]; then
                ditto "${dependency}" "${bundled_dependency}"
                chmod 755 "${bundled_dependency}"
            fi
            rewrite_runtime_links "${current}"
            if ! grep -Fqx "${bundled_dependency}" "${queue_file}" 2>/dev/null && ! grep -Fqx "${bundled_dependency}" "${seen_file}" 2>/dev/null; then
                printf '%s\n' "${bundled_dependency}" >> "${queue_file}"
            fi
        done
    done < "${queue_file}"

    if [ -d "${WEBP_LIB_DIR}" ]; then
        for dylib in "${WEBP_LIB_DIR}"/libsharpyuv*.dylib; do
            [ -e "${dylib}" ] || continue
            bundled_dependency="${RUNTIME_LIB_DIR}/$(basename "${dylib}")"
            if [ ! -e "${bundled_dependency}" ]; then
                ditto "${dylib}" "${bundled_dependency}"
                chmod 755 "${bundled_dependency}" 2>/dev/null || true
            fi
        done
    fi

    find "${RUNTIME_LIB_DIR}" -maxdepth 1 -type f -name '*.dylib' -print | while IFS= read -r dylib; do
        install_name_tool -change "@rpath/libsharpyuv.0.dylib" "@loader_path/libsharpyuv.0.dylib" "${dylib}" 2>/dev/null || true
    done

    find "${RUNTIME_LIB_DIR}" -maxdepth 1 -type f -name '*.dylib' -print | sort | while IFS= read -r dylib; do
        install_name_tool -id "@rpath/$(basename "${dylib}")" "${dylib}"
        rewrite_runtime_links "${dylib}"
        codesign --force --sign - --timestamp=none "${dylib}"
    done

    codesign --force --sign - --timestamp=none "${RUNTIME_FFMPEG}"
}

validate_runtime() {
    buildconf="$("${RUNTIME_FFMPEG}" -hide_banner -buildconf 2>/dev/null || true)"
    encoders="$("${RUNTIME_FFMPEG}" -hide_banner -encoders 2>/dev/null || true)"
    muxers="$("${RUNTIME_FFMPEG}" -hide_banner -muxers 2>/dev/null || true)"
    demuxers="$("${RUNTIME_FFMPEG}" -hide_banner -demuxers 2>/dev/null || true)"
    decoders="$("${RUNTIME_FFMPEG}" -hide_banner -decoders 2>/dev/null || true)"
    filters="$("${RUNTIME_FFMPEG}" -hide_banner -filters 2>/dev/null || true)"
    protocols="$("${RUNTIME_FFMPEG}" -hide_banner -protocols 2>/dev/null || true)"

    printf '%s\n' "${buildconf}" | grep -Eq -- '--enable-gpl|--enable-nonfree|--enable-libx264|--enable-libx265|--enable-libfdk-aac' && {
        echo "error: built ffmpeg is not App Store safe" >&2
        exit 1
    }

    printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]libwebp([[:space:]]|$)' || {
        echo "error: missing libwebp encoder" >&2
        exit 1
    }
    printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]libsvtav1([[:space:]]|$)' || {
        echo "error: missing libsvtav1 encoder" >&2
        exit 1
    }
    printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]png([[:space:]]|$)' || {
        echo "error: missing png encoder for future frame extraction" >&2
        exit 1
    }
    printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]mjpeg([[:space:]]|$)' || {
        echo "error: missing mjpeg encoder for future frame extraction" >&2
        exit 1
    }
    printf '%s\n' "${muxers}" | grep -Eq '[[:space:]]webp([[:space:]]|$)' || {
        echo "error: missing webp muxer" >&2
        exit 1
    }
    printf '%s\n' "${muxers}" | grep -Eq '[[:space:]]avif([[:space:]]|$)' || {
        echo "error: missing avif muxer" >&2
        exit 1
    }
    printf '%s\n' "${muxers}" | grep -Eq '[[:space:]]image2([[:space:]]|$)' || {
        echo "error: missing image2 muxer for future frame extraction" >&2
        exit 1
    }
    printf '%s\n' "${demuxers}" | grep -Eq '[[:space:]]mov,mp4,m4a,3gp,3g2,mj2([[:space:]]|$)' || {
        echo "error: missing mov/mp4 demuxer for future frame extraction" >&2
        exit 1
    }
    printf '%s\n' "${demuxers}" | grep -Eq '[[:space:]]matroska,webm([[:space:]]|$)' || {
        echo "error: missing matroska/webm demuxer for future frame extraction" >&2
        exit 1
    }
    printf '%s\n' "${demuxers}" | grep -Eq '[[:space:]]image2([[:space:]]|$)' || {
        echo "error: missing image2 demuxer for current still-image conversion" >&2
        exit 1
    }
    printf '%s\n' "${demuxers}" | grep -Eq '[[:space:]]gif([[:space:]]|$)' || {
        echo "error: missing gif demuxer for current gif resize support" >&2
        exit 1
    }
    printf '%s\n' "${decoders}" | grep -Eq '(^| )h264( |$)' && {
        echo "error: H.264 decoder must NOT be included (patent risk)" >&2
        exit 1
    }
    printf '%s\n' "${decoders}" | grep -Eq '(^| )hevc( |$)' && {
        echo "error: HEVC decoder must NOT be included (patent risk)" >&2
        exit 1
    }
    printf '%s\n' "${decoders}" | grep -Eq '(^| )av1( |$)' || {
        echo "error: missing AV1 decoder for future frame extraction" >&2
        exit 1
    }
    printf '%s\n' "${decoders}" | grep -Eq '[[:space:]]png([[:space:]]|$)' || {
        echo "error: missing png decoder for current still-image conversion" >&2
        exit 1
    }
    printf '%s\n' "${filters}" | grep -Eq '(^|[[:space:]])scale[[:space:]]' || {
        echo "error: missing scale filter for resize and future frame extraction" >&2
        exit 1
    }
    printf '%s\n' "${filters}" | grep -Eq '(^|[[:space:]])format[[:space:]]' || {
        echo "error: missing format filter for current image conversion" >&2
        exit 1
    }
    printf '%s\n' "${protocols}" | grep -Eq '^[[:space:]]*file$' || {
        echo "error: missing file protocol" >&2
        exit 1
    }
}

validate_runtime_dependencies() {
    if find "${RUNTIME_LIB_DIR}" -maxdepth 1 -type f \( -name 'libX11*.dylib' -o -name 'libxcb*.dylib' -o -name 'libvmaf*.dylib' \) | grep -q .; then
        echo "error: unexpected host-side runtime dependencies were bundled" >&2
        exit 1
    fi

    if {
        otool -L "${RUNTIME_FFMPEG}"
        find "${RUNTIME_LIB_DIR}" -maxdepth 1 -type f -name '*.dylib' -print | sort | while IFS= read -r dylib; do
            otool -L "${dylib}"
        done
    } | grep -E '/opt/homebrew|/usr/local|libX11|libxcb|libvmaf' >/dev/null; then
        echo "error: runtime still contains forbidden non-system dependencies" >&2
        exit 1
    fi
}

cd "${WORK_SOURCE_DIR}"

make distclean >/dev/null 2>&1 || true

./configure \
    --prefix="${PREFIX_DIR}" \
    --disable-autodetect \
    --enable-ffmpeg \
    --disable-avdevice \
    --disable-ffplay \
    --disable-ffprobe \
    --enable-shared \
    --disable-static \
    --disable-debug \
    --disable-doc \
    --disable-network \
    --disable-libvmaf \
    --disable-sdl2 \
    --enable-zlib \
    --disable-indevs \
    --disable-outdevs \
    --enable-pthreads \
    --enable-decoder=png \
    --enable-decoder=gif \
    --enable-decoder=av1 \
    --enable-encoder=png \
    --enable-encoder=mjpeg \
    --enable-encoder=gif \
    --enable-muxer=image2 \
    --enable-muxer=gif \
    --enable-muxer=webp \
    --enable-muxer=avif \
    --enable-demuxer=image2 \
    --enable-demuxer=gif \
    --enable-demuxer=mov \
    --enable-demuxer=matroska \
    --enable-parser=av1 \
    --disable-decoder=h264 \
    --disable-decoder=hevc \
    --disable-parser=h264 \
    --disable-parser=hevc \
    --enable-protocol=file \
    --enable-protocol=pipe \
    --enable-filter=scale \
    --enable-filter=format \
    --enable-libwebp \
    --enable-libdav1d \
    --enable-libsvtav1

make -j"$(sysctl -n hw.ncpu)"
make install

ditto "${PREFIX_DIR}/bin/ffmpeg" "${RUNTIME_FFMPEG}"
chmod 755 "${RUNTIME_FFMPEG}"

bundle_runtime_dependency_tree
validate_runtime
validate_runtime_dependencies

# Export build configuration and script for LGPL compliance
"${RUNTIME_FFMPEG}" -hide_banner -buildconf > "${OUTPUT_DIR}/ffmpeg-buildconf.txt" 2>/dev/null || true
cp "${SCRIPT_DIR}/build_appstore_ffmpeg.sh" "${OUTPUT_DIR}/ffmpeg-build-script.sh"

echo "Built App Store ffmpeg runtime at ${OUTPUT_DIR}"
echo "Compliance artifacts exported: ffmpeg-buildconf.txt, ffmpeg-build-script.sh"
