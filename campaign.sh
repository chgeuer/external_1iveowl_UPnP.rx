#!/usr/bin/env bash
#
# campaign.sh — drive a `br`-tracked, one-issue-per-run remediation campaign
# unattended. Repo-agnostic: it reads repo-specific settings from .campaign.conf
# in the repo root and defers the actual workflow + Definition of Done to that
# repo's prompt.md. Each iteration launches ONE headless Copilot CLI run that
# takes a single issue to Done, then the driver inspects `br` to decide whether
# to continue. It stops — and surfaces to you — only on cases that need a human:
# no ready work, a run that closed nothing (blocker/decision), a non-zero exit,
# or a dirty / already-claimed starting state.
#
# State lives in `br` (beads), so this is resumable: stop any time, re-run, and
# it picks up where it left off.
#
# ---- .campaign.conf (sourced bash; all optional) ----------------------------
#   CAMPAIGN_NAME="myproject"                # label for logs (default: repo dir name)
#   CAMPAIGN_PROJECTS=(.)                    # subdirs each with their own .beads/
#                                            #   (federated monorepos); default (.)
#   CAMPAIGN_LABELS=(audit-2026-06 ...)      # campaign labels, OR-unioned; epics skipped
#   CAMPAIGN_GUARDRAILS="..."                # repo-specific guardrails appended to the prompt
#
# ---- env knobs (override conf/defaults) -------------------------------------
#   MAX_ITERS (30)  RUN_TIMEOUT (1800s)  COPILOT_MODEL  COPILOT_EFFORT  CAMPAIGN_REPO
#
# Usage:  ./campaign.sh            # run until done / blocked / cap
#         ./campaign.sh --dry-run  # resolve config + show ready counts, launch nothing
#
set -uo pipefail

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

REPO="${CAMPAIGN_REPO:-$(git rev-parse --show-toplevel 2>/dev/null)}"

# ---- defaults (a repo's .campaign.conf may override the CAMPAIGN_* arrays) ---
CAMPAIGN_PROJECTS=(.)
CAMPAIGN_LABELS=(audit-2026-06)
CAMPAIGN_GUARDRAILS=""
CAMPAIGN_NAME=""

