# Ceremony Scripts

Scripts for executing multi-step AI ceremony sessions via Claude CLI.

Two parallel implementations are provided:

- **Bash** (`*.sh`) — POSIX / Git Bash / WSL
- **PowerShell** (`ps/*.ps1`) — PowerShell 7+ (pwsh) on Windows, macOS, Linux

Both implementations have identical behavior, parameters, and output. Pick whichever matches your environment.

## Scripts

### `run-ceremony-step.sh <step-name>` / `ps/run-ceremony-step.ps1 <step-name>`

Runs a single ceremony step. Handles schema dereferencing, runtime parameter injection, Claude CLI invocation with structured output, and auto commit+push of results.

**Usage:**

```bash
# Bash
./run-ceremony-step.sh 01-code-structure-analysis
```

```powershell
# PowerShell
./ps/run-ceremony-step.ps1 01-code-structure-analysis
```

**What it does:**

1. Generates a session UUID and UTC timestamp (per-step)
2. Resolves execution identity — uses `CEREMONY_EXECUTION_ID` / `CEREMONY_EXECUTION_FOLDER` env vars when invoked from the loop, otherwise generates fallbacks (see **Execution Identity** below)
3. Injects four runtime tags into body and context files (`sed` in bash, `.Replace()` in PowerShell):
   - `{@session_id}` — per-step UUID
   - `{@current_utc_datetime}` — per-step ISO-8601 timestamp
   - `{@execution_id}` — per-loop UUID (constant across all steps of a single loop invocation)
   - `{@ceremony_execution_folder}` — ceremony root path (parent of `_envelope/`)
4. Normalizes the JSON schema via `resolve-schema.ts` (strips meta keys, dereferences `$ref`/`$defs`, compacts to single line — see that section for why)
5. Pipes the body file to Claude CLI with the context file as appended system prompt
6. Extracts `.structured_output` from the raw Claude response (`jq` in bash, `ConvertFrom-Json` in PowerShell)
7. Commits and pushes the session artifacts and any deliverables — see **Commit Layout** below

### `run-ceremony-step-loop.sh [step-name]` / `ps/run-ceremony-step-loop.ps1 [step-name]`

Orchestrates a full ceremony run across all steps, with git safety checks and draft PR creation.

**Usage:**

```bash
# Bash — all steps in order
./run-ceremony-step-loop.sh

# Bash — single step (with pre/post checks)
./run-ceremony-step-loop.sh 03-work-docs-analysis
```

```powershell
# PowerShell — all steps in order
./ps/run-ceremony-step-loop.ps1

# PowerShell — single step (with pre/post checks)
./ps/run-ceremony-step-loop.ps1 03-work-docs-analysis
```

**Pre-check:** Rejects dirty working trees and `main`/`master` branch.
**Execution identity:** Generates a single `CEREMONY_EXECUTION_ID` (UUID) and `CEREMONY_EXECUTION_FOLDER` per loop invocation. Bash exports them; PowerShell sets them on `$env:` — either way the child step-runner processes inherit the same values so all steps in a loop share one execution identity.
**Post-loop:** Creates a draft PR via Claude session using `pr-standards.xml`, `commit-standards.xml`, and `pull_request_template.md`. Skipped in single-step mode.
**Validation:** Step folders must start with a two-digit prefix (`01-`, `02-`, etc.) for deterministic ordering.

### `resolve-schema.ts`

Bun utility that normalizes a JSON Schema file for Claude CLI `--json-schema`. Three things it does:

1. Dereferences `$ref`/`$defs` into inline definitions (if any exist).
2. **Strips meta keys** — `$defs`, `$schema`, `$comment`. Claude CLI **silently rejects** schemas carrying metadata it doesn't accept (no error, no warning — just empty `structured_output` in the raw response). Stripping these avoids the silent-reject trap.
3. Compacts to single-line JSON (claude CLI arg-friendly, reduces native-arg-passing mangling risk especially on PowerShell/Windows).

**Always enabled** — both runners unconditionally route the schema through this normalizer. Debugging missing `structured_output` without this wrapper is painful: the model completes successfully, writes its deliverables, returns prose, and you're left guessing whether the schema was honored. No toggle to disable — the "schema is already flat, so normalization is optional" theory was disproven; meta keys still cause silent rejection.

```bash
bun run resolve-schema.ts <schema-file.json>
```

```bash
bun run resolve-schema.ts <schema-file.json>
```

## Execution Identity

Four runtime tags are injected into each step's body and context files. They fall into two lifetime tiers:

| Tag | Lifetime | Source | Purpose |
|---|---|---|---|
| `{@session_id}` | **Per step** | `uuidgen` / `[guid]::NewGuid()` inside the step runner | Uniquely identifies one Claude CLI session; appears in raw/output filenames |
| `{@current_utc_datetime}` | **Per step** | `date -u` / `[DateTime]::UtcNow` inside the step runner | Wall-clock timestamp for the session start |
| `{@execution_id}` | **Per loop** | `uuidgen` / `[guid]::NewGuid()` inside the loop runner | One ID shared across every step in a single loop invocation |
| `{@ceremony_execution_folder}` | **Per loop** | Derived from `envelope_folder` (strips `/_envelope` suffix) | Ceremony root path; constant across steps |

**Handoff mechanism:** the loop runner exports (`bash`) / sets (`$env:` in PowerShell) two process-environment variables:

- `CEREMONY_EXECUTION_ID`
- `CEREMONY_EXECUTION_FOLDER`

