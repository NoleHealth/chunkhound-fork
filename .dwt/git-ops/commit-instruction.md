## Commit Standards

All sessions produce git commits. Write commit messages that serve both
human readers and downstream LLM agents consuming them as `gitContext`.

Write to `.git/COMMIT_EDITMSG` when git tooling is unavailable.

Format:
<type>(<scope>): <imperative summary, max 72 chars>

- <intent and decisions, not implementation mechanics>
- <contracts or schemas changed>
- <trade-offs or options rejected>
- <breaking changes or side effects>

Types: feat|fix|refactor|chore|docs|test|perf|plan

For planning sessions: capture decisions made, options rejected, next actions.
For code sessions: surface schema/contract changes explicitly.
Every bullet must carry signal. Omit filler.

## gitContext Schema

Commit structure follows `gitContext.schema.json`. The `type`, `scope`,
and `message` fields map directly to conventional commit format.
`body` bullets map to the structured body lines above.
`stepOrigin` should be set when operating as part of a multi-step orchestration.
