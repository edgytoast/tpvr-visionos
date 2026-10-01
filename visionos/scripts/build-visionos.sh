#!/usr/bin/env bash
# Builds TPVR for Apple Vision Pro: Dawn (cached), the game as
# DusklightGame.framework (CMake + Ninja), then the SwiftUI app around it
# (xcodegen + xcodebuild), and optionally installs it on a paired headset.
#
#   visionos/scripts/build-visionos.sh --team TEAMID [--bundle-id ID] [--debug]
#                                      [--install [--device UDID]] [--game-only]
#   visionos/scripts/build-visionos.sh --simulator [--debug] [--game-only]
#
# --simulator builds for the visionOS Simulator, unsigned (no team needed).
#
# The bundle ID defaults to dev.tpvr.vision.<TEAMID>: a bare ID may already be
# registered to another team, and then automatic signing falls back to a
# wildcard profile that lacks the memory entitlement.
#
# Needs Xcode with the visionOS SDK, CMake, Ninja, xcodegen, and Rust nightly
# with the aarch64-apple-visionos target (nod, the disc reader, is Rust).
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
team=""
bundle_id=""
config="RelWithDebInfo"
xcode_config="Release"
install=0
device=""
game_only=0
simulator=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --team) team="${2:?}"; shift 2 ;;
        --bundle-id) bundle_id="${2:?}"; shift 2 ;;
        --debug) config="Debug"; xcode_config="Debug"; shift ;;
        --install) install=1; shift ;;
        --device) device="${2:?}"; shift 2 ;;
        --game-only) game_only=1; shift ;;
        --simulator) simulator=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Homebrew's rustup is keg-only (it conflicts with the rust formula), so it is
# not on the default PATH.
[[ -d /opt/homebrew/opt/rustup/bin ]] && export PATH="/opt/homebrew/opt/rustup/bin:${PATH}"
for tool in cmake ninja xcodegen xcrun rustup; do
    command -v "${tool}" >/dev/null || { echo "ERROR: ${tool} not found" >&2; exit 1; }
done
if [[ ${simulator} -eq 1 ]]; then
    platform="SIMULATOR_VISIONOS"; rust_target="aarch64-apple-visionos-sim"; flavour="xrsimulator"
    dawn_flags=(--simulator)
else
    platform="VISIONOS"; rust_target="aarch64-apple-visionos"; flavour="visionos"
    dawn_flags=()
fi
rustup target list --toolchain nightly --installed 2>/dev/null | grep -qx "${rust_target}" || {
    echo "ERROR: Rust nightly with aarch64-apple-visionos is needed:" >&2
    echo "  brew install rustup && rustup toolchain install nightly --profile minimal &&" >&2
    echo "  rustup target add --toolchain nightly ${rust_target}" >&2
    exit 1
}

# 1. Dawn for xrOS (cached by revision, patches and flags).
dawn_package="$("${root}/visionos/scripts/build-dawn-visionos.sh" "${dawn_flags[@]+"${dawn_flags[@]}"}" | tail -1)"

# 2. The game framework.
build="${root}/.scratch/build-${flavour}-${config}"
# Host package prefixes CMake must not search: their libraries are macOS builds
# (a Miniconda fmt/zstd/nlohmann_json once got linked into the framework). The
# match is on the exact prefix, so list each one, Conda's own included.
ignore_prefixes="/opt/homebrew;/usr/local;/opt/homebrew/Caskroom/miniconda/base;${HOME}/miniconda3;${HOME}/miniforge3;${HOME}/anaconda3"
[[ -n "${CONDA_PREFIX:-}" ]] && ignore_prefixes="${ignore_prefixes};${CONDA_PREFIX}"
# nod's Rust build compiles C dependencies through the cc crate, which targets
# the SDK's own visionOS version unless told otherwise.
export XROS_DEPLOYMENT_TARGET=2.0
cmake -S "${root}" -B "${build}" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${root}/ios.toolchain.cmake" \
    -DPLATFORM="${platform}" \
    -DDEPLOYMENT_TARGET=2.0 \
    -DENABLE_BITCODE=OFF \
    -DENABLE_ARC=OFF \
    -DENABLE_VISIBILITY=ON \
    -DCMAKE_BUILD_TYPE="${config}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON \
    "-DCMAKE_IGNORE_PREFIX_PATH=${ignore_prefixes}" \
    -DRust_CARGO_TARGET="${rust_target}" \
    -DRust_TOOLCHAIN=nightly \
    -DAURORA_DAWN_PROVIDER=package \
    "-DAURORA_DAWN_PACKAGE_URL=file://${dawn_package}" \
    -DAURORA_SDL3_PROVIDER=vendor \
    -DAURORA_NOD_PROVIDER=vendor \
    -DDUSK_ENABLE_CODE_MODS=OFF \
    -DDUSK_VR=ON \
    -Ufmt_DIR -Unlohmann_json_DIR -Uzstd_DIR
