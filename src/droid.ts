import type { EventEmitter } from 'node:events'
import { Animation, Audio, AudioSets, pick } from './animations'
import { FakeR2 } from './fake'
import { Senses, type Sample, type SenseEvent } from './senses'

export type Mood = 'happy' | 'alarm' | 'attention' | 'thinking' | 'sad' | 'busy' | 'chatty' | 'laugh' | 'excited' | 'no' | 'listening' | 'welcome' | 'goodbye' | 'startled' | 'relieved' | 'dizzy' | 'help' | 'tapped' | 'idle'

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
const RECONNECT_DELAY_AWAY_MS = 30_000 // once the droid has been gone a while
const AWAY_AFTER_MS = 10 * 60_000
const GREET_AFTER_MS = 60_000 // a reconnect after a longer absence gets a welcome
const RSSI_MS = 5_000
const GOODBYE_RSSI = Number(process.env.R2_GOODBYE_RSSI ?? -88) // dBm; three readings below this = walking away
const GOODBYE_RECOVER_RSSI = GOODBYE_RSSI + 8
const FAKE = process.env.R2_FAKE === '1'
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))
const errorText = (e: unknown) => (e instanceof Error ? e.message : String(e))
// playAudioFile only sends one byte; audio IDs are 16-bit, high byte first.
const playSound = (r2: R2, id: number) => r2.playR2D2Sound(id >> 8, id & 0xff)

