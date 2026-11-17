# Continuous

One keyboard and mouse across two Macs that can't share an Apple ID.

Apple's own Universal Control needs the same Apple ID on both machines. If one Mac is managed
by your employer and the other is yours, that is not a trade you should have to make. The
third-party alternatives solve it, but they ask for Accessibility and Input Monitoring —
permission to read every keystroke you type — and you have to take their word for what happens
next.

Continuous is the same idea with the trust removed: it runs only on your two Macs, it talks
only to the other Mac, and the code that holds those permissions is in this repository.

```
     Mac A (your keyboard)                 Mac B (its screen)
  ┌────────────────────────┐          ┌────────────────────────┐
  │  pointer hits the edge │  ──────► │  pointer appears here  │
  │  keystrokes forwarded  │   TLS    │  keystrokes injected   │
  └────────────────────────┘          └────────────────────────┘
          no cloud · no account · no third-party server
```

**Status: all five milestones done.** Push the pointer off the edge of one Mac and it appears on the
other, with the keyboard following it. It reconnects on its own, starts at login, shares a
clipboard if you ask it to, and lives in the menu bar. See [BLUEPRINT.md](BLUEPRINT.md) for
how it is built and [docs/SECURITY.md](docs/SECURITY.md) for the security model.

---

## Build

Needs the Swift toolchain that ships with Xcode Command Line Tools. Nothing else — no
packages are downloaded, the whole dependency list is Apple's own SDK.

```bash
git clone <this repo> && cd Continuous
Scripts/build.sh            # builds and wraps the binary in Continuous.app
build/continuous selftest   # proves the crypto and transport work on this Mac
```

`Scripts/build.sh --install` also symlinks `continuous` into `/usr/local/bin`.

The binary lives inside a `.app` bundle on purpose. macOS attributes privacy permissions to the
bundle, so Continuous asks for Accessibility as *itself* rather than silently borrowing the
grant you gave your terminal.

## Pair the two Macs

Do this once. On the Mac that will **lend its screen**:

```bash
continuous pair init --label "Personal Mac"
```

```
  Pairing code for Personal Mac

      44WH-C0GW-VX6E-SDR4-6V3Y-3NHH-GRZ4
```

On the Mac with the **keyboard and mouse**, type that code:

```bash
continuous pair join 44WH-C0GW-VX6E-SDR4-6V3Y-3NHH-GRZ4 --label "Work Mac"
```

The code carries 128 bits of secret and is the only thing the two Macs ever share. It is
checksummed, so a typo is reported as a typo instead of failing later as an unexplained
connection error.

## Use it from the menu bar

Double-click **Continuous.app** (or `open -a Continuous`). A pointer appears in the menu bar —
no Dock icon, no window.

```
  Connected to Work Mac
  Pointer is on this Mac
  round trip 1.2 ms · clipboard shared
  ─────────────────────────────
  Stop
  Mode                 ▸  Share my keyboard & mouse
                          Lend my screen
  ─────────────────────────────
  Devices              ▸  Work Mac   ▸ Rename… · Set address… · Forget…
                          Pair a new Mac…
                          Enter a pairing code…
  Screen arrangement   ▸  Left / Right / Above / Below
                          Stretch to fit · tops · middles · bottoms
                          Show arrangement…
  ─────────────────────────────
  ☑ Share clipboard
  ☑ Start at login
  ─────────────────────────────
  Open log…
  Quit Continuous
```

The icon blinks while it is looking for the other Mac, and settles once connected. Pairing,
forgetting a Mac and changing the arrangement are all in the menu, so the terminal is optional
rather than required. Changing the arrangement or the clipboard setting restarts the
session, because both are read when one starts.

First time, choose **Set up…**. It asks the two questions in order and explains both:

1. **What should this Mac do?** One Mac shares its keyboard and mouse; the other lends its
   screen. *Set the other Mac to the opposite* — if both pick the same, neither dials and
   nothing connects.
2. **Pair them.** One secret code, shared between the two. It does not matter which Mac
   creates it, and it has no bearing on which Mac shares its keyboard — that is the separate
   choice you just made.

Then press **Start** on both.

Until the two Macs have actually spoken, each shows the pairing as *"Mac 1 — not connected
yet"*: neither can know the other's name before a handshake. Once connected, each adopts the
other's real computer name, and you can **Rename…** it to whatever you like.

If your network blocks Bonjour — common on managed networks — use **Devices ▸ Set address…**
and give the other Mac's IP. `continuous doctor` on that Mac prints it. Everything below still works from the terminal; the menu runs the same
session as a child process, so the two are never out of step.

## Use it from the terminal

On the Mac lending its screen:

```bash
continuous listen
```

On the Mac with the keyboard:

```bash
continuous connect                     # finds the Mac this pairing is pinned to
continuous connect 192.168.1.42        # or straight by address
```

Then **push the pointer off the edge of your screen** towards the other Mac. It crosses over,
and your keyboard goes with it. Push back the other way to return.

