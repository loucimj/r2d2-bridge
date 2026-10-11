// Tiny HTTP client used by all triggers. Never throws: a missing daemon must not break your tools.
import type { Mood } from './droid'

export const BRIDGE_URL = process.env.R2_BRIDGE_URL ?? 'http://127.0.0.1:4242'

export async function react(mood: Mood): Promise<boolean> {
  try {
    const res = await fetch(`${BRIDGE_URL}/react/${mood}`, { method: 'POST', signal: AbortSignal.timeout(2000) })
    return res.ok
  } catch {
    return false
  }
}
