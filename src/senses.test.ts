import assert from 'node:assert/strict'
import { test } from 'node:test'
import { Senses, type Sample } from './senses'

const rest = (t: number): Sample => ({ t, accel: { x: 0, y: 0, z: 1 }, gyro: { x: 0, y: 0, z: 0 }, angles: { pitch: 0, roll: 0, yaw: 0 } })
const run = (samples: Sample[]) => {
  const s = new Senses()
  return samples.flatMap((x) => s.feed(x))
}
const every = (from: number, to: number, f: (t: number) => Sample) => {
  const out: Sample[] = []
  for (let t = from; t < to; t += 250) out.push(f(t))
  return out
}

test('sitting still raises nothing', () => {
  assert.deepEqual(run(every(0, 10_000, rest)), [])
})

test('a lift then a calm stretch is grabbed then set down', () => {
  const lift = (t: number): Sample => ({ ...rest(t), accel: { x: 0.2, y: 0.1, z: 1.4 }, gyro: { x: 80, y: 0, z: 10 } })
  const events = run([...every(0, 1000, rest), ...every(1000, 2500, lift), ...every(2500, 6000, rest)])
  assert.deepEqual(events, ['grabbed', 'setDown'])
})

test('hard jolts in a row are a shake', () => {
  const jolt = (t: number): Sample => ({ ...rest(t), accel: { x: 2, y: 0, z: 1 } })
  const events = run([...every(0, 500, rest), ...every(500, 1500, jolt), ...every(1500, 5000, rest)])
  assert.ok(events.includes('shaken'), `got ${events}`)
})

test('lying on its side is tipped over, standing up again is righted', () => {
  const side = (t: number): Sample => ({ ...rest(t), angles: { pitch: 0, roll: 85, yaw: 0 } })
  const events = run([...every(0, 500, rest), ...every(500, 3000, side), ...every(3000, 5000, rest)])
  assert.ok(events.includes('tippedOver') && events.includes('righted'), `got ${events}`)
})

test('the same event is not repeated within the cooldown', () => {
  const jolt = (t: number): Sample => ({ ...rest(t), accel: { x: 2, y: 0, z: 1 } })
  const events = run(every(0, 2500, jolt))
  assert.equal(events.filter((e) => e === 'shaken').length, 1)
})
