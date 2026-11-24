## Agent skills

### Issue tracker

Issues live as GitHub issues in `jonalm/ChainTables`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels, unchanged. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.

Julia style: before you write or edit Julia, read
~/.cache/julia-style/v1.0/JULIA_STYLE.md, then the sub-files it names for your task.
If that folder does not exist, run once:
gh repo clone jonalm/julia_codestyle ~/.cache/julia-style/v1.0 -- --depth 1 --branch v1.0
If the clone fails, stop and tell the user. Never write Julia from memory of the Guide.

test layout: legacy runner kept until https://github.com/jonalm/julia_codestyle/issues/130
(the last ticket of the Adoption switches `test/runtests.jl` to the Guide's template).
