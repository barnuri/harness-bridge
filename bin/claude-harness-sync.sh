#!/usr/bin/env bash
# Make an existing Claude Code setup usable from the opencode, pi, codex, and cursor
# coding harnesses, without ever duplicating a file.
#
# THE RULE: the Claude Code setup is the source of truth. Anything the other harness
# already discovers on its own is left completely alone — linking it again would give the
# user two entries for one resource. Only the gaps get a symlink, and nothing under
# ~/.claude is ever modified.
#
# What opencode discovers by itself (verified against this binary, v1.18.11 — re-check
# after an upgrade with `opencode debug skill` / `opencode debug config`):
#   ~/.claude/skills/       AUTO   global skill scan
#   .claude/skills/         AUTO   project skill scan (walks up to the git root)
#   ~/.claude/CLAUDE.md     AUTO   global instructions, unless disableClaudeCodePrompt
#   CLAUDE.md               AUTO   project instructions (with AGENTS.md, CONTEXT.md)
#   ~/.claude/agents/       NO     needs links
#   .claude/agents/         NO     needs links
#   ~/.claude/commands/     NO     needs links
#   .claude/commands/       NO     needs links
#   mcpServers (4 files)    NO     cannot be linked — different schema, see --write-mcp
#   settings.json hooks     NO     no equivalent concept in either harness
#
# So this script links, from the two Claude roots:
#
#   PLUGINS (Claude-only concept — the cache is invisible to every other harness)
#     <installPath>/skills/<name>/  ->  ~/.agents/skills/<name>   (opencode + pi + codex + cursor)
#     <installPath>/commands/*.md   ->  ~/.config/opencode/command/    (opencode)
#     <installPath>/commands/*.md   ->  ~/.pi/agent/prompts/           (pi)
#     <installPath>/commands/*.md   ->  ~/.cursor/commands/            (cursor)
#     <installPath>/commands/*.md   ->  ~/.codex/prompts/              (codex — deprecated surface, still loaded)
#     <installPath>/agents/*.md     ->  ~/.config/opencode/agent/      (opencode)
#     <installPath>/agents/*.md     ->  ~/.cursor/agents/              (cursor — reads Claude agent markdown as-is)
#
#   COMPAT (plain Claude config a harness does not scan by itself)
#     ~/.claude/agents/*.md    ->  ~/.config/opencode/agent/           (opencode; cursor reads it natively)
#     ~/.claude/commands/*.md  ->  ~/.config/opencode/command/ + ~/.pi/agent/prompts/
#                                  + ~/.cursor/commands/ + ~/.codex/prompts/
#     ~/.claude/CLAUDE.md      ->  ~/.pi/agent/AGENTS.md + ~/.codex/AGENTS.md
#     ~/.claude/CLAUDE.md      ->  ~/.cursor/rules/claude-global.mdc   (cursor — generated
#                                  .mdc pointer, see "cursor global instructions" below)
#     <project>/.claude/agents/*.md    ->  <project>/.opencode/agent/  (cursor reads it natively)
#     <project>/.claude/commands/*.md  ->  <project>/.opencode/command/ + .pi/prompts/ + .cursor/commands/
#
# Plugin skills target ~/.agents/skills/ rather than ~/.claude/skills/: it is the one
# directory all four harnesses scan, and Claude Code does *not* scan it — linking into
# ~/.claude/skills/ would both modify the Claude setup and make every plugin skill appear
# twice in Claude Code's own list. Plain ~/.claude/skills is already auto-detected by
# opencode and cursor, so it is deliberately NOT linked anywhere for them.
#
# Symlinked skill directories are followed by opencode (verified via `opencode debug
# skill`), pi (loadSkillsFromDir), and codex (documented). cursor's IDE follows them from
# 2.5; cursor-agent (CLI) has a known partial gap for link TARGETS outside .cursor/.claude
# — reported as a caveat on every run rather than worked around by duplicating links.
#
# NOT LINKABLE (reported with the reason on every run):
#   - MCP servers: they must live inside each harness's own config file, so there is
#     nothing for a symlink to point at. All four Claude sources are scanned:
#     ~/.claude.json, ~/.claude/settings.json, <project>/.mcp.json, <project>/.claude/
#     settings.json. Per harness: opencode needs a schema translation ({type, command[],
#     environment}) merged into opencode.jsonc (`--write-mcp`); cursor's mcp.json uses
#     Claude's own {command, args, env} shape, so `--write-mcp` merges it near-verbatim;
#     codex is TOML (config.toml) which is never machine-edited — `--mcp-snippet` prints
#     the [mcp_servers.*] block to paste. pi has no MCP support at all. Written entries
#     are regenerated from Claude on every run so Claude stays the single source of truth.
#   - Hooks / permissions in settings.json: no equivalent concept in any harness.
#   - Plugin hooks: opencode uses JS plugin handlers, pi uses TS extensions.
#   - Subagents for pi (no subagent concept) and codex (TOML agents, different schema).
#   - Cursor user rules set in the IDE settings UI: stored server-side, no file to link.
#     (The *global rules directory* IS a file surface — see below; only the UI-entered
#     rules are unreachable.)
#
# CURSOR GLOBAL INSTRUCTIONS (verified against cursor-agent 2026.09.02-c22c1a3):
#   LocalCursorRulesService.loadRulesFromDirAndAncestors walks cwd -> / and, at every
#   ancestor, loads <dir>/.cursor/rules/**/*.mdc (followSymlinks: true) plus CLAUDE.md,
#   CLAUDE.local.md and AGENTS.md. So:
#     - ~/.cursor/rules/*.mdc IS loaded, for any project under $HOME (a repo outside
#       $HOME never has ~ as an ancestor and will not see it — reported as a caveat).
#     - ~/.claude/CLAUDE.md is NOT loaded: only a bare CLAUDE.md at an ancestor directory
#       is, and ~/.claude is not an ancestor of a project. That is the real gap.
#   A plain symlink cannot close it: a rule is only always-on when its own frontmatter
#   says alwaysApply: true, and ~/.claude/CLAUDE.md has no frontmatter. So this is the
#   second generated shim (after the opencode agent shims): ~/.cursor/rules/
#   claude-global.mdc carries the frontmatter and *points at* the Claude files rather
#   than copying them, so the instructions can never go stale between runs. Extra files
#   (e.g. a --append-system-prompt-file passed to Claude Code) are added with
#   --cursor-append-prompt / $CURSOR_APPEND_PROMPT.
#
# Usage:
#   bin/claude-harness-sync.sh [--dry-run] [--no-prune] [--target all|opencode|pi|codex|cursor]
#                                 [--project DIR | --no-project] [--mcp-snippet] [--write-mcp]
#
# Safe by default: a plain run links what is missing and prunes only the stale links it
# owns. A link is "owned" iff it is a symlink whose target points inside one of this run's
# Claude source roots — real files and hand-made links are never touched.
#
# Env (used by the test suite to isolate from the real config; all default off $HOME):
#   CLAUDE_HOME_DIR      default $HOME/.claude
#   CLAUDE_PLUGINS_DIR   default $CLAUDE_HOME_DIR/plugins
#   AGENTS_SKILLS_DIR    default $HOME/.agents/skills
#   OPENCODE_CONFIG_DIR  default $HOME/.config/opencode
#   PI_AGENT_DIR         default $HOME/.pi/agent
#   CODEX_HOME_DIR       default $HOME/.codex
#   CURSOR_CONFIG_DIR    default $HOME/.cursor
#   CURSOR_APPEND_PROMPT default empty; extra instruction file(s) for the cursor rule
#                        shim, colon-separated (same content Claude Code gets via
#                        --append-system-prompt-file)

set -u

