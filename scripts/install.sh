#!/usr/bin/env bash
# The Agency — tool installer: copies integrations/build/* to each assistant.
#
# Usage:
#   ./scripts/install.sh
#   ./scripts/install.sh --no-interactive --parallel
#   ./scripts/install.sh --no-interactive --tool all
#   ./scripts/install.sh --tool cursor
#   ./scripts/install.sh --workspace          # Flutter + Firebase functions deps only
#
# Run ./scripts/convert.sh first to generate integrations/build/.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/agency-common.sh
source "$ROOT/scripts/lib/agency-common.sh"

BUILD="$ROOT/integrations/build"
REPO_SLUG="$(basename "$ROOT")"
PARALLEL=false
JOBS=""
INTERACTIVE=""
TOOL_SPEC="" # all | <id> | empty
WORKSPACE_DEPS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel) PARALLEL=true; shift ;;
    --no-interactive) INTERACTIVE=false; shift ;;
    --interactive) INTERACTIVE=true; shift ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --tool)
      TOOL_SPEC="$(echo "$2" | tr '[:upper:]' '[:lower:]')"
      shift 2
      ;;
    --workspace)
      WORKSPACE_DEPS=true
      shift
      ;;
    -h | --help)
      sed -n '1,20p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

[[ -z "${JOBS:-}" ]] && JOBS="$(agency_default_jobs)"

if [[ -z "${INTERACTIVE:-}" ]]; then
  if [[ -t 0 ]] && [[ -t 1 ]]; then
    INTERACTIVE=true
  else
    INTERACTIVE=false
  fi
fi

# ─── Tool registry (order matches UI 1–11) ───

IDS=(claude copilot antigravity gemini opencode openclaw cursor aider windsurf qwen kimi)

LABELS=(
  "Claude Code     (claude.ai/code)"
  "Copilot         (~/.github + ~/.copilot)"
  "Antigravity     (~/.gemini/antigravity)"
  "Gemini CLI      (gemini extension)"
  "OpenCode        (opencode.ai)"
  "OpenClaw        (~/.openclaw)"
  "Cursor          (.cursor/rules)"
  "Aider           (CONVENTIONS.md)"
  "Windsurf        (.windsurfrules)"
  "Qwen Code       (~/.qwen/agents)"
  "Kimi Code       (~/.config/kimi/agents)"
)

declare -a SELECTED

tool_detected() {
  case "$1" in
    claude)
      command -v claude >/dev/null 2>&1 || [[ -d "${HOME:-}/.claude" ]]
      ;;
    copilot)
      [[ -d "${HOME:-}/.github" ]] || [[ -d "${HOME:-}/.copilot" ]]
      ;;
    antigravity)
      [[ -d "${HOME:-}/.gemini/antigravity" ]]
      ;;
    gemini)
      command -v gemini >/dev/null 2>&1 || [[ -d "${HOME:-}/.gemini" ]]
      ;;
    opencode)
      command -v opencode >/dev/null 2>&1 || [[ -d "${HOME:-}/.opencode" ]]
      ;;
    openclaw)
      [[ -d "${HOME:-}/.openclaw" ]]
      ;;
    cursor)
      [[ -d "$ROOT/.cursor" ]] || command -v cursor >/dev/null 2>&1
      ;;
    aider)
      command -v aider >/dev/null 2>&1
      ;;
    windsurf)
      command -v windsurf >/dev/null 2>&1 || [[ -f "$ROOT/.windsurfrules" ]]
      ;;
    qwen)
      [[ -d "${HOME:-}/.qwen/agents" ]] || [[ -d "${HOME:-}/.qwen" ]]
      ;;
    kimi)
      [[ -d "${HOME:-}/.config/kimi/agents" ]]
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_build() {
  if [[ ! -f "$BUILD/cursor/rules/agency.mdc" ]]; then
    echo "Agency: integrations/build/ is missing or incomplete." >&2
    echo "Run:  ./scripts/convert.sh" >&2
    return 1
  fi
}

