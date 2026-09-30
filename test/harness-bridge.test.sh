#!/usr/bin/env bash
# Tests for harness-bridge.sh — the Claude Code resource bridge across harnesses.
#
# The invariants worth protecting are about *not destroying things*: the script writes into
# three directories the user also edits by hand (~/.agents/skills, ~/.config/opencode,
# ~/.pi/agent), so it must only ever remove symlinks it created, never a real file, never a
# hand-made link, and never a link belonging to a still-live plugin. The other half is
# correctness of version resolution — the plugin cache keeps superseded copies around, and
# linking a dead version silently serves stale skills to both harnesses.
#
# Every case runs against a throwaway fixture HOME. The real ~/.claude, ~/.config/opencode,
# ~/.pi, ~/.agents, and ~/.copilot are never read or written.
#
# Run: bash harness-bridge.test.sh
# Exits non-zero (and prints which case failed) if any assertion fails.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/harness-bridge.sh"

failures=0
pass_count=0

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: entire suite (jq not installed — the script hard-requires it)"
  exit 0
fi

assert_eq() {
  local description="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass_count=$((pass_count + 1))
    echo "PASS: $description"
  else
    failures=$((failures + 1))
    echo "FAIL: $description (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local description="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*)
      pass_count=$((pass_count + 1))
      echo "PASS: $description"
      ;;
    *)
      failures=$((failures + 1))
      echo "FAIL: $description (expected to contain '$needle')"
      ;;
  esac
}

assert_link_to() {
  local description="$1" link="$2" expected="$3" actual
  actual=$(readlink "$link" 2>/dev/null || echo "<not a link>")
  assert_eq "$description" "$expected" "$actual"
}

assert_missing() {
  local description="$1" path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    failures=$((failures + 1))
    echo "FAIL: $description ($path still exists)"
  else
    pass_count=$((pass_count + 1))
    echo "PASS: $description"
  fi
}

assert_exists() {
  local description="$1" path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    pass_count=$((pass_count + 1))
    echo "PASS: $description"
  else
    failures=$((failures + 1))
    echo "FAIL: $description ($path missing)"
  fi
}

# --- Fixture helpers --------------------------------------------------------------------

new_home() {
  local d
  d=$(mktemp -d)
  mkdir -p "$d/.claude/plugins/cache"
  printf '%s' "$d"
}

# add_plugin <home> <marketplace> <plugin> <version>
# Creates a cache dir for one plugin version. Content is added by the add_* helpers below.
add_plugin() {
  local home="$1" marketplace="$2" plugin="$3" version="$4"
  local path="$home/.claude/plugins/cache/$marketplace/$plugin/$version"
  mkdir -p "$path"
  printf '%s' "$path"
}

add_skill() {
  local install_path="$1" name="$2" body="${3:-a test skill}"
  mkdir -p "$install_path/skills/$name"
  printf -- '---\nname: %s\ndescription: %s\n---\n%s\n' "$name" "$body" "$body" \
    >"$install_path/skills/$name/SKILL.md"
}

add_command() {
  mkdir -p "$1/commands"
  printf -- '---\ndescription: %s\n---\nrun it\n' "$2" >"$1/commands/$2.md"
}

add_agent() {
  mkdir -p "$1/agents"
  printf -- '---\nname: %s\ndescription: %s\n---\nbe an agent\n' "$2" "$2" >"$1/agents/$2.md"
}

add_plugin_manifest() {
  jq -n --arg name "$2" '{name:$name,version:"1.0.0"}' >"$1/plugin.json"
}

