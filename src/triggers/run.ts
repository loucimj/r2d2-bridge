// `r2 run <command...>`: runs the command, then reacts happy (exit 0) or alarm (anything else).
import { spawn } from 'node:child_process'
import { react } from '../client'

export function run(argv: string[]): Promise<number> {
  if (argv.length === 0) {
    console.error('usage: r2 run <command> [args...]')
    return Promise.resolve(2)
  }
  const [cmd, ...args] = argv
  return new Promise((resolve) => {
    const child = spawn(cmd, args, { stdio: 'inherit', shell: false })
    child.on('error', async (e) => {
      console.error(`r2: could not start ${cmd}: ${e.message}`)
      await react('alarm')
      resolve(127)
    })
    child.on('exit', async (code, signal) => {
      const exit = code ?? (signal ? 128 : 1)
      await react(exit === 0 ? 'happy' : 'alarm')
      resolve(exit)
    })
  })
}
