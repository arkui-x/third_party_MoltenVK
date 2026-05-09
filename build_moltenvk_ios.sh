#!/usr/bin/env bash
# Produces libMoltenVK.a at OUT_LIB (GN action output path).
# Args: MOLTENVK_ROOT OUT_LIB REBUILD_STAMP BUILD_ENABLED MANUAL_PREBUILT_PATH
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

# Output to terminal (stderr + /dev/tty) and append to root_build_dir/build.log.
TTY_AVAILABLE=
[[ -w /dev/tty ]] && TTY_AVAILABLE=1
log() {
  local msg="[MoltenVK] $*"
  echo "$msg" >&2
  [[ -n "$TTY_AVAILABLE" ]] && echo "$msg" >/dev/tty
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

# build.log is under root_build_dir; ninja cwd is root_build_dir when action runs.
BUILD_LOG="$(pwd)/build.log"

mkdir -p "$(dirname "$OUT_LIB")"

# Force rebuild or auto build
if [[ "$BUILD_ENABLED" == "1" || -n "$REBUILD_STAMP" ]]; then
  cd "$MOLTENVK_ROOT"
  if [[ ! -f "Makefile" || ! -d "MoltenVKPackaging.xcodeproj" ]]; then
    log "MoltenVK root invalid: $MOLTENVK_ROOT"
    exit 1
  fi

  _tee_args=()
  [[ -n "$BUILD_LOG" ]] && _tee_args+=(-a "$BUILD_LOG")
  [[ -n "$TTY_AVAILABLE" ]] && _tee_args+=(/dev/tty)

  if [[ ! -f "./build_external_deps_only.sh" ]]; then
    log "build_external_deps_only.sh missing in $MOLTENVK_ROOT"
    exit 1
  fi
  chmod +x ./build_external_deps_only.sh 2>/dev/null || true
  log "Running ./build_external_deps_only.sh --ios --iossim ..."
  if [[ ${#_tee_args[@]} -gt 0 ]]; then
    ./build_external_deps_only.sh --ios --iossim 2>&1 | tee "${_tee_args[@]}"
  else
    ./build_external_deps_only.sh --ios --iossim
  fi

  log "Running make ios ..."
  if [[ ${#_tee_args[@]} -gt 0 ]]; then
    make ios 2>&1 | tee "${_tee_args[@]}"
  else
    make ios
  fi
  FOUND=$(find Package -name "libMoltenVK.a" -type f 2>/dev/null | head -1)
  if [[ -z "$FOUND" ]]; then
    log "libMoltenVK.a not found under Package/ after make ios"
    exit 1
  fi
  # FOUND may be relative — resolve so cp always works
  FOUND="$(cd "$(dirname "$FOUND")" && pwd)/$(basename "$FOUND")"
  cp -f "$FOUND" "$OUT_LIB"
  log "Copied $FOUND -> $OUT_LIB"
  exit 0
fi

# Manual prebuilt only
if [[ -f "$MANUAL_PREBUILT" ]]; then
  cp -f "$MANUAL_PREBUILT" "$OUT_LIB"
  log "Using manual prebuilt $MANUAL_PREBUILT -> $OUT_LIB"
  exit 0
fi

log "no libMoltenVK.a. Either:"
log "  1) Set moltenvk_ios_build_enabled=true, or"
log "  2) Place libMoltenVK.a at prebuilt/ios/ (path was: $MANUAL_PREBUILT)"
exit 1