# write_manifest <home> <plugin@marketplace> <installPath> [more pairs...]
write_manifest() {
  local home="$1"
  shift
  local json='{"version":2,"plugins":{}}'
  while [ $# -ge 2 ]; do
    json=$(printf '%s' "$json" | jq --arg k "$1" --arg p "$2" \
      '.plugins[$k] = [{"scope":"user","installPath":$p,"version":"test"}]')
    shift 2
  done
  printf '%s\n' "$json" >"$home/.claude/plugins/installed_plugins.json"
}

# --no-project by default so a case's result never depends on the cwd the suite runs from.
# Project-scope cases pass --project explicitly, which overrides it.
run_sync() {
  local home="$1"
  shift
  env -u CURSOR_APPEND_PROMPT -u HARNESS_GLOBAL_INSTRUCTIONS_DIR \
    -u COPILOT_HOME -u COPILOT_CONFIG_DIR \
    HOME="$home" bash "$SCRIPT" --no-project "$@" 2>&1
}

run_sync_raw() {
  local home="$1"
  shift
  env -u CURSOR_APPEND_PROMPT -u HARNESS_GLOBAL_INSTRUCTIONS_DIR \
    -u COPILOT_HOME -u COPILOT_CONFIG_DIR \
    HOME="$home" bash "$SCRIPT" "$@" 2>&1
}

add_instruction_bundle() {
  local home="$1" bundle
  bundle="$home/config/global-instructions"
  mkdir -p "$bundle"
  printf 'shared instructions\n' >"$bundle/shared.md"
  printf 'append instructions\n' >"$bundle/append.md"
  printf 'copilot instructions\n' >"$bundle/copilot.md"
  printf '%s\n' '---' 'alwaysApply: true' '---' 'cursor instructions' >"$bundle/cursor.md"
  ln -s "../config/global-instructions/shared.md" "$home/.claude/CLAUDE.md"
  (unset CDPATH; cd -P -- "$bundle" && pwd)
}

add_user_agent() {
  mkdir -p "$1/agents"
  printf -- '---\nname: %s\ndescription: %s\n---\nprompt\n' "$2" "$2" >"$1/agents/$2.md"
}

add_user_command() {
  mkdir -p "$1/commands"
  printf -- '---\ndescription: %s\n---\ndo it\n' "$2" >"$1/commands/$2.md"
}

add_user_skill() {
  mkdir -p "$1/skills/$2"
  printf -- '---\nname: %s\ndescription: %s\n---\nbody\n' "$2" "$2" >"$1/skills/$2/SKILL.md"
}

# --- Case 1: links resolve to the version named in the manifest, not whatever is in cache.
h=$(new_home)
old=$(add_plugin "$h" mp demo 1.0.0)
new=$(add_plugin "$h" mp demo 2.0.0)
add_skill "$old" alpha "old version"
add_skill "$new" alpha "new version"
write_manifest "$h" "demo@mp" "$new"
run_sync "$h" >/dev/null
assert_link_to "case1: skill links to the manifest's version" \
  "$h/.agents/skills/alpha" "$new/skills/alpha"

# --- Case 2: a superseded version (.orphaned_at) is skipped entirely.
h=$(new_home)
dead=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$dead" ghost
: >"$dead/.orphaned_at"
write_manifest "$h" "demo@mp" "$dead"
out=$(run_sync "$h")
assert_contains "case2: reports the skip" "superseded version" "$out"
assert_missing "case2: orphaned plugin's skill is not linked" "$h/.agents/skills/ghost"

# --- Case 2b: a manifest entry whose installPath is gone is skipped, not fatal.
h=$(new_home)
live=$(add_plugin "$h" mp good 1.0.0)
add_skill "$live" real
write_manifest "$h" "good@mp" "$live" "gone@mp" "$h/.claude/plugins/cache/mp/gone/9.9.9"
out=$(run_sync "$h")
assert_contains "case2b: reports the missing installPath" "installPath missing" "$out"
assert_exists "case2b: the live plugin still syncs" "$h/.agents/skills/real"

# --- Case 3: commands land in both harnesses, agents only in opencode.
h=$(new_home)
p=$(add_plugin "$h" mp tools 1.0.0)
add_command "$p" review
add_agent "$p" hunter
write_manifest "$h" "tools@mp" "$p"
run_sync "$h" >/dev/null
assert_link_to "case3: command -> opencode" \
  "$h/.config/opencode/command/review.md" "$p/commands/review.md"
assert_link_to "case3: command -> pi prompts" \
  "$h/.pi/agent/prompts/review.md" "$p/commands/review.md"
assert_link_to "case3: agent -> opencode" \
  "$h/.config/opencode/agent/hunter.md" "$p/agents/hunter.md"
assert_missing "case3: pi gets no agents dir" "$h/.pi/agent/agent"

# --- Case 3b: --target pi leaves opencode untouched.
h=$(new_home)
p=$(add_plugin "$h" mp tools 1.0.0)
add_command "$p" review
add_agent "$p" hunter
write_manifest "$h" "tools@mp" "$p"
run_sync "$h" --target pi >/dev/null
assert_exists "case3b: pi prompt linked" "$h/.pi/agent/prompts/review.md"
assert_missing "case3b: no opencode command written" "$h/.config/opencode/command/review.md"
assert_missing "case3b: no opencode agent written" "$h/.config/opencode/agent/hunter.md"

# --- Case 4: re-running is idempotent — no churn, no duplicates.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$p" alpha
write_manifest "$h" "demo@mp" "$p"
run_sync "$h" >/dev/null
out=$(run_sync "$h")
assert_contains "case4: second run reports nothing newly linked" "0 linked" "$out"
assert_contains "case4: second run reports the link as current" "1 already current" "$out"
count=$(find "$h/.agents/skills" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')
assert_eq "case4: no duplicate entries created" "1" "$count"

# --- Case 5: after a plugin upgrade the old owned link is pruned and replaced.
h=$(new_home)
v1=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$v1" alpha
add_skill "$v1" retired
write_manifest "$h" "demo@mp" "$v1"
run_sync "$h" >/dev/null
v2=$(add_plugin "$h" mp demo 2.0.0)
add_skill "$v2" alpha
write_manifest "$h" "demo@mp" "$v2"
out=$(run_sync "$h")
assert_link_to "case5: surviving skill repointed to the new version" \
  "$h/.agents/skills/alpha" "$v2/skills/alpha"
assert_missing "case5: link to a skill the new version dropped is pruned" \
  "$h/.agents/skills/retired"
assert_contains "case5: prune is reported" "1 stale entries pruned" "$out"

# --- Case 6: nothing the script does not own is ever removed or overwritten.
# A real directory, a real file, and a symlink pointing outside the plugin cache all survive
# a run that would otherwise want those exact names.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$p" alpha
add_command "$p" review
write_manifest "$h" "demo@mp" "$p"
mkdir -p "$h/.agents/skills/alpha" "$h/.config/opencode/command" "$h/elsewhere/handmade"
printf 'mine\n' >"$h/.agents/skills/alpha/SKILL.md"
printf 'mine\n' >"$h/.config/opencode/command/review.md"
ln -sfn "$h/elsewhere/handmade" "$h/.agents/skills/handmade"
out=$(run_sync "$h")
assert_eq "case6: hand-written skill content untouched" "mine" "$(cat "$h/.agents/skills/alpha/SKILL.md")"
assert_eq "case6: hand-written command untouched" "mine" "$(cat "$h/.config/opencode/command/review.md")"
assert_link_to "case6: hand-made link outside the cache survives pruning" \
  "$h/.agents/skills/handmade" "$h/elsewhere/handmade"
assert_contains "case6: conflicts are reported, not silently skipped" "left alone" "$out"

# --- Case 7: two plugins shipping the same name — the second gets a plugin prefix.
h=$(new_home)
a=$(add_plugin "$h" mp alpha-pack 1.0.0)
b=$(add_plugin "$h" mp beta-pack 1.0.0)
add_skill "$a" review
add_skill "$b" review
write_manifest "$h" "alpha-pack@mp" "$a" "beta-pack@mp" "$b"
out=$(run_sync "$h")
assert_link_to "case7: first claimant keeps the plain name" \
  "$h/.agents/skills/review" "$a/skills/review"
assert_link_to "case7: second is prefixed with its plugin" \
  "$h/.agents/skills/beta-pack-review" "$b/skills/review"
assert_contains "case7: collision reported" "name collisions" "$out"

# --- Case 8: --dry-run changes nothing on disk, including pruning.
h=$(new_home)
v1=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$v1" alpha
write_manifest "$h" "demo@mp" "$v1"
run_sync "$h" >/dev/null
v2=$(add_plugin "$h" mp demo 2.0.0)
add_skill "$v2" beta
write_manifest "$h" "demo@mp" "$v2"
out=$(run_sync "$h" --dry-run)
assert_contains "case8: dry run announces itself" "DRY RUN" "$out"
assert_contains "case8: dry run describes the link it would make" "would link skill" "$out"
assert_contains "case8: dry run describes the prune it would do" "would prune stale entry" "$out"
assert_link_to "case8: existing link left exactly as it was" \
  "$h/.agents/skills/alpha" "$v1/skills/alpha"
assert_missing "case8: planned link was not actually created" "$h/.agents/skills/beta"

# --- Case 8b: --no-prune keeps stale links.
h=$(new_home)
v1=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$v1" alpha
write_manifest "$h" "demo@mp" "$v1"
run_sync "$h" >/dev/null
v2=$(add_plugin "$h" mp demo 2.0.0)
add_skill "$v2" beta
write_manifest "$h" "demo@mp" "$v2"
run_sync "$h" --no-prune >/dev/null
assert_exists "case8b: --no-prune leaves the stale link in place" "$h/.agents/skills/alpha"

# --- Case 9: skills depending on ${CLAUDE_PLUGIN_ROOT} are flagged for manual fixup.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$p" plain
add_skill "$p" rooted
printf 'run bash "${CLAUDE_PLUGIN_ROOT}/hooks/x.sh"\n' >>"$p/skills/rooted/SKILL.md"
write_manifest "$h" "demo@mp" "$p"
out=$(run_sync "$h")
assert_contains "case9: flags the skill that needs fixup" "demo/rooted" "$out"
case "$out" in
  *"demo/plain"*)
    failures=$((failures + 1))
    echo "FAIL: case9: flagged a skill that does not reference CLAUDE_PLUGIN_ROOT"
    ;;
  *)
    pass_count=$((pass_count + 1))
    echo "PASS: case9: does not flag unaffected skills"
    ;;
esac

# --- Case 10: hooks and .mcp.json are reported as not migrated.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$p" alpha
mkdir -p "$p/hooks"
printf '{}' >"$p/.mcp.json"
write_manifest "$h" "demo@mp" "$p"
out=$(run_sync "$h")
assert_contains "case10: hooks reported as not migrated" "hooks: demo" "$out"
assert_contains "case10: mcp servers reported as not migrated" ".mcp.json servers: demo" "$out"

# --- Case 11: a directory without SKILL.md is not treated as a skill.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
mkdir -p "$p/skills/not-a-skill"
printf 'stray\n' >"$p/skills/not-a-skill/README.md"
add_skill "$p" alpha
write_manifest "$h" "demo@mp" "$p"
run_sync "$h" >/dev/null
assert_missing "case11: dir without SKILL.md is skipped" "$h/.agents/skills/not-a-skill"
assert_exists "case11: real skill still linked" "$h/.agents/skills/alpha"

# --- Case 12: no plugin manifest is a warning, not a failure — the Claude-compat half of
# the job still has to run for someone with no plugins installed at all.
h=$(new_home)
add_user_command "$h/.claude" solo
out=$(run_sync "$h")
status=$?
assert_eq "case12: missing manifest still exits 0" "0" "$status"
assert_contains "case12: missing manifest is reported" "no plugin manifest" "$out"
assert_exists "case12: compat linking still happened" "$h/.config/opencode/command/solo.md"