tool_install() {
  local id="$1"
  case "$id" in
    claude)
      [[ -f "$BUILD/claude/CLAUDE.md" ]] || return 1
      cp "$BUILD/claude/CLAUDE.md" "$ROOT/CLAUDE.md"
      echo "Installed claude → $ROOT/CLAUDE.md"
      ;;
    copilot)
      [[ -f "$BUILD/copilot/copilot-instructions.md" ]] || return 1
      mkdir -p "$ROOT/.github"
      cp "$BUILD/copilot/copilot-instructions.md" "$ROOT/.github/copilot-instructions.md"
      echo "Installed copilot → $ROOT/.github/copilot-instructions.md"
      if [[ -n "${HOME:-}" ]]; then
        mkdir -p "$HOME/.github" "$HOME/.copilot"
        cp "$BUILD/copilot/copilot-instructions.md" "$HOME/.github/copilot-instructions.md" || true
        cp "$BUILD/copilot/copilot-instructions.md" "$HOME/.copilot/copilot-instructions.md" || true
        echo "Installed copilot → ~/.github and ~/.copilot (where writable)"
      fi
      ;;
    antigravity)
      [[ -f "$BUILD/antigravity/instructions.md" ]] || return 1
      [[ -n "${HOME:-}" ]] || return 1
      mkdir -p "$HOME/.gemini/antigravity"
      cp "$BUILD/antigravity/instructions.md" "$HOME/.gemini/antigravity/instructions.md"
      echo "Installed antigravity → ~/.gemini/antigravity/instructions.md"
      ;;
    gemini)
      [[ -f "$BUILD/gemini/AGENTS.md" ]] || return 1
      [[ -n "${HOME:-}" ]] || return 1
      mkdir -p "$HOME/.gemini"
      cp "$BUILD/gemini/AGENTS.md" "$HOME/.gemini/agency-AGENTS.md"
      echo "Installed gemini → ~/.gemini/agency-AGENTS.md"
      ;;
    opencode)
      [[ -f "$BUILD/opencode/AGENTS.md" ]] || return 1
      cp "$BUILD/opencode/AGENTS.md" "$ROOT/AGENTS.md"
      echo "Installed opencode → $ROOT/AGENTS.md"
      if [[ -n "${HOME:-}" ]] && [[ -d "$HOME/.opencode" ]]; then
        cp "$BUILD/opencode/AGENTS.md" "$HOME/.opencode/AGENTS.md" || true
        echo "Also copied → ~/.opencode/AGENTS.md"
      fi
      ;;
    openclaw)
      [[ -f "$BUILD/openclaw/instructions.md" ]] || return 1
      [[ -n "${HOME:-}" ]] || return 1
      mkdir -p "$HOME/.openclaw"
      cp "$BUILD/openclaw/instructions.md" "$HOME/.openclaw/instructions.md"
      echo "Installed openclaw → ~/.openclaw/instructions.md"
      ;;
    cursor)
      [[ -f "$BUILD/cursor/rules/agency.mdc" ]] || return 1
      mkdir -p "$ROOT/.cursor/rules"
      cp "$BUILD/cursor/rules/agency.mdc" "$ROOT/.cursor/rules/agency.mdc"
      echo "Installed cursor → $ROOT/.cursor/rules/agency.mdc"
      ;;
    aider)
      [[ -f "$BUILD/aider/CONVENTIONS.md" ]] || return 1
      cp "$BUILD/aider/CONVENTIONS.md" "$ROOT/CONVENTIONS.md"
      echo "Installed aider → $ROOT/CONVENTIONS.md"
      ;;
    windsurf)
      [[ -f "$BUILD/windsurf/windsurfrules" ]] || return 1
      cp "$BUILD/windsurf/windsurfrules" "$ROOT/.windsurfrules"
      echo "Installed windsurf → $ROOT/.windsurfrules"
      ;;
    qwen)
      [[ -f "$BUILD/qwen/project.md" ]] || return 1
      [[ -n "${HOME:-}" ]] || return 1
      mkdir -p "$HOME/.qwen/agents"
      cp "$BUILD/qwen/project.md" "$HOME/.qwen/agents/${REPO_SLUG}.md"
      echo "Installed qwen → ~/.qwen/agents/${REPO_SLUG}.md"
      ;;
    kimi)
      [[ -f "$BUILD/kimi/project.md" ]] || return 1
      [[ -n "${HOME:-}" ]] || return 1
      mkdir -p "$HOME/.config/kimi/agents"
      cp "$BUILD/kimi/project.md" "$HOME/.config/kimi/agents/${REPO_SLUG}.md"
      echo "Installed kimi → ~/.config/kimi/agents/${REPO_SLUG}.md"
      ;;
    *)
      echo "Unknown tool: $id" >&2
      return 1
      ;;
  esac
}

install_workspace() {
  echo "Workspace deps: Flutter + functions/npm"
  if [[ "$PARALLEL" == true ]]; then
    (cd "$ROOT" && flutter pub get) &
    (cd "$ROOT/functions" && npm install) &
    wait
  else
    (cd "$ROOT" && flutter pub get)
    (cd "$ROOT/functions" && npm install)
  fi
  echo "Workspace install finished."
}

init_selected_from_detected() {
  local i
  for i in "${!IDS[@]}"; do
    if tool_detected "${IDS[i]}"; then
      SELECTED[i]=1
    else
      SELECTED[i]=0
    fi
  done
}

