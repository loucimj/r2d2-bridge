import type { EventEmitter } from 'node:events'
import { Animation, Audio } from './animations'
import { FakeR2 } from './fake'

export type Mood = 'happy' | 'alarm' | 'attention' | 'thinking' | 'sad' | 'busy' | 'idle'

// The part of spherov2.js's R2D2 we use. FakeR2 implements it too.
export interface R2 {
  wake(): Promise<unknown>
  sleep(): Promise<unknown>
  destroy(): Promise<unknown>
  playAnimation(id: number): Promise<unknown>
  playR2D2Sound(hi: number, lo: number): Promise<unknown>
  playAudioFile(idx: number): Promise<unknown>
  turnDome(angle: number): Promise<unknown>
  setStance(stance: number): Promise<unknown>
  setR2D2LEDColor(r: number, g: number, b: number): Promise<unknown>
  setR2D2FrontLEDColor(r: number, g: number, b: number): Promise<unknown>
  setR2D2BackLEDcolor(r: number, g: number, b: number): Promise<unknown>
  setR2D2LogicDisplaysIntensity(i: number): Promise<unknown>
  setR2D2HoloProjectorIntensity(i: number): Promise<unknown>
  startIdleLedAnimation(): Promise<unknown>
  setAudioVolume(vol: number): Promise<unknown>
}

// Same values as spherov2.js's Stance enum, defined here so loading this file never loads BLE.
const Stance = { tripod: 1, bipod: 2 } as const

type Reaction = (r2: R2) => Promise<unknown>

const KEEP_ALIVE_MS = 60_000
const RECONNECT_DELAY_MS = 5_000
const FAKE = process.env.R2_FAKE === '1'
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e))
// playAudioFile only sends one byte; audio IDs are 16-bit, high byte first.
const playSound = (r2: R2, id: number) => r2.playR2D2Sound(id >> 8, id & 0xff)

const moods: Record<Mood, Reaction> = {
  happy: async (r2) => {
    await r2.setR2D2LEDColor(0, 200, 60)
    await r2.playAnimation(Animation.wwmHappy)
    await sleep(3000)
  },
  alarm: async (r2) => {
    await r2.setR2D2LEDColor(255, 0, 0)
    await r2.playAnimation(Animation.alarm)
    await sleep(3000)
  },
  attention: async (r2) => {
    await r2.setR2D2LEDColor(255, 160, 0)
    await r2.playAnimation(Animation.wwmYoohoo)
    await sleep(2500)
  },
  thinking: async (r2) => {
    await r2.setR2D2LEDColor(0, 120, 255)
    await r2.turnDome(90)
    await playSound(r2, Audio.chatty)
    await sleep(1500)
    await r2.turnDome(-90)
    await sleep(1500)
    await r2.turnDome(0)
  },
  sad: async (r2) => {
    await r2.setR2D2LEDColor(60, 0, 120)
    await r2.playAnimation(Animation.wwmSad)
    await sleep(3000)
  },
  busy: async (r2) => {
    await r2.setR2D2LEDColor(255, 60, 0)
    await r2.playAnimation(Animation.wwmJittery)
    await sleep(3000)
  },
  idle: async (r2) => {
    await r2.setStance(Stance.bipod)
    await r2.setR2D2LEDColor(0, 0, 0)
    await r2.startIdleLedAnimation()
  },
}

export const moodNames = Object.keys(moods) as Mood[]
// hasOwn, not `in`: "constructor" matches /[a-z]+/ and is `in` every object.
export const isMood = (s: string): s is Mood => Object.hasOwn(moods, s)

// Raw R2 methods the demo page may call, with their number of numeric arguments.
export const commands = {
  wake: 0,
  sleep: 0,
  turnDome: 1,
  setStance: 1,
  playAnimation: 1,
  playAudioFile: 1,
  playR2D2Sound: 2,
  setR2D2LEDColor: 3,
  setR2D2FrontLEDColor: 3,
  setR2D2BackLEDcolor: 3,
  setR2D2LogicDisplaysIntensity: 1,
  setR2D2HoloProjectorIntensity: 1,
  startIdleLedAnimation: 0,
  setAudioVolume: 1,
} as const
export type Command = keyof typeof commands
export const isCommand = (s: string): s is Command => Object.hasOwn(commands, s)

export class Droid {
  private r2?: R2
  private queue: Promise<unknown> = Promise.resolve()
  private keepAlive?: NodeJS.Timeout
  private detach?: () => void
  private reconnecting = false
  private stopped = false

  /** Scans until an R2-D2 is found and keeps it awake. Resolves once connected. */
  async connect(): Promise<void> {
    if (FAKE) {
      if (!this.stopped) this.attach(new FakeR2())
      return
    }
    await waitForBluetooth()
    // Loaded lazily: spherov2.js loads noble, which some host processes get killed for.
    const { Scanner } = await import('spherov2.js')
    while (!this.stopped) {
      try {
        // Typed as R2D2 but resolves to undefined when nothing is found.
        const r2: R2 | undefined = await Scanner.findR2D2()
        if (r2 && this.stopped) {
          r2.destroy().catch(() => {})
          return
        }
        if (r2) return this.attach(r2)
        console.log(`No R2-D2 found, retrying in ${RECONNECT_DELAY_MS / 1000}s`)
      } catch (e) {
        console.error(`Connecting to R2-D2 failed (${errorText(e)}), retrying in ${RECONNECT_DELAY_MS / 1000}s`)
      }
      await sleep(RECONNECT_DELAY_MS)
    }
  }