Each child step-runner invocation inherits them and uses `${VAR:-fallback}` (bash) / `if ($env:VAR) { $env:VAR } else { ... }` (PowerShell) to prefer the inherited value, falling back to local generation when invoked standalone.

**Why the split:** a ceremony run (one full loop) is a single logical execution — downstream analytics, PR generation, and cross-step correlation all need the same identity value across every step. A session, by contrast, is one Claude CLI invocation — each step has its own so raw/output artifacts are uniquely addressable.

## Commit Layout

A ceremony step can write files in three conceptual places:

```
repo-root/
├── _ceremony_executions/OBR/<ceremony-id>/
│   ├── _envelope/                            ← AI-session-mechanics storage
│   │   └── steps/<NN-step-name>/
│   │       ├── <step>-body.txt               ← prompt body (post runtime injection)
│   │       ├── <step>-context.txt            ← system-prompt context (post runtime injection)
│   │       ├── <step>-<sessionID>-raw.json   ← raw Claude response
│   │       └── <step>-<sessionID>-output.json ← extracted `.structured_output`
│   └── <summary/status files>.md / .yaml     ← ceremony-root writes (planning/docs sessions)
└── <anywhere else>                           ← dev-style session writes (source edits, etc.)
```

- **`_envelope/`** — the distributed-system "envelope" for the AI session. The session runner writes injected inputs and raw/structured outputs here. AI prompts are not expected to write inside `_envelope/`; reading is allowed for post-hoc telemetry analysis.
- **Ceremony root** — where planning/docs-type AI sessions usually drop summary or status artifacts.
- **Anywhere else in the repo** — where dev-type AI sessions may edit source code, add orchestration files, or otherwise modify the working tree as their actual deliverable.

### How the runner commits

The runner performs **two `git add` operations** per step:

1. `git add <raw.json> <output.json>` — explicit add of the named session artifacts inside `_envelope/`. Surfaces failures against specific file paths.
2. `git add -A` — sweeps the entire repo. Covers ceremony-root writes, source-code edits, and any other files the AI session produced. Overlap with step 1 is intentional (belt-and-braces).

**Safety invariant:** `git add -A` is safe because:

- The loop pre-check rejects dirty working trees AND untracked files before the first step runs.
- Each step commits and pushes before the next step runs.

Therefore, between step-start and step-commit the only changes in the working tree are the current step's output. The rule is simple: **everything the AI session produced during a ceremony step gets committed, regardless of path.**

### Edge case — the "empty raw output file"

The shell redirect (`> raw_output_file` in bash, pipeline to `Set-Content` in PowerShell) creates the raw output file **empty the moment claude starts** — before the CLI has written anything to it. If the AI session performs its own git commits during execution (common for dev-style steps that follow commit-as-you-go instructions), it may pick up that empty file as untracked and commit it.

When claude exits, the output stream flushes and the file is populated. The script's subsequent per-step commit (with `git add -A`) then captures the populated file as a modification. The git history for a single step may therefore show the raw output file briefly empty in an intra-session commit and fully populated in the step's wrap-up commit — expected behavior, and the filename + location make the origin unambiguous.

## Configuration

Currently hardcoded paths (intended for extraction to `dwt-core`):

- `envelope_folder` — ceremony execution envelope path
- `structured_output_schema_file` — quality telemetry schema (`.schema.json`). Always normalized via `resolve-schema.ts` at runtime; no toggle.
- `effort` / `model` — Claude CLI defaults

## Implementation Notes

**Dependencies:**

- **Bash**: `bash`, `git`, `claude` CLI, `bun` (schema normalization), `jq`, `uuidgen`, `sed`, `date`
- **PowerShell**: `pwsh` (PowerShell 7.3+ recommended for `$PSNativeCommandArgumentPassing = 'Standard'`), `git`, `claude` CLI, `bun` (schema normalization). `jq` and `uuidgen` are replaced by built-in `ConvertFrom-Json` and `[guid]::NewGuid()`.

**Native-exe argument passing (PowerShell):** `run-ceremony-step.ps1` sets `$PSNativeCommandArgumentPassing = 'Standard'` at script top. Windows PS defaults to `'Legacy'` which mangles long or multi-line strings passed to native executables — problematic for large `--json-schema` payloads. Combined with bun's compact single-line output, argument passing is robust.

**Parity:** The two implementations mirror each other line-for-line in structure and behavior — same pre-checks, same envelope paths, same commit/push flow, same throttle delay, same PR-creation step. Either can be used interchangeably.

## TODO

- **Parse top-level error signals from the raw Claude response.** The raw output header carries `type`, `subtype`, `is_error`, and `api_error_status` fields (e.g., `"type":"result","subtype":"success","is_error":false,"api_error_status":null`). Currently the runners only check whether `.structured_output` exists. Add a pre-extract gate that reads these four fields and fails the step early (with a clear message) when `is_error == true`, `api_error_status != null`, or `subtype != "success"` — distinguishes API/transport failures from "session succeeded but model didn't produce structured output." Cheap: `jq` in bash, `ConvertFrom-Json` property access in PS (already done for `structured_output`).

- **Explore `stepOrigin` template parameter:** Add `{@step_origin}` to the context block `context_param` list (alongside `{@session_id}` and `{@current_utc_datetime}`). This value maps to the `gitContext` schema's `stepOrigin` field, enabling downstream PR generation agents to trace which ceremony step produced which commit. Inject via `sed` like the other runtime values — `run-ceremony-step.sh` already has the `current_step` name available as the natural value for this parameter.