show_ui() {
  clear 2>/dev/null || true
  echo "+------------------------------------------------+"
  echo "|   The Agency -- Tool Installer                 |"
  echo "+------------------------------------------------+"
  echo ""
  echo "System scan: [*] = detected on this machine"
  echo ""
  local i
  for i in "${!IDS[@]}"; do
    local idx=$((i + 1))
    local chk="[ ]"
    [[ "${SELECTED[i]:-0}" == 1 ]] && chk="[x]"
    local det="[ ]"
    tool_detected "${IDS[i]}" && det="[*]"
    printf "  %s %2d)  %s  %s\n" "$chk" "$idx" "$det" "${LABELS[i]}"
  done
  echo ""
  echo "  [1-11] toggle   [a] all   [n] none   [d] detected"
  echo "  [Enter] install   [q] quit"
}

run_install_list() {
  local -a list=("$@")
  local id
  if [[ "$PARALLEL" == true ]]; then
    echo "Parallel install (jobs=$JOBS)"
    for id in "${list[@]}"; do
      [[ -z "$id" ]] && continue
      agency_wait_slot "$JOBS"
      (
        tool_install "$id" || echo "(failed: $id)" >&2
      ) &
    done
    wait
  else
    for id in "${list[@]}"; do
      [[ -z "$id" ]] && continue
      tool_install "$id" || echo "(failed: $id)" >&2
    done
  fi
}

interactive_loop() {
  init_selected_from_detected
  while true; do
    show_ui
    echo ""
    printf "Choice: "
    IFS= read -r key || return 0
    case "$key" in
      q | Q) echo "Quit."; return 0 ;;
      a | A)
        for i in "${!IDS[@]}"; do SELECTED[i]=1; done
        ;;
      n | N)
        for i in "${!IDS[@]}"; do SELECTED[i]=0; done
        ;;
      d | D) init_selected_from_detected ;;
      "")
        local -a to_run=()
        local i
        for i in "${!IDS[@]}"; do
          [[ "${SELECTED[i]:-0}" == 1 ]] && to_run+=("${IDS[i]}")
        done
        if [[ ${#to_run[@]} -eq 0 ]]; then
          echo "No tools selected."
          sleep 1
          continue
        fi
        ensure_build || return 1
        run_install_list "${to_run[@]}"
        return 0
        ;;
      *)
        if [[ "$key" =~ ^[0-9]+$ ]]; then
          local n="$key"
          if [[ "$n" -ge 1 && "$n" -le 11 ]]; then
            local ix=$((n - 1))
            if [[ "${SELECTED[ix]:-0}" == 1 ]]; then
              SELECTED[ix]=0
            else
              SELECTED[ix]=1
            fi
          fi
        fi
        ;;
    esac
  done
}

# ─── Main ───

if [[ "$WORKSPACE_DEPS" == true ]] && [[ "$TOOL_SPEC" == "" ]] && [[ "$INTERACTIVE" == false ]]; then
  install_workspace
  exit 0
fi

if [[ "$WORKSPACE_DEPS" == true ]] && [[ "$INTERACTIVE" == true ]] && [[ "$TOOL_SPEC" == "" ]]; then
  install_workspace
  exit 0
fi

if [[ -n "$TOOL_SPEC" ]]; then
  ensure_build || exit 1
  if [[ "$TOOL_SPEC" == "all" ]]; then
    run_install_list "${IDS[@]}"
  else
    local_ok=false
    for t in "${IDS[@]}"; do
      [[ "$t" == "$TOOL_SPEC" ]] && local_ok=true && break
    done
    if [[ "$local_ok" != true ]]; then
      echo "Unknown --tool value: $TOOL_SPEC (use: all, ${IDS[*]})" >&2
      exit 2
    fi
    run_install_list "$TOOL_SPEC"
  fi
  if [[ "$WORKSPACE_DEPS" == true ]]; then
    install_workspace
  fi
  exit 0
fi

if [[ "$INTERACTIVE" == true ]]; then
  interactive_loop
else
  ensure_build || exit 1
  if [[ "$PARALLEL" == false ]]; then
    : # sequential default for detected-only
  fi
  to_run=()
  for i in "${!IDS[@]}"; do
    tool_detected "${IDS[i]}" && to_run+=("${IDS[i]}")
  done
  if [[ ${#to_run[@]} -eq 0 ]]; then
    echo "Agency: no tools detected; use --tool all or --interactive"
    exit 0
  fi
  echo "Non-interactive: installing detected tools only: ${to_run[*]}"
  run_install_list "${to_run[@]}"
fi

if [[ "$WORKSPACE_DEPS" == true ]]; then
  install_workspace
fi

echo "Install finished."
