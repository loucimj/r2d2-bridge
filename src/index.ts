// Daemon: keeps R2-D2 connected, serves the demo page and a small JSON API on localhost.
import { appendFileSync, existsSync, readFileSync } from 'node:fs'
import { createServer, type IncomingMessage, type ServerResponse } from 'node:http'
import { cpus, loadavg } from 'node:os'
import { join } from 'node:path'
import { Animation, Audio, AudioSets, pick } from './animations'
import { commands, Droid, isCommand, isMood, moodNames } from './droid'

export const PORT = 4242
export const HOST = '127.0.0.1'

const CPU_CHECK_MS = 15_000
const CPU_HIGH = 1.5 // 1-minute load average per core
const NOTES = join(__dirname, '..', 'explore-log.tsv')

const droid = new Droid()
const page = readFileSync(join(__dirname, 'demo.html'))

// Timestamps on every log line; the log is the only window into the daemon under the menu bar app.
for (const level of ['log', 'warn', 'error'] as const) {
  const original = console[level]
  console[level] = (...args: unknown[]) => original(new Date().toLocaleTimeString('en-GB'), ...args)
}

// Watchdog: noble can wedge after the Mac sleeps and never report Bluetooth again. If the droid
// has been gone for a while, exit; the menu bar app starts a fresh daemon with a fresh stack.
const WATCHDOG_MS = 3 * 60_000
let disconnectedSince: number | undefined
setInterval(() => {
  if (droid.connected) {
    disconnectedSince = undefined
    return
  }
  disconnectedSince ??= Date.now()
  if (Date.now() - disconnectedSince > WATCHDOG_MS) {
    console.error('R2-D2 unreachable for 3 minutes, exiting so the supervisor can restart the daemon')
    process.exit(2)
  }
}, 15_000)

const server = createServer(async (req, res) => {
  // Not `new URL()`: it throws on targets like "//", which crashed the daemon.
  const path = (req.url ?? '/').split('?')[0]
  const get = req.method === 'GET'
  const post = req.method === 'POST'

  if (get && path === '/') return html(res, page)
  if (get && path === '/health') {
    return json(res, 200, { connected: droid.connected, moods: moodNames, awaySince: droid.awaySince ?? null, rssi: droid.rssi ?? null })
  }
  if (get && path === '/catalog') return json(res, 200, { moods: moodNames, animations: Animation, audio: Audio, commands })
  if (get && path === '/notes') return json(res, 200, readNotes())

  const react = post && path.match(/^\/react\/([a-z]+)$/)
  if (react) {
    const mood = react[1]
    if (!isMood(mood)) return json(res, 400, { error: `unknown mood, use one of ${moodNames.join(', ')}` })
    return queue(res, () => droid.react(mood), { queued: mood })
  }

  // A quick clip from a family (chatty, positive, ...), queued like everything else.
  const blip = post && path.match(/^\/blip\/([a-z]+)$/)
  if (blip) {
    const set = (AudioSets as Record<string, readonly number[]>)[blip[1]]
    if (!set) return json(res, 400, { error: `unknown family, use one of ${Object.keys(AudioSets).join(', ')}` })
    return queue(res, () => droid.play('audio', pick(set)), { blip: blip[1] })
  }

  const play = post && path.match(/^\/play\/(animation|audio)\/(\d{1,5})$/)
  if (play) {
    const kind = play[1] as 'animation' | 'audio'
    const id = Number(play[2])
    return queue(res, () => droid.play(kind, id), { playing: kind, id })
  }

  if (post && path === '/cmd') {
    const body = await readJson(req)
    const method = String(body?.method ?? '')
    const args = Array.isArray(body?.args) ? body.args.map(Number) : []
    if (!isCommand(method)) return json(res, 400, { error: `unknown method, use one of ${Object.keys(commands).join(', ')}` })
    if (args.length !== commands[method] || !args.every(Number.isFinite)) {
      return json(res, 400, { error: `${method} takes ${commands[method]} numeric argument(s)` })
    }
    return queue(res, () => droid.cmd(method, args), { queued: method, args })
  }

  if (post && path === '/note') {
    const body = await readJson(req)
    const kind = String(body?.kind ?? '')
    const id = Number(body?.id)
    const note = String(body?.note ?? '').replace(/[\t\n]/g, ' ').trim()
    if (!['animation', 'audio'].includes(kind) || !Number.isInteger(id)) return json(res, 400, { error: 'need kind, id, note' })
    appendFileSync(NOTES, `${kind}\t${id}\t${note}\n`)
    return json(res, 200, { saved: { kind, id, note } })
  }

  json(res, 404, { error: 'not found' })
})

function queue(res: ServerResponse, run: () => Promise<void>, body: unknown) {
  if (!droid.connected) return json(res, 503, { error: 'R2-D2 is not connected' })
  run().catch(() => {}) // errors are logged by Droid
  json(res, 202, body)
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { 'content-type': 'application/json' })
  res.end(JSON.stringify(body))
}

function html(res: ServerResponse, body: Buffer) {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
  res.end(body)
}

async function readJson(req: IncomingMessage): Promise<Record<string, unknown> | undefined> {
  let text = ''
  for await (const chunk of req) {
    text += chunk
    if (text.length > 10_000) return undefined
  }
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

// Latest note per kind/id from explore-log.tsv, as { "animation:40": "happy wiggle", ... }.
function readNotes(): Record<string, string> {
  if (!existsSync(NOTES)) return {}
  const notes: Record<string, string> = {}
  for (const line of readFileSync(NOTES, 'utf8').split('\n')) {
    const [kind, id, ...rest] = line.split('\t')
    if (kind && id) notes[`${kind}:${id}`] = rest.join('\t')
  }
  return notes
}

function watchCpu() {
  let high = false
  setInterval(() => {
    const perCore = loadavg()[0] / cpus().length
    if (perCore > CPU_HIGH && !high) {
      high = true
      droid.react('busy').catch(() => {})
    } else if (perCore < CPU_HIGH * 0.6 && high) {
      high = false
      droid.react('happy').catch(() => {})
    }
  }, CPU_CHECK_MS)
}

function listen() {
  return new Promise<void>((resolve, reject) => {
    server.once('error', reject)
    server.listen(PORT, HOST, () => {
      server.off('error', reject)
      console.log(`listening on http://${HOST}:${PORT}`)
      resolve()
    })
  })
}

async function main() {
  try {
    await listen()
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code !== 'EADDRINUSE') throw e
    console.error(`Port ${PORT} on ${HOST} is already in use. Is another r2d2-bridge daemon running?`)
    process.exit(1)
  }
  watchCpu()
  await droid.connect()
}

const stop = async () => {
  console.log('shutting down')
  // destroy() waits for noble's disconnect callback, which may never come on a dead link.
  setTimeout(() => process.exit(0), 10_000).unref()
  server.close()
  await droid.shutdown()
  process.exit(0)
}
process.on('SIGINT', stop)
process.on('SIGTERM', stop)
// spherov2.js does not await its BLE writes (queue.js calls onExecute and drops the promise), so a
// write on a dropped link surfaces here; without a handler Node would kill the daemon.
process.on('unhandledRejection', (e) => console.error('unhandled rejection:', e))

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
