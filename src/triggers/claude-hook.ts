// `r2 claude-hook`: prints a hooks block for Claude Code (~/.claude/settings.json or .claude/settings.json).
// Stop fires when Claude finishes a turn → happy. Notification/permission_prompt and
// idle_prompt fire when Claude is waiting on you → attention.
import { BRIDGE_URL } from '../client'

const curl = (mood: string) => `curl -s -X POST ${BRIDGE_URL}/react/${mood} >/dev/null 2>&1 || true`
const hook = (mood: string) => ({ type: 'command', command: curl(mood), timeout: 5 })

export const claudeHooks = {
  hooks: {
    Stop: [{ hooks: [hook('happy')] }],
    Notification: [
      { matcher: 'permission_prompt', hooks: [hook('attention')] },
      { matcher: 'idle_prompt', hooks: [hook('attention')] },
    ],
  },
}

export function claudeHook(): number {
  console.log(JSON.stringify(claudeHooks, null, 2))
  console.error('\nMerge the "hooks" key into ~/.claude/settings.json (or a project .claude/settings.json).')
  return 0
}
