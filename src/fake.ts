// Stand-in R2-D2 for R2_FAKE=1: logs each command instead of talking Bluetooth.
// R2_FAKE_DISCONNECT_MS=<ms> drops the "link" once, that long after the first connect.
import { EventEmitter } from 'node:events'

let dropScheduled = false

const log = (line: string) => {
  console.log(`[fake r2] ${line}`)
  return Promise.resolve()
}

export class FakeR2 {
  readonly peripheral = new EventEmitter()

  constructor() {
    const ms = Number(process.env.R2_FAKE_DISCONNECT_MS)
    if (dropScheduled || !(ms > 0)) return
    dropScheduled = true
    setTimeout(() => {
      console.log('[fake r2] simulating disconnect')
      this.peripheral.emit('disconnect')
    }, ms).unref()
  }

  wake = () => log('wake')
  sleep = () => log('sleep')
  destroy = () => log('destroy')
  playAnimation = (id: number) => log(`playAnimation ${id}`)
  playR2D2Sound = (hi: number, lo: number) => log(`playR2D2Sound ${hi} ${lo}`)
  playAudioFile = (idx: number) => log(`playAudioFile ${idx}`)
  turnDome = (angle: number) => log(`turnDome ${angle}`)
  setStance = (stance: number) => log(`setStance ${stance}`)
  setR2D2LEDColor = (r: number, g: number, b: number) => log(`setR2D2LEDColor ${r} ${g} ${b}`)
  setR2D2FrontLEDColor = (r: number, g: number, b: number) => log(`setR2D2FrontLEDColor ${r} ${g} ${b}`)
  setR2D2BackLEDcolor = (r: number, g: number, b: number) => log(`setR2D2BackLEDcolor ${r} ${g} ${b}`)
  setR2D2LogicDisplaysIntensity = (i: number) => log(`setR2D2LogicDisplaysIntensity ${i}`)
  setR2D2HoloProjectorIntensity = (i: number) => log(`setR2D2HoloProjectorIntensity ${i}`)
  startIdleLedAnimation = () => log('startIdleLedAnimation')
  setAudioVolume = (vol: number) => log(`setAudioVolume ${vol}`)
}
