# harness-bridge

Use your existing **Claude Code** setup — plugins, skills, subagents, slash commands, MCP
servers, `CLAUDE.md` — from **opencode**, **pi**, **codex**, **cursor**, and **GitHub
Copilot CLI**, without duplicating a single file.

Your Claude Code setup is the source of truth. Nothing under `~/.claude` is ever modified.

## Compatibility

What each supported harness gets from your Claude Code setup, and how. Keep this table
updated whenever harness support changes (see `CLAUDE.md`).

| Claude resource | opencode | pi | codex | cursor | copilot |
|---|---|---|---|---|---|
| **Plugin skills** | ✅ link → `~/.agents/skills/` | ✅ same link | ✅ same link (documented symlink support) | ✅ same link ⚠ CLI caveat below | ✅ same link (also auto-scanned) |
| **Plain `~/.claude/skills/`** | ✅ auto-scanned | — not scanned | — not scanned | ✅ auto-scanned (compat dir) | — not scanned (project `.claude/skills` is, though) |
| **Plugin subagents** (`agents/*.md`) | ✅ link/shim → `~/.config/opencode/agent/` | — no subagent concept | — TOML agents, different schema | ✅ link → `~/.cursor/agents/` (reads Claude markdown as-is) | ✅ link → `~/.copilot/agents/` (reads Claude markdown as-is) |
| **Plain `~/.claude/agents/`** | ✅ link/shim | — | — | ✅ auto-scanned (compat dir) | ✅ link → `~/.copilot/agents/` (not auto-scanned) |
| **Slash commands** (`commands/*.md`) | ✅ link → `command/` | ✅ link → `prompts/` | ✅ link → `~/.codex/prompts/` (deprecated surface, still loaded) | ✅ link → `~/.cursor/commands/` | — no custom command/prompt-file surface |
| **Global `~/.claude/CLAUDE.md`** | ✅ read natively | ✅ link → `~/.pi/agent/AGENTS.md` | ✅ link → `~/.codex/AGENTS.md` | 🟡 shim → `~/.cursor/rules/claude-global.mdc` (always-on rule pointing at it; projects under `$HOME` only) | ✅ link → `~/.copilot/copilot-instructions.md` |
| **Project `CLAUDE.md`** | ✅ read natively | — | — opt-in via `project_doc_fallback_filenames` in `config.toml` | ✅ CLI reads it natively | ✅ CLI reads it natively (git root & cwd) |
| **MCP servers** | ✅ `--write-mcp` → `opencode.jsonc` (translated) | — no MCP support | 🟡 `--mcp-snippet` prints TOML to paste | ✅ `--write-mcp` → `~/.cursor/mcp.json` (same schema as Claude) | ✅ `--write-mcp` → `~/.copilot/mcp-config.json` (translated) |
| **Saved dynamic workflows** (plugin `workflows/*.js`, `~/.claude/workflows/`, `.claude/workflows/`) | — no Workflow runtime | — | — | — | — |
| **Hooks / permissions** | — | — | — | — | — (own hooks system, different mechanism) |
| **Coverage** | **8/10 (80%)** | **3/10 (30%)** | **3.5/10 (35%)** | **7.5/10 (75%)** | **6/10 (60%)** |

Coverage counts the 10 resource rows above: ✅ = 1, 🟡 (manual paste step) = 0.5, — = 0.
No harness can reach 100% — Claude's dynamic-workflow runtime (`agent()`/`pipeline()`
scripts) and hooks/permissions have no equivalent anywhere. The workaround for workflows
is in the skill, not the sync: write execution tiers that detect capability, the way
barnuri-dev-skills' `code-gen` does — Tier 1 runs the saved workflow on Claude Code,
Tier 2 fans out to parallel subagents where a subagent tool exists, Tier 3 falls back to
serial everywhere else. The skill text travels through the skills link; only the Tier 1
runtime stays Claude-only. Recompute this row whenever a cell changes.

⚠ **cursor CLI caveat:** cursor-agent has a known partial symlink-discovery bug — links
whose *targets* live outside `.cursor/`/`.claude/` (e.g. a directory-source marketplace
checkout) may be missed by the CLI while the IDE (2.5+) sees them. Verify once with
cursor-agent after syncing.

```bash
bin/harness-bridge.sh --report     # what's shared, what's missing
bin/harness-bridge.sh --dry-run    # what it would do
bin/harness-bridge.sh --write-mcp  # do it, including MCP servers

# give cursor the same global instructions Claude Code runs with
bin/harness-bridge.sh --cursor-append-prompt ~/path/to/append-to-system-prompt.md
```