claude_home="${CLAUDE_HOME_DIR:-$HOME/.claude}"
plugins_dir="${CLAUDE_PLUGINS_DIR:-$claude_home/plugins}"
installed_json="$plugins_dir/installed_plugins.json"
agents_skills_dir="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
opencode_dir="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
pi_dir="${PI_AGENT_DIR:-$HOME/.pi/agent}"
codex_dir="${CODEX_HOME_DIR:-$HOME/.codex}"
cursor_dir="${CURSOR_CONFIG_DIR:-$HOME/.cursor}"
# Colon-separated so a single env var can carry more than one file, matching PATH-style
# convention; --cursor-append-prompt appends to it.
cursor_append_prompt="${CURSOR_APPEND_PROMPT:-}"
# Set once the user has stated an intent this run (a flag, or the env var), which is what
# distinguishes "no append files wanted" from "nothing said, keep what the rule already has".
cursor_append_explicit=0
[ -n "$cursor_append_prompt" ] && cursor_append_explicit=1

dry_run=0
prune=1
target="all"
project_root=""
no_project=0
mcp_snippet=0
write_mcp=0
report=0

usage() {
  cat <<'USAGE'
Make an existing Claude Code setup usable from opencode, pi, codex, and cursor, using
symlinks only. The Claude Code setup is the source of truth and is never modified.

  bin/claude-harness-sync.sh [--dry-run] [--no-prune] [--target all|opencode|pi|codex|cursor]
                                [--project DIR | --no-project] [--mcp-snippet] [--write-mcp]
                                [--cursor-append-prompt FILE]

Already auto-detected by a harness, so deliberately NOT linked:
  ~/.claude/skills/ + .claude/skills/  (opencode, cursor)
  ~/.claude/CLAUDE.md + ./CLAUDE.md    (opencode; cursor CLI reads the project one)
  ~/.claude/agents/ + .claude/agents/  (cursor)

Linked, because the harness does not scan them:
  plugin skills                 ->  ~/.agents/skills/   (opencode + pi + codex + cursor)
  ~/.claude/agents/*.md         ->  ~/.config/opencode/agent/
  ~/.claude/commands/*.md       ->  ~/.config/opencode/command/ + ~/.pi/agent/prompts/
                                    + ~/.cursor/commands/ + ~/.codex/prompts/
  ~/.claude/CLAUDE.md           ->  ~/.pi/agent/AGENTS.md + ~/.codex/AGENTS.md
  ~/.claude/CLAUDE.md           ->  ~/.cursor/rules/claude-global.mdc (generated pointer)
  plugin agents/*.md            ->  ~/.config/opencode/agent/ + ~/.cursor/agents/
  <project>/.claude/agents/*.md ->  <project>/.opencode/agent/
  <project>/.claude/commands/*.md -> <project>/.opencode/command/ + .pi/prompts/ + .cursor/commands/

  --dry-run       print the planned links and prunes, change nothing
  --no-prune      keep stale links instead of removing them
  --target        restrict destinations to one harness (default: all)
  --project DIR   also link that project's .claude/ (default: cwd when it has one)
  --no-project    skip project-level linking entirely
  --mcp-snippet   print per-harness MCP blocks (opencode jsonc, cursor mcp.json, codex TOML)
  --write-mcp     merge MCP servers into opencode.jsonc + cursor mcp.json (codex: snippet only)
  --cursor-append-prompt FILE
                  also point the cursor global rule at FILE (repeatable) — use it for the
                  file Claude Code gets via --append-system-prompt-file. Remembered in the
                  rule, so later runs keep it without repeating the flag
  --no-cursor-append-prompt
                  forget those files and regenerate the rule with CLAUDE.md alone
  --report        compare Claude's own inventory against what each harness loads, then exit
  -h, --help      this message

Default is safe: only symlinks pointing into a Claude source root are ever removed. Real
files, real directories, and hand-made links are reported and left alone.
USAGE
  exit "${1:-0}"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

# --- Verification report ----------------------------------------------------------------
# Compares what Claude Code says it has against what each harness actually loads. Claude's
# own CLI is the authority for the inventory (`claude plugin list/details`, `claude mcp
# list`) rather than this script's view of the filesystem — otherwise the report would just
# be marking its own homework.
in_list() {
  printf '%s\n' "$2" | grep -qxF "$1"
}

run_report() {
  command -v claude >/dev/null 2>&1 || die "claude CLI not found — needed for --report"
  local sk_json cfg_json oc_skills oc_agents oc_cmds oc_mcp oc_all pi_skills pi_prompts pi_all aliases alias fm d gaps=""

  # opencode's debug output is large; capture to files rather than a pipe, which truncates.
  sk_json=$(mktemp) || die "cannot create temp file"
  cfg_json=$(mktemp) || die "cannot create temp file"
  if command -v opencode >/dev/null 2>&1; then
    opencode debug skill >"$sk_json" 2>/dev/null
    opencode debug config >"$cfg_json" 2>/dev/null
  fi
  oc_skills=$(jq -r '..|objects|select(has("name"))|.name' "$sk_json" 2>/dev/null | sort -u)
  oc_agents=$(jq -r '.agent // {} | keys[]' "$cfg_json" 2>/dev/null | sort -u)
  oc_cmds=$(jq -r '.command // {} | keys[]' "$cfg_json" 2>/dev/null | sort -u)
  oc_mcp=$(jq -r '.mcp // {} | keys[]' "$cfg_json" 2>/dev/null | sort -u)

  # pi has no config dump, so read the directories its loader scans.
  pi_skills=$( { ls -1 "$agents_skills_dir" 2>/dev/null; ls -1 "$pi_dir/skills" 2>/dev/null; } | sort -u)
  pi_prompts=$(ls -1 "$pi_dir/prompts" 2>/dev/null | sed 's/\.md$//' | sort -u)

  oc_all=$(printf '%s\n%s\n%s\n%s\n' "$oc_skills" "$oc_agents" "$oc_cmds" "$oc_mcp" | grep -v '^$' | sort -u)
  pi_all=$(printf '%s\n%s\n' "$pi_skills" "$pi_prompts" | grep -v '^$' | sort -u)

  # Both harnesses register a skill under the `name:` in its SKILL.md, which is allowed to
  # differ from the directory name (atlassian ships jira-sprint-dashboard-canvas/ declaring
  # name: jira-sprint-dashboard). Claude reports the directory, so without this alias map
  # a perfectly-loaded skill looks missing.
  aliases=""
  for d in "$agents_skills_dir"/*/ "$claude_home"/skills/*/; do
    [ -f "$d/SKILL.md" ] || continue
    fm=$(sed -n 's/^name:[[:space:]]*//p' "$d/SKILL.md" | head -1 | tr -d '"'"'"'')
    [ -n "$fm" ] || continue
    aliases="$aliases$(basename "${d%/}")	$fm
"
  done

  printf '%-26s %-9s %-6s %-10s %-6s %s\n' PLUGIN COMPONENT COUNT "IN OPENCODE" "IN PI" STATUS
  printf '%s\n' "-------------------------------------------------------------------------------"

  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    local short="${pid%%@*}" details line kind names n_oc n_pi total status
    details=$(claude plugin details "$short" 2>/dev/null)
    [ -n "$details" ] || continue

    for kind in Skills Agents Commands "MCP servers"; do
      line=$(printf '%s\n' "$details" | grep -E "^  $kind \(" | head -1)
      [ -n "$line" ] || continue
      total=$(printf '%s' "$line" | sed -E 's/.*\(([0-9]+)\).*/\1/')
      [ "$total" -gt 0 ] 2>/dev/null || continue
      # Claude annotates some entries inline, e.g.
      #   MCP servers (1)  playwright  (tool schemas resolved at runtime; not counted)
      # so strip a trailing parenthetical or the name never matches anything downstream.
      names=$(printf '%s' "$line" | sed -E "s/^  $kind \([0-9]+\)[[:space:]]*//" \
        | tr ',' '\n' \
        | sed -E 's/[[:space:]]*\(.*\)[[:space:]]*$//; s/^ *//; s/ *$//' \
        | grep -v '^$')

      # Match against everything the harness loaded, not just the same-named bucket.
      # Claude's own taxonomy does not line up one-to-one: it counts a plugin's slash
      # commands as Skills, and those arrive downstream as opencode *commands*. Comparing
      # bucket-to-bucket reports those as missing when they are perfectly available.
      n_oc=0
      n_pi=0
      case "$kind" in
        Agents | "MCP servers") n_pi="-" ;;
      esac
      while IFS= read -r nm; do
        [ -n "$nm" ] || continue
        alias=$(printf '%s' "$aliases" | grep -F "$nm	" | head -1 | cut -f2)
        if in_list "$nm" "$oc_all" || { [ -n "$alias" ] && in_list "$alias" "$oc_all"; }; then
          n_oc=$((n_oc + 1))
        fi
        if [ "$n_pi" != "-" ] &&
           { in_list "$nm" "$pi_all" || { [ -n "$alias" ] && in_list "$alias" "$pi_all"; }; }; then
          n_pi=$((n_pi + 1))
        fi
      done <<NAMES
