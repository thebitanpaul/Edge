# Edge

One keyboard and mouse across two Macs that can't share an Apple ID.

Apple's own Universal Control needs the same Apple ID on both machines. If one Mac is managed
by your employer and the other is yours, that is not a trade you should have to make. The
third-party alternatives solve it, but they ask for Accessibility and Input Monitoring —
permission to read every keystroke you type — and you have to take their word for what happens
next.

Edge is the same idea with the trust removed: it runs only on your two Macs, it talks
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
other, with the keyboard following it. Drag a file at that edge and it crosses too. It
reconnects on its own, starts at login, shares a clipboard if you ask it to, and lives in the
menu bar. See [BLUEPRINT.md](BLUEPRINT.md) for
how it is built and [docs/SECURITY.md](docs/SECURITY.md) for the security model.

---

## Build

Needs the Swift toolchain that ships with Xcode Command Line Tools. Nothing else — no
packages are downloaded, the whole dependency list is Apple's own SDK.

```bash
git clone <this repo> && cd Edge
Scripts/build.sh            # builds and wraps the binary in Edge.app
build/edge selftest   # proves the crypto and transport work on this Mac
```

`Scripts/build.sh --install` also symlinks `edge` into `/usr/local/bin`.

The binary lives inside a `.app` bundle on purpose. macOS attributes privacy permissions to the
bundle, so Edge asks for Accessibility as *itself* rather than silently borrowing the
grant you gave your terminal.

## Pair the two Macs

Do this once. On the Mac that will **lend its screen**:

```bash
edge pair init --label "Personal Mac"
```

```
  Pairing code for Personal Mac

      44WH-C0GW-VX6E-SDR4-6V3Y-3NHH-GRZ4
```

On the Mac with the **keyboard and mouse**, type that code:

```bash
edge pair join 44WH-C0GW-VX6E-SDR4-6V3Y-3NHH-GRZ4 --label "Work Mac"
```

The code carries 128 bits of secret and is the only thing the two Macs ever share. It is
checksummed, so a typo is reported as a typo instead of failing later as an unexplained
connection error.

## Use it from the menu bar

Double-click **Edge.app** (or `open -a Edge`). A pointer appears in the menu bar —
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
  Quit Edge
```

The icon blinks while it is looking for the other Mac, and settles once connected. Pairing,
forgetting a Mac and changing the arrangement are all in the menu, so the terminal is optional
rather than required. Changing the arrangement or the clipboard setting restarts the
session, because both are read when one starts.

### Pairing

Choose **Devices ▸ Connect to a nearby Mac…** on *both* Macs. Each shows the same six digits;
confirm on both. That is the whole thing — there is nothing to type.

The two Macs need the **same Wi-Fi network** to find each other. A cable alone is not enough:
mDNS does advertise over a Thunderbolt bridge, but the two Macs discovering *each other*
across one proved unreliable — often in one direction only — so it is not offered. Pair once
over Wi-Fi; the cable then carries the actual link, which is where its speed matters and where
it is completely dependable.

Neither Mac can end up with a key the other does not have: they agree one over the network, so
either both save the same secret or neither saves anything.

If nothing is found, press **Search again**. For a network that blocks discovery entirely
there is a terminal escape hatch — `edge pair nearby --address <the other Mac>` — kept
out of the menu because it is almost never the right answer.

A pairing appears under **Devices** once it has connected.

There used to be a typed code. It is gone, and not because it was fiddly: it is two separate
manual actions with no feedback until much later, so re-pairing one Mac and not the other left
them with different keys — which looks exactly like a typo, making the natural fix the very
thing that caused it.

### Does a cable need pairing too?

Yes, and for a reason worth stating: the pairing key *is* the encryption key. Without one there
would be nothing to encrypt your keystrokes with, and a cable plugged into a Mac you do not
control should not hand it your keyboard. It costs nothing — the same one action pairs over a
cable just as it does over Wi-Fi.

### The rest of setup

First time, choose **Set up…** on each Mac. One question:

* **Primary** — the Mac whose keyboard and mouse you use
* **Secondary** — the Mac it reaches onto

Set the other Mac to the opposite; if both are the same, neither connects. Pairing starts
straight away, so that is the whole of setup. Both Macs need to be on the same Wi-Fi network,
or joined by a USB-C or Thunderbolt cable.

Then press **Start** on both.

Until the two Macs have actually spoken, each shows the pairing as *"Mac 1 — not connected
yet"*: neither can know the other's name before a handshake. Once connected, each adopts the
other's real computer name, and you can **Rename…** it to whatever you like.

If your network blocks Bonjour — common on managed networks — use **Devices ▸ Set address…**
and give the other Mac's IP. `edge doctor` on that Mac prints it.

**Both Macs should show the same key under Devices** (eight hex characters). That is derived
from the shared secret, so it matches when and only when the code was typed correctly. It is
the one check you can make while the two machines still cannot talk to each other.

## When it will not connect

```bash
edge troubleshoot
```

Or **menu bar ▸ Why is it not connecting?…** It checks the things that are actually wrong in
practice and names the one that applies:

* the pairing keys on the two Macs, so you can see whether the code took — if they match, the
  pairing is correct and the problem is elsewhere
* whether the macOS firewall is blocking the Mac that lends its screen — it blocks silently,
  and a blocked port looks exactly like nothing running
* whether anything is advertising over Bonjour
* whether the other Mac answers at all, answers but has nothing listening, or is simply absent
* how long a connection to it takes

That last one matters more than it sounds. Pointer sharing needs a quick, steady link. If a
connection takes more than about 150 ms, or round trips vary wildly, the pointer will feel bad
no matter what the software does — and the fix is a **Thunderbolt or USB-C cable** between the
two Macs, or Ethernet. Wi-Fi power saving on a laptop can turn a 10 ms link into a 200 ms one
without anything looking wrong. Everything below still works from the terminal; the menu runs the same
session as a child process, so the two are never out of step.

## Use it from the terminal

On the Mac lending its screen:

```bash
edge listen
```

On the Mac with the keyboard:

```bash
edge connect                     # finds the Mac this pairing is pinned to
edge connect 192.168.1.42        # or straight by address
```

Then **push the pointer off the edge of your screen** towards the other Mac. It crosses over,
and your keyboard goes with it. Push back the other way to return.

You have to *push* against the edge to go through it — about 24 points of travel — so a stray
movement near the edge will not throw the pointer across. The same applies coming back. If that
feels too sticky or too eager:

```bash
edge config set edgePressure 12     # quicker to cross
edge config set edgePressure 40     # harder to cross by accident
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