## Why

None of these harnesses understands Claude Code plugins, so everything in
`~/.claude/plugins/cache/` is invisible to them. But all five implement the
[Agent Skills standard](https://agentskills.io) and all five scan the harness-neutral
`~/.agents/skills/`, so one symlink can serve every tool.

**The rule: link only the gaps.** Anything a harness already discovers on its own is left
completely alone — linking it again would give you two entries for one resource.

## What is already automatic (never linked)

Verified against opencode 1.18.11 with `opencode debug skill` / `opencode debug config`;
cursor's compat dirs are documented at cursor.com/docs/skills; copilot CLI's are documented
at docs.github.com/copilot/how-tos/copilot-cli/customize-copilot:

| Claude resource | Auto-detected by | Action |
|---|---|---|
| `~/.claude/skills/`, `.claude/skills/` | opencode, cursor; copilot (project `.claude/skills` only, not the global path) | none |
| `~/.claude/CLAUDE.md`, `./CLAUDE.md` | opencode (both), cursor CLI (project), copilot CLI (project) | none |
| `~/.claude/agents/`, `.claude/agents/` | cursor | none (still linked for opencode and copilot) |

opencode's instruction-file list is a literal in the binary — `[config/AGENTS.md,
~/.claude/CLAUDE.md]` globally and `["AGENTS.md","CLAUDE.md","CONTEXT.md"]` walking up from
the cwd — so `CLAUDE.md` needs no shim at all. pi, codex, and copilot CLI do *not* read the
global one, so it is linked to `~/.pi/agent/AGENTS.md`, `~/.codex/AGENTS.md`, and
`~/.copilot/copilot-instructions.md`.

## What gets linked

| Source | Destination | Used by |
|---|---|---|
| plugin `skills/<name>/` | `~/.agents/skills/<name>` | opencode + pi + codex + cursor + copilot |
| plugin `agents/*.md` | `~/.config/opencode/agent/`, `~/.cursor/agents/`, `~/.copilot/agents/` | opencode, cursor, copilot |
| plugin `commands/*.md` | `~/.config/opencode/command/`, `~/.pi/agent/prompts/`, `~/.cursor/commands/`, `~/.codex/prompts/` | opencode, pi, cursor, codex |
| `~/.claude/agents/*.md` | `~/.config/opencode/agent/`, `~/.copilot/agents/` | opencode, copilot (cursor reads the source natively) |
| `~/.claude/commands/*.md` | same four command/prompt dirs as plugin commands | opencode, pi, cursor, codex |
| `<project>/.claude/agents/*.md` | `<project>/.opencode/agent/`, `<project>/.github/agents/` | opencode, copilot (cursor reads the source natively) |
| `<project>/.claude/commands/*.md` | `<project>/.opencode/command/`, `<project>/.pi/prompts/`, `<project>/.cursor/commands/` | opencode, pi, cursor |
| `~/.claude/CLAUDE.md` | `~/.pi/agent/AGENTS.md`, `~/.codex/AGENTS.md`, `~/.copilot/copilot-instructions.md` | pi, codex, copilot |
| `~/.claude/CLAUDE.md` | `~/.cursor/rules/claude-global.mdc` (generated pointer, not a link) | cursor |

Whole skill *directories* are linked, not just `SKILL.md`, so bundled scripts and
references resolve. All five harnesses follow symlinked skill directories (see the cursor
CLI caveat above). copilot CLI has no user-definable slash-command/prompt-file surface at
all, so Claude's `commands/*.md` are reported as not migrated for it rather than linked.

## The three places a symlink cannot work

1. **Agent frontmatter.** opencode validates agent files strictly and **hard-fails
   startup** on a mismatch — one bad file takes the whole harness down. Claude writes
   `tools:` as a YAML sequence (`- Bash`) where opencode wants a mapping (`Bash: true`),
   and uses colour names (`color: red`) where opencode allows only `#rrggbb` or its theme
   enum. Those agents get the smallest possible shim: the same file with only those two
   keys reshaped, marked `# generated by harness-bridge.sh from <src>` and
   regenerated from the Claude source on every run. Agents opencode already accepts stay
   plain symlinks.

2. **Cursor's global instructions.** Verified against `cursor-agent 2026.09.02`:
   `loadRulesFromDirAndAncestors` walks the cwd up to `/` and, at every ancestor, loads
   `<dir>/.cursor/rules/**/*.mdc` (following symlinks) plus `CLAUDE.md`, `CLAUDE.local.md`
   and `AGENTS.md`. So `~/.cursor/rules/*.mdc` **is** read — but `~/.claude/CLAUDE.md` is
   not, because `~/.claude` is never an ancestor of a project. A rule is only always-on
   when its **own** frontmatter says `alwaysApply: true`, and `CLAUDE.md` has no
   frontmatter, so a symlink cannot close the gap. The generated
   `~/.cursor/rules/claude-global.mdc` carries the frontmatter and *names* the Claude
   files instead of copying them, so edits to `~/.claude/CLAUDE.md` take effect
   immediately rather than at the next sync. Add the file Claude Code gets via
   `--append-system-prompt-file` with `--cursor-append-prompt FILE` (repeatable, or
   `$CURSOR_APPEND_PROMPT` colon-separated); it is listed ahead of `CLAUDE.md`, matching
   Claude Code's own precedence. Two limits, both reported on every run: the rule only
   reaches projects under `$HOME`, and it asks the agent to *read* the files rather than
   inlining them.

3. **MCP servers.** They must live *inside* each harness's own config file — there is
   nothing to point a link at. Four Claude sources are scanned (`~/.claude.json`,
   `~/.claude/settings.json`, `<project>/.mcp.json`, `<project>/.claude/settings.json`)
   plus every plugin's `.mcp.json`, in both the wrapped (`{"mcpServers": …}`) and bare
   (`{"name": …}`) shapes. Per harness:
   - **opencode** — schema differs (`{type, command[], environment}`). `--write-mcp`
     merges the translation into `opencode.jsonc`, refusing to touch a file containing
     comments because `jq` would eat them.
   - **cursor** — `~/.cursor/mcp.json` uses Claude's own `{command, args, env}` shape, so
     `--write-mcp` merges the servers near-verbatim.
   - **codex** — `~/.codex/config.toml` is TOML and routinely hand-commented, so it is
     never machine-edited: `--mcp-snippet` prints the `[mcp_servers.*]` block to paste.
   - **copilot CLI** — `~/.copilot/mcp-config.json` requires a `type` key (`local`/`http`/
     `sse`) and a `tools` array that Claude's shape doesn't have, so `--write-mcp` merges
     a translation (`tools` defaults to `["*"]`, everything allowed).
   - **pi** — no MCP support.

Not bridgeable at all: saved dynamic workflows (the `Workflow` runtime executing plugin
`workflows/*.js` / `~/.claude/workflows/` scripts is Claude Code-only — linking the files
would give the other harnesses scripts nothing can run), `settings.json`
hooks/permissions, plugin hooks, subagents for pi (no such concept) and codex (TOML agents
with a different schema — `developer_instructions` et al.), and cursor user rules entered
in the IDE settings UI (stored server-side, no file — distinct from the global rules
*directory*, which is bridged above).

## Keeping the generated cursor rule in git

`~/.cursor/rules/claude-global.mdc` is the only file this tool generates outside a harness
cache, so it is the only one worth version-controlling. Point `~/.cursor/rules` at a
directory in a repo and the tool writes straight through the symlink — no flag, no change:

```sh
mkdir -p ~/my-dotfiles/cursor/rules
mv ~/.cursor/rules/*.mdc ~/my-dotfiles/cursor/rules/ 2>/dev/null
rmdir ~/.cursor/rules && ln -sfn ~/my-dotfiles/cursor/rules ~/.cursor/rules
```

Writes, regeneration and pruning all follow the link; the link itself is never touched.
The rule remembers its own `--cursor-append-prompt` paths, so a run from a shell that never
exported `$CURSOR_APPEND_PROMPT` (cron, a hook, any non-interactive shell) reproduces the
same file byte-for-byte instead of leaving a diff. Clear them with
`--no-cursor-append-prompt`. The one caveat left: the generated rule embeds absolute paths,
so it is machine-specific.

## Safety

- A destination entry is **owned** iff it is a symlink whose target points inside a Claude
  source root, or a file carrying the generated-shim marker. Only those are ever removed.
- Real files, real directories, and hand-made links are reported as "left alone" and never
  touched or overwritten — unless `--force` is given.
- `--force` (off by default) replaces a conflicting real file/dir or hand-made symlink with
  the planned link instead of skipping it — e.g. a pre-existing `~/.copilot/copilot-instructions.md`
  you never asked this tool to manage. Replacing a real file/dir this way routes through
  `trash`, so it stays recoverable; if `trash` isn't installed, that entry is still reported
  and left alone rather than falling back to an unrecoverable delete. Every entry it touches
  is reported as "overwritten (--force given)", never silent.
- `--dry-run` changes nothing. A default run also prunes links whose source disappeared.
- Nothing under `~/.claude` is written to.

## Edge cases it handles

- **Version pinning** — reads `installed_plugins.json`; the cache also holds superseded
  copies flagged `.orphaned_at`, and globbing it would ship dead code.
- **Directory marketplaces** — when a marketplace is a local directory, Claude reads it
  live while the cache lags behind, so the live path wins.
- **Custom component paths** — a plugin may declare `"skills": "./.claude/skills/"` in
  `plugin.json` instead of using the conventional directory.
- **Shadowing** — a plugin skill is skipped when `~/.claude/skills/<same-name>` exists,
  since opencode already scans that directory.
- **Name collisions** — two plugins shipping `review.md` both survive; the second is
  prefixed with its plugin name.
- **`${CLAUDE_PLUGIN_ROOT}`** — only Claude Code sets it, so skills referencing it are
  flagged as needing manual fixup rather than silently linked broken.

## Verification

`--report` compares Claude's own inventory (`claude plugin list/details`) against what each
harness actually loaded, so it cannot mark its own homework:

```
PLUGIN                     COMPONENT COUNT  IN OPENCODE IN PI  STATUS
ui-ux-pro-max              Skills    7      7          7      ok
playwright                 MCP servers 1    1          -      ok
...
no gaps — every enabled plugin's components are visible downstream
```

Name matching accounts for two quirks: a skill registers under the `name:` in its
`SKILL.md`, which may differ from its directory, and Claude counts a plugin's slash
commands as "Skills" while they arrive downstream as opencode commands.

## Use as an opencode plugin

`src/plugin.js` wraps the script so it runs at opencode startup:

```jsonc
// ~/.config/opencode/opencode.jsonc
{ "plugin": ["file:///absolute/path/to/harness-bridge/src/plugin.js"] }
```

opencode reads its config once at startup, so links created during a run are picked up on
the **next** launch. The plugin swallows its own errors — a sync failure must never stop
opencode from starting.

## Requirements

`bash`, `jq`. `trash` is used to remove stale generated shims (they are regenerated files,
so removal stays recoverable). Optional: `claude` for `--report`, `opencode`/`pi` to verify.

## Platform support

The script is plain POSIX-ish bash — no GNU-only or BSD-only flags — and has been run
against both macOS and Linux (Debian/Alpine) with an identical result: same plans, same
links, same test suite passing (168/168 on Linux with `jq` + a `trash` command installed;
macOS has 5 pre-existing, environment-specific test failures from a `/var` vs
`/private/var` `mktemp` path-canonicalization quirk in the test harness itself, unrelated
to the tool's actual behavior).

- **macOS / Linux** — no extra setup. Install `jq` (`brew install jq` / `apt install jq` /
  `dnf install jq`) and, optionally, a `trash` command (`brew install trash`, or the
  `trash-cli` package on most Linux distros) so stale shims and `--force` overwrites are
  removed recoverably instead of being reported and left alone.
- **Windows** — this is a bash script, so it needs a bash to run in:
  - **WSL2 (recommended)** — behaves exactly like the Linux case above; install `jq` and
    `trash-cli` inside the WSL distro.
  - **Git Bash / MSYS2** — works, but creating a symlink on Windows needs either
    [Developer Mode](https://learn.microsoft.com/en-us/windows/apps/get-started/enable-your-device-for-development)
    enabled or an elevated (Administrator) shell; without one of those, `ln -s` fails for
    every ordinary user account. The script checks this once up front and fails fast with
    that exact remediation instead of reporting dozens of individual "link failed"
    conflicts. `--dry-run` skips the check entirely, so you can preview the plan without
    either prerequisite. Install `jq` via `winget install jqlang.jq` and a `trash`-named
    command on `PATH` (e.g. the `trash-cli` npm package) for the same recoverable-delete
    behavior as macOS/Linux.

## Tests

```bash
bash test/harness-bridge.test.sh   # 168 assertions, throwaway fixture HOME
```

Every case runs against a temporary `HOME`; the suite never reads or writes the real
`~/.claude`, `~/.config/opencode`, `~/.pi`, `~/.codex`, `~/.cursor`, `~/.copilot`, or
`~/.agents`.

## Licence

MIT
