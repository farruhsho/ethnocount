#!/usr/bin/env bash
# Shared helpers for scripts/convert.sh and scripts/install.sh
# shellcheck shell=bash

agency_default_jobs() {
  local n=4
  if command -v nproc >/dev/null 2>&1; then
    n="$(nproc 2>/dev/null || echo 4)"
  elif [[ "$(uname -s 2>/dev/null)" == "Darwin" ]]; then
    n="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
  fi
  [[ "$n" =~ ^[0-9]+$ ]] || n=4
  [[ "$n" -lt 1 ]] && n=1
  echo "$n"
}

# Run commands in parallel with at most $max concurrent children.
# Usage: agency_run_parallel MAX command args...   (one batch)
# Or:  max=N; while read; do agency_wait_slot $max; cmd & done; wait
agency_wait_slot() {
  local max="$1"
  local n
  while true; do
    n="$(jobs -p 2>/dev/null | wc -l | tr -d '[:space:]')"
    [[ "${n:-0}" -lt "$max" ]] && break
    sleep 0.05
  done
}

agency_read_source() {
  local src="$1"
  if [[ ! -f "$src" ]]; then
    echo "Agency: missing source file: $src" >&2
    return 1
  fi
  cat "$src"
}
