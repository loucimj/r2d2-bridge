// Animation and audio IDs for the Sphero R2-D2.
//
// The names come from the Python spherov2 port
// (spherov2/toy/r2d2.py in artificial-intelligence-class/spherov2.py), which
// extracted them from the official app. They are NOT verified on this toy yet:
// run `npm run explore` and fix anything that does not match what you see.
// Entries you confirmed by hand are marked with "✓".

export const Animation = {
  // dock / charger
  charger1: 0,
  charger2: 1,
  charger3: 2,
  charger4: 3,
  charger5: 4,
  charger6: 5,
  charger7: 6,
  // emotes (dome + lights + sound)
  alarm: 7,
  angry: 8,
  attention: 9,
  frustrated: 10,
  drive: 11,
  excited: 12,
  search: 13,
  shortCircuit: 14,
  laugh: 15,
  no: 16,
  retreat: 17,
  fiery: 18,
  understood: 19,
  yes: 21,
  scan: 22,
  surprised: 24,
  // idle fidgets
  idle1: 25,
  idle2: 26,
  idle3: 27,
  // "watch with me" reactions
  wwmAngry: 31,
  wwmAnxious: 32,
  wwmBow: 33,
  wwmConcern: 34,
  wwmCurious: 35,
  wwmDoubleTake: 36,
  wwmExcited: 37,
  wwmFiery: 38,
  wwmFrustrated: 39,
  wwmHappy: 40,
  wwmJittery: 41,
  wwmLaugh: 42,
  wwmLongShake: 43,
  wwmNo: 44,
  wwmOminous: 45,
  wwmRelieved: 46,
  wwmSad: 47,
  wwmScared: 48,
  wwmShake: 49,
  wwmSurprised: 50,
  wwmTaunting: 51,
  wwmWhisper: 52,
  wwmYelling: 53,
  wwmYoohoo: 54,
  motor: 55,
} as const

export type Animation = (typeof Animation)[keyof typeof Animation]

// Audio file IDs. The full table has ~60 chatty, ~30 negative, ~25 sad clips
// and so on; these are the first of each R2-D2 group. Use `npm run explore --
// audio 1950 2010` style ranges to find more.
export const Audio = {
  fall: 1609,
  hit: 1623,
  step: 1690,
  accessPanels: 1704,
  alarm: 1737,
  annoyed: 1910,
  burnout: 1915,
  chatty: 1950,
  engageHyperdrive: 2586,
  excited: 2600,
  headSpin: 2797,
  hey: 2813,
  laugh: 2919,
  motor: 2970,
  negative: 3101,
  positive: 3302,
  sad: 3484,
  scream: 3797,
  scream2: 3810,
  shortOut: 3825,
} as const

export type Audio = (typeof Audio)[keyof typeof Audio]

// Families of clips, for reactions that should not sound the same twice (IDs from the same table).
export const AudioSets = {
  chatty: [1950, 1959, 1966, 1977, 1987, 2002, 2007, 2010, 2019, 2028, 2039, 2061],
  positive: [3302, 3309, 3318, 3326, 3340, 3353, 3358, 3364],
  negative: [3101, 3111, 3115, 3121, 3132, 3136],
  laugh: [2919, 2935, 2950, 2955],
  excited: [2600, 2615, 2633, 2644, 2654],
  sad: [3484, 3495, 3518, 3526],
  hey: [2813, 2824, 2828, 2833, 2841],
} as const

export const pick = (set: readonly number[]) => set[Math.floor(Math.random() * set.length)]
