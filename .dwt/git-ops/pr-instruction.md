Generate PR descriptions using these sections. Omit any section with no meaningful content.

## Summary [human] — problem solved or decision enacted

## Changes [human] — synthesized arc of work from commit history; not a raw list sessionType informs tone: plan → decisions, code → contracts changed

## Contracts & Schemas [LLM] — schemas added/modified/removed; JSON Schema exports; envelope changes. Omit if no schema changes.

## Agent Context [LLM] — stepOrigin values from commits; non-obvious decisions; options rejected. Omit if single-session human-only work.

## Side Effects & Dependencies [LLM] — cross-repo/worktree/branch impacts; env or tooling changes. Omit if none.

## Verification — build · lint; add schema regeneration check if schemas changed Synthesize commit body bullets into prose. Every sentence must carry signal.