# --- Case 13: a HOME containing a space must still link *and* prune.
# Regression: pruning used to iterate a space-separated string of directories, so any space
# in the path split it into non-existent paths and stale links were silently never removed.
d=$(mktemp -d)
h="$d/home dir"
mkdir -p "$h/.claude/plugins/cache"
v1=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$v1" alpha
write_manifest "$h" "demo@mp" "$v1"
run_sync "$h" >/dev/null
assert_exists "case13: links into a HOME with a space" "$h/.agents/skills/alpha"
v2=$(add_plugin "$h" mp demo 2.0.0)
add_skill "$v2" beta
write_manifest "$h" "demo@mp" "$v2"
out=$(run_sync "$h")
assert_missing "case13: prunes inside a HOME with a space" "$h/.agents/skills/alpha"
assert_contains "case13: prune counted" "1 stale entries pruned" "$out"

# --- Case 14: one plugin listed twice in the manifest (e.g. user + managed scope) links once.
h=$(new_home)
p1=$(add_plugin "$h" mp demo 1.0.0)
p2=$(add_plugin "$h" mp demo 2.0.0)
add_skill "$p1" alpha
add_skill "$p2" alpha
jq -n --arg a "$p1" --arg b "$p2" \
  '{version:2,plugins:{"demo@mp":[{scope:"user",installPath:$a},{scope:"managed",installPath:$b}]}}' \
  >"$h/.claude/plugins/installed_plugins.json"
out=$(run_sync "$h")
assert_contains "case14: duplicate scope entry does not double-link" "1 linked" "$out"
count=$(find "$h/.agents/skills" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')
assert_eq "case14: exactly one entry on disk" "1" "$count"
case "$out" in
  *"name collisions"*)
    failures=$((failures + 1))
    echo "FAIL: case14: same plugin treated as a collision with itself"
    ;;
  *)
    pass_count=$((pass_count + 1))
    echo "PASS: case14: not reported as a collision"
    ;;
esac

# --- Case 15: global ~/.claude agents/commands are linked; skills and CLAUDE.md are NOT.
# This is the central anti-duplication invariant: opencode already discovers ~/.claude/skills
# and ~/.claude/CLAUDE.md, so linking them anywhere would give one resource two entries.
h=$(new_home)
add_user_agent "$h/.claude" my-agent
add_user_command "$h/.claude" my-cmd
add_user_skill "$h/.claude" my-skill
printf 'instructions\n' >"$h/.claude/CLAUDE.md"
write_manifest "$h"
out=$(run_sync "$h")
assert_link_to "case15: user agent -> opencode" \
  "$h/.config/opencode/agent/my-agent.md" "$h/.claude/agents/my-agent.md"
assert_link_to "case15: user command -> opencode" \
  "$h/.config/opencode/command/my-cmd.md" "$h/.claude/commands/my-cmd.md"
assert_link_to "case15: user command -> pi prompts" \
  "$h/.pi/agent/prompts/my-cmd.md" "$h/.claude/commands/my-cmd.md"
assert_missing "case15: auto-detected skill is NOT re-linked" "$h/.agents/skills/my-skill"
assert_missing "case15: CLAUDE.md is NOT linked into opencode" "$h/.config/opencode/AGENTS.md"
assert_contains "case15: report lists the auto-detected skills dir" "~/.claude/skills/" "$out"
assert_contains "case15: report lists auto-detected CLAUDE.md" "~/.claude/CLAUDE.md" "$out"

# --- Case 15b: the Claude source tree is never written to.
h=$(new_home)
add_user_agent "$h/.claude" my-agent
add_user_command "$h/.claude" my-cmd
write_manifest "$h"
before=$(find "$h/.claude" | sort | md5)
run_sync "$h" >/dev/null
after=$(find "$h/.claude" | sort | md5)
assert_eq "case15b: nothing added to or removed from ~/.claude" "$before" "$after"
assert_eq "case15b: no symlinks created inside ~/.claude" "0" \
  "$(find "$h/.claude" -type l | wc -l | tr -d ' ')"

# --- Case 16: project .claude/{agents,commands} link into the project's own .opencode/.
h=$(new_home)
proj="$h/work/repo"
mkdir -p "$proj/.claude"
add_user_agent "$proj/.claude" proj-agent
add_user_command "$proj/.claude" proj-cmd
write_manifest "$h"
run_sync_raw "$h" --project "$proj" >/dev/null
assert_link_to "case16: project agent -> project .opencode" \
  "$proj/.opencode/agent/proj-agent.md" "$proj/.claude/agents/proj-agent.md"
assert_link_to "case16: project command -> project .opencode" \
  "$proj/.opencode/command/proj-cmd.md" "$proj/.claude/commands/proj-cmd.md"
assert_link_to "case16: project command -> project .pi/prompts" \
  "$proj/.pi/prompts/proj-cmd.md" "$proj/.claude/commands/proj-cmd.md"
assert_missing "case16: project content does not leak into the global config" \
  "$h/.config/opencode/agent/proj-agent.md"

# --- Case 16b: --no-project skips project scope even when the cwd has Claude config.
h=$(new_home)
proj="$h/work/repo"
mkdir -p "$proj/.claude"
add_user_agent "$proj/.claude" proj-agent
write_manifest "$h"
(cd "$proj" && HOME="$h" bash "$SCRIPT" --no-project >/dev/null 2>&1)
assert_missing "case16b: --no-project links nothing for the project" "$proj/.opencode/agent/proj-agent.md"

# --- Case 16c: with no flag, a cwd carrying .claude/agents is picked up automatically.
h=$(new_home)
proj="$h/work/repo"
mkdir -p "$proj/.claude"
add_user_agent "$proj/.claude" proj-agent
write_manifest "$h"
(cd "$proj" && HOME="$h" bash "$SCRIPT" >/dev/null 2>&1)
assert_exists "case16c: cwd project auto-detected" "$proj/.opencode/agent/proj-agent.md"

# --- Case 17: the user's own Claude command outranks a plugin shipping the same name.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_command "$p" review
add_user_command "$h/.claude" review
write_manifest "$h" "demo@mp" "$p"
out=$(run_sync "$h")
assert_link_to "case17: user's command keeps the plain name" \
  "$h/.config/opencode/command/review.md" "$h/.claude/commands/review.md"
assert_link_to "case17: plugin's copy is prefixed" \
  "$h/.config/opencode/command/demo-review.md" "$p/commands/review.md"

# --- Case 18: a compat link is pruned once its Claude source file is gone.
h=$(new_home)
add_user_command "$h/.claude" temporary
write_manifest "$h"
run_sync "$h" >/dev/null
assert_exists "case18: linked while the source exists" "$h/.config/opencode/command/temporary.md"
mv "$h/.claude/commands/temporary.md" "$h/removed.md"
out=$(run_sync "$h")
assert_missing "case18: pruned once the source is gone" "$h/.config/opencode/command/temporary.md"
assert_missing "case18: pi prompt pruned too" "$h/.pi/agent/prompts/temporary.md"
assert_missing "case18: cursor command pruned too" "$h/.cursor/commands/temporary.md"
assert_missing "case18: codex prompt pruned too" "$h/.codex/prompts/temporary.md"
# One command produced four links (opencode + pi + cursor + codex), so all four are pruned.
assert_contains "case18: prune reported" "4 stale entries pruned" "$out"

# --- Case 19: --mcp-snippet translates Claude's schema and writes nothing.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"ctx7":{"command":"npx","args":["-y","ctx7"],"env":{"K":"v"}}}}' \
  >"$h/.claude.json"
out=$(run_sync "$h" --mcp-snippet)
assert_contains "case19: emits opencode's local type" '"type": "local"' "$out"
assert_contains "case19: folds command+args into one array" '"npx"' "$out"
assert_contains "case19: renames env to environment" '"environment"' "$out"
assert_missing "case19: no opencode.jsonc was written" "$h/.config/opencode/opencode.jsonc"
out=$(run_sync "$h")
assert_contains "case19: without a flag it only points at the options" "--mcp-snippet prints" "$out"

# --- Case 19b: MCP servers configured only in ~/.claude/settings.json are still found.
# Claude stores them in more than one file; missing this one loses the global servers.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"only-in-settings":{"command":"srv"}}}' >"$h/.claude/settings.json"
out=$(run_sync "$h")
assert_contains "case19b: global settings.json is scanned for MCP" "only-in-settings" "$out"
assert_contains "case19b: source file named in the report" ".claude/settings.json" "$out"

