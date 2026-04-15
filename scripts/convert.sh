#!/usr/bin/env bash
# Generate per-tool integration files from integrations/source/AGENCY.md
# Usage:
#   ./scripts/convert.sh
#   ./scripts/convert.sh --parallel
#   ./scripts/convert.sh --parallel --jobs 8

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/agency-common.sh
source "$ROOT/scripts/lib/agency-common.sh"

SRC_FILE="$ROOT/integrations/source/AGENCY.md"
BUILD="$ROOT/integrations/build"
PARALLEL=false
JOBS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel) PARALLEL=true; shift ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    -h | --help)
      echo "Usage: $0 [--parallel] [--jobs N]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -z "${JOBS:-}" ]] && JOBS="$(agency_default_jobs)"

if ! agency_read_source "$SRC_FILE" >/dev/null; then
  exit 1
fi

write_cursor_mdc() {
  local out="$BUILD/cursor/rules/agency.mdc"
  mkdir -p "$(dirname "$out")"
  {
    echo "---"
    echo "description: Agency project rules (generated — edit integrations/source/AGENCY.md)"
    echo "globs:"
    echo "  - \"**/*\""
    echo "---"
    echo ""
    cat "$SRC_FILE"
  } >"$out"
  echo "  → $out"
}

copy_plain() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cp "$SRC_FILE" "$dest"
  echo "  → $dest"
}

run_convert_job() {
  case "$1" in
    claude) copy_plain "$BUILD/claude/CLAUDE.md" ;;
    copilot) copy_plain "$BUILD/copilot/copilot-instructions.md" ;;
    antigravity) copy_plain "$BUILD/antigravity/instructions.md" ;;
    gemini) copy_plain "$BUILD/gemini/AGENTS.md" ;;
    opencode) copy_plain "$BUILD/opencode/AGENTS.md" ;;
    openclaw) copy_plain "$BUILD/openclaw/instructions.md" ;;
    cursor) write_cursor_mdc ;;
    aider) copy_plain "$BUILD/aider/CONVENTIONS.md" ;;
    windsurf)
      mkdir -p "$BUILD/windsurf"
      cp "$SRC_FILE" "$BUILD/windsurf/windsurfrules"
      echo "  → $BUILD/windsurf/windsurfrules"
      ;;
    qwen) copy_plain "$BUILD/qwen/project.md" ;;
    kimi) copy_plain "$BUILD/kimi/project.md" ;;
    *)
      echo "Unknown tool id: $1" >&2
      return 1
      ;;
  esac
}

TOOL_ORDER=(claude copilot antigravity gemini opencode openclaw cursor aider windsurf qwen kimi)

echo "Agency convert — source: $SRC_FILE"
echo "Build dir: $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD"

_convert_one() {
  run_convert_job "$1"
}

if [[ "$PARALLEL" == true ]]; then
  echo "Parallel mode (jobs=$JOBS, output order may vary)"
  for id in "${TOOL_ORDER[@]}"; do
    agency_wait_slot "$JOBS"
    ( _convert_one "$id" ) &
  done
  wait
else
  for id in "${TOOL_ORDER[@]}"; do
    _convert_one "$id"
  done
fi

echo "Convert finished."
