#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Orchestrates a full ceremony run across all steps (or a single step), with git
  safety checks and draft PR creation on full loops.
.PARAMETER SingleStep
  Optional — run only this step (pre/post checks still apply, draft PR is skipped).
.EXAMPLE
  ./run-ceremony-step-loop.ps1
  ./run-ceremony-step-loop.ps1 03-work-docs-analysis
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$SingleStep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptDir = $PSScriptRoot

# --- Configuration (hardcoded for now) ---
$envelope_folder = "./_ceremony_executions/OBR/20-REPO-ANALYSIS-01/_envelope"
$steps_folder = "$envelope_folder/steps"

# Delay between steps (seconds). Helps throttle when running across multiple repos.
$StepDelaySeconds = 30

# --- Bell helper ---
function Ring-Bell { [Console]::Write("`a") }

# =============================================================================
# PRE-CHECK: Git state validation
# =============================================================================
function Invoke-PreCheckGitState {
    $current_branch = (git rev-parse --abbrev-ref HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-parse failed" }

    if ($current_branch -in @('main', 'master')) {
        Write-Error @"
🚫 ERROR: Cannot run ceremony on '$current_branch' branch.
  Ceremony steps commit and push results. Create a feature branch first.
  Example: git checkout -b OBR-20-REPO-ANALYSIS-01
"@
        Ring-Bell
        exit 1
    }

    git diff --quiet
    $diffDirty = $LASTEXITCODE -ne 0
    git diff --cached --quiet
    $cachedDirty = $LASTEXITCODE -ne 0

    if ($diffDirty -or $cachedDirty) {
        Write-Host "🚫 ERROR: Working tree is not clean." -ForegroundColor Red
        Write-Host "  Ceremony steps commit results after each step. Uncommitted changes" -ForegroundColor Red
        Write-Host "  would be included in those commits unintentionally." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Please commit or stash your changes before running the ceremony." -ForegroundColor Red
        Write-Host "  git status:" -ForegroundColor Red
        git status --short
        Ring-Bell
        exit 1
    }

    $untracked = git ls-files --others --exclude-standard
    if ($untracked) {
        Write-Host "🚫 ERROR: Untracked files found in working tree." -ForegroundColor Red
        Write-Host "  Ceremony steps commit results after each step. Untracked files" -ForegroundColor Red
        Write-Host "  could be included in those commits unintentionally." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Please commit, stash, or .gitignore these files:" -ForegroundColor Red
        $untracked | ForEach-Object { Write-Host $_ }
        Ring-Bell
        exit 1
    }

    Write-Host "✅ Pre-check passed: clean working tree on branch '$current_branch'"
}

# =============================================================================
# VALIDATION: Step folder naming integrity
# =============================================================================
function Test-StepFolders {
    $has_invalid = $false

    $dirs = Get-ChildItem -LiteralPath $steps_folder -Directory
    foreach ($dir in $dirs) {
        # Must start with NN- (two digit prefix followed by dash)
        if ($dir.Name -notmatch '^\d{2}-') {
            Write-Host "🚫 ERROR: Step folder '$($dir.Name)' does not start with a two-digit prefix (e.g., 01-, 02-)." -ForegroundColor Red
            Write-Host "  All step folders must be numbered to ensure deterministic execution order." -ForegroundColor Red
            $has_invalid = $true
        }
    }

    if ($has_invalid) {
        Ring-Bell
        exit 1
    }

    Write-Host "✅ Step folder validation passed."
}

# =============================================================================
# POST: Create draft PR
# =============================================================================
function Invoke-PostCreateDraftPR {
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "📋 POST: Creating draft PR..."
    Write-Host "============================================================================="

    $pr_standards_file = "./.dwt/git-ops/pr-standards.xml"
    $commit_standards_file = "./.dwt/git-ops/commit-standards.xml"
    $pr_template_file = "./.dwt/git-ops/pull_request_template.md"
    $current_branch = (git rev-parse --abbrev-ref HEAD).Trim()

    Write-Host "ℹ️  Branch: $current_branch"
    Write-Host "ℹ️  Loading PR standards and commit history..."

    # Build context for PR generation
    $commit_log = (git log --oneline main..HEAD) -join "`n"
    $diff_stat = (git diff --stat main..HEAD) -join "`n"

    $commit_count = if ([string]::IsNullOrWhiteSpace($commit_log)) { 0 } else { ($commit_log -split "`n").Count }
    Write-Host "ℹ️  Commits since main: $commit_count"
    Write-Host "ℹ️  Launching Claude session for PR creation..."

    $commit_standards = Get-Content -Raw -LiteralPath $commit_standards_file
    $pr_template = Get-Content -Raw -LiteralPath $pr_template_file

    $prompt = @"
## Commit Standards
$commit_standards

## PR Template
$pr_template

## Commit Log (main..HEAD)
$commit_log

## Diff Stat (main..HEAD)
$diff_stat
"@

    $claudeArgs = @(
        '-p', "Create a draft PR for branch '$current_branch' targeting main. Follow the PR standards and template provided. Use the commit log and diff stat as source material. Create the PR using 'gh pr create --draft'.",
        '--model', 'sonnet',
        '--effort', 'medium',
        '--dangerously-skip-permissions',
        '--append-system-prompt-file', $pr_standards_file,
        '--output-format', 'json'
    )

    $prompt | & claude @claudeArgs
    if ($LASTEXITCODE -ne 0) { throw "claude PR creation failed (exit $LASTEXITCODE)" }

    Write-Host "✅ Draft PR creation complete."
}

# =============================================================================
# MAIN
# =============================================================================

Write-Host ""
Write-Host "============================================================================="
Write-Host "🚀 Ceremony Step Loop — Starting"
Write-Host "   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Write-Host "============================================================================="
Ring-Bell

# --- Pre-check ---
Write-Host ""
Write-Host "ℹ️  Running pre-checks..."
Invoke-PreCheckGitState

# --- Resolve step list ---
if (-not [string]::IsNullOrWhiteSpace($SingleStep)) {
    # Single step mode
    $step_dir = "$steps_folder/$SingleStep"
    if (-not (Test-Path -LiteralPath $step_dir -PathType Container)) {
        Write-Host "🚫 ERROR: Step folder not found: $step_dir" -ForegroundColor Red
        Write-Host "  Available steps:" -ForegroundColor Red
        Get-ChildItem -LiteralPath $steps_folder -Directory | ForEach-Object { Write-Host $_.Name }
        Ring-Bell
        exit 1
    }
    $steps = @($SingleStep)
    Write-Host "ℹ️  Single-step mode: $SingleStep"
}
else {
    # Loop mode — validate naming then collect sorted
    Test-StepFolders
    $steps = Get-ChildItem -LiteralPath $steps_folder -Directory | Sort-Object Name | ForEach-Object { $_.Name }
    Write-Host "ℹ️  Loop mode: $($steps.Count) steps queued"
}

# --- Per-execution data (one ID per loop invocation) ---
# Set as process-env vars so every child run-ceremony-step.ps1 invocation
# inherits the same execution identity. Standalone step runs fall back to
# local generation.
$env:CEREMONY_EXECUTION_ID = [guid]::NewGuid().ToString()
$env:CEREMONY_EXECUTION_FOLDER = $envelope_folder -replace '/_envelope$', ''

Write-Host ""
Write-Host "============================================================================="
Write-Host "🔄 Ceremony Step Loop"
Write-Host "   Steps: $($steps.Count)"
Write-Host "   Envelope: $envelope_folder"
Write-Host "   Execution ID: $($env:CEREMONY_EXECUTION_ID)"
Write-Host "   Execution folder: $($env:CEREMONY_EXECUTION_FOLDER)"
Write-Host "   Delay between steps: ${StepDelaySeconds}s"
Write-Host "============================================================================="

# --- Run steps ---
$step_index = 0
foreach ($step_name in $steps) {
    $step_index++

    # Throttle delay between steps (skip before the first step)
    if ($step_index -gt 1) {
        Write-Host ""
        Write-Host "⏳ Throttle delay: waiting ${StepDelaySeconds}s before next step..."
        Start-Sleep -Seconds $StepDelaySeconds
    }

    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "▶️  [$step_index/$($steps.Count)] Starting step: $step_name"
    Write-Host "   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host "============================================================================="
    Ring-Bell

    & "$ScriptDir/run-ceremony-step.ps1" $step_name
    if ($LASTEXITCODE -ne 0) {
        Write-Host "" -ForegroundColor Red
        Write-Host "🚫❌ ERROR: Step '$step_name' failed. Aborting loop." -ForegroundColor Red
        Write-Host "   Failed at step $step_index of $($steps.Count)." -ForegroundColor Red
        Write-Host "   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))" -ForegroundColor Red
        Ring-Bell; Ring-Bell; Ring-Bell
        exit 1
    }

    Write-Host ""
    Write-Host "✅ [$step_index/$($steps.Count)] Step complete: $step_name"
}

Write-Host ""
Write-Host "============================================================================="
Write-Host "🎉 All $($steps.Count) steps completed successfully!"
Write-Host "   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
Write-Host "============================================================================="
Ring-Bell; Ring-Bell

# --- Post: Draft PR (full loop only) ---
if ([string]::IsNullOrWhiteSpace($SingleStep)) {
    Invoke-PostCreateDraftPR
    Write-Host ""
    Write-Host "============================================================================="
    Write-Host "🏁 Ceremony complete — all steps finished and draft PR created."
    Write-Host "   $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))"
    Write-Host "============================================================================="
    Ring-Bell; Ring-Bell; Ring-Bell
}
else {
    Write-Host ""
    Write-Host "ℹ️  Single-step mode — skipping draft PR creation."
}