# ---- helpers ----------------------------------------------------------------
log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
rule() { printf '\033[2m%s\033[0m\n' "────────────────────────────────────────────────────────"; }
need() { command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"; }

# Unique, non-epic issue IDs that are ready / closed across all projects×labels.
ids_ready() {
  local proj label
  for proj in "${CAMPAIGN_PROJECTS[@]}"; do
    for label in "${CAMPAIGN_LABELS[@]}"; do
      ( cd "$REPO/$proj" 2>/dev/null && br ready -l "$label" --limit 0 --json 2>/dev/null ) \
        | jq -r '.[]? | select(.issue_type != "epic") | .id' 2>/dev/null
    done
  done | sort -u
}
ids_closed() {
  local proj label
  for proj in "${CAMPAIGN_PROJECTS[@]}"; do
    for label in "${CAMPAIGN_LABELS[@]}"; do
      ( cd "$REPO/$proj" 2>/dev/null && br list -l "$label" --status closed --limit 0 --json 2>/dev/null ) \
        | jq -r '.[]? | select(.issue_type != "epic") | .id' 2>/dev/null
    done
  done | sort -u
}
n_ready()  { ids_ready  | grep -c . ; }
n_closed() { ids_closed | grep -c . ; }
n_inprogress() {
  local proj total=0 n
  for proj in "${CAMPAIGN_PROJECTS[@]}"; do
    n="$( ( cd "$REPO/$proj" 2>/dev/null && br list --status in_progress --limit 0 --json 2>/dev/null ) | jq 'length' 2>/dev/null )"
    total=$(( total + ${n:-0} ))
  done
  echo "$total"
}

# Paths that do NOT signal a crashed/active issue run, so they must not halt the
# loop's dirty-tree guard:
#   - .beads/ is rewritten by br on every read;
#   - the campaign's own files are operator-tunable and are never touched by an
#     issue-fix run, so editing the prompt/driver/config mid-run is allowed.
# A genuinely crashed issue run still trips the guard via dirty lib/test/source
# files (and/or an in_progress claim, which is checked separately).
GUARD_EXCLUDES=(
  ':(exclude,glob)**/.beads/**'
  ':(exclude)prompt.md'
  ':(exclude)campaign.sh'
  ':(exclude).campaign.conf'
)

# True if any TRACKED file (outside GUARD_EXCLUDES) has staged/unstaged changes.
# (untracked tooling/logs are ignored — git diff does not see them.)
src_dirty() {
  ! git -C "$REPO" diff        --quiet -- . "${GUARD_EXCLUDES[@]}" 2>/dev/null && return 0
  ! git -C "$REPO" diff --cached --quiet -- . "${GUARD_EXCLUDES[@]}" 2>/dev/null && return 0
  return 1
}

surface() { # $1=headline  $2=optional log file
  rule
  printf '\033[33m⏸  HUMAN NEEDED: %s\033[0m\n' "$1"
  local proj ip
  for proj in "${CAMPAIGN_PROJECTS[@]}"; do
    ip="$( ( cd "$REPO/$proj" 2>/dev/null && br list --status in_progress --limit 0 --json 2>/dev/null ) \
      | jq -r --arg p "$proj" '.[]? | "   in_progress (\($p)): \(.id) — \(.title)"' 2>/dev/null )"
    [[ -n "$ip" ]] && printf '%s\n' "$ip"
  done
  if [[ -n "${2:-}" && -f "${2:-}" ]]; then
    printf '\033[2m   last lines of %s:\033[0m\n' "$2"
    tail -n 25 "$2" | sed 's/^/   │ /'
  fi
  rule
}

# ---- preflight + config -----------------------------------------------------
[[ -n "$REPO" ]] || die "not inside a git repository (set CAMPAIGN_REPO)"
cd "$REPO" || die "cannot cd to $REPO"
need br; need jq; need git; need copilot
[[ -f "$REPO/prompt.md" ]] || die "prompt.md not found in $REPO"

# shellcheck source=/dev/null
[[ -f "$REPO/.campaign.conf" ]] && source "$REPO/.campaign.conf"
[[ -n "$CAMPAIGN_NAME" ]] || CAMPAIGN_NAME="$(basename "$REPO")"

MAX_ITERS="${MAX_ITERS:-30}"
RUN_TIMEOUT="${RUN_TIMEOUT:-1800}"
LOG_DIR="$REPO/.campaign/logs"
mkdir -p "$LOG_DIR"
SESSION_ID="$(date +%Y%m%d-%H%M%S)"   # one id per loop invocation → logs group & sort, no run-N collisions

# Validate configured projects.
for proj in "${CAMPAIGN_PROJECTS[@]}"; do
  [[ -d "$REPO/$proj/.beads" ]] || log "⚠  project '$proj' has no .beads/ — it will contribute 0 issues"
done

DRIVER_PROMPT="You are one automated run of this repository's remediation campaign. Read prompt.md in the repository root and follow it EXACTLY. Pick ONE ready, non-epic issue per its ordering rules, claim it (br update <id> --claim), and take it to Done end-to-end: confirm the finding against the current code, implement the smallest correct fix, add a regression test that fails before and passes after, run that file's full Definition of Done, then commit and br close per its workflow. Then STOP — do not start a second issue. If no issue is ready, or the only correct next action needs a human decision, do NOT force a change: stop and explain what you found. Never weaken security or correctness just to make something pass.${CAMPAIGN_GUARDRAILS:+ ${CAMPAIGN_GUARDRAILS}}"

log "campaign:   $CAMPAIGN_NAME"
log "repo:       $REPO"
log "projects:   ${CAMPAIGN_PROJECTS[*]}"
log "labels:     ${CAMPAIGN_LABELS[*]}"
log "max iters:  $MAX_ITERS   run timeout: ${RUN_TIMEOUT}s"
[[ -n "${COPILOT_MODEL:-}"  ]] && log "model:      $COPILOT_MODEL"
[[ -n "${COPILOT_EFFORT:-}" ]] && log "effort:     $COPILOT_EFFORT"
rule

# ---- dry run: resolve + report, launch nothing ------------------------------
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[dry-run] ready (non-epic): $(n_ready)   closed: $(n_closed)   in_progress: $(n_inprogress)"
  for proj in "${CAMPAIGN_PROJECTS[@]}"; do
    for label in "${CAMPAIGN_LABELS[@]}"; do
      c="$( ( cd "$REPO/$proj" 2>/dev/null && br ready -l "$label" --limit 0 --json 2>/dev/null ) \
        | jq '[.[]? | select(.issue_type != "epic")] | length' 2>/dev/null )"
      log "[dry-run]   $proj / $label : ${c:-0} ready"
    done
  done
  src_dirty && log "[dry-run] tracked changes present → a real run would stop and ask you to clean/finish first."
  log "[dry-run] driver prompt: ${DRIVER_PROMPT:0:96}..."
  exit 0
fi

# ---- main loop --------------------------------------------------------------
attempted=0
for (( iter=1; iter<=MAX_ITERS; iter++ )); do
  if src_dirty; then
    surface "tracked changes are present before iteration $iter — a previous run crashed or another run is active. Commit/finish or revert it, then re-run."
    git -C "$REPO" status --short -- . "${GUARD_EXCLUDES[@]}" | sed 's/^/   /'
    exit 2
  fi
  if [[ "$(n_inprogress)" -gt 0 ]]; then
    surface "an issue is already claimed (in_progress) before iteration $iter — finish or release it first."
    exit 2
  fi

  ready="$(n_ready)"
  if [[ "$ready" -eq 0 ]]; then
    rule
    printf '\033[32m✓ No ready, non-epic work for [%s]. Campaign complete (or all remaining work is blocked).\033[0m\n' "$CAMPAIGN_NAME"
    exit 0
  fi

  before_closed="$(n_closed)"
  # Pin the copilot session UUID ourselves (rather than scrape it — `-s` hides it)
  # so the log carries it (filename + header) and a killed/timed-out/blocked run is
  # directly resumable: `copilot --resume=<id>`. Falls back gracefully if no uuid
  # source exists (then copilot self-generates and we just don't know the id).
  csid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
  logf="$LOG_DIR/run-${SESSION_ID}-$(printf '%02d' "$iter")${csid:+-$csid}.log"
  log "iteration $iter/$MAX_ITERS — $ready ready, $before_closed closed so far → $logf"
  [[ -n "$csid" ]] && log "  copilot session: $csid   (resume with: copilot --resume=$csid)"

  cargs=( -C "$REPO" -p "$DRIVER_PROMPT" --allow-all-tools --no-ask-user
          --no-auto-update --no-color --log-level error -s )
  [[ -n "$csid" ]] && cargs+=( --session-id "$csid" )
  [[ -n "${COPILOT_MODEL:-}"  ]] && cargs+=( --model "$COPILOT_MODEL" )
  [[ -n "${COPILOT_EFFORT:-}" ]] && cargs+=( --effort "$COPILOT_EFFORT" )

  attempted=$(( attempted + 1 ))
  # Header first (truncates/creates the file), then append the teed run output.
  { printf '# campaign %s  iter=%s/%s  session=%s  started=%s\n' \
      "$CAMPAIGN_NAME" "$iter" "$MAX_ITERS" "${csid:-<auto>}" "$(date -Is)"
    printf '# resume: copilot --resume=%s\n\n' "${csid:-<id>}"
  } > "$logf"
  timeout "$RUN_TIMEOUT" copilot "${cargs[@]}" 2>&1 | tee -a "$logf"
  rc="${PIPESTATUS[0]}"

  if [[ "$rc" -eq 124 ]]; then
    surface "run $iter exceeded ${RUN_TIMEOUT}s and was killed. Resume it: copilot --resume=${csid:-<id>}" "$logf"; exit 3
  elif [[ "$rc" -ne 0 ]]; then
    surface "copilot exited with code $rc on iteration $iter. Resume it: copilot --resume=${csid:-<id>}" "$logf"; exit 3
  fi

  after_closed="$(n_closed)"
  if [[ "$after_closed" -le "$before_closed" ]]; then
    surface "run $iter closed no issue (closed $before_closed → $after_closed) — likely a blocker or a decision that needs you. Inspect/continue: copilot --resume=${csid:-<id>}" "$logf"
    exit 4
  fi

  log "iteration $iter done — closed $before_closed → $after_closed. Continuing."
  rule
done

rule
printf '\033[32m✓ Reached MAX_ITERS=%s (attempted %s runs). Re-run ./campaign.sh to continue.\033[0m\n' "$MAX_ITERS" "$attempted"
