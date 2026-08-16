# claude-harness-sync — Repo Notes

## Keep the README Compatibility table current

The table at the top of `README.md` ("Compatibility") is the contract this tool is judged
by: one row per Claude resource, one column per supported harness (opencode, pi, codex,
cursor), each cell saying whether it works and by what mechanism (auto-detected, symlink,
shim, snippet). **Any change that adds, removes, or alters harness support — a new
`--target`, a new link rule, a discovery path a harness gained or lost in an upgrade —
must update that table in the same change.** A table that lags the script silently
misleads every user deciding whether their setup will carry over. The table ends with a
**Coverage** row (✅ = 1, 🟡 = 0.5, — = 0, out of the resource-row count) — recompute it
whenever any cell changes.

When adding a new harness:

1. Verify its discovery paths against its current docs/binary first (which dirs it scans,
   whether it follows symlinked directories, its instructions-file names, its MCP config
   shape). Wrong destination paths are the costly failure here — the engine will happily
   create links nothing ever reads.
2. Follow the existing pattern in `bin/claude-harness-sync.sh`: a `want_<harness>` flag, a
   `--target` value, an env-overridable destination dir (needed for test isolation), plan
   rules, prune dirs, usage/header text.
3. Add test cases to `test/claude-harness-sync.test.sh` (fixture-`HOME` isolated) and run
   the suite.
4. Update the Compatibility table, the "What gets linked" table, and the assertion count
   in the Tests section of `README.md`.

## Invariants (do not weaken)

- The Claude Code setup is the source of truth; nothing under `~/.claude` is ever written.
- Link only the gaps — never link a resource the harness already auto-discovers
  (duplication is the failure mode this tool exists to avoid).
- Only owned entries are ever pruned: symlinks targeting a Claude source root, or files
  carrying the generated-shim marker. Real files and hand-made links are reported, never
  touched.
- TOML configs (codex `config.toml`) are never machine-edited — snippet-only.
