## Agent skills

### Issue tracker

Issues live as GitHub issues in `jonalm/ChainTables`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

Julia style: before you write or edit Julia, read
~/.cache/julia-style/trial-777a0df/JULIA_STYLE.md, then the sub-files it names for your task.
If that folder does not exist, run once:
gh repo clone jonalm/julia_codestyle ~/.cache/julia-style/trial-777a0df -- --depth 1 --branch trial-777a0df
If the clone fails, stop and tell the user. Never write Julia from memory of the Guide.
