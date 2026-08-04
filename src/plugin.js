import { dirname, join } from "path"
import { fileURLToPath } from "url"

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "claude-harness-sync.sh")

const DEFAULT_ARGS = ["--no-project", "--write-mcp"]

/**
 * opencode plugin wrapper around bin/claude-harness-sync.sh.
 *
 * It deliberately shells out to the script rather than reimplementing the logic in JS:
 * the script is the single source of truth, it is covered by the test suite, and it stays
 * usable from a plain terminal (and from pi, which has no plugin API of this shape).
 *
 * TIMING CAVEAT: opencode reads its config, agents, commands and skills once at startup.
 * A plugin runs inside that startup, so links created on this run are generally picked up
 * on the *next* launch, not the current one. That is fine for the steady state — you only
 * pay the one-launch lag right after installing or updating a Claude plugin.
 *
 * Configure in opencode.jsonc:
 *   { "plugin": ["file:///abs/path/to/claude-harness-sync/src/plugin.js"] }
 * or with options:
 *   { "plugin": [["file:///.../src/plugin.js", { "args": ["--no-project"] }]] }
 */
export const ClaudeHarnessSync = async ({ $ }, options = {}) => {
  const args = Array.isArray(options?.args) ? options.args : DEFAULT_ARGS

  // Never let a sync failure take opencode down with it — a broken harness is a far worse
  // outcome than an out-of-date symlink.
  try {
    await $`bash ${SCRIPT} ${args}`.quiet()
  } catch {
    // intentionally silent; run the script by hand to see why
  }

  return {}
}

export default ClaudeHarnessSync
