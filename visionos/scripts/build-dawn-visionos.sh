#!/usr/bin/env bash
# Builds Dawn for Apple Vision Pro (or its simulator) as an install tree that
# aurora's "package" provider consumes (extern/aurora/cmake/AuroraDawnProvider.cmake).
#
# encounter/dawn publishes prebuilt packages for ios-arm64 but not visionOS, and
# the linker refuses an iOS Mach-O on visionOS, so Dawn is built from source at
# the exact revision aurora pins (AURORA_DAWN_REF), Metal only, one static library.
# visionos/patches/dawn/*.patch are applied to the source first.
#
#   visionos/scripts/build-dawn-visionos.sh [--simulator] [--jobs N] [--force]
#
# Prints the package tarball path last. A package built from the same revision,
# patches and flags is reused. Needs Xcode with the visionOS SDK, CMake 3.28+,
# Ninja, Python 3 and git (DAWN_FETCH_DEPENDENCIES clones Dawn's third_party).
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
work="${root}/.scratch/dawn"
jobs="$(sysctl -n hw.ncpu)"
sysroot="xros"
flavour="visionos-arm64"
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --simulator) sysroot="xrsimulator"; flavour="xrsimulator-arm64"; shift ;;
        --jobs) jobs="${2:?}"; shift 2 ;;
        --force) force=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

dawn_ref="$(sed -n 's/.*_aurora_dependency_version(AURORA_DAWN_REF "\([0-9a-f]\{40\}\)".*/\1/p' \
    "${root}/extern/aurora/cmake/AuroraDependencyVersions.cmake")"
[[ -n "${dawn_ref}" ]] || { echo "ERROR: AURORA_DAWN_REF not found; is extern/aurora checked out?" >&2; exit 1; }

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun --sdk "${sysroot}" --show-sdk-path >/dev/null 2>&1 || {
    echo "ERROR: no ${sysroot} SDK; install Xcode with the visionOS platform" >&2; exit 1; }
for tool in cmake ninja python3 git curl; do
    command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} not found" >&2; exit 1; }
done

patches=("${root}"/visionos/patches/dawn/*.patch)
[[ -e "${patches[0]}" ]] || patches=()
flags=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_SYSTEM_NAME=visionOS
    "-DCMAKE_OSX_SYSROOT=${sysroot}"
    -DCMAKE_OSX_ARCHITECTURES=arm64
    # Lower than the app's visionOS 26 on purpose: a static library built for an
    # older minimum links into the app as is, and this value is part of the
    # package's cache key, so raising it would only rebuild Dawn.
    -DCMAKE_OSX_DEPLOYMENT_TARGET=2.0
    -DCMAKE_SYSTEM_PROCESSOR=arm64
    -DDAWN_FETCH_DEPENDENCIES=ON
    -DDAWN_BUILD_MONOLITHIC_LIBRARY=STATIC
    -DBUILD_SHARED_LIBS=OFF
    -DDAWN_ENABLE_INSTALL=ON
    -DDAWN_BUILD_SAMPLES=OFF
    -DDAWN_BUILD_TESTS=OFF
    -DDAWN_BUILD_BENCHMARKS=OFF
    -DDAWN_BUILD_PROTOBUF=OFF
    -DDAWN_USE_GLFW=OFF
    -DDAWN_SUPPORTS_GLFW_FOR_WINDOWING=OFF
    -DDAWN_ENABLE_METAL=ON
    -DDAWN_ENABLE_VULKAN=OFF
    -DDAWN_ENABLE_NULL=ON
    -DDAWN_ENABLE_DESKTOP_GL=OFF
    -DDAWN_ENABLE_OPENGLES=OFF
    -DDAWN_ENABLE_D3D11=OFF
    -DDAWN_ENABLE_D3D12=OFF
    -DTINT_BUILD_TESTS=OFF
    -DTINT_BUILD_CMD_TOOLS=OFF
    -DTINT_BUILD_IR_BINARY=OFF
    -DTINT_BUILD_MSL_WRITER=ON
    -DTINT_BUILD_SPV_READER=OFF
    -DTINT_BUILD_SPV_WRITER=OFF
    -DTINT_BUILD_HLSL_WRITER=OFF
    -DTINT_BUILD_GLSL_WRITER=OFF
    -DTINT_BUILD_GLSL_VALIDATOR=OFF
)

# Stamp: revision + patch contents + flags. A matching stamp means the package is current.
stamp="$( { echo "${dawn_ref}"; printf '%s\n' "${flags[@]}"; for p in "${patches[@]}"; do shasum -a 256 "$p"; done; } | shasum -a 256 | cut -c1-16)"
package="${work}/dawn-${flavour}.tar.gz"
if [[ ${force} -eq 0 && -f "${package}" && "$(cat "${work}/dawn-${flavour}.stamp" 2>/dev/null)" == "${stamp}" ]]; then
    echo "Dawn package is current (${dawn_ref:0:12}, stamp ${stamp})" >&2
    echo "${package}"
    exit 0
fi

mkdir -p "${work}"
tarball="${work}/dawn-${dawn_ref}.tar.gz"
src="${work}/src-${dawn_ref:0:12}-${flavour}"
if [[ ! -f "${tarball}" ]]; then
    echo "Downloading encounter/dawn ${dawn_ref:0:12}" >&2
    curl -fL --retry 3 -o "${tarball}.part" "https://github.com/encounter/dawn/archive/${dawn_ref}.tar.gz"
    mv "${tarball}.part" "${tarball}"
fi
# Fresh source each time the stamp changes, so patches always apply to pristine files.
# Large trees on this external volume sometimes refuse an in-place rm -rf ("Directory
# not empty" while something else writes into them), so the old tree is moved aside
# first and removed best-effort.
discard() {
    [[ -e "$1" ]] || return 0
    local aside="${work}/.trash-$(basename "$1")-$$-${RANDOM}"
    mv "$1" "${aside}" && { rm -rf "${aside}" 2>/dev/null || true; }
}
discard "${src}"
mkdir -p "${src}"
tar -xzf "${tarball}" -C "${src}" --strip-components=1
for p in "${patches[@]}"; do
    echo "Applying $(basename "$p")" >&2
    patch -p1 --forward --fuzz=0 -d "${src}" < "$p" >&2
done

build="${work}/build-${flavour}"
install="${work}/install-${flavour}"
discard "${build}"
discard "${install}"
cmake -S "${src}" -B "${build}" -G Ninja "${flags[@]}" "-DCMAKE_INSTALL_PREFIX=${install}" >&2
cmake --build "${build}" --parallel "${jobs}" >&2
cmake --install "${build}" >&2

# aurora's provider looks for a dawn-install/ directory at the top of the package.
rm -rf "${work}/pkg-${flavour}"
mkdir -p "${work}/pkg-${flavour}"
cp -R "${install}" "${work}/pkg-${flavour}/dawn-install"
tar -czf "${package}.part" -C "${work}/pkg-${flavour}" dawn-install
mv "${package}.part" "${package}"
echo "${stamp}" > "${work}/dawn-${flavour}.stamp"
echo "${package}"
