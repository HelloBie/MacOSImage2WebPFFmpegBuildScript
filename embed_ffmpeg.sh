#!/bin/sh

set -eu

PROJECT_ROOT="${PROJECT_DIR}"
APPSTORE_SOURCE="${PROJECT_ROOT}/ffmpeg-appstore/ffmpeg"
DEFAULT_SOURCE="${PROJECT_ROOT}/ffmpeg-8.1/ffmpeg"
APP_CONTENTS="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}/Contents"
HELPERS_DIR="${APP_CONTENTS}/Helpers"
FRAMEWORKS_DIR="${APP_CONTENTS}/Frameworks"
RESOURCES_DIR="${APP_CONTENTS}/Resources"
FFMPEG_DEST="${HELPERS_DIR}/ffmpeg"
STAMP_FILE="${RESOURCES_DIR}/ffmpeg-runtime.stamp"
HELPER_ENTITLEMENTS="${PROJECT_ROOT}/FFmpegHelper.entitlements"
THIRD_PARTY_NOTICES_SOURCE="${PROJECT_ROOT}/ThirdPartyNotices.txt"
FFMPEG_LICENSE_SOURCE="${PROJECT_ROOT}/ffmpeg-8.1/COPYING.LGPLv2.1"
FFMPEG_BUILD_SCRIPT_SOURCE="${PROJECT_ROOT}/Scripts/build_appstore_ffmpeg.sh"
THIRD_PARTY_NOTICES_DEST="${RESOURCES_DIR}/ThirdPartyNotices.txt"
FFMPEG_LICENSE_DEST="${RESOURCES_DIR}/FFmpeg-LGPL-2.1.txt"
FFMPEG_BUILDCONF_DEST="${RESOURCES_DIR}/ffmpeg-buildconf.txt"
FFMPEG_BUILD_SCRIPT_DEST="${RESOURCES_DIR}/ffmpeg-build-script.sh"
FFMPEG_CAPABILITIES_DEST="${RESOURCES_DIR}/ffmpeg-capabilities.txt"

