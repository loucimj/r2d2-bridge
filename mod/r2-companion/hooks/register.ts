// R2 companion: forwards what happens in this session to the r2d2-bridge daemon.
//
//   turn starts            → dome turns, logic displays on, status "thinking"
//   a tool fails           → short negative chirp, red back LED
//   turn ends with edits   → happy mood; without edits → a "hey" chirp, dome back to center
//   turn aborted / errored → dome to center / sad mood
//   permission or idle prompt → attention mood
//   /r2 <mood>             → fire a mood by hand
//
// Every call is fire-and-forget on the daemon side and swallowed here: a daemon that is
// down must never slow or break the session.
import type { EngineInterface, Register } from 'claude-code'

type Mood = 'happy' | 'alarm' | 'attention' | 'thinking' | 'sad' | 'busy' | 'idle'

const MOODS: readonly Mood[] = ['happy', 'alarm', 'attention', 'thinking', 'sad', 'busy', 'idle']
const EDIT_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit'])
const SOUND_NEGATIVE = 3101 // R2_NEGATIVE_1, see src/animations.ts in r2d2-bridge
const SOUND_HEY = 2813 // R2_HEY_1
const NEEDS_YOU = new Set(['permission_prompt', 'idle_prompt'])

// The validator requires every function that receives `$` to be declared at the top of the file.
let base = 'http://127.0.0.1:4242'
let edited = false

function show($: EngineInterface, text: string) {
  return $.ui.status(`R2 · ${text}`)
}

async function post($: EngineInterface, path: string, body?: unknown): Promise<boolean> {
  try {
    const res = await $.http.fetch(base + path, {
      method: 'POST',
      headers: body ? { 'content-type': 'application/json' } : undefined,
      body: body ? JSON.stringify(body) : undefined,
    })
    return res.ok
  } catch {
    return false
  }
}

function react($: EngineInterface, mood: Mood) {
  return post($, `/react/${mood}`)
}

function cmd($: EngineInterface, method: string, ...args: number[]) {
  return post($, '/cmd', { method, args })
}

function chirp($: EngineInterface, id: number) {
  return post($, `/play/audio/${id}`)
}

async function connected($: EngineInterface): Promise<boolean> {
  try {
    const res = await $.http.fetch(`${base}/health`)
    return res.ok && JSON.parse(res.text).connected === true
  } catch {
    return false
  }
}

export const register: Register = (on, options) => {
  base = String(options.bridgeUrl ?? base).replace(/\/$/, '')

  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'r2',
      description: `Make R2-D2 react: /r2 ${MOODS.join('|')}`,
    })
    show($, (await connected($)) ? 'connected' : 'offline')
    return next(e)
  })

  on('command.run', { command: 'r2' }, async ($, e) => {
    const mood = e.args.trim() as Mood
    if (!MOODS.includes(mood)) return { text: `usage: /r2 ${MOODS.join('|')}` }
    const ok = await react($, mood)
    return { text: ok ? `R2: ${mood}` : 'R2 bridge is not reachable. Start it with `npm run app` in r2d2-bridge.' }
  })

  on('turn.start', async ($, e, next) => {
    edited = false
    show($, 'thinking')
    await cmd($, 'setR2D2LogicDisplaysIntensity', 255)
    await cmd($, 'turnDome', 60)
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (e.agentId) return ran
    if (ran.deny === undefined && ran.isError === true) {
      show($, `failed: ${e.tool}`)
      await cmd($, 'setR2D2BackLEDcolor', 255, 0, 0)
      await chirp($, SOUND_NEGATIVE)
    } else if (EDIT_TOOLS.has(e.tool)) {
      edited = true
    }
    return ran
  })

  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId) return result
    if (e.reason === 'answer' && edited) {
      show($, 'happy')
      await react($, 'happy')
    } else if (e.reason === 'answer') {
      show($, 'done')
      await cmd($, 'turnDome', 0)
      await chirp($, SOUND_HEY)
    } else if (e.reason === 'aborted') {
      show($, 'interrupted')
      await cmd($, 'turnDome', 0)
    } else {
      show($, e.reason)
      await react($, 'sad')
    }
    return result
  })

  on('classic.Notification', async ($, e, next) => {
    if (NEEDS_YOU.has(e.notification_type)) {
      show($, 'needs you')
      await react($, 'attention')
    }
    return next(e)
  })
}
