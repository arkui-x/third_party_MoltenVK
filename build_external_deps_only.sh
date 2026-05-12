#!/bin/bash
# Copyright (c) 2026 Huawei Device Co., Ltd.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build MoltenVK ExternalDependencies only (xcodebuild + xcframework packaging).
# Does not clone, fetch, or checkout any git repos under External/.
# Prerequisite: External/cereal, Vulkan-Headers, SPIRV-Cross, SPIRV-Tools, Vulkan-Tools, Volk
# already present at MoltenVK-expected layout (e.g. after a prior fetchDependencies or manual copy).
#
# Usage (same platform flags as fetchDependencies):
#   ./build_external_deps_only.sh --ios --iossim
#   ./build_external_deps_only.sh --all
#   ./build_external_deps_only.sh --macos
#
# Optional: --debug -v --parallel-build --no-parallel-build --keep-cache --asan --tsan --ubsan --none

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR"

EXT_DIR=External
if [[ ! -d "$EXT_DIR" ]]; then
	echo "Error: missing ${EXT_DIR}/ (MoltenVK root is ${SCRIPT_DIR})" >&2
	exit 1
fi
if [[ ! -d "${EXT_DIR}/SPIRV-Cross" || ! -d "${EXT_DIR}/SPIRV-Tools" ]]; then
	echo "Error: External/SPIRV-Cross or External/SPIRV-Tools missing; populate External/ first." >&2
	exit 1
fi
if [[ ! -d ExternalDependencies.xcodeproj ]]; then
	echo "Error: ExternalDependencies.xcodeproj not found in ${SCRIPT_DIR}" >&2
	exit 1
fi

BLD_NONE=""
BLD_IOS=""
BLD_IOS_SIM=""
BLD_MAC_CAT=""
BLD_TVOS=""
BLD_TVOS_SIM=""
BLD_VISIONOS=""
BLD_VISIONOS_SIM=""
BLD_MACOS=""
BLD_SPECIFIED=""
XC_CONFIG="Release"
XC_BUILD_VERBOSITY="-quiet"
XC_USE_BCKGND=""
XC_USE_ASAN="NO"
XC_USE_TSAN="NO"
XC_USE_UBSAN="NO"
export KEEP_CACHE=""

while (($#)); do
	case "$1" in
	--ios)
		BLD_IOS="Y"
		shift
		;;
	--iossim)
		BLD_IOS_SIM="Y"
		shift
		;;
	--maccat)
		BLD_MAC_CAT="Y"
		shift
		;;
	--tvos)
		BLD_TVOS="Y"
		shift
		;;
	--tvossim)
		BLD_TVOS_SIM="Y"
		shift
		;;
	--visionos)
		BLD_VISIONOS="Y"
		shift
		;;
	--visionossim)
		BLD_VISIONOS_SIM="Y"
		shift
		;;
	--macos)
		BLD_MACOS="Y"
		shift
		;;
	--all)
		BLD_MACOS="Y"
		BLD_IOS="Y"
		BLD_IOS_SIM="Y"
		BLD_MAC_CAT="Y"
		BLD_TVOS="Y"
		BLD_TVOS_SIM="Y"
		BLD_VISIONOS="Y"
		BLD_VISIONOS_SIM="Y"
		shift
		;;
	--none)
		BLD_NONE="Y"
		shift
		;;
	--debug)
		XC_CONFIG="Debug"
		shift
		;;
	--asan)
		XC_USE_ASAN="YES"
		shift
		;;
	--tsan)
		XC_USE_TSAN="YES"
		shift
		;;
	--ubsan)
		XC_USE_UBSAN="YES"
		shift
		;;
	--parallel-build)
		XC_USE_BCKGND="Y"
		shift
		;;
	--no-parallel-build)
		XC_USE_BCKGND=""
		shift
		;;
	--keep-cache)
		KEEP_CACHE="Y"
		shift
		;;
	-v)
		XC_BUILD_VERBOSITY=""
		shift
		;;
	*)
		echo "Error: unsupported option: $1" >&2
		echo "See header in build_external_deps_only.sh for supported flags." >&2
		exit 1
		;;
	esac
done

echo
echo "========== Build-only: ExternalDependencies (no git updates) at $(date +"%r") =========="
echo

