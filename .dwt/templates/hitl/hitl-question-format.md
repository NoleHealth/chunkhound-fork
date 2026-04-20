## HITL Question Format Guidelines

When generating HITL decision files, use this standardized format for all questions.

If the decision needs follow-on work or reuse across sessions, include dedicated action directive options so reviewers can capture those actions explicitly.

### Action Directive Glossary

Use these standardized action directives when questions require follow-up work:

| Directive     | Meaning                                               | Use When                                            |
| ------------- | ----------------------------------------------------- | --------------------------------------------------- |
| **IMPLEMENT** | Execute this action now in current ceremony           | Decision requires immediate action                  |
| **DEFER**     | Add to backlog for future ceremony (requires action)  | Decision is "yes, but later" - NOT same as ignoring |
| **REJECT**    | Explicitly decline or abandon this option             | Decision is "no, we won't do this"                  |
| **EXTEND**    | Create follow-up work based on this decision          | Decision creates new tasks or ceremonies            |
| **APPLY**     | Propagate this decision to other locations/ceremonies | Decision needs to be applied elsewhere              |
| **VALIDATE**  | Create test/verification step for this decision       | Decision needs proof or validation                  |
| **DOCUMENT**  | Generate ADR or decision record                       | Decision rationale must be captured                 |

**IMPORTANT**: DEFER ≠ IGNORE. DEFER means "yes, and add to backlog" - it requires capturing the work item for later action.

### Question Format

```markdown
### Q{section}.{number}: {Short Question Title}

{Context/explanation paragraph if needed}

- [_] (a) {Option A label} (Recommended - {why it's recommended})
- [_] (b) {Option B label} ({brief description})
- [_] (c) {Option C label} ({brief description})
- [_] (d) DEFER - Add to backlog for future action: `________________________________`
- [_] (e) EXTEND - {Describe follow-up action}: `________________________________`
- [_] (z) Other: `______________________________`
```

### Format Rules

1. **Question ID**: Use `Q{section}.{number}` format (e.g., Q1.1, Q2.3)
2. **Title**: Clear, concise question in title case
3. **Context**: Explain what the decision affects and why it matters
4. **Checkboxes**: Use `[_]` for unmarked, `[x]` for selected
5. **Option Letters**: Number each option with (a), (b), (c), etc. for clear reference
6. **Recommended**: Mark preferred option with "(Recommended - {reason})"
7. **Other option**: Always include as last option with letter '(z): Other: `______________________________`'
8. **Extend/Apply**: Only add `(EXTEND)` or `(APPLY)` options when the question creates follow-up work (EXTEND) or needs the decision applied elsewhere (APPLY)
9. To prevent markdown becoming malformed by autoformatters, When generating markdown always Enclose strings with multiple consecutive underscores in backticks or brackets.
   Note an underscore between the brackets does not need and should not be enclosed in backticks
   Examples:

   - `my__string`: Without backticks becomes: "my\_\_string"
   - `__tests__`: Without backticks becomes: "**tests**"
   - [_] Other: `________________`: Without backticks becomes: "[_] Other: **\*\***\*\***\*\***\_\_**\*\***\*\***\*\***"

### Example

```markdown
### Q2.1: Backlog System Integration

Which external backlog system will this repository integrate with?

- [_] (a) Azure DevOps (Recommended - aligns with existing tooling)
- [_] (b) Jira (enterprise alternative)
- [_] (c) None (standalone backlog.yaml only)
- [_] (d) DEFER - Decide later, add to backlog: `________________________________`
- [_] (e) EXTEND - Document integration checklist: `________________________________`
- [_] (z) Other: `______________________________`
```

### HITL Frontmatter Requirements

HITL files MUST include these frontmatter fields:

```yaml
---
name: '{Decision Gate Name}'
doc_type: 'hitl'
status: 'pending' # pending | completed
execution_id: '{{execution_id}}'
session_id: '{{session_id}}'
---
```

### Status Values

| Status      | Meaning                                  |
| ----------- | ---------------------------------------- |
| `pending`   | Awaiting human input                     |
| `completed` | All questions answered, ready to proceed |

### Answer Interpretation

- Answers are captured in the checkbox selections only
- LLM reads `[x]` marked options to determine user decisions
- The option letter (a, b, c, z) provides unambiguous reference
- CLI only checks `status: completed` in frontmatter to gate progression
- Do NOT include redundant answer tables or resolved maps
