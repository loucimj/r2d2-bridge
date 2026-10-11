// `r2 git-hook install|uninstall`: post-commit hook that makes R2 happy after every commit.
import { execFileSync } from 'node:child_process'
import { chmodSync, existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const MARKER = '# r2d2-bridge'
const LINE = `${MARKER}\ncurl -s -X POST "\${R2_BRIDGE_URL:-http://127.0.0.1:4242}/react/happy" >/dev/null 2>&1 || true\n`

export function gitHook(action = 'install'): number {
  let hooksDir: string
  try {
    const gitDir = execFileSync('git', ['rev-parse', '--git-path', 'hooks'], { encoding: 'utf8' }).trim()
    hooksDir = join(process.cwd(), gitDir)
  } catch {
    console.error('r2: not inside a git repository')
    return 1
  }
  const hook = join(hooksDir, 'post-commit')
  const current = existsSync(hook) ? readFileSync(hook, 'utf8') : ''

  if (action === 'uninstall') {
    if (!current.includes(MARKER)) return console.log('r2: hook not installed'), 0
    const rest = current.replace(LINE, '')
    rest.trim() === '#!/bin/sh' ? unlinkSync(hook) : writeFileSync(hook, rest)
    console.log(`r2: removed from ${hook}`)
    return 0
  }
  if (action !== 'install') return console.error('usage: r2 git-hook install|uninstall'), 2
  if (current.includes(MARKER)) return console.log('r2: hook already installed'), 0

  writeFileSync(hook, (current || '#!/bin/sh\n') + LINE)
  chmodSync(hook, 0o755)
  console.log(`r2: installed post-commit hook at ${hook}`)
  return 0
}
