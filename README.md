# Apple TV Remote for Mac

A native macOS remote for any Apple TV on your network. Built with Swift and SwiftUI.
No web view, no Electron. The app speaks Apple's Companion Link protocol directly, the same
protocol the Siri Remote and the iPhone Remote use.

![Menu bar and window](docs/screenshot.png)

## Features

- Finds every Apple TV on the local network.
- Pairs with the four-digit PIN the TV shows. The pairing persists.
- Clickpad: scroll to swipe, click to select, click an edge to move.
- Back, TV, Play/Pause, Volume up and down, Siri (hold), and a power button that sleeps an
  awake TV and wakes a sleeping one.
- Full keyboard control. Arrow keys, Return, Escape, Space.
- Types into Apple TV text fields with the Mac keyboard. Return runs a search.
- Command-K app launcher.
- Now playing: title, app, artwork and a live progress bar with pause and skip.
- The menu bar item shows the artwork and the title of what plays. Its panel holds a compact
  remote with the same card.
- Control-Option-R summons the window from any app.
- Switch Apple TVs with Command-1 to Command-9.
- `atvctl` command line tool for scripts.

## Requirements

- macOS 15 or later.
- An Apple TV 4K or Apple TV HD on the same network, tvOS 15 or later.

## Install

### From the DMG

1. Download `AppleTVRemote.dmg` from the Releases page.
2. Open it and drag **Apple TV Remote** to Applications.
3. The app is not notarized yet. On the first launch, right-click the app in Applications and
   choose **Open**, then confirm. macOS asks only once.
4. Allow local network access when macOS asks. The app needs it to find your Apple TV.

### From source

Xcode is not required. The Command Line Tools are enough.

```sh
xcode-select --install          # once, if you have no Command Line Tools
git clone https://github.com/areddy1000/apple-tv-remote-mac.git
cd apple-tv-remote-mac
scripts/run.sh                  # debug build, bundle, open
scripts/make-dmg.sh             # release build and dist/AppleTVRemote.dmg
scripts/test.sh                 # unit tests
```

The scripts set `SDKROOT` to the macOS 26.5 SDK inside the Command Line Tools. When you run
`swift` by hand, set it first:

```sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
```

## Use

### First run

1. Open the app. The toolbar shows the first Apple TV it finds. Pick another one from the
   same menu.
2. The TV shows a four-digit code. Type it into the sheet and click **Pair**.
3. A few seconds later the TV shows a second code. This one is for the now-playing link.
   Type it in the same way.

Both pairings persist. Later launches connect in under a second with no code.

### The remote

| Control | Action |
| --- | --- |
| Scroll on the clickpad | Swipe |
| Click the clickpad centre | Select |
| Click near a clickpad edge | Up, Down, Left or Right |
| Back, TV, Play/Pause | The same buttons as the Siri Remote |
| Minus, Plus | Volume down, volume up |
| Microphone | Siri. Hold it while you speak |
| Power | Sleep an awake TV. Wake a sleeping one |
| Now-playing card | Pause, play, skip back and forward ten seconds |

### Keys

| Key | Action |
| --- | --- |
| Arrows | Move |
| Return | Select |
| Escape or Delete | Back |
| Space | Play/Pause |
| Command-Up, Command-Down | Volume |
| Command-K | Open an app. Type to filter, Return to launch |
| Command-T | Type text. Return runs the search. Escape closes the bar |
| Command-Shift-H | TV (home) |
| Command-1 to Command-9 | Switch Apple TV |
| Control-Option-R | Summon the remote from any app |

### Text input

Open a text field on the TV, for example Search. The keyboard bar appears in the app by
itself. Press Command-T if it does not. Type on the Mac keyboard. Paste works. Return runs
the search. Escape sends Back and closes the bar.

### Menu bar

Click the menu bar item for a compact remote. While something plays, the item shows the
artwork and the title. Open the full window from the panel with the window button.

### Command line

```sh
.build/debug/atvctl discover
.build/debug/atvctl press select
.build/debug/atvctl press menu --hold 500
.build/debug/atvctl swipe down
.build/debug/atvctl launch com.google.ios.youtube
.build/debug/atvctl type "hello"
.build/debug/atvctl apps
.build/debug/atvctl state
.build/debug/atvctl media pause
.build/debug/atvctl volume 40
.build/debug/atvctl now-playing --watch 60
.build/debug/atvctl forget
```

Run `atvctl` with no arguments for the full list. Add `--device "Living Room"` to pick one
Apple TV by name. The Apple TV allows one session for each paired client, so quit the app
before you use `atvctl`.

### Scripting

The app answers URL commands. For example from a Shortcut or a terminal:

```sh
open "atvremote://press/select"
open "atvremote://launch/com.google.ios.youtube"
open "atvremote://media/pause"
open "atvremote://device/Living%20Room"
open "atvremote://wake"
```

Verbs: `press/<button>`, `launch/<bundle-id>`, `media/<play|pause|toggle|next|previous|skip-forward|skip-backward>`,
`device/<name>`, `wake` and `sleep`.

## Credentials

Pairing keys live in `~/Library/Application Support/AppleTVRemote/credentials.json` with
mode 0600. Delete the file to pair again. Use **Forget This Apple TV** in the device menu to
remove one TV.

## Limits

- The volume slider appears only when the Apple TV reports a volume level. An HDMI
  television controlled over CEC reports none, so the plus and minus keys work but no slider
  shows. AirPlay speakers and HomePods report a level.
- The app is ad-hoc signed. `scripts/notarize.sh` signs and notarizes it when a Developer ID
  is available.

## How it works

- Discovery: Bonjour, `_companion-link._tcp` and `_airplay._tcp`.
- Control: Companion Link over TCP with HomeKit pairing (SRP-6a, Curve25519, Ed25519) and
  ChaCha20-Poly1305 encryption. Buttons, touch, text and app launch travel on this link.
- Now playing: the MediaRemote protocol tunneled over AirPlay 2, with a second HomeKit
  pairing.
- The protocol facts come from the pyatv project. Thanks to its authors.

## License

MIT
