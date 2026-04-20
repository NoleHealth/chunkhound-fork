#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration (hardcoded for now) ---
envelope_folder="./_ceremony_executions/OBR/20-REPO-ANALYSIS-01/_envelope"
steps_folder="${envelope_folder}/steps"

# Delay between steps (seconds). Helps throttle when running across multiple repos.
STEP_DELAY_SECONDS=30

# --- Optional param: run a single step ---
single_step="${1:-}"

# --- Bell helper ---
ring_bell() { printf '\a'; }

# =============================================================================
# PRE-CHECK: Git state validation
# =============================================================================
pre_check_git_state() {
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)

  if [[ "${current_branch}" == "main" || "${current_branch}" == "master" ]]; then
    echo "🚫 ERROR: Cannot run ceremony on '${current_branch}' branch." >&2
    echo "  Ceremony steps commit and push results. Create a feature branch first." >&2
    echo "  Example: git checkout -b OBR-20-REPO-ANALYSIS-01" >&2
    ring_bell
    exit 1
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "🚫 ERROR: Working tree is not clean." >&2
    echo "  Ceremony steps commit results after each step. Uncommitted changes" >&2
    echo "  would be included in those commits unintentionally." >&2
    echo "" >&2
    echo "  Please commit or stash your changes before running the ceremony." >&2
    echo "  git status:" >&2
    git status --short >&2
    ring_bell
    exit 1
  fi

  if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    echo "🚫 ERROR: Untracked files found in working tree." >&2
    echo "  Ceremony steps commit results after each step. Untracked files" >&2
    echo "  could be included in those commits unintentionally." >&2
    echo "" >&2
    echo "  Please commit, stash, or .gitignore these files:" >&2
    git ls-files --others --exclude-standard >&2
    ring_bell
    exit 1
  fi

  echo "✅ Pre-check passed: clean working tree on branch '${current_branch}'"
}