cmake --build "${build}" --target dusklight --parallel "$(sysctl -n hw.ncpu)"
[[ -d "${build}/DusklightGame.framework" ]] || { echo "ERROR: ${build}/DusklightGame.framework was not produced" >&2; exit 1; }
echo "Game framework: ${build}/DusklightGame.framework"
[[ ${game_only} -eq 1 ]] && exit 0

# 3. The app.
# Where xcodebuild put the product. Xcode's own "Custom" build location
# preference (IDEBuildLocationStyle) overrides -derivedDataPath, so ask.
products_dir() {
    xcodebuild "$@" -showBuildSettings 2>/dev/null | awk -F' = ' '/^ *BUILT_PRODUCTS_DIR = / {print $2; exit}'
}
if [[ ${simulator} -eq 1 ]]; then
    app_dir="${root}/visionos/App"
    export TPVR_TEAM="${team:-NONE}" TPVR_BUNDLE_ID="${bundle_id:-dev.tpvr.vision.simulator}" TPVR_GAME_BUILD_DIR="${build}"
    (cd "${app_dir}" && xcodegen generate --quiet)
    derived="${root}/.scratch/DerivedData-simulator"
    sim_args=(-project "${app_dir}/TPVRVision.xcodeproj" -scheme TPVRVision -configuration "${xcode_config}"
              -destination 'generic/platform=visionOS Simulator' -derivedDataPath "${derived}"
              ARCHS=arm64 CODE_SIGNING_ALLOWED=NO)
    # clean: the app is a handful of Swift files, and Xcode's incremental build
    # (in a shared custom build location) has been seen to keep a stale embedded
    # framework and stale Swift objects.
    xcodebuild "${sim_args[@]}" clean build
    echo "App: $(products_dir "${sim_args[@]}")/TPVRVision.app"
    exit 0
fi
[[ -n "${team}" ]] || { echo "ERROR: --team TEAMID is needed to sign the app" >&2; exit 2; }
[[ -n "${bundle_id}" ]] || bundle_id="dev.tpvr.vision.${team}"
app_dir="${root}/visionos/App"
export TPVR_TEAM="${team}" TPVR_BUNDLE_ID="${bundle_id}" TPVR_GAME_BUILD_DIR="${build}"
(cd "${app_dir}" && xcodegen generate --quiet)
derived="${root}/.scratch/DerivedData"
device_args=(-project "${app_dir}/TPVRVision.xcodeproj" -scheme TPVRVision -configuration "${xcode_config}"
             -destination 'generic/platform=visionOS' -derivedDataPath "${derived}"
             DEVELOPMENT_TEAM="${team}" PRODUCT_BUNDLE_IDENTIFIER="${bundle_id}")
xcodebuild "${device_args[@]}" -allowProvisioningUpdates clean build
app="$(products_dir "${device_args[@]}")/TPVRVision.app"
echo "App: ${app}"

# 4. Install.
if [[ ${install} -eq 1 ]]; then
    if [[ -z "${device}" ]]; then
        devices_json="$(mktemp)"
        xcrun devicectl list devices --json-output "${devices_json}" >/dev/null 2>&1 || true
        device="$(python3 - "${devices_json}" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "visionOS" and hw.get("reality") == "physical":
        print(hw.get("udid", d.get("identifier", "")))
        break
PY
)"
        rm -f "${devices_json}"
    fi
    [[ -n "${device}" ]] || { echo "ERROR: no paired Apple Vision Pro found; pass --device UDID" >&2; exit 1; }
    xcrun devicectl device install app --device "${device}" "${app}"
fi
