#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Bell helper ---
ring_bell() { printf '\a'; }

# --- Validate required param ---
current_step="${1:-}"
if [[ -z "${current_step}" ]]; then
  echo "🚫 ERROR: current_step is required." >&2
  echo "Usage: $(basename "$0") <step-name>" >&2
  echo "  Example: $(basename "$0") 01-code-structure-analysis" >&2
  ring_bell
  exit 1
fi

# --- Per-session data ---
sessionID=$(uuidgen)
current_utc_datetime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "ℹ️  Running ceremony step: ${current_step}"
echo "🔑 Session ID: ${sessionID}"
echo "ℹ️  UTC: ${current_utc_datetime}"

# --- Defaults ---
effort="medium"
model="opus"

# --- Computed paths ---
envelope_folder="./_ceremony_executions/OBR/20-REPO-ANALYSIS-01/_envelope"

# --- Per-execution data (shared across loop, generated if standalone) ---
# When invoked from run-ceremony-step-loop.sh, both env vars are exported once
# per loop invocation so every step sees the same execution identity.
# Standalone invocations fall back to local generation.
executionID="${CEREMONY_EXECUTION_ID:-$(uuidgen)}"
ceremony_exec_folder="${CEREMONY_EXECUTION_FOLDER:-${envelope_folder%/_envelope}}"

echo "🔑 Execution ID: ${executionID}"
echo "ℹ️  Execution folder: ${ceremony_exec_folder}"

current_step_folder="steps/${current_step}/"
input_body_file="${current_step}-body.txt"
input_body_path="${envelope_folder}/${current_step_folder}${input_body_file}"

input_context_file="${current_step}-context.txt"
input_context_path="${envelope_folder}/${current_step_folder}${input_context_file}"

structured_output_schema_file="./.dwt/schemas/quality-gate/quality-telemetry-inputs-with-result.schema.json"

raw_output_file="${envelope_folder}/${current_step_folder}${current_step}-${sessionID}-raw.json"
output_file="${envelope_folder}/${current_step_folder}${current_step}-${sessionID}-output.json"

echo "ℹ️  Body:    ${input_body_path}"
echo "ℹ️  Context: ${input_context_path}"
echo "ℹ️  Schema:  ${structured_output_schema_file}"
echo "ℹ️  Output:  ${output_file}"

# --- Inject runtime values into body and context files ---
echo "ℹ️  Injecting runtime values into input files..."
for inject_file in "${input_body_path}" "${input_context_path}"; do
  sed -i "s/{@session_id}/${sessionID}/g" "${inject_file}"
  sed -i "s/{@current_utc_datetime}/${current_utc_datetime}/g" "${inject_file}"
  sed -i "s/{@execution_id}/${executionID}/g" "${inject_file}"
  # Path contains forward slashes — use `|` as sed delimiter to avoid escaping.
  sed -i "s|{@ceremony_execution_folder}|${ceremony_exec_folder}|g" "${inject_file}"
done

# --- Normalize JSON Schema via bun ---
# Claude CLI silently rejects schemas with unfamiliar metadata ($schema, $defs,
# etc.) and produces empty structured_output with no error. Routing through
# resolve-schema.ts strips meta keys, dereferences $ref/$defs (if any), and
# emits compact single-line JSON — claude-compatible and arg-passing-safe.
echo "ℹ️  Normalizing JSON schema via bun..."
SCHEMA=$(bun run "${SCRIPT_DIR}/resolve-schema.ts" "${structured_output_schema_file}")

# --- Run Claude ---
echo ""
echo "🤖 Launching Claude session..."
echo "   Model: ${model} | Effort: ${effort}"
echo "🔑 Session ID: ${sessionID}"
echo ""

# Pipe body as context; query arg tells Claude to execute the provided instructions.
cat "${input_body_path}" | claude \
  -p "Execute the provided instructions. Return structured output per the json-schema." \
  --session-id "${sessionID}" \
  --effort "${effort}" \
  --model "${model}" \
  --dangerously-skip-permissions \
  --append-system-prompt-file "${input_context_path}" \
  --output-format json \
  --json-schema "${SCHEMA}" \
  > "${raw_output_file}"

echo ""
echo "✅ Claude session complete."
echo "🔑 Session ID: ${sessionID}"
echo "ℹ️  Raw output: ${raw_output_file}"

# --- Extract structured output ---
# When --json-schema works and model produces schema-matching output, structured
# data is in .structured_output. Null here means: schema silently rejected
# (normalize via bun), or AI returned prose-only (e.g., tool-use session).
# Raw output file retains the full session record either way.
jq '.structured_output' "${raw_output_file}" > "${output_file}"
if [[ "$(cat "${output_file}")" == "null" ]]; then
  echo "⚠️  No 'structured_output' in raw response — wrote null. See raw file for session record." >&2
fi

echo "ℹ️  Structured output: ${output_file}"

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
echo "ℹ️  Committing ceremony outputs..."
git add "${raw_output_file}" "${output_file}"
git add -A

git commit -m "$(cat <<EOF
chore(repo-analysis): add ${current_step} ceremony outputs [${sessionID}]

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)"

git push

echo "✅ Committed and pushed ceremony outputs."
echo "🔑 Session ID: ${sessionID}"