# --- Case 19c: servers from both global files are merged, and --write-mcp lands them in
# opencode's config in opencode's own schema.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"from-claude-json":{"command":"a","args":["x"],"env":{"K":"v"}}}}' >"$h/.claude.json"
printf '%s\n' '{"mcpServers":{"from-settings":{"command":"b"}}}' >"$h/.claude/settings.json"
printf '%s\n' '{"$schema":"https://opencode.ai/config.json"}' >"$h/.config/opencode/opencode.jsonc"
mkdir -p "$h/.config/opencode"
printf '%s\n' '{"$schema":"https://opencode.ai/config.json"}' >"$h/.config/opencode/opencode.jsonc"
run_sync "$h" --write-mcp >/dev/null
merged=$(jq -r '.mcp | keys | join(",")' "$h/.config/opencode/opencode.jsonc" 2>/dev/null)
assert_eq "case19c: both global sources merged into opencode config" "from-claude-json,from-settings" "$merged"
assert_eq "case19c: command and args folded into one array" '["a","x"]' \
  "$(jq -c '.mcp["from-claude-json"].command' "$h/.config/opencode/opencode.jsonc")"
assert_eq "case19c: existing keys preserved" "https://opencode.ai/config.json" \
  "$(jq -r '.["$schema"]' "$h/.config/opencode/opencode.jsonc")"
run_sync "$h" --write-mcp >/dev/null
assert_eq "case19c: re-running does not duplicate" "from-claude-json,from-settings" \
  "$(jq -r '.mcp | keys | join(",")' "$h/.config/opencode/opencode.jsonc")"

# --- Case 19d: a JSONC config with real comments is never rewritten (jq would eat them).
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"srv":{"command":"a"}}}' >"$h/.claude.json"
mkdir -p "$h/.config/opencode"
printf '%s\n' '{' '  // keep me' '  "$schema": "https://opencode.ai/config.json"' '}' \
  >"$h/.config/opencode/opencode.jsonc"
out=$(run_sync "$h" --write-mcp)
assert_contains "case19d: refuses to rewrite a commented config" "has comments or is invalid JSON" "$out"
assert_contains "case19d: the comment survives" "// keep me" "$(cat "$h/.config/opencode/opencode.jsonc")"

# --- Case 20: a plugin skill is not linked when ~/.claude/skills already has that name.
# opencode scans ~/.claude/skills itself, so linking the plugin copy into ~/.agents/skills
# would show it the same skill twice.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$p" candlekeep
add_skill "$p" unique-one
add_user_skill "$h/.claude" candlekeep
write_manifest "$h" "demo@mp" "$p"
out=$(run_sync "$h")
assert_missing "case20: shadowed plugin skill is not linked" "$h/.agents/skills/candlekeep"
assert_exists "case20: unshadowed plugin skill still linked" "$h/.agents/skills/unique-one"
assert_contains "case20: shadowing is explained" "already visible via ~/.claude/skills" "$out"

# --- Case 21: an agent whose tools are a YAML list gets a shim, not a symlink.
# opencode's schema wants a mapping and hard-fails startup on a list, so symlinking the
# Claude file verbatim takes the whole harness down. Agents opencode can already read are
# still symlinked — a shim is only used where a link cannot work.
h=$(new_home)
write_manifest "$h"
mkdir -p "$h/.claude/agents"
printf -- '---\nname: listy\ndescription: uses a yaml list\nmodel: sonnet\ntools:\n  - Bash\n  - Read\n---\nBody stays intact.\n' \
  >"$h/.claude/agents/listy.md"
printf -- '---\nname: plain\ndescription: no tools key\n---\nBody.\n' >"$h/.claude/agents/plain.md"
out=$(run_sync "$h")
assert_link_to "case21: compatible agent is still a symlink" \
  "$h/.config/opencode/agent/plain.md" "$h/.claude/agents/plain.md"
shim="$h/.config/opencode/agent/listy.md"
if [ -L "$shim" ]; then
  failures=$((failures + 1))
  echo "FAIL: case21: incompatible agent was symlinked instead of shimmed"
else
  pass_count=$((pass_count + 1))
  echo "PASS: case21: incompatible agent is a generated file, not a link"
fi
assert_contains "case21: tools rewritten as a map" "  Bash: true" "$(cat "$shim")"
assert_contains "case21: second tool kept" "  Read: true" "$(cat "$shim")"
assert_contains "case21: body preserved" "Body stays intact." "$(cat "$shim")"
assert_contains "case21: shim names its source" "$h/.claude/agents/listy.md" "$(cat "$shim")"
assert_contains "case21: shim reported" "compatibility shims" "$out"
assert_eq "case21: source file untouched" "  - Bash" \
  "$(grep -m1 -- '- Bash' "$h/.claude/agents/listy.md")"

# --- Case 21b: re-running does not rewrite an up-to-date shim, and a stale one is pruned.
out=$(run_sync "$h")
assert_contains "case21b: shim recognised as current on re-run" "already current" "$out"
mv "$h/.claude/agents/listy.md" "$h/listy-removed.md"
out=$(run_sync "$h")
if command -v trash >/dev/null 2>&1; then
  assert_missing "case21b: orphaned shim pruned once its source is gone" "$shim"
else
  assert_contains "case21b: orphaned shim reported when trash is unavailable" "stale generated shim" "$out"
fi

# --- Case 22: colour names Claude uses are mapped to opencode's theme enum, and an
# unmappable one is dropped rather than left to fail opencode's startup validation.
h=$(new_home)
write_manifest "$h"
mkdir -p "$h/.claude/agents"
printf -- '---\nname: c1\ndescription: d\ncolor: red\n---\nb\n' >"$h/.claude/agents/c1.md"
printf -- '---\nname: c2\ndescription: d\ncolor: chartreuse\n---\nb\n' >"$h/.claude/agents/c2.md"
printf -- '---\nname: c3\ndescription: d\ncolor: "#ff5733"\n---\nb\n' >"$h/.claude/agents/c3.md"
printf -- '---\nname: c4\ndescription: d\ncolor: success\n---\nb\n' >"$h/.claude/agents/c4.md"
run_sync "$h" >/dev/null
assert_contains "case22: red -> error" "color: error" "$(cat "$h/.config/opencode/agent/c1.md")"
case "$(cat "$h/.config/opencode/agent/c2.md")" in
  *color:*)
    failures=$((failures + 1))
    echo "FAIL: case22: unmappable colour was kept and will fail opencode validation"
    ;;
  *)
    pass_count=$((pass_count + 1))
    echo "PASS: case22: unmappable colour dropped"
    ;;
esac
assert_link_to "case22: valid hex needs no shim, stays a symlink" \
  "$h/.config/opencode/agent/c3.md" "$h/.claude/agents/c3.md"
assert_link_to "case22: already-valid enum stays a symlink" \
  "$h/.config/opencode/agent/c4.md" "$h/.claude/agents/c4.md"

# --- Case 23: the inline flow-sequence form of tools is translated too.
h=$(new_home)
write_manifest "$h"
mkdir -p "$h/.claude/agents"
printf -- '---\nname: inline\ndescription: d\ntools: [Bash, Read]\n---\nb\n' >"$h/.claude/agents/inline.md"
run_sync "$h" >/dev/null
assert_contains "case23: inline list translated" "  Bash: true" "$(cat "$h/.config/opencode/agent/inline.md")"
assert_contains "case23: second inline entry translated" "  Read: true" "$(cat "$h/.config/opencode/agent/inline.md")"

# --- Case 24: a user command reaches cursor and codex alongside opencode and pi.
h=$(new_home)
add_user_command "$h/.claude" everywhere
write_manifest "$h"
run_sync "$h" >/dev/null
assert_link_to "case24: cursor command linked" \
  "$h/.cursor/commands/everywhere.md" "$h/.claude/commands/everywhere.md"
