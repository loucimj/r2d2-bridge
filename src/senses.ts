// Turns R2-D2's sensor stream into a few events: grabbed, set down, shaken, tipped over.
// Pure logic, no Bluetooth: Droid feeds it samples and acts on what it returns.
//
// Units from spherov2.js: accelerometer in g (resting ≈ 1 g total), gyro in °/s, angles in degrees.
// Thresholds are first guesses; tune them with R2_SENSE_LOG=1 and a few real grabs.

export type Sample = {
  t: number // ms
  accel?: { x: number; y: number; z: number }
  gyro?: { x: number; y: number; z: number }
  angles?: { pitch: number; roll: number; yaw: number }
}

export type SenseEvent = 'tapped' | 'grabbed' | 'setDown' | 'shaken' | 'tippedOver' | 'righted'

export const LIMITS = {
  grabAccel: Number(process.env.R2_GRAB_G ?? 0.25), // |a| away from 1 g
  grabGyro: Number(process.env.R2_GRAB_DPS ?? 60), // °/s
  shakeAccel: Number(process.env.R2_SHAKE_G ?? 0.9),
  shakeHits: 3, // strong jolts within shakeWindow
  shakeWindow: 1500,
  tiltDeg: 60, // pitch or roll beyond this…
  tiltFor: 1500, // …for this long = tipped over
  // A tap is a blip: at most tapMaxSamples moving readings, then tapQuiet calm ones, tilt unchanged.
  // Anything longer, or a tilt change beyond grabTiltDeg, is a grab. At ~4 readings/s a tap is one spike.
  tapMaxSamples: 2,
  tapQuiet: 2,
  grabTiltDeg: 15,
  stillAccel: 0.1,
  stillGyro: 20,
  stillFor: 1500, // calm this long after a grab = set down
  cooldown: 4000, // minimum time between two events of the same kind
}

const mag = (v: { x: number; y: number; z: number }) => Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)

type Candidate = { moving: number; quiet: number; tilt0: { pitch: number; roll: number } }

export class Senses {
  private held = false
  private tipped = false
  private calmSince?: number
  private tiltSince?: number
  private jolts: number[] = []
  private candidate?: Candidate
  private restTilt = { pitch: 0, roll: 0 }
  private lastEvent: Partial<Record<SenseEvent, number>> = {}

  /** Feeds one sample, returns the events it completes (usually none). */
  feed(s: Sample): SenseEvent[] {
    const out: SenseEvent[] = []
    const accelOff = s.accel ? Math.abs(mag(s.accel) - 1) : 0
    const spin = s.gyro ? mag(s.gyro) : 0
    const tilt = s.angles ? Math.max(Math.abs(s.angles.pitch), Math.abs(s.angles.roll)) : 0
    const moving = accelOff > LIMITS.grabAccel || spin > LIMITS.grabGyro
    const calm = accelOff < LIMITS.stillAccel && spin < LIMITS.stillGyro
    if (calm && !this.held && s.angles) this.restTilt = { pitch: s.angles.pitch, roll: s.angles.roll }

    // Shaken: several strong jolts close together. Counts as being held, without a separate grab.
    if (accelOff > LIMITS.shakeAccel) this.jolts.push(s.t)
    this.jolts = this.jolts.filter((t) => s.t - t < LIMITS.shakeWindow)
    if (this.jolts.length >= LIMITS.shakeHits) {
      this.jolts = []
      this.candidate = undefined
      this.held = true
      this.calmSince = undefined
      if (this.emit('shaken', s.t)) out.push('shaken')
      return out
    }

    // Tipped over: lying at a steep angle for a while; righted when back up.
    if (tilt > LIMITS.tiltDeg) {
      this.tiltSince ??= s.t
      if (!this.tipped && s.t - this.tiltSince > LIMITS.tiltFor && this.emit('tippedOver', s.t)) {
        this.tipped = true
        this.candidate = undefined
        out.push('tippedOver')
      }
    } else {
      this.tiltSince = undefined
      if (this.tipped && tilt < LIMITS.tiltDeg / 2) {
        this.tipped = false
        out.push('righted')
      }
    }

    if (this.held) {
      // Set down: a calm stretch after being held.
      if (!calm) this.calmSince = undefined
      else {
        this.calmSince ??= s.t
        if (s.t - this.calmSince > LIMITS.stillFor) {
          this.held = false
          if (!this.tipped && this.emit('setDown', s.t)) out.push('setDown')
        }
      }
      return out
    }

    // Tap or grab: a movement starts a candidate; its length and tilt decide which it was.
    const c = this.candidate
    if (!c) {
      if (moving && !this.tipped) this.candidate = { moving: 1, quiet: 0, tilt0: { ...this.restTilt } }
      return out
    }
    const tiltMoved = s.angles
      ? Math.max(Math.abs(s.angles.pitch - c.tilt0.pitch), Math.abs(s.angles.roll - c.tilt0.roll)) > LIMITS.grabTiltDeg
      : false
    if (moving || tiltMoved) {
      c.moving++
      c.quiet = 0
      if (c.moving > LIMITS.tapMaxSamples || tiltMoved) {
        this.candidate = undefined
        this.held = true
        this.calmSince = undefined
        if (this.emit('grabbed', s.t)) out.push('grabbed')
      }
    } else if (++c.quiet >= LIMITS.tapQuiet) {
      this.candidate = undefined
      if (this.emit('tapped', s.t)) out.push('tapped')
    }
    return out
  }

  /**
   * R2 is moving on its own (an animation): drop half-read gestures, but keep whether it is
   * being held, so the set-down still comes once things calm down.
   */
  reset() {
    this.candidate = undefined
    this.jolts = []
    this.calmSince = undefined
  }

  private emit(e: SenseEvent, t: number): boolean {
    const last = this.lastEvent[e]
    const cooldown = e === 'tapped' ? 1500 : LIMITS.cooldown
    if (last !== undefined && t - last < cooldown) return false
    this.lastEvent[e] = t
    return true
  }
}
