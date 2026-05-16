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

# Produces libMoltenVK.a at OUT_LIB (GN action output path).
# Args: MOLTENVK_ROOT OUT_LIB REBUILD_STAMP BUILD_ENABLED MANUAL_PREBUILT_PATH
#       TARGET_TYPE TARGET_CPU
# TARGET_TYPE: "device" (default) | "simulator"
# TARGET_CPU: "arm64" | "x64" (from GN current_cpu; used to lipo simulator fat lib)
# REBUILD_STAMP: use "-" when empty (never pass "" — shell drops empty argv).
# Paths from GN/rebase_path are often relative to ninja cwd — we normalize to absolute
# before any cd so cp/mkdir always target the correct files.
set -e

# This script lives in MoltenVK repo root; use as canonical root (avoids ../../... breakage).
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
MOLTENVK_ROOT="${_SCRIPT_DIR}"
OUT_LIB="$2"
REBUILD_STAMP="$3"
BUILD_ENABLED="$4"
MANUAL_PREBUILT="$5"
TARGET_TYPE="${6:-device}"
TARGET_CPU="${7:-arm64}"
if [[ "$REBUILD_STAMP" == "-" ]]; then
  REBUILD_STAMP=""
fi

# Output to terminal (stderr + /dev/tty) and append to root_build_dir/build.log.
TTY_AVAILABLE=
[[ -w /dev/tty ]] && TTY_AVAILABLE=1
log() {
  local msg="[MoltenVK-$TARGET_TYPE] $*"
  echo "$msg" >&2
  [[ -n "$TTY_AVAILABLE" ]] && echo "$msg" >/dev/tty 2>/dev/null || true
  [[ -n "$BUILD_LOG" && -w "$BUILD_LOG" ]] 2>/dev/null && echo "$msg" >>"$BUILD_LOG"
}