**Menu bar ▸ Screen arrangement…** opens a window showing both Macs' screens to scale, with
the edge and alignment set there. From the terminal:

```bash
edge layout                   # draw the combined desktop
edge layout set right         # the other Mac is to my right
edge layout set right center  # ...and line the screens up by their middles
```

Arrange each Mac's own displays in System Settings ▸ Displays as they sit on your desk; the
monitor should be to the *right* of the built-in screen on the personal Mac, and to the *left*
of the built-in screen on the work Mac.

When the two Macs' screens are different heights, `proportional` alignment (the default) means
the pointer leaves at the same fraction of the way down the edge as it arrives, so every part
of the taller screen stays reachable. `start`, `center` and `end` keep a 1:1 scale instead.

### Over a USB-C or Thunderbolt cable

A Thunderbolt cable between two Macs appears as an ordinary network interface, so everything
above works unchanged — just point `connect` at the bridge address instead. `edge doctor`
lists your interfaces and marks the bridge. This gets you a private, physically isolated,
very low latency path with no Wi-Fi involved, which is the best option if your office network
blocks peer-to-peer traffic.

## Commands

| | |
| --- | --- |
| `edge doctor` | environment, permissions, pairings, interfaces |
| `edge selftest` | full crypto + transport check, loopback only |
| `edge id` | this Mac's device identity |
| `edge pair init` | generate a pairing code |
| `edge pair join <CODE>` | accept a pairing code |
| `edge pair list` | show pairings and what they are bound to |
| `edge pair forget <NAME>` | revoke a pairing |
| `edge listen` | accept links from a paired Mac, and act on what it sends |
| `edge connect [HOST\|NAME]` | dial a listening Mac |
| `edge discover` | browse the network for listening Macs |
| `edge layout` | draw how both Macs' screens combine |
| `edge layout set <EDGE>` | where the other Mac sits: `left`, `right`, `top`, `bottom` |
| `edge inject-test` | move this Mac's own pointer, to check Accessibility |
| `edge remote-test` | drive the **other** Mac's pointer across the link |
| `edge permissions` | what is granted, and how to grant the rest |
| `edge capture-test` | can this Mac capture input? |
| `edge status` | what is running, and which Mac has the pointer |
| `edge service install <ROLE>` | start at login as `listen` or `connect` |
| `edge service start` / `stop` / `uninstall` | control the login item |
| `edge config show` / `set` | settings |

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

Grant them to `Edge.app`, not to your terminal. macOS attributes a permission to whatever
launched the process, so running the bare binary from a shell hands Accessibility to your
terminal or editor — a far broader grant than you meant to make, and one that survives long
after you stop using this.

```bash
edge permissions        # what is granted, and how to grant the rest
edge capture-test       # can this Mac capture input?
edge inject-test        # can this Mac be driven?
edge cursor-doctor      # can this Mac's cursor be held still?
```