$names
NAMES

      status="ok"
      [ "$n_oc" != "$total" ] && status="GAP: $((total - n_oc)) missing"
      if [ "$status" != "ok" ]; then
        gaps="$gaps
  $short / $kind — opencode $n_oc of $total"
      fi
      printf '%-26s %-9s %-6s %-10s %-6s %s\n' \
        "$short" "$kind" "$total" "$n_oc" "$n_pi" "$status"
    done
  done <<PLUGINS
$(claude plugin list --json 2>/dev/null | jq -r '.[] | select(.enabled != false) | .id')
PLUGINS

  printf '%s\n' "-------------------------------------------------------------------------------"
  printf '%-26s %-9s %-6s %-10s %-6s\n' "TOTAL LOADED" "" "" \
    "$(printf '%s\n' "$oc_skills" | grep -c . )s/$(printf '%s\n' "$oc_agents" | grep -c .)a" \
    "$(printf '%s\n' "$pi_skills" | grep -c .)s"

  echo
  echo "harness totals:"
  printf '  opencode: %s skills, %s agents, %s commands, %s mcp servers\n' \
    "$(printf '%s\n' "$oc_skills" | grep -c .)" "$(printf '%s\n' "$oc_agents" | grep -c .)" \
    "$(printf '%s\n' "$oc_cmds" | grep -c .)" "$(printf '%s\n' "$oc_mcp" | grep -c .)"
  printf '  pi:       %s skills, %s prompts, global AGENTS.md %s\n' \
    "$(printf '%s\n' "$pi_skills" | grep -c .)" "$(printf '%s\n' "$pi_prompts" | grep -c .)" \
    "$([ -e "$pi_dir/AGENTS.md" ] && echo present || echo MISSING)"
  printf '  claude:   %s enabled plugins\n' \
    "$(claude plugin list --json 2>/dev/null | jq '[.[] | select(.enabled != false)] | length')"

  if [ -n "$gaps" ]; then
    printf '\ngaps (in Claude, not in the harness):%s\n' "$gaps"
    echo
    echo "run without --report to close them"
  else
    echo
    echo "no gaps — every enabled plugin's components are visible downstream"
  fi

  rm -f "$sk_json" "$cfg_json" 2>/dev/null
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --no-prune) prune=0 ;;
    --prune) prune=1 ;;
    --target)
      [ $# -ge 2 ] || die "--target needs a value (all|opencode|pi|codex|cursor)"
      target="$2"
      shift
      ;;
    --target=*) target="${1#--target=}" ;;
    --project)
      [ $# -ge 2 ] || die "--project needs a directory"
      project_root="$2"
      shift
      ;;
    --project=*) project_root="${1#--project=}" ;;
    --no-project) no_project=1 ;;
    --mcp-snippet) mcp_snippet=1 ;;
    --write-mcp) write_mcp=1 ;;
    --cursor-append-prompt)
      [ $# -ge 2 ] || die "--cursor-append-prompt needs a file"
      cursor_append_prompt="${cursor_append_prompt:+$cursor_append_prompt:}$2"
      cursor_append_explicit=1
      shift
      ;;
    --cursor-append-prompt=*)
      cursor_append_prompt="${cursor_append_prompt:+$cursor_append_prompt:}${1#--cursor-append-prompt=}"
      ;;
    --no-cursor-append-prompt) cursor_append_prompt=""; cursor_append_explicit=1 ;;
    --report) report=1 ;;
    -h | --help) usage 0 ;;
    *) printf 'error: unknown argument: %s\n\n' "$1" >&2; usage 1 ;;
  esac
  shift
done

case "$target" in
  all | opencode | pi | codex | cursor) ;;
  *) die "--target must be one of: all, opencode, pi, codex, cursor (got '$target')" ;;
esac

command -v jq >/dev/null 2>&1 || die "jq is required (brew install jq)"

if [ "$report" -eq 1 ]; then
  run_report
  exit 0
fi

# Default the project to the cwd, but only when it actually carries Claude config the
# harnesses cannot see — otherwise a run from an unrelated directory would say nothing.
if [ "$no_project" -eq 1 ]; then
  project_root=""
elif [ -z "$project_root" ]; then
  if [ -d "$PWD/.claude/agents" ] || [ -d "$PWD/.claude/commands" ]; then
    project_root="$PWD"
  fi
fi
[ -z "$project_root" ] || [ -d "$project_root" ] || die "--project directory not found: $project_root"

want_opencode=0
want_pi=0
want_codex=0
want_cursor=0
case "$target" in
  all) want_opencode=1; want_pi=1; want_codex=1; want_cursor=1 ;;
  opencode) want_opencode=1 ;;
  pi) want_pi=1 ;;
  codex) want_codex=1 ;;
  cursor) want_cursor=1 ;;
esac

# Plan lines: <kind>\t<src>\t<dst>. Built first, applied second; dst_file holds the same
# destinations one-per-line and doubles as the keep-list for pruning.
plan_file=$(mktemp) || die "cannot create temp file"
claim_file=$(mktemp) || die "cannot create temp file"
dst_file=$(mktemp) || die "cannot create temp file"
plugin_mcp_file=$(mktemp) || die "cannot create temp file"
# Removes only the three temp files this invocation just created.
trap 'rm -f "$plan_file" "$claim_file" "$dst_file" "$plugin_mcp_file"' EXIT INT TERM

linked=0
unchanged=0
pruned=0
skipped_plugins=0
collisions=""
conflicts=""
fixups=""
mcp_plugins=""
hook_plugins=""
shadowed=""
shimmed=0
shims=""

note() { printf '%s\n' "$1"; }

# The Claude roots this run links out of. A destination entry is ours to manage iff it is
# a symlink pointing inside one of them — which covers the plugin cache too, since that
# lives under ~/.claude. Anything pointing elsewhere is the user's own and is left alone.
source_roots="$claude_home"
[ -n "$project_root" ] && source_roots="$source_roots
$project_root/.claude"