# Optional first arg: only use if absolute and exists as MoltenVK root
if [[ -n "$1" && "$1" == /* && -f "$1/Makefile" ]]; then
  MOLTENVK_ROOT="$1"
fi

# Ninja cwd is usually out/... — relative OUT_LIB must become absolute before cd
_abs() {
  local p="$1"
  [[ -z "$p" ]] && return
  if [[ "$p" != /* ]]; then
    p="$(pwd)/${p#./}"
  fi
  # Normalize . and ..
  local d
  d="$(dirname "$p")"
  p="$(cd "$d" 2>/dev/null && pwd)/$(basename "$p")"
  echo "$p"
}
OUT_LIB="$(_abs "$OUT_LIB")"
MANUAL_PREBUILT="$(_abs "$MANUAL_PREBUILT")"

# Build log location
BUILD_LOG="$(pwd)/build.log"

# Global lock: GN pool is per-toolchain; multiple ios_clang_* jobs share one
# MoltenVK tree and xcodebuild DerivedData under External/build/.
MOLTENVK_GLOBAL_LOCK_DIR="${_SCRIPT_DIR}/.moltenvk_global_build.lock"
MOLTENVK_LOCK_MAX_WAIT_SEC=7200
MOLTENVK_LOCK_POLL_SEC=2

_acquire_moltenvk_global_lock() {
  local waited=0
  while true; do
    if mkdir "$MOLTENVK_GLOBAL_LOCK_DIR" 2>/dev/null; then
      echo $$ >"$MOLTENVK_GLOBAL_LOCK_DIR/pid"
      return 0
    fi
    local holder_pid
    holder_pid="$(cat "$MOLTENVK_GLOBAL_LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ -n "$holder_pid" ]] && kill -0 "$holder_pid" 2>/dev/null; then
      :
    else
      log "Removing stale MoltenVK global lock (pid=${holder_pid:-unknown})"
      rm -rf "$MOLTENVK_GLOBAL_LOCK_DIR"
      continue
    fi
    if (( waited == 0 || waited % 30 == 0 )); then
      log "Waiting for global MoltenVK build lock (holder pid=$holder_pid)..."
    fi
    sleep "$MOLTENVK_LOCK_POLL_SEC"
    waited=$((waited + MOLTENVK_LOCK_POLL_SEC))
    if (( waited >= MOLTENVK_LOCK_MAX_WAIT_SEC )); then
      log "Timeout (${MOLTENVK_LOCK_MAX_WAIT_SEC}s) waiting for global MoltenVK build lock"
      exit 1
    fi
  done
}

_release_moltenvk_global_lock() {
  rm -f "$MOLTENVK_GLOBAL_LOCK_DIR/pid"
  rmdir "$MOLTENVK_GLOBAL_LOCK_DIR" 2>/dev/null || true
}

# Simulator xcframework slice is fat (arm64 + x86_64); each toolchain needs one arch.
_copy_moltenvk_out_lib() {
  local src="$1"
  local lipo_arch="$2"
  if [[ -z "$lipo_arch" ]]; then
    cp -f "$src" "$OUT_LIB"
    return
  fi
  if ! lipo -info "$src" 2>/dev/null | grep -q "$lipo_arch"; then
    log "Architecture $lipo_arch not in $src: $(lipo -info "$src" 2>&1)"
    exit 1
  fi
  lipo -thin "$lipo_arch" "$src" -output "$OUT_LIB"
}

mkdir -p "$(dirname "$OUT_LIB")"

# If build is not enabled, just use prebuilt
if [[ "$BUILD_ENABLED" != "1" && -z "$REBUILD_STAMP" ]]; then
  if [[ -f "$MANUAL_PREBUILT" ]]; then
    cp -f "$MANUAL_PREBUILT" "$OUT_LIB"
    log "Using manual prebuilt $MANUAL_PREBUILT -> $OUT_LIB"
    exit 0
  fi
  log "No prebuilt available at $MANUAL_PREBUILT"
  exit 1
fi

# Shared MoltenVK build (serialized across all iOS toolchains via global lock).
cd "$MOLTENVK_ROOT"
if [[ ! -f "Makefile" || ! -d "MoltenVKPackaging.xcodeproj" ]]; then
  log "MoltenVK root invalid: $MOLTENVK_ROOT"
  exit 1
fi

DEVICE_LIB="Package/Release/MoltenVK/static/MoltenVK.xcframework/ios-arm64/libMoltenVK.a"
SIMULATOR_LIB="Package/Release/MoltenVK/static/MoltenVK.xcframework/ios-arm64_x86_64-simulator/libMoltenVK.a"

_acquire_moltenvk_global_lock
trap '_release_moltenvk_global_lock' EXIT

# Re-check under lock (another toolchain may have finished while we waited).
if [[ -f "$DEVICE_LIB" && -f "$SIMULATOR_LIB" ]]; then
  log "Both libraries already exist, skipping build"
else
  log "Cleaning previous build..."
  rm -rf Package/ External/build/

  log "Running ./build_external_deps_only.sh --ios --iossim..."
  ./build_external_deps_only.sh --ios --iossim

  log "Building device (ios)..."
  make ios
  log "Building simulator (iossim)..."
  make iossim
fi

_release_moltenvk_global_lock
trap - EXIT

# Verify the libraries exist
if [[ ! -f "$DEVICE_LIB" ]]; then
  log "Device library not found: $DEVICE_LIB"
  exit 1
fi
if [[ ! -f "$SIMULATOR_LIB" ]]; then
  log "Simulator library not found: $SIMULATOR_LIB"
  exit 1
fi

# Copy the correct library for the target (thin simulator fat lib per TARGET_CPU).
if [[ "$TARGET_TYPE" == "simulator" ]]; then
  _lipo_arch="arm64"
  if [[ "$TARGET_CPU" == "x64" ]]; then
    _lipo_arch="x86_64"
  fi
  log "Using simulator library ($TARGET_CPU -> lipo -thin $_lipo_arch): $SIMULATOR_LIB"
  _copy_moltenvk_out_lib "$SIMULATOR_LIB" "$_lipo_arch"
else
  log "Using device library: $DEVICE_LIB"
  _copy_moltenvk_out_lib "$DEVICE_LIB" ""
fi

log "Copied to $OUT_LIB"

log "Successfully built MoltenVK"