find_preferred_ffmpeg() {
    for candidate in \
        "${FFMPEG_SOURCE:-}" \
        "${APPSTORE_SOURCE}" \
        "${DEFAULT_SOURCE}" \
        /opt/homebrew/bin/ffmpeg \
        /usr/local/bin/ffmpeg
    do
        if [ -n "${candidate}" ] && [ -x "${candidate}" ] && ffmpeg_is_appstore_safe "${candidate}" && ffmpeg_supports_avif "${candidate}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    for candidate in \
        "${FFMPEG_SOURCE:-}" \
        "${APPSTORE_SOURCE}" \
        "${DEFAULT_SOURCE}" \
        /opt/homebrew/bin/ffmpeg \
        /usr/local/bin/ffmpeg
    do
        if [ -n "${candidate}" ] && [ -x "${candidate}" ] && ffmpeg_is_appstore_safe "${candidate}"; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

ffmpeg_supports_avif() {
    candidate="$1"

    muxers="$("${candidate}" -hide_banner -muxers 2>/dev/null || true)"
    encoders="$("${candidate}" -hide_banner -encoders 2>/dev/null || true)"

    printf '%s\n' "${muxers}" | grep -Eq '[[:space:]]avif([[:space:]]|$)' || return 1
    printf '%s\n' "${encoders}" | grep -Eq 'libsvtav1|libaom-av1|librav1e' || return 1
}

ffmpeg_is_appstore_safe() {
    candidate="$1"
    buildconf="$("${candidate}" -hide_banner -buildconf 2>/dev/null || true)"

    printf '%s\n' "${buildconf}" | grep -Eq -- '--enable-gpl|--enable-nonfree|--enable-libx264|--enable-libx265|--enable-libfdk-aac' && return 1
    return 0
}

is_bundle_dependency() {
    case "$1" in
        /opt/homebrew/*|/usr/local/*|@executable_path/lib/*|@rpath/*|@loader_path/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

queue_contains() {
    queue_file="$1"
    item="$2"
    grep -Fqx "${item}" "${queue_file}" 2>/dev/null
}

copy_dependency() {
    source_path="$1"
    dest_path="$2"

    if [ ! -f "${dest_path}" ]; then
        ditto "${source_path}" "${dest_path}"
        chmod 755 "${dest_path}"
    fi
}

copy_prebundled_runtime() {
    source_dir="$(dirname "${FFMPEG_SOURCE_PATH}")/lib"
    if [ ! -d "${source_dir}" ]; then
        return 0
    fi

    find "${source_dir}" -maxdepth 1 -type f -name '*.dylib' -print | while IFS= read -r dylib; do
        copy_dependency "${dylib}" "${FRAMEWORKS_DIR}/$(basename "${dylib}")"
    done
}

rewrite_dependencies() {
    binary_path="$1"

    otool -L "${binary_path}" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
        if ! is_bundle_dependency "${dependency}"; then
            continue
        fi

        dependency_name="$(basename "${dependency}")"
        if [ "${binary_path}" = "${FFMPEG_DEST}" ]; then
            target_path="@executable_path/../Frameworks/${dependency_name}"
        else
            target_path="@loader_path/${dependency_name}"
        fi

        install_name_tool -change "${dependency}" "${target_path}" "${binary_path}"
    done
}

bundle_runtime_dependencies() {
    work_file="$(mktemp)"
    processed_file="$(mktemp)"
    trap 'rm -f "${work_file}" "${processed_file}"' EXIT INT TERM

    printf '%s\n' "${FFMPEG_DEST}" > "${work_file}"

    while IFS= read -r current; do
        if queue_contains "${processed_file}" "${current}"; then
            continue
        fi

        printf '%s\n' "${current}" >> "${processed_file}"

        if [ "${current}" != "${FFMPEG_DEST}" ]; then
            install_name_tool -id "@rpath/$(basename "${current}")" "${current}"
        fi

        otool -L "${current}" | tail -n +2 | awk '{print $1}' | while IFS= read -r dependency; do
            if ! is_bundle_dependency "${dependency}"; then
                continue
            fi

            dependency_name="$(basename "${dependency}")"
            bundled_dependency="${FRAMEWORKS_DIR}/${dependency_name}"
            copy_dependency "${dependency}" "${bundled_dependency}"
            rewrite_dependencies "${current}"

            if ! queue_contains "${work_file}" "${bundled_dependency}" && ! queue_contains "${processed_file}" "${bundled_dependency}"; then
                printf '%s\n' "${bundled_dependency}" >> "${work_file}"
            fi
        done
    done < "${work_file}"
}

finalize_embedded_link_paths() {
    rewrite_dependencies "${FFMPEG_DEST}"

    find "${FRAMEWORKS_DIR}" -maxdepth 1 -type f -name '*.dylib' -print | while IFS= read -r dylib; do
        install_name_tool -id "@rpath/$(basename "${dylib}")" "${dylib}"
        rewrite_dependencies "${dylib}"
    done
}

sign_embedded_runtime() {
    sign_identity="-"
    if [ "${CODE_SIGNING_ALLOWED:-NO}" = "YES" ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
        sign_identity="${EXPANDED_CODE_SIGN_IDENTITY}"
    fi

    find "${FRAMEWORKS_DIR}" -maxdepth 1 -type f -name '*.dylib' -print | sort | while IFS= read -r dylib; do
        codesign --force --sign "${sign_identity}" --timestamp=none "${dylib}"
    done

    if [ -f "${HELPER_ENTITLEMENTS}" ]; then
        codesign --force --sign "${sign_identity}" --entitlements "${HELPER_ENTITLEMENTS}" --timestamp=none "${FFMPEG_DEST}"
    else
        codesign --force --sign "${sign_identity}" --timestamp=none "${FFMPEG_DEST}"
    fi
}

copy_compliance_materials() {
    if [ -f "${THIRD_PARTY_NOTICES_SOURCE}" ]; then
        ditto "${THIRD_PARTY_NOTICES_SOURCE}" "${THIRD_PARTY_NOTICES_DEST}"
    fi

    if [ -f "${FFMPEG_LICENSE_SOURCE}" ]; then
        ditto "${FFMPEG_LICENSE_SOURCE}" "${FFMPEG_LICENSE_DEST}"
    fi

    if [ -f "${FFMPEG_BUILD_SCRIPT_SOURCE}" ]; then
        ditto "${FFMPEG_BUILD_SCRIPT_SOURCE}" "${FFMPEG_BUILD_SCRIPT_DEST}"
        chmod 644 "${FFMPEG_BUILD_SCRIPT_DEST}" 2>/dev/null || true
    fi

    if ! "${FFMPEG_SOURCE_PATH}" -hide_banner -buildconf > "${FFMPEG_BUILDCONF_DEST}" 2>/dev/null; then
        if ! "${FFMPEG_DEST}" -hide_banner -buildconf > "${FFMPEG_BUILDCONF_DEST}" 2>/dev/null; then
            printf '%s\n' "Unable to capture ffmpeg build configuration during build." > "${FFMPEG_BUILDCONF_DEST}"
        fi
    fi

    muxers="$("${FFMPEG_SOURCE_PATH}" -hide_banner -muxers 2>/dev/null || true)"
    encoders="$("${FFMPEG_SOURCE_PATH}" -hide_banner -encoders 2>/dev/null || true)"

    supports_webp=0
    supports_gif=0
    avif_encoder=""

    printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]libwebp([[:space:]]|$)' && printf '%s\n' "${muxers}" | grep -Eq '[[:space:]]webp([[:space:]]|$)' && supports_webp=1
    printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]gif([[:space:]]|$)' && printf '%s\n' "${muxers}" | grep -Eq '[[:space:]]gif([[:space:]]|$)' && supports_gif=1

    if printf '%s\n' "${muxers}" | grep -Eq '[[:space:]]avif([[:space:]]|$)'; then
        if printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]libsvtav1([[:space:]]|$)'; then
            avif_encoder="libsvtav1"
        elif printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]libaom-av1([[:space:]]|$)'; then
            avif_encoder="libaom-av1"
        elif printf '%s\n' "${encoders}" | grep -Eq '[[:space:]]librav1e([[:space:]]|$)'; then
            avif_encoder="librav1e"
        fi
    fi

    {
        printf '%s\n' "supports_webp_encoding=${supports_webp}"
        printf '%s\n' "supports_gif_output=${supports_gif}"
        printf '%s\n' "avif_encoder=${avif_encoder}"
    } > "${FFMPEG_CAPABILITIES_DEST}"
}

FFMPEG_SOURCE_PATH="$(find_preferred_ffmpeg || true)"
if [ -z "${FFMPEG_SOURCE_PATH}" ]; then
    echo "error: unable to find an App Store-safe ffmpeg executable" >&2
    exit 1
fi

mkdir -p "${HELPERS_DIR}" "${FRAMEWORKS_DIR}" "${RESOURCES_DIR}"

ditto "${FFMPEG_SOURCE_PATH}" "${FFMPEG_DEST}"
chmod 755 "${FFMPEG_DEST}"

copy_prebundled_runtime
bundle_runtime_dependencies
finalize_embedded_link_paths
sign_embedded_runtime
copy_compliance_materials

printf '%s\n' "${FFMPEG_SOURCE_PATH}" > "${STAMP_FILE}"
