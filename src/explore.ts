// Cycles through undocumented animation / audio IDs so you can map them by hand.
//
//   npm run explore -- animation 0 60
//   npm run explore -- audio 1600 1800   (16-bit IDs, see src/animations.ts)
//   npm run explore -- sound 0 255       (raw single-byte playAudioFile)
//
// After each ID it asks for a note. Notes are appended to explore-log.tsv.
// Fold the good ones into src/animations.ts.
import { appendFileSync } from 'node:fs'
import { createInterface } from 'node:readline/promises'
import { Scanner } from 'spherov2.js'
import { waitForBluetooth } from './droid'

type Kind = 'animation' | 'audio' | 'sound'

const [kind = 'animation', fromArg = '0', toArg = '40', delayArg = '3000'] = process.argv.slice(2)
const from = Number(fromArg)
const to = Number(toArg)
const delay = Number(delayArg)
const log = 'explore-log.tsv'

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

async function main() {
  if (!['animation', 'audio', 'sound'].includes(kind)) {
    console.error(`unknown kind "${kind}", use animation | audio | sound`)
    process.exit(1)
  }
  await waitForBluetooth()
  const r2 = await Scanner.findR2D2()
  if (!r2) {
    console.error('No R2-D2 found. Is it on, charged, and disconnected from the phone app?')
    process.exit(1)
  }
  await r2.setAudioVolume(255)
  const rl = process.stdin.isTTY ? createInterface({ input: process.stdin, output: process.stdout }) : null

  for (let id = from; id <= to; id++) {
    console.log(`\n>>> ${kind} ${id}`)
    try {
      if (kind === 'animation') await r2.playAnimation(id)
      else if (kind === 'audio') await r2.playR2D2Sound(id >> 8, id & 0xff)
      else await r2.playAudioFile(id)
    } catch (e) {
      console.log(`    failed: ${e}`)
    }
    await sleep(delay)
    if (!rl) continue
    const note = (await rl.question('    note (Enter = skip, q = quit): ')).trim()
    if (note === 'q') break
    if (note) appendFileSync(log, `${kind as Kind}\t${id}\t${note}\n`)
  }

  rl?.close()
  await r2.sleep().catch(() => {})
  await r2.destroy().catch(() => {})
  process.exit(0)
}

main().catch((e) => {
  console.error(e)
  process.exit(1)
})
