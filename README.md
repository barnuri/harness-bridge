# claude-harness-sync

Use your existing **Claude Code** setup — plugins, skills, subagents, slash commands, MCP
servers, `CLAUDE.md` — from **opencode**, **pi**, **codex**, and **cursor**, without
duplicating a single file.

Your Claude Code setup is the source of truth. Nothing under `~/.claude` is ever modified.

## Compatibility

What each supported harness gets from your Claude Code setup, and how. Keep this table
updated whenever harness support changes (see `CLAUDE.md`).

| Claude resource | opencode | pi | codex | cursor |
|---|---|---|---|---|
| **Plugin skills** | ✅ link → `~/.agents/skills/` | ✅ same link | ✅ same link (documented symlink support) | ✅ same link ⚠ CLI caveat below |
| **Plain `~/.claude/skills/`** | ✅ auto-scanned | — not scanned | — not scanned | ✅ auto-scanned (compat dir) |
| **Plugin subagents** (`agents/*.md`) | ✅ link/shim → `~/.config/opencode/agent/` | — no subagent concept | — TOML agents, different schema | ✅ link → `~/.cursor/agents/` (reads Claude markdown as-is) |
| **Plain `~/.claude/agents/`** | ✅ link/shim | — | — | ✅ auto-scanned (compat dir) |
| **Slash commands** (`commands/*.md`) | ✅ link → `command/` | ✅ link → `prompts/` | ✅ link → `~/.codex/prompts/` (deprecated surface, still loaded) | ✅ link → `~/.cursor/commands/` |
| **Global `~/.claude/CLAUDE.md`** | ✅ read natively | ✅ link → `~/.pi/agent/AGENTS.md` | ✅ link → `~/.codex/AGENTS.md` | — no global-instructions file (settings UI only) |
| **Project `CLAUDE.md`** | ✅ read natively | — | — opt-in via `project_doc_fallback_filenames` in `config.toml` | ✅ CLI reads it natively |
| **MCP servers** | ✅ `--write-mcp` → `opencode.jsonc` (translated) | — no MCP support | 🟡 `--mcp-snippet` prints TOML to paste | ✅ `--write-mcp` → `~/.cursor/mcp.json` (same schema as Claude) |
| **Saved dynamic workflows** (plugin `workflows/*.js`, `~/.claude/workflows/`, `.claude/workflows/`) | — no Workflow runtime | — | — | — |
| **Hooks / permissions** | — | — | — | — |
| **Coverage** | **8/10 (80%)** | **3/10 (30%)** | **3.5/10 (35%)** | **7/10 (70%)** |

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
bin/claude-harness-sync.sh --report     # what's shared, what's missing
bin/claude-harness-sync.sh --dry-run    # what it would do
bin/claude-harness-sync.sh --write-mcp  # do it, including MCP servers
```

## Why

None of these harnesses understands Claude Code plugins, so everything in
`~/.claude/plugins/cache/` is invisible to them. But all four implement the
[Agent Skills standard](https://agentskills.io) and all four scan the harness-neutral
`~/.agents/skills/`, so one symlink can serve every tool.

**The rule: link only the gaps.** Anything a harness already discovers on its own is left
completely alone — linking it again would give you two entries for one resource.

## What is already automatic (never linked)

Verified against opencode 1.18.11 with `opencode debug skill` / `opencode debug config`;
cursor's compat dirs are documented at cursor.com/docs/skills:

| Claude resource | Auto-detected by | Action |
|---|---|---|
| `~/.claude/skills/`, `.claude/skills/` | opencode, cursor | none |
| `~/.claude/CLAUDE.md`, `./CLAUDE.md` | opencode (both), cursor CLI (project) | none |
| `~/.claude/agents/`, `.claude/agents/` | cursor | none (still linked for opencode) |

opencode's instruction-file list is a literal in the binary — `[config/AGENTS.md,
~/.claude/CLAUDE.md]` globally and `["AGENTS.md","CLAUDE.md","CONTEXT.md"]` walking up from
the cwd — so `CLAUDE.md` needs no shim at all. pi and codex do *not* read it, so the global
`CLAUDE.md` is linked to `~/.pi/agent/AGENTS.md` and `~/.codex/AGENTS.md`.

## What gets linked

| Source | Destination | Used by |
|---|---|---|
| plugin `skills/<name>/` | `~/.agents/skills/<name>` | opencode + pi + codex + cursor |
| plugin `agents/*.md` | `~/.config/opencode/agent/`, `~/.cursor/agents/` | opencode, cursor |
| plugin `commands/*.md` | `~/.config/opencode/command/`, `~/.pi/agent/prompts/`, `~/.cursor/commands/`, `~/.codex/prompts/` | opencode, pi, cursor, codex |
| `~/.claude/agents/*.md` | `~/.config/opencode/agent/` | opencode (cursor reads the source natively) |
| `~/.claude/commands/*.md` | same four command/prompt dirs as plugin commands | opencode, pi, cursor, codex |
| `<project>/.claude/agents/*.md` | `<project>/.opencode/agent/` | opencode (cursor reads the source natively) |
| `<project>/.claude/commands/*.md` | `<project>/.opencode/command/`, `<project>/.pi/prompts/`, `<project>/.cursor/commands/` | opencode, pi, cursor |
| `~/.claude/CLAUDE.md` | `~/.pi/agent/AGENTS.md`, `~/.codex/AGENTS.md` | pi, codex |

Whole skill *directories* are linked, not just `SKILL.md`, so bundled scripts and
references resolve. All four harnesses follow symlinked skill directories (see the cursor
CLI caveat above).

## The two places a symlink cannot work

1. **Agent frontmatter.** opencode validates agent files strictly and **hard-fails
   startup** on a mismatch — one bad file takes the whole harness down. Claude writes
   `tools:` as a YAML sequence (`- Bash`) where opencode wants a mapping (`Bash: true`),
   and uses colour names (`color: red`) where opencode allows only `#rrggbb` or its theme
   enum. Those agents get the smallest possible shim: the same file with only those two
   keys reshaped, marked `# generated by claude-harness-sync.sh from <src>` and
   regenerated from the Claude source on every run. Agents opencode already accepts stay
   plain symlinks.

2. **MCP servers.** They must live *inside* each harness's own config file — there is
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
   - **pi** — no MCP support.

Not bridgeable at all: saved dynamic workflows (the `Workflow` runtime executing plugin
`workflows/*.js` / `~/.claude/workflows/` scripts is Claude Code-only — linking the files
would give the other harnesses scripts nothing can run), `settings.json`
hooks/permissions, plugin hooks, subagents for pi (no such concept) and codex (TOML agents
with a different schema — `developer_instructions` et al.), and cursor user rules
(settings UI, no file).

## Safety

- A destination entry is **owned** iff it is a symlink whose target points inside a Claude
  source root, or a file carrying the generated-shim marker. Only those are ever removed.
- Real files, real directories, and hand-made links are reported as "left alone" and never
  touched or overwritten.
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
{ "plugin": ["file:///absolute/path/to/claude-harness-sync/src/plugin.js"] }
```

opencode reads its config once at startup, so links created during a run are picked up on
the **next** launch. The plugin swallows its own errors — a sync failure must never stop
opencode from starting.

## Requirements

`bash`, `jq`. `trash` is used to remove stale generated shims (they are regenerated files,
so removal stays recoverable). Optional: `claude` for `--report`, `opencode`/`pi` to verify.

## Tests

```bash
bash test/claude-harness-sync.test.sh   # 123 assertions, throwaway fixture HOME
```

Every case runs against a temporary `HOME`; the suite never reads or writes the real
`~/.claude`, `~/.config/opencode`, `~/.pi`, `~/.codex`, `~/.cursor`, or `~/.agents`.

## Licence

MIT
