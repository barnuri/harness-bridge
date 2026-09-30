import { dirname, join } from "path"
import { fileURLToPath } from "url"

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), "..", "bin", "harness-bridge.sh")

const DEFAULT_ARGS = ["--no-project", "--write-mcp"]

/**
 * opencode plugin wrapper around bin/harness-bridge.sh.
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
 *   { "plugin": ["file:///abs/path/to/harness-bridge/src/plugin.js"] }
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

  return {
    /**
     * Give shared skills a real per-session id under opencode.
     *
     * opencode exports no session-id environment variable, so hooks/agent-env.sh in the
     * skills repo otherwise falls back to `opencode-$OPENCODE_PID` — stable per *process*,
     * which means two sequential sessions in one opencode process share a key. This hook
     * receives the actual sessionID and, because a plugin runs in-process, assigning to
     * process.env here propagates to every child the bash tool spawns afterwards.
     *
     * AGENT_SESSION_ID is the first link in that resolver's chain, so this simply wins.
     */
    "tool.execute.before": async (input) => {
      if (input?.sessionID) process.env.AGENT_SESSION_ID = input.sessionID
    },
  }
}

export default ClaudeHarnessSync
