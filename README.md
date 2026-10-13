# Apple TV Remote for Mac

A native macOS remote for any Apple TV on your network. The app is Swift and SwiftUI. It
speaks the same protocol as the Siri Remote and the iPhone Remote. It lives only in the menu
bar. It has no window and no Dock icon.

## Install

### Option 1: the DMG

1. Download `AppleTVRemote.dmg` from the Releases page.
2. Open the DMG. Drag **Apple TV Remote** to Applications.
3. Right-click the app in Applications and choose **Open**. Click **Open** in the dialog.
   macOS shows this dialog one time, because the app is not notarized.
4. Click **Allow** when macOS asks for local network access. The app needs it to find your
   Apple TV.

### Option 2: build from source

You do not need Xcode. The Command Line Tools are enough.

```sh
xcode-select --install
git clone https://github.com/areddy1000/apple-tv-remote-mac.git
cd apple-tv-remote-mac
scripts/run.sh
```

The script builds the app, makes the bundle, and opens it. `scripts/make-dmg.sh` makes a
release DMG. `scripts/test.sh` runs the unit tests.

## Pair with your Apple TV

1. Open the app. The toolbar shows the first Apple TV it finds. Click the name to pick
   another one.
2. The TV shows a four-digit code. Type the code into the sheet. Click **Pair**.

That is the only code. The app keeps the pairing. Later launches connect in less than one
second with no code.

To pair again, choose **Forget This Apple TV** from the device menu. Then click the device
name to connect.

## The remote

| Control | Action |
| --- | --- |
| Scroll on the clickpad | Swipe |
| Click the centre of the clickpad | Select |
| Click near an edge of the clickpad | Up, Down, Left or Right |
| Back | Go up one level |
| TV | Go to the Home screen |
| Play/Pause | Play or pause |
| Minus, Plus | Volume down, volume up |
| Microphone | Siri. Hold the button while you speak |
| Power | Sleep an awake TV. Wake a sleeping TV |

The now-playing card appears at the top while media plays. It shows the artwork, the title,
the app and a progress bar. The card has pause, play, skip back and skip forward buttons.
Each skip moves ten seconds. Drag anywhere on the progress bar to seek. The time labels follow
the pointer while you drag, and playback moves when you let go.

A volume slider appears below the buttons when a volume level is known. Set up the volume
hook below when your volume keys do nothing.

## Keys

| Key | Action |
| --- | --- |
| Arrow keys | Move |
| Return | Select |
| Escape or Delete | Back |
| Space | Play/Pause |
| Command-Up, Command-Down | Volume up, volume down |
| Command-K | Open an app. Type to filter. Press Return to launch |
| Command-T | Show the text bar |
| Command-Shift-H | TV (Home screen) |
| Control-Option-R | Open the remote in the menu bar from any app |
| Command-Q | Quit (also in the Apple TV menu at the top of the panel) |

The keys work while the menu bar panel is open.

Hold an arrow key to repeat the move. Hold Return for a long press of Select.

## Type on the Apple TV

1. Open a text field on the TV. For example, open Search.
2. The text bar appears in the app. Press Command-T if it does not.
3. Type on the Mac keyboard. Paste works.
4. Press Return to run the search.
5. Press Escape to close the bar and go back one level.

## Menu bar

Click the menu bar item, or press Control-Option-R, to open the remote. While media plays, the
item shows the artwork and the title.

At launch, the app connects by itself only to a paired Apple TV, the last used one first.
The menu bar icon always shows. With no Apple TV on the network, the list says "No devices
found".

Without a link, the panel shows the Apple TVs on the network now. An Apple TV that was paired
before but is away does not show. Click an Apple TV to open it. There you can connect to a paired
Apple TV, or pair a new one. Nothing connects or pairs until you click. A pairing shows a PIN
on the TV, which turns the TV on.

With a link, the Apple TV menu at the top of the panel holds Disconnect, Forget This Apple TV,
Wake, Sleep, Screensaver, and Quit. Disconnect goes back to the list. If the link drops, the
app tries one time to connect again. If that fails, the panel shows the list.

## Command line tool

The build also makes `atvctl`. It shares the pairing with the app. Quit the app before you
use it, because the Apple TV allows one session for each paired client.

```sh
.build/debug/atvctl discover
.build/debug/atvctl press select
.build/debug/atvctl press menu
.build/debug/atvctl press play-pause --hold 300
.build/debug/atvctl swipe down
.build/debug/atvctl type "hello"
.build/debug/atvctl apps
.build/debug/atvctl launch com.google.ios.youtube
.build/debug/atvctl media pause
.build/debug/atvctl state
.build/debug/atvctl volume 40
.build/debug/atvctl now-playing --watch 60
.build/debug/atvctl now-playing --seek 600 --watch 5
.build/debug/atvctl forget
```