execute_xcodebuild_command() {
	if [[ -n "${XCPRETTY}" ]]; then
		set -o pipefail && xcodebuild "$@" | tee -a "dependenciesbuild.log" | ${XCPRETTY}
	else
		xcodebuild "$@"
	fi
}

build_impl() {
	local XC_OS=${1}
	local XC_PLTFM=${2}
	local XC_DEST
	if [[ -n "${3:-}" ]]; then
		XC_DEST=${3}
	else
		XC_DEST=${XC_PLTFM}
	fi

	local XC_SCHEME="${EXT_DEPS}-${XC_OS}"
	local XC_LCL_DD_PATH="${XC_DD_PATH}/Intermediates/${XC_PLTFM}"

	echo "Building external libraries for platform ${XC_PLTFM} and destination ${XC_DEST}"

	execute_xcodebuild_command \
		-project "${XC_PROJ}" \
		-scheme "${XC_SCHEME}" \
		-destination "generic/platform=${XC_DEST}" \
		-configuration "${XC_CONFIG}" \
		-enableAddressSanitizer "${XC_USE_ASAN}" \
		-enableThreadSanitizer "${XC_USE_TSAN}" \
		-enableUndefinedBehaviorSanitizer "${XC_USE_UBSAN}" \
		-derivedDataPath "${XC_LCL_DD_PATH}" \
		${XC_BUILD_VERBOSITY} \
		build

	echo "Completed building external libraries for ${XC_PLTFM}"
}

build() {
	BLD_SPECIFIED="Y"
	if [[ -n "$XC_USE_BCKGND" ]]; then
		build_impl "${1}" "${2}" "${3:-}" &
	else
		build_impl "${1}" "${2}" "${3:-}"
	fi
}

EXT_DEPS=ExternalDependencies
XC_PROJ="${EXT_DEPS}.xcodeproj"
XC_DD_PATH="${EXT_DIR}/build"
export SKIP_PACKAGING="Y"

XCPRETTY_PATH=$(command -v xcpretty 2>/dev/null || true)
XCPRETTY=""
if [[ -n "$XCPRETTY_PATH" ]]; then
	XCPRETTY="xcpretty -c"
fi
if [[ -n "$XC_USE_BCKGND" ]]; then
	XCPRETTY=""
fi

if [[ -n "$XC_USE_BCKGND" ]]; then
	trap "exit" INT TERM ERR
	trap "kill 0" EXIT
fi

if [[ -n "$BLD_MACOS" ]]; then
	build "macOS" "macOS"
fi
if [[ -n "$BLD_IOS" ]]; then
	build "iOS" "iOS"
fi
if [[ -n "$BLD_IOS_SIM" ]]; then
	build "iOS" "iOS Simulator"
fi
if [[ -n "$BLD_MAC_CAT" ]]; then
	build "iOS" "Mac Catalyst" "macOS,variant=Mac Catalyst"
fi
if [[ -n "$BLD_TVOS" ]]; then
	build "tvOS" "tvOS"
fi
if [[ -n "$BLD_TVOS_SIM" ]]; then
	build "tvOS" "tvOS Simulator"
fi
if [[ -n "$BLD_VISIONOS" ]]; then
	build "xrOS" "xrOS"
fi
if [[ -n "$BLD_VISIONOS_SIM" ]]; then
	build "xrOS" "xrOS Simulator"
fi

if [[ -n "$XC_USE_BCKGND" ]]; then
	wait
fi

if [[ -n "$BLD_SPECIFIED" ]]; then
	PROJECT_DIR="."
	CONFIGURATION=${XC_CONFIG}
	SKIP_PACKAGING=""
	. "./Scripts/create_ext_lib_xcframeworks.sh"
	. "./Scripts/package_ext_libs_finish.sh"
else
	if [[ -n "$BLD_NONE" ]]; then
		echo "Not building any platforms (--none)."
	else
		echo "WARNING: no platform flags. Pass e.g. --ios --iossim or --all." >&2
		echo "    --macos --ios --iossim --maccat --tvos --tvossim --visionos --visionossim --all" >&2
		exit 1
	fi
fi

echo "========== Finished at $(date +"%r") =========="