  /** Queues a mood. Reactions run one at a time, in order. */
  react(mood: Mood): Promise<void> {
    return this.enqueue(`react: ${mood}`, async (r2) => {
      await moods[mood](r2)
      // The link may have dropped, or been replaced, while the mood played.
      if (this.r2 === r2) await moods.idle(r2)
    })
  }

  /** Plays one raw ID; for mapping IDs without a Bluetooth-capable terminal. */
  play(kind: 'animation' | 'audio', id: number): Promise<void> {
    return this.enqueue(`play: ${kind} ${id}`, (r2) => (kind === 'animation' ? r2.playAnimation(id) : playSound(r2, id)))
  }

  /** Runs one whitelisted R2 method; used by the demo page. */
  cmd(method: Command, args: number[]): Promise<void> {
    return this.enqueue(`${method}(${args.join(', ')})`, (r2) => (r2[method] as (...a: number[]) => Promise<unknown>)(...args))
  }

  private enqueue(label: string, fn: (r2: R2) => Promise<unknown>): Promise<void> {
    // Fail now rather than wait behind commands that may be timing out on a dead link.
    if (!this.r2) return Promise.reject(new Error('R2-D2 is not connected'))
    const run = this.queue.then(async () => {
      const r2 = this.r2
      if (!r2) throw new Error('R2-D2 is not connected')
      console.log(label)
      await fn(r2)
    })
    this.queue = run.catch((e) => console.error(`${label} failed:`, e))
    return run
  }

  get connected(): boolean {
    return this.r2 !== undefined
  }

  async shutdown(): Promise<void> {
    this.stopped = true
    clearInterval(this.keepAlive)
    const r2 = this.r2
    this.r2 = undefined
    if (!r2) return
    await r2.sleep().catch(() => {})
    await r2.destroy().catch(() => {})
  }

  private attach(r2: R2) {
    this.r2 = r2
    // noble reuses one Peripheral object per device across reconnects, so the listener must be removed.
    const peripheral = peripheralOf(r2)
    const onDrop = () => this.onDisconnect(r2)
    peripheral.once('disconnect', onDrop)
    this.detach = () => peripheral.removeListener('disconnect', onDrop)
    this.keepAlive = setInterval(() => this.ping(), KEEP_ALIVE_MS)
    // Queued so it cannot interleave with a reaction that arrives right after connecting.
    this.queue = this.queue.then(() => r2.setAudioVolume(200)).then(() => moods.idle(r2)).catch(() => {})
    console.log('R2-D2 ready')
  }

  // Cannot overlap itself: wake() rejects after the library's 5 s command timeout, well under KEEP_ALIVE_MS.
  private async ping() {
    const r2 = this.r2
    if (!r2) return
    try {
      await r2.wake()
    } catch (e) {
      if (this.r2 !== r2) return // that connection is already gone
      console.warn('keep-alive failed, assuming link is down:', e)
      this.onDisconnect(r2)
      // noble may still think it is connected, and a connected R2-D2 does not advertise.
      r2.destroy().catch(() => {})
    }
  }

  private onDisconnect(source: R2) {
    if (this.stopped || this.reconnecting || source !== this.r2) return
    this.reconnecting = true
    clearInterval(this.keepAlive)
    this.detach?.()
    this.r2 = undefined
    console.warn('R2-D2 disconnected, reconnecting…')
    this.reconnectLoop().finally(() => (this.reconnecting = false))
  }

  private async reconnectLoop() {
    while (!this.stopped) {
      await sleep(RECONNECT_DELAY_MS)
      try {
        await this.connect()
        return
      } catch (e) {
        console.error('reconnect failed, will retry:', errorText(e))
      }
    }
  }
}

// `peripheral` is private in spherov2.js but it is the only way to hear about drops.
const peripheralOf = (r2: R2) => (r2 as unknown as { peripheral: EventEmitter }).peripheral

export async function waitForBluetooth(hintEveryMs = 10_000) {
  const noble = (await import('@abandonware/noble')).default
  const state = () => (noble as unknown as { state: string }).state
  if (state() === 'poweredOn') return
  // Never give up: while macOS shows the Bluetooth permission prompt the state stays
  // "unknown", and the daemon must still be alive when the user clicks Allow.
  await new Promise<void>((resolve) => {
    const hint = setInterval(() => console.warn(bluetoothHint(state())), hintEveryMs)
    const onChange = (s: string) => {
      if (s !== 'poweredOn') return
      clearInterval(hint)
      noble.removeListener('stateChange', onChange)
      resolve()
    }
    noble.on('stateChange', onChange)
  })
}

const bluetoothHint = (state: string) =>
  state === 'unauthorized'
    ? 'Bluetooth access denied. On macOS: System Settings → Privacy & Security → Bluetooth → enable R2 Bridge (or the app you launched the daemon from).'
    : state === 'poweredOff'
      ? 'Bluetooth is turned off.'
      : `Bluetooth not ready (state: ${state}). If macOS is showing a Bluetooth permission prompt, click Allow; otherwise enable R2 Bridge under Privacy & Security → Bluetooth.`