You have to *push* against the edge to go through it — about 24 points of travel — so a stray
movement near the edge will not throw the pointer across. The same applies coming back. If that
feels too sticky or too eager:

```bash
continuous config set edgePressure 12     # quicker to cross
continuous config set edgePressure 40     # harder to cross by accident
```

Hold **⌘ ⌥ ⌃ ⇧** together at any time to bring the pointer straight back. You should not need
it — the pointer also returns on its own if the link drops, if the other Mac goes quiet for
four seconds, or if macOS disables the event tap — but it is there, it is checked before
anything else, and it works even if everything else has gone wrong.

```
✓ link up  →  Personal Mac  [Z0P8GCY3]  192.168.1.42:52777
· TLS 1.2 / ECDHE-PSK-CHACHA20-POLY1305-SHA256  ·  key 4447f0c4  ·  role client

  rtt   0.29 ms   last 0.29 ms · min 0.29 · mean 0.48 · max 0.69 · 3 sent, 0 lost
```

That round-trip number is worth watching. Under about 5 ms the pointer will feel attached to
your hand; much above that and you will notice it.

## Three screens, one of them switchable

The arrangement this was built for: personal Mac on the left, an external monitor in the middle
that switches between the two machines, work Mac on the right.

```
   personal Mac        external monitor        work Mac
   ┌──────────┐        ┌──────────────┐        ┌──────────┐
   │ built-in │        │   switchable │        │ built-in │
   └──────────┘        └──────────────┘        └──────────┘
```

Each Mac reports *all* of its displays, and the layout is built from the union of them, so the
monitor needs no special handling: plugged into the left Mac it widens that Mac's desktop and
the handover point moves right; switched to the right Mac it widens that one instead. Both
sides watch for displays being plugged in or rearranged and re-send their layout, so a switch
takes effect without reconnecting.

```bash
continuous layout                   # draw the combined desktop
continuous layout set right         # the other Mac is to my right
continuous layout set right center  # ...and line the screens up by their middles
```

Arrange each Mac's own displays in System Settings ▸ Displays as they sit on your desk; the
monitor should be to the *right* of the built-in screen on the personal Mac, and to the *left*
of the built-in screen on the work Mac.

When the two Macs' screens are different heights, `proportional` alignment (the default) means
the pointer leaves at the same fraction of the way down the edge as it arrives, so every part
of the taller screen stays reachable. `start`, `center` and `end` keep a 1:1 scale instead.

### Over a USB-C or Thunderbolt cable

A Thunderbolt cable between two Macs appears as an ordinary network interface, so everything
above works unchanged — just point `connect` at the bridge address instead. `continuous doctor`
lists your interfaces and marks the bridge. This gets you a private, physically isolated,
very low latency path with no Wi-Fi involved, which is the best option if your office network
blocks peer-to-peer traffic.

## Commands

| | |
| --- | --- |
| `continuous doctor` | environment, permissions, pairings, interfaces |
| `continuous selftest` | full crypto + transport check, loopback only |
| `continuous id` | this Mac's device identity |
| `continuous pair init` | generate a pairing code |
| `continuous pair join <CODE>` | accept a pairing code |
| `continuous pair list` | show pairings and what they are bound to |
| `continuous pair forget <NAME>` | revoke a pairing |
| `continuous listen` | accept links from a paired Mac, and act on what it sends |
| `continuous connect [HOST\|NAME]` | dial a listening Mac |
| `continuous discover` | browse the network for listening Macs |
| `continuous layout` | draw how both Macs' screens combine |
| `continuous layout set <EDGE>` | where the other Mac sits: `left`, `right`, `top`, `bottom` |
| `continuous inject-test` | move this Mac's own pointer, to check Accessibility |
| `continuous remote-test` | drive the **other** Mac's pointer across the link |
| `continuous permissions` | what is granted, and how to grant the rest |
| `continuous capture-test` | can this Mac capture input? |
| `continuous status` | what is running, and which Mac has the pointer |
| `continuous service install <ROLE>` | start at login as `listen` or `connect` |
| `continuous service start` / `stop` / `uninstall` | control the login item |
| `continuous config show` / `set` | settings |

Useful options: `--port`, `--pair <label>` (when you have more than one pairing),
`--duration <seconds>`, `--no-bonjour`, `--keys`, `--link-only`, `--no-retry`, `--log debug`.

A dropped link reconnects on its own, backing off from one second up to twenty. `--no-retry`
turns that off.

`connect` takes a pairing label, a device id, a Bonjour name, or an address — and with a single
pairing it takes nothing at all. It looks for the Mac that pairing is pinned to, and falls back
to the address it was last seen on.

## Permissions

| | |
| --- | --- |
| Mac with the keyboard | **Input Monitoring** and **Accessibility** — to read events and to swallow them |
| Mac lending its screen | **Accessibility** — to synthesize events into its own apps |