# =============================================================================
# VALIDATION: Step folder naming integrity
# =============================================================================
validate_step_folders() {
  local has_invalid=false

  for dir in "${steps_folder}"/*/; do
    local dirname
    dirname=$(basename "${dir}")
    # Must start with NN- (one or two digit prefix followed by dash)
    if [[ ! "${dirname}" =~ ^[0-9]{2}- ]]; then
      echo "🚫 ERROR: Step folder '${dirname}' does not start with a two-digit prefix (e.g., 01-, 02-)." >&2
      echo "  All step folders must be numbered to ensure deterministic execution order." >&2
      has_invalid=true
    fi
  done

  if [[ "${has_invalid}" == "true" ]]; then
    ring_bell
    exit 1
  fi

  echo "✅ Step folder validation passed."
}

# =============================================================================
# POST: Create draft PR
# =============================================================================
post_create_draft_pr() {
  echo ""
  echo "============================================================================="
  echo "📋 POST: Creating draft PR..."
  echo "============================================================================="

  local pr_standards_file="./.dwt/git-ops/pr-standards.xml"
  local commit_standards_file="./.dwt/git-ops/commit-standards.xml"
  local pr_template_file="./.dwt/git-ops/pull_request_template.md"
  local current_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD)

  echo "ℹ️  Branch: ${current_branch}"
  echo "ℹ️  Loading PR standards and commit history..."

  # Build context for PR generation
  local commit_log
  commit_log=$(git log --oneline main..HEAD)

  local diff_stat
  diff_stat=$(git diff --stat main..HEAD)

  echo "ℹ️  Commits since main: $(echo "${commit_log}" | wc -l)"
  echo "ℹ️  Launching Claude session for PR creation..."

  cat <<PROMPT | claude \
    -p "Create a draft PR for branch '${current_branch}' targeting main. Follow the PR standards and template provided. Use the commit log and diff stat as source material. Create the PR using 'gh pr create --draft'." \
    --model sonnet \
    --effort medium \
    --dangerously-skip-permissions \
    --append-system-prompt-file "${pr_standards_file}" \
    --output-format json
## Commit Standards
$(cat "${commit_standards_file}")

## PR Template
$(cat "${pr_template_file}")

## Commit Log (main..HEAD)
${commit_log}

## Diff Stat (main..HEAD)
${diff_stat}
PROMPT

  echo "✅ Draft PR creation complete."
}

# =============================================================================
# MAIN
# =============================================================================

echo ""
echo "============================================================================="
echo "🚀 Ceremony Step Loop — Starting"
echo "   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "============================================================================="
ring_bell

# --- Pre-check ---
echo ""
echo "ℹ️  Running pre-checks..."
pre_check_git_state

# --- Resolve step list ---
if [[ -n "${single_step}" ]]; then
  # Single step mode
  step_dir="${steps_folder}/${single_step}"
  if [[ ! -d "${step_dir}" ]]; then
    echo "🚫 ERROR: Step folder not found: ${step_dir}" >&2
    echo "  Available steps:" >&2
    ls -1 "${steps_folder}" >&2
    ring_bell
    exit 1
  fi
  steps=("${single_step}")
  echo "ℹ️  Single-step mode: ${single_step}"
else
  # Loop mode — validate naming then collect sorted
  validate_step_folders

  steps=()
  for dir in "${steps_folder}"/*/; do
    steps+=("$(basename "${dir}")")
  done
  echo "ℹ️  Loop mode: ${#steps[@]} steps queued"
fi

# --- Per-execution data (one ID per loop invocation) ---
# Exported so every child `run-ceremony-step.sh` invocation inherits the same
# execution identity. A standalone step run generates its own fallback values.
export CEREMONY_EXECUTION_ID=$(uuidgen)
export CEREMONY_EXECUTION_FOLDER="${envelope_folder%/_envelope}"

echo ""
echo "============================================================================="
echo "🔄 Ceremony Step Loop"
echo "   Steps: ${#steps[@]}"
echo "   Envelope: ${envelope_folder}"
echo "   Execution ID: ${CEREMONY_EXECUTION_ID}"
echo "   Execution folder: ${CEREMONY_EXECUTION_FOLDER}"
echo "   Delay between steps: ${STEP_DELAY_SECONDS}s"
echo "============================================================================="

# --- Run steps ---
step_index=0
for step_name in "${steps[@]}"; do
  step_index=$((step_index + 1))

  # Throttle delay between steps (skip before the first step)
  if [[ ${step_index} -gt 1 ]]; then
    echo ""
    echo "⏳ Throttle delay: waiting ${STEP_DELAY_SECONDS}s before next step..."
    sleep "${STEP_DELAY_SECONDS}"
  fi

  echo ""
  echo "============================================================================="
  echo "▶️  [${step_index}/${#steps[@]}] Starting step: ${step_name}"
  echo "   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "============================================================================="
  ring_bell

  if ! "${SCRIPT_DIR}/run-ceremony-step.sh" "${step_name}"; then
    echo "" >&2
    echo "🚫❌ ERROR: Step '${step_name}' failed. Aborting loop." >&2
    echo "   Failed at step ${step_index} of ${#steps[@]}." >&2
    echo "   $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
    ring_bell; ring_bell; ring_bell
    exit 1
  fi

  echo ""
  echo "✅ [${step_index}/${#steps[@]}] Step complete: ${step_name}"
done

echo ""
echo "============================================================================="
echo "🎉 All ${#steps[@]} steps completed successfully!"
echo "   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "============================================================================="
ring_bell; ring_bell

# --- Post: Draft PR (full loop only) ---
if [[ -z "${single_step}" ]]; then
  post_create_draft_pr
  echo ""
  echo "============================================================================="
  echo "🏁 Ceremony complete — all steps finished and draft PR created."
  echo "   $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "============================================================================="
  ring_bell; ring_bell; ring_bell
else
  echo ""
  echo "ℹ️  Single-step mode — skipping draft PR creation."
fi