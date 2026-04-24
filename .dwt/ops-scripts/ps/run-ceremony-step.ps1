#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Runs a single ceremony step via Claude CLI.
.DESCRIPTION
  Generates session UUID + UTC timestamp, injects runtime values into body/context
  files, invokes Claude with structured JSON schema output, then commits and pushes
  the raw and structured outputs plus any YAML deliverables.
.PARAMETER CurrentStep
  The step name (matches a folder under the envelope's steps directory).
.EXAMPLE
  ./run-ceremony-step.ps1 01-code-structure-analysis
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$CurrentStep
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PS 7.3+: force proper native-exe argument quoting. Windows PS defaults to
# 'Legacy' which mangles long/multi-line strings passed to native executables
# — fatal for `--json-schema` with a multi-KB JSON payload. Even with bun
# normalization to single-line, defense-in-depth against arg-length edge cases.
$PSNativeCommandArgumentPassing = 'Standard'

$ScriptDir = $PSScriptRoot

# --- Bell helper ---
function Ring-Bell { [Console]::Write("`a") }

# --- Validate required param ---
if ([string]::IsNullOrWhiteSpace($CurrentStep)) {
    Write-Error "🚫 ERROR: CurrentStep is required.`nUsage: ./run-ceremony-step.ps1 <step-name>`n  Example: ./run-ceremony-step.ps1 01-code-structure-analysis"
    Ring-Bell
    exit 1
}

# --- Per-session data ---
$sessionID = [guid]::NewGuid().ToString()
$current_utc_datetime = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host ""
Write-Host "ℹ️  Running ceremony step: $CurrentStep"
Write-Host "🔑 Session ID: $sessionID"
Write-Host "ℹ️  UTC: $current_utc_datetime"

# --- Defaults ---
$effort = "medium"
$model = "opus"

# --- Computed paths ---
$envelope_folder = "./_ceremony_executions/OBR/20-REPO-ANALYSIS-01/_envelope"

# --- Per-execution data (shared across loop, generated if standalone) ---
# When invoked from run-ceremony-step-loop.ps1, both env vars are set once per
# loop invocation so every step sees the same execution identity.
# Standalone invocations fall back to local generation.
$executionID = if ($env:CEREMONY_EXECUTION_ID) { $env:CEREMONY_EXECUTION_ID } else { [guid]::NewGuid().ToString() }
$ceremony_exec_folder = if ($env:CEREMONY_EXECUTION_FOLDER) { $env:CEREMONY_EXECUTION_FOLDER } else { $envelope_folder -replace '/_envelope$', '' }

Write-Host "🔑 Execution ID: $executionID"
Write-Host "ℹ️  Execution folder: $ceremony_exec_folder"

$current_step_folder = "steps/$CurrentStep/"
$input_body_file = "$CurrentStep-body.txt"
$input_body_path = "$envelope_folder/$current_step_folder$input_body_file"

$input_context_file = "$CurrentStep-context.txt"
$input_context_path = "$envelope_folder/$current_step_folder$input_context_file"

$structured_output_schema_file = "./.dwt/schemas/quality-gate/llm-output/quality-telemetry-with-result.schema.json"
$raw_output_file = "$envelope_folder/$current_step_folder$CurrentStep-$sessionID-raw.json"
$output_file = "$envelope_folder/$current_step_folder$CurrentStep-$sessionID-output.json"

Write-Host "ℹ️  Body:    $input_body_path"
Write-Host "ℹ️  Context: $input_context_path"
Write-Host "ℹ️  Schema:  $structured_output_schema_file"
Write-Host "ℹ️  Output:  $output_file"

# --- Inject runtime values into body and context files ---
Write-Host "ℹ️  Injecting runtime values into input files..."
foreach ($inject_file in @($input_body_path, $input_context_path)) {
    $content = Get-Content -Raw -LiteralPath $inject_file
    $content = $content.
        Replace('{@session_id}', $sessionID).
        Replace('{@current_utc_datetime}', $current_utc_datetime).
        Replace('{@execution_id}', $executionID).
        Replace('{@ceremony_execution_folder}', $ceremony_exec_folder)
    Set-Content -LiteralPath $inject_file -Value $content -NoNewline -Encoding utf8NoBOM
}

# --- Normalize JSON Schema via bun ---
# Claude CLI silently rejects schemas with unfamiliar metadata ($schema, $defs,
# etc.) and produces empty structured_output with no error. Routing through
# resolve-schema.ts strips meta keys, dereferences $ref/$defs (if any), and
# emits compact single-line JSON — claude-compatible and arg-passing-safe.
Write-Host "ℹ️  Normalizing JSON schema via bun..."
$SCHEMA = bun run "$ScriptDir/../resolve-schema.ts" $structured_output_schema_file
if ($LASTEXITCODE -ne 0) { throw "bun resolve-schema.ts failed (exit $LASTEXITCODE)" }
$SCHEMA = $SCHEMA -join "`n"

# --- Run Claude ---
Write-Host ""
Write-Host "🤖 Launching Claude session..."
Write-Host "   Model: $model | Effort: $effort"
Write-Host "🔑 Session ID: $sessionID"
Write-Host ""

$claudeArgs = @(
    '-p', 'Execute the provided instructions. Return structured output per the json-schema.',
    '--session-id', $sessionID,
    '--effort', $effort,
    '--model', $model,
    '--dangerously-skip-permissions',
    '--append-system-prompt-file', $input_context_path,
    '--output-format', 'json',
    '--json-schema', $SCHEMA
)

Get-Content -Raw -LiteralPath $input_body_path |
    & claude @claudeArgs |
    Set-Content -LiteralPath $raw_output_file -Encoding utf8NoBOM

if ($LASTEXITCODE -ne 0) { throw "claude invocation failed (exit $LASTEXITCODE)" }

Write-Host ""
Write-Host "✅ Claude session complete."
Write-Host "🔑 Session ID: $sessionID"
Write-Host "ℹ️  Raw output: $raw_output_file"

# --- Extract structured output ---
# Claude CLI populates `.structured_output` when --json-schema is honored AND
# the model produces schema-matching output. Absent means: (a) schema was
# silently rejected (format not accepted — normalize via bun), (b) AI used
# tools and returned prose only, (c) model didn't produce structured output
# for another reason. Mirror bash+jq behavior: write `null` and continue —
# the raw output file retains the full session record.
$raw_json = Get-Content -Raw -LiteralPath $raw_output_file | ConvertFrom-Json -Depth 100
if ($raw_json.PSObject.Properties.Name -contains 'structured_output') {
    $raw_json.structured_output | ConvertTo-Json -Depth 100 |
        Set-Content -LiteralPath $output_file -Encoding utf8NoBOM
}
else {
    Write-Warning "No 'structured_output' in raw response — writing null. Raw session record is in $raw_output_file."
    'null' | Set-Content -LiteralPath $output_file -Encoding utf8NoBOM -NoNewline
}

Write-Host "ℹ️  Structured output: $output_file"

# --- Commit and push results ---
# Two-layer add, belt-and-braces for safety:
#   1. Named session artifacts inside _envelope/ (raw + structured JSON) —
#      explicit so failures surface against specific file paths. _envelope/ is
#      AI-session-mechanics storage (inputs, raw Claude response, extracted
#      output); AI prompts are not expected to write here.
#   2. `git add -A` sweeps the entire repo — AI sessions may write anywhere
#      (ceremony-root summaries, source-code edits for dev-style steps, other
#      orchestration files). Safe because the loop pre-check requires a clean
#      tree on start and each step commits before the next runs — so between
#      step-start and step-commit, any new or modified file is necessarily
#      from this step.
Write-Host "ℹ️  Committing ceremony outputs..."
git add $raw_output_file $output_file
if ($LASTEXITCODE -ne 0) { throw "git add (session artifacts) failed" }

git add -A
if ($LASTEXITCODE -ne 0) { throw "git add -A failed" }

$commit_message = @"
chore(repo-analysis): add $CurrentStep ceremony outputs [$sessionID]

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
"@

git commit -m $commit_message
if ($LASTEXITCODE -ne 0) { throw "git commit failed" }

git push
if ($LASTEXITCODE -ne 0) { throw "git push failed" }

Write-Host "✅ Committed and pushed ceremony outputs."
Write-Host "🔑 Session ID: $sessionID"