const moods: Record<Mood, Reaction> = {
  happy: async (r2) => {
    await r2.setR2D2LEDColor(0, 200, 60)
    await playSound(r2, pick(AudioSets.positive))
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
    await playSound(r2, pick(AudioSets.sad))
    await r2.playAnimation(Animation.wwmSad)
    await sleep(3000)
  },
  busy: async (r2) => {
    await r2.setR2D2LEDColor(255, 60, 0)
    await r2.playAnimation(Animation.wwmJittery)
    await sleep(3000)
  },
  // Conversation moods: short, varied, no words. R2 answers banter in beeps.
  chatty: async (r2) => {
    await r2.setR2D2LogicDisplaysIntensity(255)
    await playSound(r2, pick(AudioSets.chatty))
    await r2.turnDome(20)
    await sleep(350)
    await r2.turnDome(-20)
    await sleep(350)
    await r2.turnDome(0)
  },
  laugh: async (r2) => {
    await r2.setR2D2LEDColor(255, 200, 0)
    await playSound(r2, pick(AudioSets.laugh))
    await r2.playAnimation(Animation.wwmLaugh)
    await sleep(2500)
  },
  excited: async (r2) => {
    await r2.setR2D2LEDColor(0, 255, 120)
    await playSound(r2, pick(AudioSets.excited))
    await r2.playAnimation(Animation.wwmExcited)
    await sleep(2500)
  },
  no: async (r2) => {
    await r2.setR2D2LEDColor(255, 0, 0)
    await playSound(r2, pick(AudioSets.negative))
    await r2.playAnimation(Animation.wwmNo)
    await sleep(2000)
  },
  // Wake word heard: a quick, visible "I'm listening" before the command is understood.
  listening: async (r2) => {
    await r2.setR2D2FrontLEDColor(0, 120, 255)
    await r2.setR2D2LogicDisplaysIntensity(255)
    await r2.turnDome(40)
    await playSound(r2, Audio.hey)
    await sleep(700)
    await r2.turnDome(0)
  },
  // Touch: picked up, put back, shaken, knocked over, tapped.
  startled: async (r2) => {
    await r2.setR2D2LEDColor(255, 0, 0)
    await playSound(r2, Audio.scream)
    await r2.playAnimation(Animation.surprised)
    await sleep(1500)
  },
  relieved: async (r2) => {
    await r2.setR2D2LEDColor(0, 200, 60)
    await playSound(r2, pick(AudioSets.positive))
    await r2.playAnimation(Animation.wwmRelieved)
    await sleep(2000)
  },
  dizzy: async (r2) => {
    await r2.setR2D2LEDColor(255, 120, 0)
    await playSound(r2, Audio.shortOut)
    await r2.playAnimation(Animation.shortCircuit)
    await sleep(2500)
  },
  help: async (r2) => {
    await r2.setR2D2BackLEDcolor(255, 0, 0)
    await playSound(r2, pick(AudioSets.sad))
    await sleep(1500)
  },
  tapped: async (r2) => {
    await r2.setR2D2FrontLEDColor(0, 120, 255)
    await playSound(r2, pick(AudioSets.hey))
    await r2.turnDome(-40)
    await sleep(500)
    await r2.turnDome(0)
  },
  // Back in range after being away.
  welcome: async (r2) => {
    await r2.setR2D2LEDColor(0, 200, 60)
    await r2.turnDome(60)
    await playSound(r2, Audio.hey)
    await sleep(700)
    await r2.turnDome(-30)
    await sleep(400)
    await r2.turnDome(0)
  },
  // Signal fading: a small wave before the link drops.
  goodbye: async (r2) => {
    await r2.setR2D2BackLEDcolor(255, 40, 0)
    await r2.turnDome(-60)
    await sleep(400)
    await r2.turnDome(60)
    await sleep(400)
    await r2.turnDome(0)
    await playSound(r2, Audio.sad)
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
  private rssiTimer?: NodeJS.Timeout
  private detach?: () => void
  private reconnecting = false
  private stopped = false
  private disconnectedAt?: number
  private saidGoodbye = false
  private weakReadings = 0
  private senses = new Senses()
  /** Until when R2 is moving on its own (an animation), so its own motion is not read as a grab. */
  private selfMovingUntil = 0
  private pendingTap?: NodeJS.Timeout
  /** The last touch event, for /health and tuning. */
  lastSense?: { event: SenseEvent | 'tap'; at: string }
  /** Last signal strength in dBm, for /health and tuning. */
  rssi?: number

  /** When the droid went out of reach, or undefined while connected. */
  get awaySince(): Date | undefined {
    return this.disconnectedAt === undefined ? undefined : new Date(this.disconnectedAt)
  }

  private get reconnectDelay(): number {
    const away = this.disconnectedAt === undefined ? 0 : Date.now() - this.disconnectedAt
    return away > AWAY_AFTER_MS ? RECONNECT_DELAY_AWAY_MS : RECONNECT_DELAY_MS
  }

  /** Scans until an R2-D2 is found and keeps it awake. Resolves once connected. */
  async connect(): Promise<void> {
    if (FAKE) {
      if (!this.stopped) this.attach(new FakeR2())
      return
    }
    // Loaded lazily: spherov2.js loads noble, which some host processes get killed for.
    const { Scanner } = await import('spherov2.js')
    while (!this.stopped) {
      try {
        await waitForBluetooth()
        // Typed as R2D2 but resolves to undefined when nothing is found.
        const r2: R2 | undefined = await Scanner.findR2D2()
        if (r2 && this.stopped) {
          r2.destroy().catch(() => {})
          return
        }
        if (r2) return this.attach(r2)
        console.log(`No R2-D2 found, retrying in ${this.reconnectDelay / 1000}s`)
      } catch (e) {
        console.error(`Connecting to R2-D2 failed (${errorText(e)}), retrying in ${this.reconnectDelay / 1000}s`)
      }
      await sleep(this.reconnectDelay)
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
      this.selfMovingUntil = Number.MAX_SAFE_INTEGER
      try {
        await fn(r2)
      } finally {
        this.selfMovingUntil = Date.now() + 1200
      }
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
    clearInterval(this.rssiTimer)
    const r2 = this.r2
    this.r2 = undefined
    if (!r2) return
    await r2.sleep().catch(() => {})
    await r2.destroy().catch(() => {})
  }

  private attach(r2: R2) {
    this.r2 = r2
    const awayFor = this.disconnectedAt === undefined ? 0 : Date.now() - this.disconnectedAt
    this.disconnectedAt = undefined
    this.saidGoodbye = false
    this.weakReadings = 0
    // noble reuses one Peripheral object per device across reconnects, so the listener must be removed.
    const peripheral = peripheralOf(r2)
    const onDrop = () => this.onDisconnect(r2)
    peripheral.once('disconnect', onDrop)
    this.detach = () => peripheral.removeListener('disconnect', onDrop)
    this.keepAlive = setInterval(() => this.ping(), KEEP_ALIVE_MS)
    if (typeof peripheral.updateRssi === 'function') this.rssiTimer = setInterval(() => this.readRssi(r2), RSSI_MS)
    this.startSensing(r2)
    // Queued so it cannot interleave with a reaction that arrives right after connecting.
    this.queue = this.queue.then(() => r2.setAudioVolume(200)).then(() => moods.idle(r2)).catch(() => {})
    console.log(awayFor ? `R2-D2 ready again after ${Math.round(awayFor / 1000)}s away` : 'R2-D2 ready')
    if (awayFor > GREET_AFTER_MS) this.react('welcome').catch(() => {})
  }

  /** Sensor stream + collision events → touch reactions. The fake droid has neither and is skipped. */
  private startSensing(r2: R2) {
    const sensing = r2 as unknown as Partial<Sensing>
    if (!sensing.on || !sensing.configureSensorStream || !sensing.enableCollisionDetection) return
    this.senses = new Senses()
    const log = process.env.R2_SENSE_LOG === '1'
    sensing.on('onSensor', (data) => {
      if (this.r2 !== r2) return
      const d = data as unknown as SensorData
      const sample: Sample = { t: Date.now(), accel: d.accelerometer?.filtered, gyro: d.gyro?.filtered, angles: d.angles }
      if (log) console.log('sense', JSON.stringify(sample))
      if (Date.now() < this.selfMovingUntil) return this.senses.reset()
      for (const e of this.senses.feed(sample)) this.onSense(e)
    })
    sensing.on('onCollision', () => {
      if (this.r2 !== r2 || Date.now() < this.selfMovingUntil) return
      // A grab also jolts; wait a moment and drop the tap if a grab followed.
      clearTimeout(this.pendingTap)
      this.pendingTap = setTimeout(() => this.onSense('tap'), 700)
    })
    // Not queued behind reactions: these are setup commands; failures only mean no touch events.
    sensing.configureSensorStream().catch((e) => console.warn('sensor stream not available:', errorText(e)))
    sensing.configureCollisionDetection?.().catch(() => {})
    sensing.enableCollisionDetection().catch((e) => console.warn('collision detection not available:', errorText(e)))
  }

  private static readonly touchMoods: Record<SenseEvent | 'tap', Mood | undefined> = {
    grabbed: 'startled',
    setDown: 'relieved',
    shaken: 'dizzy',
    tippedOver: 'help',
    righted: 'relieved',
    tap: 'tapped',
  }

  private onSense(e: SenseEvent | 'tap') {
    if (e === 'tap' && this.lastSense?.event === 'grabbed' && Date.now() - Date.parse(this.lastSense.at) < 1500) return
    if (e === 'grabbed') clearTimeout(this.pendingTap)
    this.lastSense = { event: e, at: new Date().toISOString() }
    console.log(`touch: ${e}`)
    const mood = Droid.touchMoods[e]
    if (mood) this.react(mood).catch(() => {})
  }

  private readRssi(r2: R2) {
    if (this.r2 !== r2) return
    peripheralOf(r2).updateRssi?.((err, rssi) => {
      if (err || this.r2 !== r2 || typeof rssi !== 'number') return
      this.rssi = rssi
      if (rssi < GOODBYE_RSSI) this.weakReadings++
      else if (rssi > GOODBYE_RECOVER_RSSI) {
        this.weakReadings = 0
        this.saidGoodbye = false
      }
      if (this.weakReadings % 6 === 1 || rssi < GOODBYE_RSSI) console.log(`rssi ${rssi} dBm`)
      if (this.weakReadings >= 3 && !this.saidGoodbye) {
        this.saidGoodbye = true
        console.log('signal fading, saying goodbye')
        this.react('goodbye').catch(() => {})
      }
    })
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
    clearInterval(this.rssiTimer)
    this.detach?.()
    this.r2 = undefined
    this.rssi = undefined
    this.disconnectedAt = Date.now()
    console.warn('R2-D2 disconnected, reconnecting…')
    this.reconnectLoop().finally(() => (this.reconnecting = false))
  }

  private async reconnectLoop() {
    while (!this.stopped) {
      await sleep(this.reconnectDelay)
      try {
        await this.connect()
        return
      } catch (e) {
        console.error('reconnect failed, will retry:', errorText(e))
      }
    }
  }
}

// `peripheral` is private in spherov2.js but it is the only way to hear about drops or read signal strength.
type SensorData = {
  accelerometer?: { filtered: { x: number; y: number; z: number } }
  gyro?: { filtered: { x: number; y: number; z: number } }
  angles?: { pitch: number; roll: number; yaw: number }
}
type Sensing = {
  on(event: 'onSensor' | 'onCollision', handler: (data: unknown) => void): void
  configureSensorStream(): Promise<void>
  enableCollisionDetection(): Promise<unknown>
  configureCollisionDetection(): Promise<unknown>
}
type Peripheral = EventEmitter & { updateRssi?: (cb: (err: Error | null, rssi: number) => void) => void }
const peripheralOf = (r2: R2) => (r2 as unknown as { peripheral: Peripheral }).peripheral

export async function waitForBluetooth(hintEveryMs = 10_000, giveUpMs = 60_000) {
  const noble = (await import('@abandonware/noble')).default
  const state = () => (noble as unknown as { state: string }).state
  if (state() === 'poweredOn') return
  // While macOS shows the Bluetooth permission prompt the state stays "unknown", so this hints
  // rather than exits. It does give up after a minute: the caller retries, and a fresh wait
  // re-reads the state, which noble sometimes stops reporting after the Mac sleeps.
  await new Promise<void>((resolve, reject) => {
    const hint = setInterval(() => console.warn(bluetoothHint(state())), hintEveryMs)
    const giveUp = setTimeout(() => {
      cleanup()
      reject(new Error(`still waiting for Bluetooth (state: ${state()})`))
    }, giveUpMs)
    const cleanup = () => {
      clearInterval(hint)
      clearTimeout(giveUp)
      noble.removeListener('stateChange', onChange)
    }
    const onChange = (s: string) => {
      if (s !== 'poweredOn') return
      cleanup()
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
