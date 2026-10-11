import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'

// Stands for the engine beneath the mod: answers every event the mod hooks pass through,
// and records every request the mod makes to the bridge, answering as the daemon would.
const engine = (on: On, fetchFails = false) => {
  const calls: string[] = []
  on('http.fetch', (_$, e) => {
    if (fetchFails) throw new Error('ECONNREFUSED')
    calls.push(`${e.init?.method ?? 'GET'} ${new URL(e.url).pathname} ${e.init?.body ?? ''}`.trim())
    const text = e.url.endsWith('/health') ? '{"connected":true}' : '{}'
    return { value: { status: 200, ok: true, headers: {}, text } }
  })
  on('ui.status', () => ({ value: undefined }))
  on('command.register', () => ({ value: undefined }) as never)
  on('session.start', (_$, e) => ({ cwd: e.cwd }) as never)
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', (_$, e) => ({ text: e.answer }))
  on('classic.Notification', () => ({}))
  return calls
}

const turn = (reason: 'answer' | 'aborted' | 'error' = 'answer') =>
  ({ turnId: 't', answer: 'done', durationMs: 1, isAborted: reason === 'aborted', reason }) as never

const run = (args: string) =>
  ({ command: 'r2', args, origin: { kind: 'composer' }, presentation: { isFullscreen: false, columns: 80 } }) as never

test('a turn that edited a file ends happy', async ($, on) => {
  const calls = engine(on)
  on('tool.call', { tool: 'Edit' }, () => ({ result: {} as never }))

  await $.turn.start({ text: 'fix it', turnId: 't' })
  await $.tool.call({ tool: 'Edit', file_path: '/tmp/a.ts', old_string: 'a', new_string: 'b' })
  await $.turn.complete(turn())

  expect(calls).toContain('POST /cmd {"method":"turnDome","args":[60]}')
  expect(calls).toContain('POST /react/happy')
})

test('a turn with no edits only chirps', async ($, on) => {
  const calls = engine(on)

  await $.turn.start({ text: 'what is this?', turnId: 't' })
  await $.turn.complete(turn())

  expect(calls).toContain('POST /play/audio/2813')
  expect(calls).not.toContain('POST /react/happy')
})

test('an aborted turn only recenters the dome', async ($, on) => {
  const calls = engine(on)

  await $.turn.start({ text: 'x', turnId: 't' })
  await $.turn.complete(turn('aborted'))

  expect(calls).toContain('POST /cmd {"method":"turnDome","args":[0]}')
  expect(calls).not.toContain('POST /react/sad')
})

test('a failed tool call chirps negative and reddens the back LED', async ($, on) => {
  const calls = engine(on)
  on('tool.call', { tool: 'Bash' }, () => ({ result: {} as never, isError: true, text: 'boom' }) as never)

  await $.tool.call({ tool: 'Bash', command: 'false' })

  expect(calls).toContain('POST /cmd {"method":"setR2D2BackLEDcolor","args":[255,0,0]}')
  expect(calls).toContain('POST /play/audio/3101')
})

test('a permission prompt asks for attention, other notifications do not', async ($, on) => {
  const calls = engine(on)

  await $.classic.Notification({ message: 'Claude needs your permission', notification_type: 'permission_prompt' })
  await $.classic.Notification({ message: 'signed in', notification_type: 'auth_success' })

  expect(calls.filter((c) => c === 'POST /react/attention')).toHaveLength(1)
})

test('a daemon that is down never throws', async ($, on) => {
  engine(on, true)

  await $.turn.start({ text: 'x', turnId: 't' })
  await $.turn.complete(turn())
})

test('/r2 fires a mood and rejects unknown ones', async ($, on) => {
  const calls = engine(on)

  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
  const bad = await $.command.run(run('dance'))
  const good = await $.command.run(run('alarm'))

  expect(bad.text).toContain('usage')
  expect(good.text).toBe('R2: alarm')
  expect(calls).toContain('POST /react/alarm')
})
