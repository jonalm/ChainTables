# Trial log

Trial of Guide `trial-777a0df` (codestyle `777a0df`) on ChainTables, branch
`trial/guide-777a0df` cut from `1e1d300`. Append-only. Ground rules:
jonalm/julia_codestyle#44.

## Baseline (before any change)

Julia 1.13.2, aarch64 macOS. ChainTables `1e1d300`, BioMeCore `dff75ef`
(BioMeFrontend included), each suite run with `Pkg.test()` after
`Pkg.instantiate(); Pkg.precompile()`. Wall time = the `Pkg.test()` call (it
includes the test env's resolve and precompile). BioMeCore and BioMeFrontend
`Pkg.develop` this worktree at `1e1d300`.

| Suite | Result | Passes | Wall time |
|---|---|---|---|
| ChainTables `1e1d300`, non-live (`test/live/` excluded by the runner) | pass | 2981 | 106.9 s |
| BioMeCore `dff75ef` vs ChainTables `1e1d300` | pass | 22808 | 57.6 s |
| BioMeFrontend `dff75ef` vs ChainTables `1e1d300` | pass | 355 | 40.1 s |

No failures, no broken tests. BioMeFrontend logs `@error` output from its
injected-fault tests (`network down`); these are expected and pass.

TestConventions precheck: `Pkg.add("TestConventions")` from BioMeRegistry
(`0921a36`, v0.1.0, tree `f1e4fce` = `777a0df:TestConventions`) in a throwaway
env, then `using TestConventions`: pass.

## Rewrite

Wall time and tokens: (recorded by the rewrite session)

Line format: `file:line | Rule/Default | unclear/wrong/blocked | choice made`