If you ever see a second pointer mirroring your hand on the Mac you are *not* using, run
`cursor-doctor`. It runs three trials on one machine — deleting the movement, deleting plus
re-parking on a timer, and deleting plus warping from inside the tap callback — samples the
cursor every millisecond, and prints the three numbers side by side.

`edge capture-test` answers the simpler half: it asks the window server whether this
Mac's cursor actually went away, rather than trusting `CGDisplayHideCursor`, which returns
success whether or not it was allowed to do anything.

`edge --version` reports the exact commit the bundle was built from, so there is never
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
`security delete-certificate -c "Edge Local Signing"`.

If a permission is ticked but clearly not in force, untick and re-tick it.

## Starting at login

```bash
edge service install listen      # on the Mac lending its screen
edge service install connect     # on the Mac with the keyboard
edge status                      # what is running right now
```

This installs a user LaunchAgent — it runs as you, in your login session, with your
permissions and no root anywhere. A keyboard forwarder running as root is exactly what this
project exists to avoid installing.

## Only one session at a time

A second session on the same Mac means two event taps, two sets of forwarded events and two
processes taking turns hiding the cursor. It feels like a laggy pointer and a cursor that will
not stay hidden, which looks like a bug rather than like there being two of it — so starting a
second one is refused. `edge status` says what is already running; `--replace` takes over.

The menu bar offers to take over a session it did not start, such as one left running in a
terminal.

## Clipboard sharing

Off by default — whatever you last copied is quite often a password. Turn it on in the menu,
or:

```sh
edge config set clipboardSharing true
```

Turn it on at both ends; neither Mac sends a clipboard to a Mac that did not ask for one.

## Dragging files across

On by default, and unlike the clipboard nothing crosses unless you deliberately drag it.

Pick a file up and push it against the shared edge. The pointer goes through, carrying the
file with it, and it lands in **Downloads** on the other Mac with a Finder window showing it.
It works in both directions: drag something on the far Mac back towards the edge you came
from and it arrives here. A folder is zipped on the way, the same as Finder's Compress.

A drag that is *not* carrying files — a window, a text selection — still stops at the edge,
because it has nowhere to go on the other Mac.

What it does not do is drop the file into whatever application happens to be under the pointer
over there. That needs a synthetic drag session on the receiving side, and it is the part that
every implementation of this has failed to make dependable — Deskflow, which inherited
Synergy's, has since removed the feature outright. Landing the files in a folder is a promise
that can be kept every time.

| | |
|---|---|
| Limits | 64 files, 2 GB in total |
| Where they land | `~/Downloads`, with a number appended rather than overwriting |
| Turn it off | `edge config set fileSharing false` |
| Don't open Finder | `edge config set revealReceivedFiles false` |

`edge selftest` carries a real file over a real encrypted link and checks every byte of it,
so the machinery can be verified on one Mac before two are involved.

## Over a cable

A USB-C or Thunderbolt cable between the two Macs appears as an ordinary wired interface, and
it is far quicker and steadier than Wi-Fi — which matters, because a pointer follows your hand
and notices a slow link long before a file transfer would. With both a cable and Wi-Fi
connected, the system is free to pick either and will usually pick Wi-Fi.

This is about how this Mac **dials out**. Listening is unrestricted, so the two Macs cannot
be set to incompatible links and left unable to reach each other.

`auto` already prefers a cable when it finds one; the setting is there to insist, or to stay
on Wi-Fi. Measured between the two Macs this was written for: **1.2 ms over the cable against
236 ms over Wi-Fi**.

This is per-Mac and the two need not agree: it only governs how *this* Mac connects out, and
a Mac that is listening accepts whichever link you arrive on.

**Menu bar ▸ Connect over ▸ Cable**, or:

```bash
edge config set preferredLink cable    # auto | cable | wifi
```

```bash
edge config set clipboardSharing true     # on BOTH Macs
edge config set clipboardImages true      # also carry images (a screenshot is megabytes)
edge config set clipboardLimit 4194304    # raise the 1 MiB ceiling
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
~/Library/Application Support/Edge/
    identity.json   this Mac's device id
    secrets.json    pairing keys — mode 0600, refuses to load if looser
    config.json     settings
```

Set `EDGE_HOME` to put that somewhere else.

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
build/edge selftest       # transport end-to-end, including the rejection paths
build/edge inject-test    # this Mac can drive its own pointer
build/edge remote-test    # this Mac can drive the other Mac's pointer
```

Use `Scripts/test.sh` rather than `swift test` directly. swift-testing's macro plugin ships in
a `testing/` subdirectory that is not on the default plugin search path, so plain `swift test`
fails with `plugin for module 'TestingMacros' not found`; the script passes the right
`-plugin-path`.

## Licence

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Copyright (c) 2026 Bitan Paul, phiUture. All Rights Reserved.