assert_link_to "case24: codex prompt linked" \
  "$h/.codex/prompts/everywhere.md" "$h/.claude/commands/everywhere.md"

# --- Case 25: global CLAUDE.md reaches codex as AGENTS.md; a real file there is never touched.
h=$(new_home)
printf 'my global instructions\n' >"$h/.claude/CLAUDE.md"
write_manifest "$h"
run_sync "$h" >/dev/null
assert_link_to "case25: codex AGENTS.md linked from CLAUDE.md" \
  "$h/.codex/AGENTS.md" "$h/.claude/CLAUDE.md"
h=$(new_home)
printf 'my global instructions\n' >"$h/.claude/CLAUDE.md"
mkdir -p "$h/.codex"
printf 'hand-written codex instructions\n' >"$h/.codex/AGENTS.md"
write_manifest "$h"
out=$(run_sync "$h")
assert_eq "case25: pre-existing real AGENTS.md untouched" \
  "hand-written codex instructions" "$(cat "$h/.codex/AGENTS.md")"
assert_contains "case25: conflict reported" "left alone" "$out"

# --- Case 26: plugin agents reach cursor as plain symlinks (raw Claude markdown), even
# when the same agent needs a rewritten shim for opencode.
h=$(new_home)
p=$(add_plugin "$h" mp toolkit 1.0.0)
mkdir -p "$p/agents"
printf -- '---\nname: helper\ndescription: d\ntools:\n  - Bash\n---\nbody\n' >"$p/agents/helper.md"
write_manifest "$h" "toolkit@mp" "$p"
run_sync "$h" >/dev/null
assert_link_to "case26: cursor agent is a plain symlink to the raw file" \
  "$h/.cursor/agents/helper.md" "$p/agents/helper.md"
assert_contains "case26: opencode copy is the shim" "Bash: true" "$(cat "$h/.config/opencode/agent/helper.md")"

# --- Case 27: --target codex restricts destinations to codex only.
h=$(new_home)
add_user_command "$h/.claude" scoped
printf 'global\n' >"$h/.claude/CLAUDE.md"
write_manifest "$h"
run_sync "$h" --target codex >/dev/null
assert_exists "case27: codex prompt linked" "$h/.codex/prompts/scoped.md"
assert_exists "case27: codex AGENTS.md linked" "$h/.codex/AGENTS.md"
assert_missing "case27: no opencode command" "$h/.config/opencode/command/scoped.md"
assert_missing "case27: no cursor command" "$h/.cursor/commands/scoped.md"
assert_missing "case27: no pi prompt" "$h/.pi/agent/prompts/scoped.md"

# --- Case 28: --write-mcp merges Claude-shaped servers into cursor's mcp.json.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"ctx7":{"command":"npx","args":["-y","ctx7"],"env":{"K":"v"}}}}' \
  >"$h/.claude.json"
run_sync "$h" --write-mcp >/dev/null
assert_eq "case28: cursor mcp.json carries the server in Claude shape" \
  "npx" "$(jq -r '.mcpServers.ctx7.command' "$h/.cursor/mcp.json" 2>/dev/null)"
assert_eq "case28: env preserved verbatim" \
  "v" "$(jq -r '.mcpServers.ctx7.env.K' "$h/.cursor/mcp.json" 2>/dev/null)"

# --- Case 29: --mcp-snippet prints a codex TOML block; nothing is written to config.toml.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"ctx7":{"command":"npx","args":["-y","ctx7"],"env":{"K":"v"}}}}' \
  >"$h/.claude.json"
out=$(run_sync "$h" --mcp-snippet)
assert_contains "case29: TOML server table printed" "[mcp_servers.ctx7]" "$out"
assert_contains "case29: env translated to env_vars" 'env_vars = { K = "v" }' "$out"
assert_missing "case29: config.toml never written" "$h/.codex/config.toml"

# --- Case 30: plain ~/.claude/agents is NOT linked for cursor — cursor scans it natively,
# and a link would show every agent twice.
h=$(new_home)
add_user_agent "$h/.claude" native
write_manifest "$h"
run_sync "$h" >/dev/null
assert_missing "case30: no cursor link for plain claude agents" "$h/.cursor/agents/native.md"

# --- Case 31: --mcp-snippet is print-only even when --write-mcp is also given — snippet
# mode always wins, for every harness.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"ctx7":{"command":"npx","args":["-y","ctx7"]}}}' >"$h/.claude.json"
out=$(run_sync "$h" --mcp-snippet --write-mcp)
assert_contains "case31: snippet still printed" "[mcp_servers.ctx7]" "$out"
assert_missing "case31: opencode.jsonc never written" "$h/.config/opencode/opencode.jsonc"
assert_missing "case31: cursor mcp.json never written" "$h/.cursor/mcp.json"
assert_missing "case31: codex config.toml never written" "$h/.codex/config.toml"

# --- Case 32: cursor's global-instructions gap is closed by a generated .mdc rule —
# frontmatter is mandatory for an always-on rule, so a symlink cannot do it. The rule must
# POINT at the Claude files, never copy them, or it goes stale between runs.
h=$(new_home)
write_manifest "$h"
printf 'global claude rules\n' >"$h/.claude/CLAUDE.md"
run_sync "$h" --target cursor >/dev/null
rule="$h/.cursor/rules/claude-global.mdc"
assert_exists "case32: cursor global rule written" "$rule"
assert_eq "case32: frontmatter starts the file" "---" "$(head -1 "$rule")"
assert_contains "case32: rule is always-on" "alwaysApply: true" "$(cat "$rule")"
assert_contains "case32: rule points at the Claude file" "$h/.claude/CLAUDE.md" "$(cat "$rule")"
assert_eq "case32: instructions are referenced, not copied" \
  "" "$(grep -c 'global claude rules' "$rule" | tr -d ' ' | sed 's/^0$//')"
assert_contains "case32: shim marker present so prune can own it" \
  "generated by harness-bridge.sh from" "$(cat "$rule")"

# --- Case 33: --cursor-append-prompt adds a file ahead of CLAUDE.md, and a missing one is
# dropped rather than listed as a broken path.
h=$(new_home)
write_manifest "$h"
printf 'global\n' >"$h/.claude/CLAUDE.md"
printf 'be concise\n' >"$h/append.md"
run_sync "$h" --target cursor --cursor-append-prompt "$h/append.md" \
  --cursor-append-prompt "$h/nope.md" >/dev/null
rule="$h/.cursor/rules/claude-global.mdc"
assert_contains "case33: append prompt listed first" "1. $h/append.md" "$(cat "$rule")"
assert_contains "case33: CLAUDE.md listed second" "2. $h/.claude/CLAUDE.md" "$(cat "$rule")"
assert_eq "case33: missing file omitted" \
  "" "$(grep -c 'nope.md' "$rule" | tr -d ' ' | sed 's/^0$//')"

# --- Case 34: the rule is regenerated when its inputs change, left alone when they do not,
# and pruned when CLAUDE.md disappears — without touching a hand-written user rule.
h=$(new_home)
write_manifest "$h"
printf 'global\n' >"$h/.claude/CLAUDE.md"
mkdir -p "$h/.cursor/rules"
printf -- '---\nalwaysApply: true\n---\nmy own rule\n' >"$h/.cursor/rules/mine.mdc"
run_sync "$h" --target cursor >/dev/null
out=$(run_sync "$h" --target cursor)
assert_contains "case34: second run is a no-op" "0 shimmed, 1 already current" "$out"
rm -f "$h/.claude/CLAUDE.md"
out=$(run_sync "$h" --target cursor)
assert_missing "case34: rule pruned once CLAUDE.md is gone" "$h/.cursor/rules/claude-global.mdc"
assert_exists "case34: hand-written user rule untouched" "$h/.cursor/rules/mine.mdc"