Grant them to `Continuous.app`, not to your terminal. macOS attributes a permission to whatever
launched the process, so running the bare binary from a shell hands Accessibility to your
terminal or editor — a far broader grant than you meant to make, and one that survives long
after you stop using this.

```bash
continuous permissions        # what is granted, and how to grant the rest
continuous capture-test       # can this Mac capture input?
continuous inject-test        # can this Mac be driven?
continuous cursor-doctor      # can this Mac's cursor be held still?
```

If you ever see a second pointer mirroring your hand on the Mac you are *not* using, run
`cursor-doctor`. It runs three trials on one machine — deleting the movement, deleting plus
re-parking on a timer, and deleting plus warping from inside the tap callback — samples the
cursor every millisecond, and prints the three numbers side by side.

`continuous capture-test` answers the simpler half: it asks the window server whether this
Mac's cursor actually went away, rather than trusting `CGDisplayHideCursor`, which returns
success whether or not it was allowed to do anything.

`continuous --version` reports the exact commit the bundle was built from, so there is never
any doubt about which code produced a result.

### Granting them once instead of after every rebuild

macOS keys these permissions to an app's *code identity*. With an ad-hoc signature that
identity is a hash of the app's contents, so every rebuild looks like a brand new app and you
have to grant both permissions again. One command fixes that for good:

```bash
Scripts/create-signing-identity.sh
```

(If you ran an earlier version of this and saw *"MAC verification failed during PKCS12 import"*,
that was a bug in the script, not your Mac: it built the certificate bundle with an empty
password, which macOS rejects, and with OpenSSL 3's default algorithms, which macOS cannot
read. Both are fixed — just run it again.)

It creates a self-signed code-signing certificate in your login keychain, trusted by nothing
but your own Mac. `Scripts/build.sh` picks it up automatically and the app then keeps one
identity across rebuilds. You will be asked for the two permissions once more — because the
identity has just changed — and not again. Remove it any time with
`security delete-certificate -c "Continuous Local Signing"`.

If a permission is ticked but clearly not in force, untick and re-tick it.

## Starting at login

```bash
continuous service install listen      # on the Mac lending its screen
continuous service install connect     # on the Mac with the keyboard
continuous status                      # what is running right now
```

This installs a user LaunchAgent — it runs as you, in your login session, with your
permissions and no root anywhere. A keyboard forwarder running as root is exactly what this
project exists to avoid installing.

## Only one session at a time

A second session on the same Mac means two event taps, two sets of forwarded events and two
processes taking turns hiding the cursor. It feels like a laggy pointer and a cursor that will
not stay hidden, which looks like a bug rather than like there being two of it — so starting a
second one is refused. `continuous status` says what is already running; `--replace` takes over.

The menu bar offers to take over a session it did not start, such as one left running in a
terminal.

## Clipboard sharing

Off by default. Turn it on in the menu, or:

```bash
continuous config set clipboardSharing true     # on BOTH Macs
continuous config set clipboardImages true      # also carry images (a screenshot is megabytes)
continuous config set clipboardLimit 4194304    # raise the 1 MiB ceiling
```

It has to be on at both ends: nothing is sent unless both Macs advertised the capability, so
switching it off on either one stops it. You are not relying on the other side to respect your
setting.

Worth being deliberate about. Whatever you last copied is frequently a password, and this
sends it to the other machine every time it changes. Text, rich text and HTML travel together
so a paste works wherever it lands; file paths are never carried, because a path that means
something on one Mac means nothing on the other.

## Where state lives

```
~/Library/Application Support/Continuous/
    identity.json   this Mac's device id
    secrets.json    pairing keys — mode 0600, refuses to load if looser
    config.json     settings
```

Set `CONTINUOUS_HOME` to put that somewhere else.

## Security in one paragraph

Every link is TLS with a pre-shared key derived from the pairing code, using
`ECDHE-PSK-CHACHA20-POLY1305`. A machine without the key cannot get past the TLS handshake, so
no unauthenticated party ever reaches code that parses input events. ECDHE means each session
has its own ephemeral key: recording the traffic today and stealing `secrets.json` later still
does not decrypt what was recorded. On top of that both ends prove possession of a separately
derived key over fresh nonces, and a pairing pins itself to the first Mac that uses it, so a
code that leaks after first use is no longer enough to impersonate anything. The full
reasoning, including what is deliberately *not* defended against, is in
[docs/SECURITY.md](docs/SECURITY.md).

## Testing

```bash
Scripts/test.sh                 # unit tests
build/continuous selftest       # transport end-to-end, including the rejection paths
build/continuous inject-test    # this Mac can drive its own pointer
build/continuous remote-test    # this Mac can drive the other Mac's pointer
```

Use `Scripts/test.sh` rather than `swift test` directly. swift-testing's macro plugin ships in
a `testing/` subdirectory that is not on the default plugin search path, so plain `swift test`
fails with `plugin for module 'TestingMacros' not found`; the script passes the right
`-plugin-path`.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Copyright (c) 2026 Bitan Paul, phiUture. All Rights Reserved.
