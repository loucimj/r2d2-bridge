import { react } from './client'
import { isMood, moodNames } from './droid'
import { claudeHook } from './triggers/claude-hook'
import { gitHook } from './triggers/git-hook'
import { run } from './triggers/run'

const usage = `usage:
  r2 run <command> [args...]     run a command, react happy/alarm on exit code
  r2 react <mood>                moods: ${moodNames.join(', ')}
  r2 git-hook install|uninstall  post-commit → happy, in the current repo
  r2 claude-hook                 print a Claude Code hooks config`

async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv
  switch (cmd) {
    case 'run':
      return run(rest)
    case 'react': {
      const mood = rest[0] ?? ''
      if (!isMood(mood)) return console.error(usage), 2
      const ok = await react(mood)
      if (!ok) console.error('r2: bridge not reachable, is `npm start` running?')
      return ok ? 0 : 1
    }
    case 'git-hook':
      return gitHook(rest[0])
    case 'claude-hook':
      return claudeHook()
    default:
      console.error(usage)
      return 2
  }
}

main(process.argv.slice(2)).then((code) => process.exit(code))