Button names: `up`, `down`, `left`, `right`, `select`, `menu`, `home`, `volume-up`,
`volume-down`, `siri`, `screensaver`, `sleep`, `wake`, `play-pause`, `channel-up`,
`channel-down`, `guide`, `page-up`, `page-down`.

Media names: `play`, `pause`, `toggle`, `next`, `previous`, `skip-forward`, `skip-backward`.

Options:

| Option | Meaning |
| --- | --- |
| `--device <name>` | Pick the Apple TV by name. The default is the first one found |
| `--wait <seconds>` | Discovery time before a command runs. The default is 2 |
| `--hold <ms>` | Hold time for `press`. The default is 0 |
| `--watch <seconds>` | How long `now-playing` listens. The default is 30 |
| `--seek <seconds>` | With `now-playing`, move playback to this position first |
| `--pin-file <path>` | Read the PIN from this file instead of the terminal |

Run `atvctl` with no arguments to see this list.

## URL commands

Other apps and Shortcuts can control the TV through the app with `atvremote://` URLs.

```sh
open "atvremote://press/select"
open "atvremote://press/menu"
open "atvremote://launch/com.google.ios.youtube"
open "atvremote://media/pause"
open "atvremote://device/Living%20Room"
open "atvremote://wake"
open "atvremote://sleep"
```

The `press` and `media` verbs take the same names as the command line tool.

## Volume hook

Volume works out of the box when the Apple TV has a volume route of its own. That means a
soundbar or receiver on HDMI ARC, or an AirPlay speaker such as a HomePod.

Many televisions give the Apple TV no such route. The Apple TV then sends volume by infrared
from the remote itself, and no network client can reach that, not this app and not Apple's
own Remote app. The symptom is plain: the Apple TV blinks when you press the key, and
nothing happens. The app shows **Volume needs local access to your TV** where the slider
normally is.

The hook fixes that by talking to the television directly. Put a file named
`volume-command.json` in `~/Library/Application Support/AppleTVRemote/`:

```json
{
  "up":   "my-tv-tool up",
  "down": "my-tv-tool down",
  "set":  "my-tv-tool set {level}",
  "get":  "my-tv-tool get"
}
```

Every field is optional. `up` and `down` run for one press of the volume keys. `set` runs
when you drag the slider, with `{level}` replaced by a whole number from 0 to 100. `get`
prints the level as a whole number from 0 to 100, and the slider appears when it is present.

### A helper that stays running

A command that opens a fresh connection on every press feels slow, because the connection
costs far more than the command. Televisions that need a session, such as LG and Samsung,
are better served by a helper the app keeps running:

```json
{ "daemon": "my-tv-helper serve" }
```

The app starts it once and holds it. The helper reads one request per line on its standard
input and answers with exactly one line on its standard output:

| Request | Answer |
| --- | --- |
| `up` | `ok` |
| `down` | `ok` |
| `set 37` | `ok` |
| `get` | a whole number, 0 to 100 |
| anything that failed | `err <reason>` |

The helper exits when its standard input closes, which is how it learns the app has gone.
The app starts it again if it stops on its own. This field wins over the four above.

On an LG this takes a press from about one second to about sixty milliseconds.

Each value is a shell command run with your own account, the same trust as a shell alias.
The app never writes this file. It re-reads it when you change it, so there is no restart.
The hook runs only when the Apple TV reports no volume route, so a later soundbar takes
over by itself.

Check it from the terminal with the app closed:

```sh
.build/debug/atvctl volume        # prints the level
.build/debug/atvctl volume 30     # sets the level
```

### Commands for common televisions

The tools below are other people's projects. Pick the one for your brand, confirm it works
in a terminal, then put it in the file.

**Roku TV**, including TCL, Hisense and onn. No pairing, nothing to install:

```json
{
  "up":   "curl -s -X POST http://TV-ADDRESS:8060/keypress/VolumeUp",
  "down": "curl -s -X POST http://TV-ADDRESS:8060/keypress/VolumeDown"
}
```

**LG webOS**, with [aiowebostv](https://github.com/home-assistant-libs/aiowebostv). It reports
a level, so the slider works. The television shows a prompt the first time you connect. Use
the `daemon` field, because each connection costs about a second.

**Samsung Tizen**, with [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api). Keys
only, no level.

**Sony Bravia**, with the pre-shared key from the television's own menu.

**Anything else.** Any script that exits zero counts. The `get` command only has to print a
number.

## Where the app keeps its data

The pairing keys are in `~/Library/Application Support/AppleTVRemote/`. The files have mode
0600. Delete the folder to remove every pairing. The same folder holds `volume-command.json`
when you set up the volume hook.

The app launcher shows each app's icon. The TV sends no icons, so the app asks Apple's public
app lookup service for the artwork of each bundle identifier, one time, and keeps the image in
the `icons` folder next to the pairing keys. Only the bundle identifier leaves your Mac.

## License

MIT. The protocol facts come from the pyatv project. Thank you to its authors.