# --- Case 35: no cursor rule for the other harnesses.
h=$(new_home)
write_manifest "$h"
printf 'global\n' >"$h/.claude/CLAUDE.md"
run_sync "$h" --target opencode >/dev/null
assert_missing "case35: --target opencode writes no cursor rule" "$h/.cursor/rules/claude-global.mdc"

# --- Case 36: the append-prompt paths survive a run that does not mention them. Without
# this, any sync from a shell missing $CURSOR_APPEND_PROMPT (cron, a hook, a non-interactive
# shell) would silently drop instructions the user had wired up.
h=$(new_home)
write_manifest "$h"
printf 'global\n' >"$h/.claude/CLAUDE.md"
printf 'be concise\n' >"$h/append.md"
run_sync "$h" --target cursor --cursor-append-prompt "$h/append.md" >/dev/null
out=$(run_sync "$h" --target cursor)
rule="$h/.cursor/rules/claude-global.mdc"
assert_contains "case36: append prompt carried forward" "1. $h/append.md" "$(cat "$rule")"
assert_contains "case36: carry-forward is a no-op, not a rewrite" "0 shimmed, 1 already current" "$out"

# --- Case 37: --no-cursor-append-prompt is the way to actually clear them.
run_sync "$h" --target cursor --no-cursor-append-prompt >/dev/null
assert_eq "case37: append prompt cleared on request" \
  "" "$(grep -c 'append.md' "$rule" | tr -d ' ' | sed 's/^0$//')"
assert_contains "case37: CLAUDE.md still listed" "1. $h/.claude/CLAUDE.md" "$(cat "$rule")"

# --- Case 38: an explicit flag replaces the remembered set rather than appending to it.
run_sync "$h" --target cursor --cursor-append-prompt "$h/append.md" >/dev/null
printf 'other\n' >"$h/other.md"
run_sync "$h" --target cursor --cursor-append-prompt "$h/other.md" >/dev/null
assert_contains "case38: new flag value used" "1. $h/other.md" "$(cat "$rule")"
assert_eq "case38: previous value not carried alongside" \
  "" "$(grep -c 'append.md$' "$rule" | tr -d ' ' | sed 's/^0$//')"

# --- Case 39: plugin agents and plain ~/.claude/agents both reach copilot CLI's user
# agents dir as plain symlinks (raw Claude markdown, same policy as cursor).
h=$(new_home)
p=$(add_plugin "$h" mp toolkit 1.0.0)
mkdir -p "$p/agents"
printf -- '---\nname: helper\ndescription: d\ntools:\n  - Bash\n---\nbody\n' >"$p/agents/helper.md"
write_manifest "$h" "toolkit@mp" "$p"
add_user_agent "$h/.claude" native
run_sync "$h" >/dev/null
assert_link_to "case39: plugin agent -> copilot agents dir" \
  "$h/.copilot/agents/helper.md" "$p/agents/helper.md"
assert_link_to "case39: plain claude agent -> copilot agents dir" \
  "$h/.copilot/agents/native.md" "$h/.claude/agents/native.md"

# --- Case 40: global CLAUDE.md reaches copilot as copilot-instructions.md; a real file
# there is never touched.
h=$(new_home)
printf 'my global instructions\n' >"$h/.claude/CLAUDE.md"
write_manifest "$h"
run_sync "$h" >/dev/null
assert_link_to "case40: copilot-instructions.md linked from CLAUDE.md" \
  "$h/.copilot/copilot-instructions.md" "$h/.claude/CLAUDE.md"
h=$(new_home)
printf 'my global instructions\n' >"$h/.claude/CLAUDE.md"
mkdir -p "$h/.copilot"
printf 'hand-written copilot instructions\n' >"$h/.copilot/copilot-instructions.md"
write_manifest "$h"
out=$(run_sync "$h")
assert_eq "case40: pre-existing real copilot-instructions.md untouched" \
  "hand-written copilot instructions" "$(cat "$h/.copilot/copilot-instructions.md")"
assert_contains "case40: conflict reported" "left alone" "$out"

# --- Case 40b: --force overwrites a pre-existing real copilot-instructions.md (when
# 'trash' is available) and reports it as overwritten rather than left alone.
if command -v trash >/dev/null 2>&1; then
  h=$(new_home)
  printf 'my global instructions\n' >"$h/.claude/CLAUDE.md"
  mkdir -p "$h/.copilot"
  printf 'hand-written copilot instructions\n' >"$h/.copilot/copilot-instructions.md"
  write_manifest "$h"
  out=$(run_sync "$h" --force)
  assert_link_to "case40b: --force replaces the real file with a symlink" \
    "$h/.copilot/copilot-instructions.md" "$h/.claude/CLAUDE.md"
  assert_contains "case40b: overwrite reported" "overwritten" "$out"
fi

# --- Case 41: --target copilot restricts destinations to copilot only, and no plugin
# command linking happens for it (copilot has no command/prompt-file concept).
h=$(new_home)
p=$(add_plugin "$h" mp toolkit 1.0.0)
add_command "$p" review
mkdir -p "$p/agents"
printf -- '---\nname: helper\ndescription: d\n---\nbody\n' >"$p/agents/helper.md"
write_manifest "$h" "toolkit@mp" "$p"
printf 'global\n' >"$h/.claude/CLAUDE.md"
run_sync "$h" --target copilot >/dev/null
assert_exists "case41: copilot agent linked" "$h/.copilot/agents/helper.md"
assert_exists "case41: copilot-instructions.md linked" "$h/.copilot/copilot-instructions.md"
assert_missing "case41: no opencode command" "$h/.config/opencode/command/review.md"
assert_missing "case41: no cursor agent" "$h/.cursor/agents/helper.md"

# --- Case 42: --write-mcp merges a schema-translated server into copilot's mcp-config.json.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"ctx7":{"command":"npx","args":["-y","ctx7"],"env":{"K":"v"}}}}' \
  >"$h/.claude.json"
run_sync "$h" --write-mcp >/dev/null
assert_eq "case42: copilot mcp-config.json has the local type" \
  "local" "$(jq -r '.mcpServers.ctx7.type' "$h/.copilot/mcp-config.json" 2>/dev/null)"
assert_eq "case42: command carried over" \
  "npx" "$(jq -r '.mcpServers.ctx7.command' "$h/.copilot/mcp-config.json" 2>/dev/null)"
assert_eq "case42: env preserved" \
  "v" "$(jq -r '.mcpServers.ctx7.env.K' "$h/.copilot/mcp-config.json" 2>/dev/null)"
assert_eq "case42: tools defaulted to everything" \
  "*" "$(jq -r '.mcpServers.ctx7.tools[0]' "$h/.copilot/mcp-config.json" 2>/dev/null)"

# --- Case 43: --mcp-snippet prints a copilot mcp-config.json block; nothing is written.
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"ctx7":{"command":"npx","args":["-y","ctx7"],"env":{"K":"v"}}}}' \
  >"$h/.claude.json"
out=$(run_sync "$h" --mcp-snippet)
assert_contains "case43: copilot snippet header printed" "mcp-config.json" "$out"
assert_contains "case43: type key printed" '"type": "local"' "$out"
assert_missing "case43: mcp-config.json never written" "$h/.copilot/mcp-config.json"

# --- Case 44: project-level .claude/agents reaches copilot's .github/agents dir.
h=$(new_home)
proj=$(mktemp -d)
mkdir -p "$proj/.claude/agents"
printf -- '---\nname: reviewer\ndescription: d\n---\nbody\n' >"$proj/.claude/agents/reviewer.md"
write_manifest "$h"
run_sync_raw "$h" --project "$proj" >/dev/null
assert_link_to "case44: project agent -> project .github/agents" \
  "$proj/.github/agents/reviewer.md" "$proj/.claude/agents/reviewer.md"

# --- Case 45: a Claude remote (url-based) MCP server is normalized to copilot's own
# accepted "http" type, regardless of Claude's own source type value (e.g. "sse").
h=$(new_home)
write_manifest "$h"
printf '%s\n' '{"mcpServers":{"remote1":{"type":"sse","url":"https://example.com/mcp","headers":{"X":"y"}}}}' \
  >"$h/.claude.json"