# Reads the raw link text rather than resolving it, so broken links (the usual state after
# a plugin upgrade) are still recognised as owned and can be pruned.
is_owned_link() {
  local path="$1" link_target root
  [ -L "$path" ] || return 1
  link_target=$(readlink "$path" 2>/dev/null) || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    case "$link_target" in
      "$root"/*) return 0 ;;
    esac
  done <<EOF
$source_roots
EOF
  return 1
}

# A destination file is a shim of ours iff it carries the marker naming its Claude source.
is_own_shim() {
  [ -f "$1" ] && [ ! -L "$1" ] && grep -q "^# $SHIM_MARKER " "$1" 2>/dev/null
}

# Registers src -> <dir>/<name>, prefixing the name with the plugin when a *different*
# plugin already claimed it, so two plugins shipping review.md can coexist.
plan_link() {
  local kind="$1" plugin="$2" src="$3" dir="$4" name="$5"
  local dst owner

  dst="$dir/$name"
  owner=$(grep -F "	$dst	" "$claim_file" 2>/dev/null | head -1 | cut -f3)
  # Same plugin claiming the same destination twice (a manifest can list a plugin under
  # more than one scope). Keep the first — planning both would link, then immediately
  # relink, the same path and double-count it.
  [ "$owner" = "$plugin" ] && return 0
  if [ -n "$owner" ] && [ "$owner" != "$plugin" ]; then
    name="$plugin-$name"
    dst="$dir/$name"
    collisions="$collisions
  $kind '$owner' vs '$plugin' -> linked as $name"
  fi

  printf '%s\t%s\t%s\n' "$kind" "$src" "$dst" >>"$plan_file"
  printf '\t%s\t%s\n' "$dst" "$plugin" >>"$claim_file"
  printf '%s\n' "$dst" >>"$dst_file"
}

# Claude writes an agent's tools as a YAML sequence:   tools:
#                                                        - Bash
# opencode's schema demands a mapping ({Bash: true}) and *hard-fails startup* on anything
# else — one linked agent file takes the whole harness down. A symlink cannot fix a schema
# mismatch, so those agents get the smallest shim that works: the same file with only the
# tools block reshaped, regenerated from the Claude source on every run.
SHIM_MARKER="generated by claude-harness-sync.sh from"

translate_agent() {
  awk -v marker="$SHIM_MARKER" -v src="$1" '
    BEGIN { fm = 0; intools = 0 }
    /^---[ \t]*$/ {
      fm++
      intools = 0
      print
      if (fm == 1) print "# " marker " " src " — edit the source, not this file"
      next
    }
    fm == 1 {
      if (intools) {
        if ($0 ~ /^[ \t]*-[ \t]*/) {
          v = $0
          sub(/^[ \t]*-[ \t]*/, "", v)
          gsub(/^["'"'"']|["'"'"']$/, "", v)
          if (v != "") print "  " v ": true"
          next
        }
        if ($0 ~ /^[ \t]+[^ \t#]/) { print; next }
        intools = 0
      }
      # Claude writes plain colour names; opencode accepts only a hex code or its own
      # theme enum, and rejects anything else at startup. Map what maps, drop the rest —
      # colour is cosmetic, so losing it never costs behaviour.
      if ($0 ~ /^color:[ \t]*/) {
        v = $0
        sub(/^color:[ \t]*/, "", v)
        gsub(/^["'"'"' \t]+|["'"'"' \t]+$/, "", v)
        if (v ~ /^#[0-9a-fA-F]{6}$/ ||
            v == "primary" || v == "secondary" || v == "accent" ||
            v == "success" || v == "warning" || v == "error" || v == "info") {
          # Already valid — emit the original line untouched. Re-quoting a hex value
          # would turn it into a YAML comment, and rewriting an identical line would
          # force a pointless shim where a symlink works.
          print
        } else {
          lc = tolower(v)
          if (lc == "red") print "color: error"
          else if (lc == "orange" || lc == "yellow") print "color: warning"
          else if (lc == "green") print "color: success"
          else if (lc == "blue" || lc == "cyan") print "color: info"
          else if (lc == "purple" || lc == "magenta" || lc == "pink") print "color: accent"
          else if (lc == "gray" || lc == "grey") print "color: secondary"
        }
        next
      }
      if ($0 ~ /^tools:[ \t]*$/) { print "tools:"; intools = 1; next }
      if ($0 ~ /^tools:[ \t]*\[/) {
        v = $0
        sub(/^tools:[ \t]*\[/, "", v)
        sub(/\][ \t]*$/, "", v)
        print "tools:"
        n = split(v, a, ",")
        for (i = 1; i <= n; i++) {
          gsub(/^[ \t"'"'"']+|[ \t"'"'"']+$/, "", a[i])
          if (a[i] != "") print "  " a[i] ": true"
        }
        next
      }
      if ($0 ~ /^tools:[ \t]*[^ \t]/) {
        v = $0
        sub(/^tools:[ \t]*/, "", v)
        print "tools:"
        n = split(v, a, ",")
        for (i = 1; i <= n; i++) {
          gsub(/^[ \t]+|[ \t]+$/, "", a[i])
          if (a[i] != "") print "  " a[i] ": true"
        }
        next
      }
    }
    { print }
  ' "$1"
}

# A symlink is preferred whenever opencode can read the Claude file as-is. The test is
# simply whether translating changes anything beyond the marker line we add.
agent_needs_shim() {
  local src="$1"
  [ "$(translate_agent "$src" | grep -v "^# $SHIM_MARKER")" != "$(cat "$src")" ]
}

# Cursor's global-rule shim. A rule is only always-on when its OWN frontmatter says so,
# and ~/.claude/CLAUDE.md has none — so this file cannot be a symlink. It deliberately
# carries no copy of the instructions either: it names the Claude files and tells the
# agent to read them, so editing ~/.claude/CLAUDE.md takes effect immediately instead of
# at the next sync. Regenerated (and pruned) like any other shim.
render_cursor_rule() {
  local src="$1" f first=1
  cat <<MDC
---
description: Claude Code global instructions (generated by claude-harness-sync)
alwaysApply: true
---

# $SHIM_MARKER $src — edit the source, not this file

Before planning, answering a substantive question, editing a file, or running a command,
read these instruction files and follow them for the rest of the session. They are listed
in priority order — an earlier file wins a conflict with a later one.

MDC
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s. %s\n' "$first" "$f"
    first=$((first + 1))
  done <<FILES
$(cursor_rule_sources "$src")
FILES
  cat <<'MDC'

If a file cannot be read, continue with whichever of the others you could read, and say
which one was missing.
MDC
}

# The rule's targets, in priority order: the append-prompt files first (they are the
# outermost layer Claude Code itself applies via --append-system-prompt-file), then the
# global CLAUDE.md. Missing files are dropped rather than listed as broken.
cursor_rule_sources() {
  local claude_md="$1" rest="$cursor_append_prompt" one
  while [ -n "$rest" ]; do
    one="${rest%%:*}"
    [ "$one" = "$rest" ] && rest="" || rest="${rest#*:}"
    [ -n "$one" ] && [ -f "$one" ] && printf '%s\n' "$one"
  done
  printf '%s\n' "$claude_md"
}

# Shim kinds are content-generated rather than linked; each maps to its renderer.
render_shim() {
  case "$1" in
    agent-shim) translate_agent "$2" ;;
    cursor-rule) render_cursor_rule "$2" ;;
    *) return 1 ;;
  esac
}

is_shim_kind() {
  case "$1" in
    agent-shim | cursor-rule) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Build the plan: plain Claude config opencode does not scan -------------------------
