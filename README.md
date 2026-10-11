# r2d2-bridge

Makes a Sphero R2-D2 react to what happens on your computer. A small daemon keeps
the droid connected over Bluetooth Low Energy and exposes `POST /react/:mood` on
`127.0.0.1:4242`. Triggers (CLI wrapper, git hook, Claude Code hooks) just call it.

Built on [spherov2.js](https://github.com/igbopie/spherov2.js), an unofficial
reverse-engineered Sphero V2 API on top of `@abandonware/noble`.

## Setup

Requirements: Node 20 or newer (tested on Node 26), a C++ toolchain for the native
BLE module, and the R2-D2 **disconnected from the phone app** (BLE allows one connection).

```bash
npm install
```

npm 11 blocks install scripts by default. If `npm install` prints an `install-scripts`
warning, approve the two that need to build and rebuild:

```bash
npm install-scripts approve @abandonware/noble esbuild && npm rebuild
```

### macOS

- Xcode Command Line Tools: `xcode-select --install`
- macOS attributes Bluetooth access to the app that launched the process and kills
  node unless that app declares `NSBluetoothAlwaysUsageDescription`. Terminal and
  Warp do not (tested on macOS 27), so `npm start` from them dies with exit 134.
  Use the menu bar app instead (next section).
- VS Code's integrated terminal also declares the key, so `npm start` and
  `npm run explore` work from there after you allow the prompt.

### Linux

- `sudo apt install bluetooth bluez libbluetooth-dev libudev-dev build-essential`
- Let node open raw BLE sockets without root:
  `sudo setcap cap_net_raw+eip $(eval readlink -f $(which node))`

### Windows

- Needs a WinUSB-bound BLE dongle via Zadig (see the noble README). The built-in
  Bluetooth stack is not supported by `@abandonware/noble`.

## Menu bar app (macOS)

```bash
npm run app
```

Builds `dist/R2 Bridge.app` from the SwiftUI package in `macos/R2Menu` (Swift 5.9+, macOS 13+)
and opens it. It sits in the status bar, starts the node daemon on launch and stops it on quit,
and shows whether R2 is connected. The menu has the moods, dome and light controls, the demo
page, the daemon log, start/stop/restart, and a Launch at Login toggle. Allow the Bluetooth
prompt the first time. The bundle reads `Contents/Resources/bridge.json` for the project
directory and node path, so rebuild after moving the project or changing Node.

## Voice commands (macOS)

The menu bar app listens for **"R2"** or **"Artu"** and takes the rest of the sentence as a
command. R2 answers the wake word at once: front LED blue, dome turns to you with a "hey" chirp.
Turn it on with *Listen for "R2" / "Artu"* in the menu; allow the microphone and speech recognition
prompts once. ⌃⌥R is push-to-talk: the next sentence is a command with no wake word.

Recognition runs on-device in English and Spanish at the same time, so either wake word works
with either language ("R2, poné música" is fine). The language is picked from the transcripts:
accents, ñ and common words settle most sentences without the model; the rest go to the model
with both readings and it chooses the coherent one. Replies come back in the language you spoke.

Commands are routed by a local model on [Ollama](https://ollama.com) (`ollama pull qwen3:4b`),
which answers in about a second with an intent, a one-line reply in your language and an R2 mood:

- "Artu, poné música" / "R2, play some music" → Spotify plays
- "R2, search quantum computing" → Safari opens a web search
- "Artu, ¿cómo está mi calendario?" → Calendar opens, Claude summarizes today
- "Artu, estuvo bien eso, ¿no?" → approval: happy mood and a cheeky reply
- anything else that needs real information → handed to Claude Code

**Your own phrases** go in `~/Library/Application Support/R2 Bridge/phrases.json` (menu →
*Edit Phrases…*; created with an example on first run). They are matched before the model, so
they are instant and exact. Each entry has `match` (any of these, accent-insensitive substrings)
and any of `reply`, `mood`, `spotify` (a `spotify:track:` / `album:` / `playlist:` URI),
`open` (URL or app name) and `animation` (raw id). The example plays Highway to Hell for
"R2, daddy is home" or "Artu, llegó papá".

The Claude tier runs `claude -p` headless with `macos/claude-voice-settings.json`, which only
allows read-only tools, `osascript` and `open`, and loads the companion mod so R2 reacts while
Claude works. Replies are spoken with a system voice (Spanish uses the Mexican voice when no
Argentine one is installed). Without Ollama a few built-in patterns keep the basics working.

## Run

```bash
npm start
```

Scans for a device advertising `D2-…`, connects, sets the idle stance and waits.
A keep-alive command is sent every 60 s so the droid does not fall asleep; if the
link drops, the daemon rescans and reconnects on its own.

```bash
curl -X POST http://127.0.0.1:4242/react/happy
curl -X POST http://127.0.0.1:4242/react/alarm
curl -X POST http://127.0.0.1:4242/react/attention
curl -X POST http://127.0.0.1:4242/react/thinking
curl http://127.0.0.1:4242/health
```

Moods: `happy`, `alarm`, `attention`, `thinking`, `sad`, `busy`, `idle`. Reactions
run one at a time in the order received. The daemon also watches CPU load and plays
`busy` when the 1-minute load average per core goes above 1.5, then `happy` when it drops.

`R2_FAKE=1 npm start` runs without Bluetooth: a fake droid logs each command instead (noble is never loaded).
Add `R2_FAKE_DISCONNECT_MS=<ms>` to simulate one dropped link and exercise the reconnect path.

## Demo page

With the daemon running, open <http://127.0.0.1:4242/>. It lists every mood, every named
animation and audio ID with a note field (saved to `explore-log.tsv`), free ID inputs, and live
controls for the dome, stance, LEDs, holo projector, logic displays, volume, wake and sleep.
The page talks to `POST /cmd` (`{"method": "turnDome", "args": [90]}`, whitelisted methods only),
`GET /catalog` and `GET/POST /notes|/note`.

## Mapping animation and audio IDs

The IDs are undocumented. `src/animations.ts` ships names taken from the Python
spherov2 port, unverified on your droid. Check them:

```bash
npm run explore -- animation 0 55
npm run explore -- audio 1600 1800
```

Each ID plays, then you are asked for a note; notes go to `explore-log.tsv`.
`npm run explore` needs a Bluetooth-capable terminal (see macOS above). From any other
terminal, map IDs through the running daemon instead:

```bash
curl -X POST http://127.0.0.1:4242/play/animation/40
curl -X POST http://127.0.0.1:4242/play/audio/1950
```
Fix the names in `src/animations.ts` as you go. Audio IDs are 16-bit, so the bridge
sends them through `playR2D2Sound(hi, lo)` rather than the single-byte `playAudioFile`.

## Triggers

Link the CLI once so `r2` is on your PATH:

```bash
npm link
```

- `r2 run <command>`: runs the command and reacts `happy` on exit 0, `alarm` otherwise.
  Example: `r2 run npm test`.
- `r2 react <mood>`: fire a mood by hand.
- `r2 git-hook install`: adds a `post-commit` hook to the current repo that plays
  `happy` after every commit. `r2 git-hook uninstall` removes it.
- `r2 claude-hook`: prints a minimal Claude Code hooks block (`Stop` → `happy`,
  `permission_prompt` / `idle_prompt` → `attention`); copy in `examples/claude-settings.json`.
  The companion mod below does more; use one or the other, not both.

## Claude Code companion mod

`mod/r2-companion` is a Claude Code plugin (function hooks) that gives R2 a running
commentary of a session:

- turn starts → dome turns, logic displays on, status line `R2 · thinking`
- a tool fails → negative chirp, red back LED
- turn ends with edits → `happy`; without edits → a "hey" chirp and dome to center
- turn interrupted → dome to center; model error → `sad`
- permission or idle prompt → `attention`
- `/r2 <mood>` fires a mood by hand

Run a session with it: `claude --plugin-dir ~/workspaces/loucimj/r2d2-bridge/mod/r2-companion`,
or add that folder to `CLAUDE_CODE_PLUGIN_DIRS`. The bridge URL is a plugin option
(`bridgeUrl`, default `http://127.0.0.1:4242`). Check it with `claude plugin validate mod/r2-companion`
and `claude plugin test mod/r2-companion`. A daemon that is down is ignored; nothing in the
session slows down or breaks.

`r2 run` and the git hook fail silently when the daemon is not running, so they never break
your tools; `r2 react` tells you. The port is the `PORT` constant in `src/index.ts`; if you
change it, point the triggers at it with `R2_BRIDGE_URL`.

## Troubleshooting

- `npm start` dies right after `listening on …` with exit code 134 (SIGABRT): macOS killed
  node because the app you launched it from has no Bluetooth usage description. This
  happens inside editors and AI tools that embed a shell (the crash report says
  `NSBluetoothAlwaysUsageDescription`). Run it from Terminal or iTerm instead.
- `Scanning devices...` and nothing else: Bluetooth permission (see macOS above), or
  R2 is asleep. Tap its head or put it on the charger for a second.
- `No R2-D2 found`: still connected to the phone app, or out of range.
- `Command Timedout`: the link dropped mid-command. The daemon reconnects by itself.
- Native build errors on `npm install`: make sure the toolchain above is installed, or
  try Node 20 LTS. `@abandonware/noble` 1.9.2-26 builds cleanly on Node 20 through 26 on
  Apple Silicon.