run_sync "$h" --write-mcp >/dev/null
assert_eq "case45: remote server normalized to http type" \
  "http" "$(jq -r '.mcpServers.remote1.type' "$h/.copilot/mcp-config.json" 2>/dev/null)"
assert_eq "case45: url carried over" \
  "https://example.com/mcp" "$(jq -r '.mcpServers.remote1.url' "$h/.copilot/mcp-config.json" 2>/dev/null)"
assert_eq "case45: headers preserved" \
  "y" "$(jq -r '.mcpServers.remote1.headers.X' "$h/.copilot/mcp-config.json" 2>/dev/null)"

# --- Case 46: stale copilot agent links (global and project) are pruned once their
# Claude source disappears.
h=$(new_home)
add_user_agent "$h/.claude" temporary
write_manifest "$h"
run_sync "$h" >/dev/null
assert_exists "case46: copilot agent linked while the source exists" \
  "$h/.copilot/agents/temporary.md"
mv "$h/.claude/agents/temporary.md" "$h/removed-agent.md"
out=$(run_sync "$h")
assert_missing "case46: copilot agent link pruned once the source is gone" \
  "$h/.copilot/agents/temporary.md"

proj=$(mktemp -d)
mkdir -p "$proj/.claude/agents"
printf -- '---\nname: reviewer\ndescription: d\n---\nbody\n' >"$proj/.claude/agents/reviewer.md"
run_sync_raw "$h" --project "$proj" >/dev/null
assert_exists "case46: project copilot agent linked while the source exists" \
  "$proj/.github/agents/reviewer.md"
mv "$proj/.claude/agents/reviewer.md" "$proj/removed-agent.md"
run_sync_raw "$h" --project "$proj" >/dev/null
assert_missing "case46: project copilot agent link pruned once the source is gone" \
  "$proj/.github/agents/reviewer.md"

# --- Case 47: a generic instruction bundle is autodetected through the global CLAUDE.md
# symlink and routed through each harness's native global entrypoint.
h=$(new_home)
bundle=$(add_instruction_bundle "$h")
write_manifest "$h"
run_sync "$h" >/dev/null
assert_contains "case47: opencode native global file includes append" \
  "1. $bundle/append.md" "$(cat "$h/.config/opencode/AGENTS.md")"
assert_contains "case47: opencode native global file includes shared" \
  "2. $bundle/shared.md" "$(cat "$h/.config/opencode/AGENTS.md")"
assert_contains "case47: pi native global file includes append" \
  "1. $bundle/append.md" "$(cat "$h/.pi/agent/AGENTS.md")"
assert_contains "case47: codex native global file includes shared" \
  "2. $bundle/shared.md" "$(cat "$h/.codex/AGENTS.md")"
assert_contains "case47: copilot native file includes harness-specific instructions" \
  "1. $bundle/copilot.md" "$(cat "$h/.copilot/copilot-instructions.md")"
assert_contains "case47: copilot native file includes append" \
  "2. $bundle/append.md" "$(cat "$h/.copilot/copilot-instructions.md")"
assert_contains "case47: copilot native file includes shared" \
  "3. $bundle/shared.md" "$(cat "$h/.copilot/copilot-instructions.md")"
assert_contains "case47: cursor shared rule includes bundle append" \
  "1. $bundle/append.md" "$(cat "$h/.cursor/rules/claude-global.mdc")"
assert_contains "case47: cursor shared rule includes bundle shared" \
  "2. $bundle/shared.md" "$(cat "$h/.cursor/rules/claude-global.mdc")"
assert_link_to "case47: cursor uses its harness-specific native rule" \
  "$h/.cursor/rules/cursor-instructions.mdc" "$bundle/cursor.md"

# --- Case 48: the generic bundle can be supplied explicitly and does not depend on a
# repository name or on CLAUDE.md being a symlink.
h=$(new_home)
printf 'legacy global\n' >"$h/.claude/CLAUDE.md"
bundle="$h/arbitrary/location"
mkdir -p "$bundle"
printf 'shared\n' >"$bundle/shared.md"
printf 'append\n' >"$bundle/append.md"
bundle=$(unset CDPATH; cd -P -- "$bundle" && pwd)
write_manifest "$h"
env -u CURSOR_APPEND_PROMPT HOME="$h" HARNESS_GLOBAL_INSTRUCTIONS_DIR="$bundle" \
  bash "$SCRIPT" --no-project --target pi >/dev/null
assert_contains "case48: environment override uses arbitrary bundle path" \
  "1. $bundle/append.md" "$(cat "$h/.pi/agent/AGENTS.md")"
run_sync "$h" --target codex --global-instructions-dir "$bundle" >/dev/null
assert_contains "case48: CLI override uses arbitrary bundle path" \
  "2. $bundle/shared.md" "$(cat "$h/.codex/AGENTS.md")"

# --- Case 49: bundle awareness does not weaken conflict protection. Existing real files
# remain untouched unless the caller explicitly supplies --force.
h=$(new_home)
bundle=$(add_instruction_bundle "$h")
write_manifest "$h"
mkdir -p "$h/.copilot" "$h/.config/opencode"
printf 'my copilot rules\n' >"$h/.copilot/copilot-instructions.md"
printf 'my opencode rules\n' >"$h/.config/opencode/AGENTS.md"
out=$(run_sync "$h")
assert_eq "case49: real copilot instructions remain untouched" \
  "my copilot rules" "$(cat "$h/.copilot/copilot-instructions.md")"
assert_eq "case49: real opencode instructions remain untouched" \
  "my opencode rules" "$(cat "$h/.config/opencode/AGENTS.md")"
assert_contains "case49: bundle conflicts are reported" "left alone" "$out"

# --- Case 50: an explicit bundle must satisfy the generic contract.
h=$(new_home)
write_manifest "$h"
mkdir -p "$h/incomplete-bundle"
out=$(run_sync "$h" --global-instructions-dir "$h/incomplete-bundle" || true)
assert_contains "case50: missing shared.md is rejected" \
  "must contain shared.md" "$out"

# --- Case 51: an explicit dotenv file applies persistent options, resolves bundle paths
# relative to itself, and still yields to explicit CLI arguments.
h=$(new_home)
bundle="$h/config/global-instructions"
mkdir -p "$bundle"
printf 'shared\n' >"$bundle/shared.md"
printf 'append\n' >"$bundle/append.md"
bundle=$(unset CDPATH; cd -P -- "$bundle" && pwd)
printf '%s\n' \
  'HARNESS_GLOBAL_INSTRUCTIONS_DIR=./global-instructions' \
  'HARNESS_BRIDGE_TARGET=copilot' \
  >"$h/config/bridge.env"
write_manifest "$h"
run_sync "$h" --env-file "$h/config/bridge.env" >/dev/null
assert_exists "case51: dotenv target is applied" "$h/.copilot/copilot-instructions.md"
assert_missing "case51: dotenv target excludes pi" "$h/.pi/agent/AGENTS.md"
run_sync "$h" --env-file "$h/config/bridge.env" --target pi >/dev/null
assert_contains "case51: CLI target overrides dotenv target" \
  "1. $bundle/append.md" "$(cat "$h/.pi/agent/AGENTS.md")"

# --- Case 52: HARNESS_BRIDGE_ENV_FILE and a cwd .harness-bridge.env are both supported.
h=$(new_home)
bundle="$h/bundle"
mkdir -p "$bundle"
printf 'shared\n' >"$bundle/shared.md"
bundle=$(unset CDPATH; cd -P -- "$bundle" && pwd)
printf 'HARNESS_GLOBAL_INSTRUCTIONS_DIR=%s\nHARNESS_BRIDGE_TARGET=codex\n' \
  "$bundle" >"$h/persistent.env"