# Planned BEFORE plugins so that when a plugin ships a command with the same filename, the
# user's own Claude config keeps the plain name and the plugin's copy gets the prefix. The
# Claude setup is the source of truth.
#
# Note what is absent here on purpose: ~/.claude/skills, .claude/skills, ~/.claude/CLAUDE.md
# and ./CLAUDE.md. opencode already discovers all four, so linking them would produce a
# second entry for one resource.
plan_compat_tree() {
  local owner="$1" root="$2" oc_agent_dir="$3" oc_cmd_dir="$4" pi_prompt_dir="$5"
  local cursor_cmd_dir="${6:-}" codex_prompt_dir="${7:-}" f

  # Agents from plain Claude config go to opencode only. Cursor scans ~/.claude/agents and
  # <project>/.claude/agents natively (documented compat dirs), so linking them for cursor
  # would show every agent twice; codex agents are TOML with a different schema, so a
  # symlink cannot serve them at all (reported in the not-migrated section).
  if [ "$want_opencode" -eq 1 ]; then
    for f in "$root"/agents/*.md; do
      [ -f "$f" ] || continue
      if agent_needs_shim "$f"; then
        plan_link agent-shim "$owner" "$f" "$oc_agent_dir" "$(basename "$f")"
      else
        plan_link agent "$owner" "$f" "$oc_agent_dir" "$(basename "$f")"
      fi
    done
  fi

  for f in "$root"/commands/*.md; do
    [ -f "$f" ] || continue
    [ "$want_opencode" -eq 1 ] && plan_link command "$owner" "$f" "$oc_cmd_dir" "$(basename "$f")"
    [ "$want_pi" -eq 1 ] && [ -n "$pi_prompt_dir" ] &&
      plan_link prompt "$owner" "$f" "$pi_prompt_dir" "$(basename "$f")"
    [ "$want_cursor" -eq 1 ] && [ -n "$cursor_cmd_dir" ] &&
      plan_link cursor-command "$owner" "$f" "$cursor_cmd_dir" "$(basename "$f")"
    # codex custom prompts are global-only (~/.codex/prompts), so the project call site
    # passes an empty dir here. Deprecated by codex in favor of skills, but still loaded.
    [ "$want_codex" -eq 1 ] && [ -n "$codex_prompt_dir" ] &&
      plan_link codex-prompt "$owner" "$f" "$codex_prompt_dir" "$(basename "$f")"
  done
}

plan_compat_tree "claude-user" "$claude_home" \
  "$opencode_dir/agent" "$opencode_dir/command" "$pi_dir/prompts" \
  "$cursor_dir/commands" "$codex_dir/prompts"

# The global CLAUDE.md: opencode reads ~/.claude/CLAUDE.md directly, so it needs nothing.
# pi does not — it loads ~/.pi/agent/AGENTS.md — so that one file is a real gap, and a
# symlink closes it with no copy. codex has the same gap: its global instructions live at
# ~/.codex/AGENTS.md and CLAUDE.md is not read natively (project-level CLAUDE.md can be
# opted into via project_doc_fallback_filenames in config.toml — a config change, not a
# link, so it is only reported). Cursor has no global instructions FILE at all (user rules
# live in the settings UI), and its CLI reads the project-root CLAUDE.md by itself.
if [ "$want_pi" -eq 1 ] && [ -f "$claude_home/CLAUDE.md" ]; then
  plan_link instructions "claude-user" "$claude_home/CLAUDE.md" "$pi_dir" "AGENTS.md"
fi
if [ "$want_codex" -eq 1 ] && [ -f "$claude_home/CLAUDE.md" ]; then
  plan_link instructions "claude-user" "$claude_home/CLAUDE.md" "$codex_dir" "AGENTS.md"
fi
# The append-prompt paths are remembered in the rule itself. Without this, a sync run from
# any shell that did not export $CURSOR_APPEND_PROMPT (a non-interactive shell, cron, a hook)
# would silently regenerate the rule without them — losing instructions the user had wired
# up, and churning the file for anyone keeping ~/.cursor/rules in git. The generated file is
# the state; --no-cursor-append-prompt is how you actually clear it.
if [ "$want_cursor" -eq 1 ] && [ "$cursor_append_explicit" -eq 0 ]; then
  cursor_prev_rule="$cursor_dir/rules/claude-global.mdc"
  if is_own_shim "$cursor_prev_rule"; then
    while IFS= read -r prev_path; do
      [ -n "$prev_path" ] || continue
      [ "$prev_path" = "$claude_home/CLAUDE.md" ] && continue
      cursor_append_prompt="${cursor_append_prompt:+$cursor_append_prompt:}$prev_path"
    done <<PREV
$(sed -n 's/^[0-9][0-9]*\. \(\/.*\)$/\1/p' "$cursor_prev_rule" 2>/dev/null)
PREV
  fi
fi

# cursor reads .cursor/rules/*.mdc at every ancestor of the cwd, so one generated rule in
# $HOME covers every project under it. See the CURSOR GLOBAL INSTRUCTIONS note at the top.
if [ "$want_cursor" -eq 1 ] && [ -f "$claude_home/CLAUDE.md" ]; then
  plan_link cursor-rule "claude-user" "$claude_home/CLAUDE.md" "$cursor_dir/rules" "claude-global.mdc"
fi

if [ -n "$project_root" ]; then
  # Project scope stays inside the project: opencode reads .opencode/, pi reads .pi/,
  # cursor reads .cursor/. codex gets nothing here — its prompts are global-only and its
  # project agents are TOML.
  plan_compat_tree "claude-project" "$project_root/.claude" \
    "$project_root/.opencode/agent" "$project_root/.opencode/command" "$project_root/.pi/prompts" \
    "$project_root/.cursor/commands" ""
fi

# A marketplace can be a local directory rather than a git checkout. Claude then reads
# that directory live, while installed_plugins.json still points at an older copy in the
# cache — so syncing from the cache silently ships a stale plugin (a skill added today
# would simply be missing downstream). Prefer the live path when one is declared.
live_plugin_root() {
  local plugin="$1" cache_path="$2" mkts="$plugins_dir/known_marketplaces.json" mpath sub
  [ -f "$mkts" ] || { printf '%s\n' "$cache_path"; return 0; }
  while IFS= read -r mpath; do
    [ -n "$mpath" ] && [ -d "$mpath" ] || continue
    sub=$(jq -r --arg n "$plugin" \
      '(.plugins // []) | map(select(.name == $n)) | .[0].source // empty' \
      "$mpath/.claude-plugin/marketplace.json" 2>/dev/null)
    [ -n "$sub" ] || continue
    sub=${sub#./}
    sub=${sub%/}
    if [ -n "$sub" ]; then
      [ -d "$mpath/$sub" ] && { printf '%s\n' "$mpath/$sub"; return 0; }
    else
      printf '%s\n' "$mpath"
      return 0
    fi
  done <<MKTS
$(jq -r 'to_entries[] | select(.value.source.source == "directory") | .value.source.path // empty' "$mkts" 2>/dev/null)
MKTS
  printf '%s\n' "$cache_path"
}

# A plugin may put its components somewhere other than the conventional directory by
# declaring a path in plugin.json ("skills": "./.claude/skills/"). ui-ux-pro-max does
# exactly that, and globbing only <root>/skills would silently share nothing from it.
# Emits the default directory plus every declared one; duplicates are harmless because
# plan_link ignores a destination the same plugin already claimed.
component_dirs() {
  local root="$1" key="$2" manifest="$1/.claude-plugin/plugin.json" p
  printf '%s\n' "$root/$key"
  [ -f "$manifest" ] || return 0
  jq -r --arg k "$key" '(.[$k] // empty) | if type == "array" then .[] else . end' \
    "$manifest" 2>/dev/null | while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in
      /*) printf '%s\n' "${p%/}" ;;
      *) printf '%s\n' "$root/$(printf '%s' "${p#./}" | sed 's|/$||')" ;;
    esac
  done
}

# --- Build the plan from the live plugin set ------------------------------------------
# installed_plugins.json is the only source of truth for which version is live. The cache
# also holds superseded copies (flagged with .orphaned_at); globbing it would link dead code.
[ -f "$installed_json" ] || note "no plugin manifest at $installed_json — skipping the plugin phase"
while IFS="	" read -r plugin_key install_path; do
  [ -n "$install_path" ] || continue
  plugin="${plugin_key%%@*}"

  if [ ! -d "$install_path" ]; then
    skipped_plugins=$((skipped_plugins + 1))
    note "skip $plugin: installPath missing ($install_path)"
    continue
  fi
  if [ -e "$install_path/.orphaned_at" ]; then
    skipped_plugins=$((skipped_plugins + 1))
    note "skip $plugin: superseded version (.orphaned_at)"
    continue
  fi

  resolved=$(live_plugin_root "$plugin" "$install_path")
  if [ "$resolved" != "$install_path" ]; then
    note "using live directory marketplace path for $plugin: $resolved"
    install_path="$resolved"
  fi

  while IFS= read -r sk_root; do
    [ -d "$sk_root" ] || continue
    for skill_dir in "$sk_root"/*/; do
      [ -f "$skill_dir/SKILL.md" ] || continue
      skill_dir="${skill_dir%/}"
      skill_name=$(basename "$skill_dir")
      # opencode already scans ~/.claude/skills. If a skill of this name is there too,
      # linking the plugin's copy into ~/.agents/skills would show opencode the same skill
      # twice — exactly the duplication this script exists to avoid.
      if [ -e "$claude_home/skills/$skill_name" ]; then
        shadowed="$shadowed
  $skill_name (from $plugin) — already visible via ~/.claude/skills"
        continue
      fi
      plan_link skill "$plugin" "$skill_dir" "$agents_skills_dir" "$skill_name"
      if grep -q 'CLAUDE_PLUGIN_ROOT' "$skill_dir/SKILL.md" 2>/dev/null; then
        fixups="$fixups
  $plugin/$skill_name"
      fi
    done
  done <<SKILLDIRS
$(component_dirs "$install_path" skills)
SKILLDIRS

  while IFS= read -r cmd_root; do
    [ -d "$cmd_root" ] || continue
    for cmd in "$cmd_root"/*.md; do
      [ -f "$cmd" ] || continue
      [ "$want_opencode" -eq 1 ] && plan_link command "$plugin" "$cmd" "$opencode_dir/command" "$(basename "$cmd")"
      [ "$want_pi" -eq 1 ] && plan_link prompt "$plugin" "$cmd" "$pi_dir/prompts" "$(basename "$cmd")"
      [ "$want_cursor" -eq 1 ] && plan_link cursor-command "$plugin" "$cmd" "$cursor_dir/commands" "$(basename "$cmd")"
      [ "$want_codex" -eq 1 ] && plan_link codex-prompt "$plugin" "$cmd" "$codex_dir/prompts" "$(basename "$cmd")"
    done
  done <<CMDDIRS
$(component_dirs "$install_path" commands)
CMDDIRS

  # pi has no subagent concept and codex agents are TOML (different schema) — so plugin
  # agents go to opencode (shimmed when the frontmatter needs it) and to cursor, which
  # accepts Claude-format agent markdown as-is (it reads .claude/agents natively; the
  # plugin cache is the one agents dir it cannot see).
  if [ "$want_opencode" -eq 1 ] || [ "$want_cursor" -eq 1 ]; then
    while IFS= read -r ag_root; do
      [ -d "$ag_root" ] || continue
      for agent in "$ag_root"/*.md; do
        [ -f "$agent" ] || continue
        if [ "$want_opencode" -eq 1 ]; then
          if agent_needs_shim "$agent"; then
            plan_link agent-shim "$plugin" "$agent" "$opencode_dir/agent" "$(basename "$agent")"
          else
            plan_link agent "$plugin" "$agent" "$opencode_dir/agent" "$(basename "$agent")"
          fi
        fi
        [ "$want_cursor" -eq 1 ] && plan_link cursor-agent "$plugin" "$agent" "$cursor_dir/agents" "$(basename "$agent")"
      done
    done <<AGENTDIRS
$(component_dirs "$install_path" agents)
AGENTDIRS
  fi

  [ -d "$install_path/hooks" ] && hook_plugins="$hook_plugins $plugin"
  # Plugin MCP servers are collected for the MCP merge further down; the path may be
  # declared in plugin.json, so resolve it the same way as the component directories.
  while IFS= read -r mcp_path; do
    [ -f "$mcp_path" ] || continue
    case " $mcp_plugins " in *" $plugin "*) ;; *) mcp_plugins="$mcp_plugins $plugin" ;; esac
    grep -qxF "$mcp_path	$install_path" "$plugin_mcp_file" 2>/dev/null ||
      printf '%s\t%s\n' "$mcp_path" "$install_path" >>"$plugin_mcp_file"
  done <<MCPFILES
$(component_dirs "$install_path" mcpServers | sed "s|/mcpServers$|/.mcp.json|")
MCPFILES
done <<EOF
$(jq -r '.plugins // {} | to_entries[] | .key as $k | .value[]? | [$k, (.installPath // "")] | @tsv' "$installed_json" 2>/dev/null)
EOF

# --- Apply -----------------------------------------------------------------------------
while IFS="	" read -r kind src dst; do
  [ -n "$kind" ] || continue
  dst_dir=$(dirname "$dst")

  if [ -L "$dst" ]; then
    if ! is_shim_kind "$kind" && [ "$(readlink "$dst" 2>/dev/null)" = "$src" ]; then
      unchanged=$((unchanged + 1))
      continue
    fi
    if ! is_owned_link "$dst"; then
      conflicts="$conflicts
  $dst (existing symlink not created by this script — left alone)"
      continue
    fi
  elif [ -e "$dst" ]; then
    # Our own regenerated shim may be overwritten; anything else is the user's content.
    if ! is_own_shim "$dst"; then
      conflicts="$conflicts
  $dst (real file/dir already there — left alone)"
      continue
    fi
    if is_shim_kind "$kind" && [ "$(render_shim "$kind" "$src")" = "$(cat "$dst")" ]; then
      unchanged=$((unchanged + 1))
      continue
    fi
  fi

  if [ "$dry_run" -eq 1 ]; then
    if is_shim_kind "$kind"; then
      note "would write shim $kind: $dst (from $src)"
    else
      note "would link $kind: $dst -> $src"
    fi
    linked=$((linked + 1))
    continue
  fi

  mkdir -p "$dst_dir" 2>/dev/null || { conflicts="$conflicts
  $dst_dir (cannot create directory)"; continue; }

  if is_shim_kind "$kind"; then
    # Replace a previous symlink for this destination — the raw Claude file is not
    # loadable there (opencode rejects the agent YAML; cursor ignores a rule with no
    # alwaysApply frontmatter).
    [ -L "$dst" ] && rm -- "$dst" 2>/dev/null
    if render_shim "$kind" "$src" >"$dst" 2>/dev/null; then
      shimmed=$((shimmed + 1))
      if [ "$kind" = "cursor-rule" ]; then
        shims="$shims
  $dst (from $src) — alwaysApply frontmatter added; points at the Claude files, no copy"
      else
        shims="$shims
  $dst (from $src) — tools: rewritten from a YAML list to a map"
      fi
    else
      conflicts="$conflicts
  $dst (could not write shim)"
    fi
    continue
  fi

  # -n so an existing dst symlink is replaced rather than dereferenced into.
  if ln -sfn "$src" "$dst" 2>/dev/null; then
    linked=$((linked + 1))
  else
    conflicts="$conflicts
  $dst (link failed)"
  fi
done <"$plan_file"

# --- Prune stale links we own -----------------------------------------------------------
# The usual case: a plugin upgraded, so last run's link points at a version path that is
# gone. Only symlinks into the cache are considered, so hand-made entries survive.
# Takes one directory as an argument rather than iterating a space-separated string —
# a $HOME containing a space would otherwise split into non-existent paths and silently
# prune nothing.
prune_dir() {
  local dir="$1" entry
  [ -d "$dir" ] || return 0
  for entry in "$dir"/* "$dir"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    is_owned_link "$entry" || is_own_shim "$entry" || continue
    # Still in this run's plan? Then it is current, keep it. -x so a link named as a
    # prefix of another destination is not mistaken for a planned one.
    grep -qxF "$entry" "$dst_file" 2>/dev/null && continue

    if [ "$dry_run" -eq 1 ]; then
      note "would prune stale entry: $entry"
    elif is_own_shim "$entry"; then
      # A generated file, not a link. Route it through trash so it stays recoverable.
      if command -v trash >/dev/null 2>&1; then
        trash "$entry" 2>/dev/null || continue
      else
        conflicts="$conflicts
  $entry (stale generated shim — install 'trash' or remove it by hand)"
        continue
      fi
    else
      # Guarded by is_owned_link, so this only ever unlinks a symlink we created —
      # the file it pointed at is untouched, nothing recoverable is destroyed.
      rm -- "$entry" 2>/dev/null || continue
    fi
    pruned=$((pruned + 1))
  done
}

if [ "$prune" -eq 1 ]; then
  prune_dir "$agents_skills_dir"
  if [ "$want_opencode" -eq 1 ]; then
    prune_dir "$opencode_dir/command"
    prune_dir "$opencode_dir/agent"
  fi
  [ "$want_pi" -eq 1 ] && prune_dir "$pi_dir/prompts"
  if [ "$want_cursor" -eq 1 ]; then
    prune_dir "$cursor_dir/commands"
    prune_dir "$cursor_dir/agents"
    # Only ever removes a .mdc carrying our marker — hand-written user rules stay.
    prune_dir "$cursor_dir/rules"
  fi
  [ "$want_codex" -eq 1 ] && prune_dir "$codex_dir/prompts"
  if [ -n "$project_root" ]; then
    if [ "$want_opencode" -eq 1 ]; then
      prune_dir "$project_root/.opencode/agent"
      prune_dir "$project_root/.opencode/command"
    fi
    [ "$want_pi" -eq 1 ] && prune_dir "$project_root/.pi/prompts"
    [ "$want_cursor" -eq 1 ] && prune_dir "$project_root/.cursor/commands"
  fi
fi

# --- Report -----------------------------------------------------------------------------
count_kind() { grep -c "^$1	" "$plan_file" 2>/dev/null | tr -d ' '; }

echo
[ "$dry_run" -eq 1 ] && echo "DRY RUN — nothing was changed"
printf 'planned: %s skills, %s opencode commands, %s pi prompts, %s opencode agents, %s cursor commands, %s cursor agents, %s cursor rules, %s codex prompts\n' \
  "$(count_kind skill)" "$(count_kind command)" "$(count_kind prompt)" "$(count_kind agent)" \
  "$(count_kind cursor-command)" "$(count_kind cursor-agent)" "$(count_kind cursor-rule)" \
  "$(count_kind codex-prompt)"
verb="applied"
[ "$dry_run" -eq 1 ] && verb="would apply"
printf '%s: %s linked, %s shimmed, %s already current, %s stale entries pruned, %s plugin entries skipped\n' \
  "$verb" "$linked" "$shimmed" "$unchanged" "$pruned" "$skipped_plugins"
printf 'targets: skills -> %s (opencode + pi + codex + cursor all scan it)\n' "$agents_skills_dir"

[ -n "$shims" ] && printf '\ncompatibility shims (symlink impossible — opencode hard-fails on Claude'"'"'s YAML list\nform for agent tools, and a cursor rule is only always-on when its own frontmatter says\nso; regenerated from the Claude source on every run):%s\n' "$shims"
[ -n "$shadowed" ] && printf '\nnot linked — opencode already sees an equally-named skill in ~/.claude/skills,\nso linking the plugin copy would duplicate it:%s\n' "$shadowed"
[ -n "$collisions" ] && printf '\nname collisions (prefixed with the plugin name):%s\n' "$collisions"
[ -n "$conflicts" ] && printf '\nleft alone (not ours to touch):%s\n' "$conflicts"
[ -n "$fixups" ] && printf '\nmay need manual fixup — these skills reference ${CLAUDE_PLUGIN_ROOT},\nwhich only Claude Code sets, so paths inside them will not resolve under opencode/pi:%s\n' "$fixups"

# Reports a Claude resource opencode finds by itself. Present/absent is shown so the line
# is honest about whether there was anything there to find.
report_auto() {
  local label="$1" path="$2" state="not present"
  { [ -e "$path" ] || [ -L "$path" ]; } && state="present"
  printf '  %-34s %s — auto-detected, deliberately not linked\n' "$label" "$state"
}

echo
echo "detected automatically by a harness (left untouched):"
report_auto "~/.claude/skills/ (opencode, cursor)" "$claude_home/skills"
report_auto "~/.claude/CLAUDE.md (opencode)" "$claude_home/CLAUDE.md"
report_auto "~/.claude/agents/ (cursor)" "$claude_home/agents"
if [ -n "$project_root" ]; then
  report_auto "<project>/.claude/skills/ (opencode, cursor)" "$project_root/.claude/skills"
  report_auto "<project>/CLAUDE.md (opencode, cursor CLI)" "$project_root/CLAUDE.md"
  report_auto "<project>/.claude/agents/ (cursor)" "$project_root/.claude/agents"
fi

echo
echo "not migrated (no linkable equivalent):"
[ -n "$hook_plugins" ] && echo "  hooks:$hook_plugins — opencode uses JS plugin handlers, pi uses TS extensions; codex/cursor have no plugin-hook concept"
[ -n "$mcp_plugins" ] && echo "  .mcp.json servers:$mcp_plugins — see --mcp-snippet / --write-mcp; pi has no MCP support"
echo "  subagents for pi (no subagent concept) and codex (TOML agents with a different schema — a symlink cannot convert them)"
echo "  cursor user rules entered in the IDE settings UI — stored server-side, no file to link"
echo "  codex project-level CLAUDE.md — opt in via project_doc_fallback_filenames in ~/.codex/config.toml (a config change, not a link)"
echo "  settings.json hooks/permissions — no equivalent concept in any harness"
if [ "$want_cursor" -eq 1 ]; then
  echo
  echo "cursor caveat: cursor-agent (CLI) has a known partial symlink-discovery bug — links whose"
  echo "  TARGETS live outside .cursor/ or .claude/ (e.g. a directory-source marketplace checkout)"
  echo "  may be missed by the CLI while the IDE (2.5+) sees them. Verify with cursor-agent once."
  if [ -f "$claude_home/CLAUDE.md" ]; then
    echo "cursor global rule: ~/.cursor/rules/*.mdc is read at every ancestor of the cwd, so the"
    echo "  generated claude-global.mdc only reaches projects UNDER \$HOME. A repo elsewhere needs"
    echo "  its own <repo>/.cursor/rules/ copy."
    if [ -n "$cursor_append_prompt" ]; then
      printf '  rule points at: %s\n' \
        "$(cursor_rule_sources "$claude_home/CLAUDE.md" | tr '\n' ' ')"
    else
      echo "  rule points at ~/.claude/CLAUDE.md only — add --cursor-append-prompt FILE (or set"
      echo "  \$CURSOR_APPEND_PROMPT) to include what Claude Code gets via --append-system-prompt-file"
    fi
  fi
fi

# --- MCP: the one thing a symlink genuinely cannot do -----------------------------------
# Claude's {command, args, env} and opencode's {type, command[], environment} are different
# shapes, and the servers have to live inside opencode.jsonc rather than in a file of their
# own — so there is nothing to point a symlink at. The translation is printed on demand and
# never written, so this stays a one-way shim instead of a second copy that drifts.
# Claude keeps MCP servers in more than one place: the global ~/.claude.json, the global
# settings.json, and per-project .mcp.json / .claude/settings.json. All of them are checked
# so a globally-configured server is never missed just because the project has none.
# Two shapes exist in the wild. ~/.claude.json and settings.json wrap the servers in an
# "mcpServers" key; a plugin's .mcp.json may do that (atlassian) or list servers bare at
# the top level (playwright, context7). Reading only the wrapped form silently drops the
# bare ones — which is exactly how the playwright MCP went missing.
# Emits a normalised {name: definition} object, with ${CLAUDE_PLUGIN_ROOT} resolved.
mcp_extract() {
  local file="$1" root="${2:-}" filter
  case "$file" in
    *.mcp.json)
      filter='if has("mcpServers") then .mcpServers
              else with_entries(select(.value | type == "object"
                                       and (has("command") or has("url")))) end' ;;
    *) filter='.mcpServers // {}' ;;
  esac
  jq --arg root "$root" "$filter"'
      | walk(if type == "string" and $root != "" then
               gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $root) else . end)' \
    "$file" 2>/dev/null
}

mcp_sources=""
add_mcp_source() {
  local n
  [ -f "$1" ] || return 0
  # A plugin can declare its .mcp.json explicitly *and* have it at the default path
  # (atlassian does), which would list the same servers twice.
  case "$mcp_sources" in *"$1	"*) return 0 ;; esac
  n=$(mcp_extract "$1" "${2:-}" | jq 'length' 2>/dev/null)
  [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
  mcp_sources="$mcp_sources$1	${2:-}
"
}
add_mcp_source "$HOME/.claude.json"
add_mcp_source "$claude_home/settings.json"
if [ -n "$project_root" ]; then
  add_mcp_source "$project_root/.mcp.json"
  add_mcp_source "$project_root/.claude/settings.json"
fi
# Plugin-provided servers (playwright, context7, atlassian) — collected during planning.
while IFS="	" read -r pmcp proot; do
  [ -n "$pmcp" ] || continue
  add_mcp_source "$pmcp" "$proot"
done <"$plugin_mcp_file"

# Claude's {command, args, env} -> opencode's {type, command[], environment}.
MCP_TRANSLATE='to_entries
  | map({key: .key, value: (
      if .value.command then
        {type: "local",
         command: ([.value.command] + (.value.args // [])),
         enabled: true,
         environment: (.value.env // {})}
      else
        {type: "remote", url: (.value.url // ""), enabled: true}
      end)})
  | from_entries'

mcp_translated=""
mcp_merged=""
if [ -n "$mcp_sources" ]; then
  echo
  echo "MCP servers found in Claude config (cannot be symlinked — lives inside each harness's config):"
  mcp_merged='{}'
  while IFS="	" read -r src root; do
    [ -n "$src" ] || continue
    printf '  %s: %s\n' "${src/#$HOME/~}" \
      "$(mcp_extract "$src" "$root" | jq -r 'keys | join(", ")')"
    mcp_merged=$(printf '%s' "$mcp_merged" |
      jq --argjson add "$(mcp_extract "$src" "$root")" '. + $add' 2>/dev/null)
  done <<EOF
$mcp_sources
EOF
  mcp_translated=$(printf '%s' "$mcp_merged" | jq "$MCP_TRANSLATE" 2>/dev/null)
  printf '  currently in opencode config: %s\n' \
    "$(jq -r '(.mcp // {}) | keys | join(", ") | if . == "" then "(none)" else . end' \
      "$opencode_dir/opencode.jsonc" 2>/dev/null || echo "(unreadable)")"
fi

# Claude's {command, args, env} -> codex's TOML [mcp_servers.<name>] tables. Printed only:
# config.toml routinely carries user comments and jq cannot round-trip TOML, so a machine
# merge would risk destroying the user's file. The shapes map 1:1 (env -> env_vars).
MCP_TO_CODEX_TOML='to_entries[]
  | "[mcp_servers.\(.key)]\n"
    + (if .value.command then
        "command = \(.value.command | @json)\n"
        + "args = \(.value.args // [] | @json)\n"
        + (if (.value.env // {} | length) > 0 then
            "env_vars = { " + (.value.env | to_entries | map("\(.key) = \(.value | @json)") | join(", ")) + " }\n"
          else "" end)
      else
        "url = \(.value.url // "" | @json)\n"
      end)'

if [ -n "$mcp_translated" ] && [ "$mcp_snippet" -eq 1 ]; then
  if [ "$want_opencode" -eq 1 ]; then
    echo
    echo "paste into $opencode_dir/opencode.jsonc (printed only — nothing written):"
    printf '%s\n' "$mcp_translated" | jq '{mcp: .}'
  fi
  if [ "$want_cursor" -eq 1 ]; then
    echo
    echo "paste into $cursor_dir/mcp.json (printed only — cursor's schema matches Claude's):"
    printf '%s\n' "$mcp_merged" | jq '{mcpServers: .}'
  fi
  if [ "$want_codex" -eq 1 ]; then
    echo
    echo "paste into $codex_dir/config.toml (printed only — TOML is never machine-edited):"
    printf '%s\n' "$mcp_merged" | jq -r "$MCP_TO_CODEX_TOML"
  fi
  # Snippet mode is print-only and always wins: clear the translation so the opencode
  # write block below can never fire in the same run, even when --write-mcp was also given.
  mcp_translated=""
elif [ -n "$mcp_translated" ] && [ "$write_mcp" -eq 1 ]; then
  # Cursor's mcp.json uses Claude's own {command, args, env} shape under mcpServers, so the
  # merged Claude set is written near-verbatim — regenerated from Claude config on every
  # run, same single-source-of-truth rule as the opencode merge below.
  if [ "$want_cursor" -eq 1 ]; then
    cursor_mcp="$cursor_dir/mcp.json"
    if [ "$dry_run" -eq 1 ]; then
      echo "  would merge $(printf '%s' "$mcp_merged" | jq -r 'keys | length') server(s) into $cursor_mcp"
    elif [ -s "$cursor_mcp" ] && ! jq -e . "$cursor_mcp" >/dev/null 2>&1; then
      echo "  $cursor_mcp is not valid JSON — not rewriting it. Use --mcp-snippet and paste by hand."
    else
      mkdir -p "$cursor_dir"
      tmp_cursor="$cursor_mcp.tmp.$$"
      if jq --argjson add "$mcp_merged" '. + {mcpServers: ((.mcpServers // {}) + $add)}' \
           "$cursor_mcp" 2>/dev/null >"$tmp_cursor" ||
         printf '%s' '{}' | jq --argjson add "$mcp_merged" '{mcpServers: $add}' >"$tmp_cursor" 2>/dev/null; then
        mv -f "$tmp_cursor" "$cursor_mcp"
        echo "  merged $(printf '%s' "$mcp_merged" | jq -r 'keys | length') server(s) into $cursor_mcp"
      else
        rm -f "$tmp_cursor" 2>/dev/null
        echo "  could not write $cursor_mcp — use --mcp-snippet and paste by hand"
      fi
    fi
  fi
  if [ "$want_codex" -eq 1 ]; then
    echo "  codex: config.toml is never machine-edited (TOML, may carry comments) — run --mcp-snippet and paste the [mcp_servers.*] block"
  fi
  [ "$want_opencode" -eq 1 ] || mcp_translated=""
fi
if [ -n "$mcp_translated" ] && [ "$write_mcp" -eq 1 ]; then
  oc_config="$opencode_dir/opencode.jsonc"
  if [ "$dry_run" -eq 1 ]; then
    echo "  would merge $(printf '%s' "$mcp_translated" | jq -r 'keys | length') server(s) into $oc_config"
  elif ! jq -e . "$oc_config" >/dev/null 2>&1 && [ -s "$oc_config" ]; then
    # jq cannot parse JSONC comments; rewriting would silently drop them.
    echo "  $oc_config has comments or is invalid JSON — not rewriting it."
    echo "  Re-run with --mcp-snippet and paste the block by hand."
  else
    mkdir -p "$opencode_dir"
    tmp_cfg="$oc_config.tmp.$$"
    if jq --argjson mcp "$mcp_translated" \
         '. + {mcp: ((.mcp // {}) + $mcp)}' \
         "$oc_config" 2>/dev/null >"$tmp_cfg" ||
       printf '%s' '{"$schema":"https://opencode.ai/config.json"}' |
         jq --argjson mcp "$mcp_translated" '. + {mcp: $mcp}' >"$tmp_cfg" 2>/dev/null; then
      mv -f "$tmp_cfg" "$oc_config"
      echo "  merged $(printf '%s' "$mcp_translated" | jq -r 'keys | length') server(s) into $oc_config"
      echo "  (regenerated from the Claude config on every run — do not hand-edit those entries)"
    else
      rm -f "$tmp_cfg" 2>/dev/null
      echo "  could not write $oc_config — re-run with --mcp-snippet and paste by hand"
    fi
  fi
elif [ -n "$mcp_translated" ] && [ "$mcp_snippet" -eq 0 ]; then
  echo "  --mcp-snippet prints per-harness blocks (opencode jsonc, cursor mcp.json, codex TOML);"
  echo "  --write-mcp merges into opencode.jsonc and cursor mcp.json (codex stays snippet-only)"
fi

exit 0