write_manifest "$h"
HOME="$h" HARNESS_BRIDGE_ENV_FILE="$h/persistent.env" \
  env -u CURSOR_APPEND_PROMPT bash "$SCRIPT" --no-project >/dev/null
assert_link_to "case52: env-file pointer is loaded" \
  "$h/.codex/AGENTS.md" "$bundle/shared.md"
work="$h/work"
mkdir -p "$work"
printf 'HARNESS_GLOBAL_INSTRUCTIONS_DIR=%s\nHARNESS_BRIDGE_TARGET=pi\n' \
  "$bundle" >"$work/.harness-bridge.env"
(cd "$work" && env -u HARNESS_BRIDGE_ENV_FILE -u CURSOR_APPEND_PROMPT \
  HOME="$h" bash "$SCRIPT" --no-project >/dev/null)
assert_link_to "case52: cwd dotenv is auto-loaded" \
  "$h/.pi/agent/AGENTS.md" "$bundle/shared.md"

# --- Case 53: dotenv parsing is data-only and rejects unknown options instead of sourcing
# arbitrary shell.
h=$(new_home)
write_manifest "$h"
printf 'UNSUPPORTED_OPTION=$(touch %s/pwned)\n' "$h" >"$h/bad.env"
out=$(run_sync "$h" --env-file "$h/bad.env" || true)
assert_contains "case53: unsupported dotenv option is rejected" \
  "unsupported option" "$out"
assert_missing "case53: dotenv content is never executed" "$h/pwned"

# --- Case 54: Copilot plugin import merges marketplaces and installed plugin state.
h=$(new_home)
enabled_plugin=$(add_plugin "$h" demo-market enabled 1.0.0)
disabled_plugin=$(add_plugin "$h" demo-market disabled 1.0.0)
add_plugin_manifest "$enabled_plugin" enabled
add_plugin_manifest "$disabled_plugin" disabled
write_manifest "$h" "enabled@demo-market" "$enabled_plugin" \
  "disabled@demo-market" "$disabled_plugin"
marketplace="$h/.claude/plugins/marketplaces/demo-market"
mkdir -p "$marketplace"
jq -n --arg path "$marketplace" \
  '{"demo-market":{"source":{"source":"directory","path":$path}}}' \
  >"$h/.claude/plugins/known_marketplaces.json"
jq -n \
  '{"enabledPlugins":{"enabled@demo-market":true,"disabled@demo-market":false}}' \
  >"$h/.claude/settings.json"
mkdir -p "$h/.copilot"
printf '%s\n' \
  '{"theme":"dark","enabledPlugins":{"existing@other":true},"extraKnownMarketplaces":{"existing":{"source":{"source":"github","repo":"example/existing"}}}}' \
  >"$h/.copilot/settings.json"
out=$(run_sync "$h" --target copilot --write-plugins)
assert_eq "case54: existing Copilot setting is preserved" \
  "dark" "$(jq -r '.theme' "$h/.copilot/settings.json")"
assert_eq "case54: Claude marketplace is registered" \
  "$marketplace" "$(jq -r '.extraKnownMarketplaces["demo-market"].source.path' "$h/.copilot/settings.json")"
assert_eq "case54: installed enabled plugin is enabled" \
  "true" "$(jq -r '.enabledPlugins["enabled@demo-market"]' "$h/.copilot/settings.json")"
assert_eq "case54: disabled Claude plugin remains disabled" \
  "false" "$(jq -r '.enabledPlugins["disabled@demo-market"]' "$h/.copilot/settings.json")"
assert_eq "case54: existing Copilot plugin value is preserved" \
  "true" "$(jq -r '.enabledPlugins["existing@other"]' "$h/.copilot/settings.json")"
assert_contains "case54: reports plugin enablement" \
  "Copilot CLI will attempt to install compatible enabled plugins" "$out"
first_settings=$(cat "$h/.copilot/settings.json")
out=$(run_sync "$h" --target copilot --write-plugins)
assert_eq "case54: repeated import is idempotent" "$first_settings" \
  "$(cat "$h/.copilot/settings.json")"

# --- Case 55: plugin import is opt-in and dry-run leaves Copilot settings unchanged.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_plugin_manifest "$p" demo
write_manifest "$h" "demo@mp" "$p"
mkdir -p "$h/.claude/plugins/marketplaces/mp"
jq -n --arg path "$h/.claude/plugins/marketplaces/mp" \
  '{"mp":{"source":{"source":"directory","path":$path}}}' \
  >"$h/.claude/plugins/known_marketplaces.json"
run_sync "$h" --target copilot >/dev/null
assert_missing "case55: default sync does not enable Copilot plugins" \
  "$h/.copilot/settings.json"
out=$(run_sync "$h" --target copilot --write-plugins --dry-run)
assert_contains "case55: dry-run previews marketplace/plugin settings" \
  "would add 1 marketplace(s) and 1 plugin(s)" "$out"
assert_missing "case55: dry-run does not write Copilot settings" \
  "$h/.copilot/settings.json"

# --- Case 56: JSONC Copilot settings are preserved instead of rewritten by jq.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_plugin_manifest "$p" demo
write_manifest "$h" "demo@mp" "$p"
mkdir -p "$h/.claude/plugins/marketplaces/mp" "$h/.copilot"
jq -n --arg path "$h/.claude/plugins/marketplaces/mp" \
  '{"mp":{"source":{"source":"directory","path":$path}}}' \
  >"$h/.claude/plugins/known_marketplaces.json"
printf '{\n  // keep this comment\n  "theme": "dark"\n}\n' >"$h/.copilot/settings.json"
settings_before=$(cat "$h/.copilot/settings.json")
out=$(run_sync "$h" --target copilot --write-plugins)
assert_eq "case56: JSONC Copilot settings remain unchanged" \
  "$settings_before" "$(cat "$h/.copilot/settings.json")"
assert_contains "case56: invalid JSONC is reported" \
  "is not valid JSON or has invalid plugin settings" "$out"

# --- Case 57: COPILOT_HOME redirects imported plugin settings.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_plugin_manifest "$p" demo
write_manifest "$h" "demo@mp" "$p"
mkdir -p "$h/.claude/plugins/marketplaces/mp"
jq -n --arg path "$h/.claude/plugins/marketplaces/mp" \
  '{"mp":{"source":{"source":"directory","path":$path}}}' \
  >"$h/.claude/plugins/known_marketplaces.json"
env -u COPILOT_CONFIG_DIR -u CURSOR_APPEND_PROMPT -u HARNESS_GLOBAL_INSTRUCTIONS_DIR \
  HOME="$h" COPILOT_HOME="$h/copilot-home" bash "$SCRIPT" --no-project \
  --target copilot --write-plugins >/dev/null
assert_exists "case57: COPILOT_HOME settings receive imported plugins" \
  "$h/copilot-home/settings.json"
assert_missing "case57: default Copilot config remains untouched" \
  "$h/.copilot/settings.json"

# --- Case 58: plugins without a Copilot-supported manifest remain component-only.
h=$(new_home)
p=$(add_plugin "$h" mp demo 1.0.0)
add_skill "$p" included
write_manifest "$h" "demo@mp" "$p"
mkdir -p "$h/.claude/plugins/marketplaces/mp"
jq -n --arg path "$h/.claude/plugins/marketplaces/mp" \
  '{"mp":{"source":{"source":"directory","path":$path}}}' \
  >"$h/.claude/plugins/known_marketplaces.json"
out=$(run_sync "$h" --target copilot --write-plugins)
assert_contains "case58: missing plugin manifest is reported" \
  "skipped 1 plugin(s) without a Copilot-supported plugin manifest" "$out"
assert_eq "case58: compatible component remains linked" \
  "$p/skills/included" "$(readlink "$h/.agents/skills/included")"
assert_eq "case58: unsupported plugin is not enabled natively" \
  "0" "$(jq '.enabledPlugins // {} | length' "$h/.copilot/settings.json")"

echo
echo "$pass_count passed, $failures failed"
[ "$failures" -eq 0 ] || exit 1
