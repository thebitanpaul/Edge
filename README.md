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

**Status: working.** Push the pointer off the edge of one Mac and it appears on the
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

Do this once. On **both** Macs, open Edge.app and choose **Set up** (or run
`edge pair nearby` on both). Each Mac shows the same six digits; confirm on both. The two
Macs agree a key between them over the network, so there is no code to type and nothing for
either to get wrong.

## Use it from the menu bar

Double-click **Edge.app** (or `open -a Edge`). A pointer appears in the menu bar —
no Dock icon, no window.

```
  Primary · connected to Work Mac
  Cable · 1 ms · clipboard
  ─────────────────────────────
  Stop
  ─────────────────────────────
  Devices              ▸  ✓ Work Mac ▸ Rename · Set address · Forget
                          Pair a Mac
  Screen arrangement                        (primary only)
  Connect over         ▸  Whichever connects · Cable · Wi-Fi   (primary only)
  ─────────────────────────────
  ✓ Share clipboard
  ✓ Carry dragged files
  ✓ Start at login
  ✓ Show in menu bar        (macOS 26+, once Edge is in Control Center)
  ─────────────────────────────
  Switch to Secondary                       (or Switch to Primary)
  Help                 ▸  Open log · Report an issue · Version
  Quit Edge
```

On the primary, the icon blinks while it is looking for the other Mac, and settles once
connected. Pairing,
forgetting a Mac and changing the arrangement are all in the menu, so the terminal is optional
rather than required. Changing the arrangement or the clipboard setting restarts the
session, because both are read when one starts.

**Start at login** adds Edge.app under *System Settings ▸ General ▸ Login Items ▸ Open at
Login*, and the tick always reads what that list says — remove Edge there and the menu
un-ticks too. Unticking removes it; if macOS ever refuses, Edge opens that page so you can
select Edge and click **−**. At login a primary that was left running starts again, and a
secondary makes itself ready as usual. (`edge service install` is a separate, headless launch
agent for a Mac where the app is never opened: opening Edge.app replaces it with Edge's own
Open at Login item.)

### Control Center (macOS 26 and later)

Open Control Center, click **Edit Controls**, search for Edge, and add:

- **Edge**, the switch. It is highlighted while Edge is on and shows the other Mac's name once
  connected. **On** opens Edge if it is not running and starts it. **Off** quits Edge, the
  same as Quit in the menu: nothing keeps running in the background, and start at login is
  left as it was.
- **Edge Options** (›), if you want it: opens Edge's whole menu where you clicked — devices,
  screen arrangement, settings and Quit — without the menu-bar icon.

macOS also offers **Add to Menu Bar** for every control, and apps cannot remove that choice.
If an Edge control goes in the menu bar, Edge's own icon steps aside so there is only ever one,
and comes back when the control is removed. (Edge reads the menu bar through Accessibility,
which it already has.)

Once the switch is in Control Center, **Show in menu bar** in the menu can be unticked so Edge
lives in Control Center only. Edge never lets itself become unreachable:

- the icon can only be hidden while the switch or Edge Options is in Control Center;
- if they are removed later, the icon comes back by itself within about 15 seconds;
- opening Edge from Applications or Spotlight always brings the icon back, and with it the
  menu for everything else (pairing, arrangement, clipboard, start at login).

`edge controls` checks each part of this setup and says what is missing.

### Pairing

Choose **Set up** (or **Devices ▸ Pair a Mac**) on *both* Macs. Each shows the same six digits;
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

A pairing appears under **Devices** as soon as it succeeds.

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

First time, choose **Set up** on each Mac. One question:

* **Primary** — the Mac whose keyboard and mouse you use
* **Secondary** — the Mac it reaches onto

Choose Primary on one Mac and Secondary on the other; if both are the same, neither connects.
Pairing starts straight away, so that is the whole of setup. The two Macs pair over the network
they share; a cable can then carry the link.

Then choose **Start** on the primary. The secondary gets itself ready on its own.

### Swapping roles

**Switch to Secondary** (or **Switch to Primary**) swaps both Macs at once while they are
connected: the other Mac becomes the primary and opens **Screen arrangement**, already mirrored
— if the secondary sat to the right, the old primary now sits to the left. Press **Start**
there and you are done. If they are not connected, only this Mac switches, and Edge says to
switch the other one too.

Until the first connection, the pairing shows as *"&lt;Name&gt; — not connected yet"*. Once
connected you can **Rename** it to whatever you like.

If your network blocks Bonjour — common on managed networks — use **Devices ▸ &lt;the Mac&gt; ▸
Set address** and give the other Mac's IP. `edge doctor` on that Mac prints it.

Until the first connection, **Devices ▸ &lt;the Mac&gt;** also shows a key (eight hex
characters). It must match on both Macs; `edge troubleshoot` shows it too. It is the one check
you can make while the two machines still cannot talk to each other.

## When it will not connect

```bash
edge troubleshoot
```

It checks the things that are actually wrong in practice and names the one that applies:

* the pairing keys on the two Macs, so you can see whether pairing worked on both — if they
  match, the pairing is correct and the problem is elsewhere
* whether the macOS firewall is blocking the secondary — it blocks silently,
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

On the secondary:

```bash
edge listen
```

On the primary:

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
· TLS 1.2 / ECDHE-PSK-CHACHA20-POLY1305-SHA256  ·  key 4447f0c4

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

**Menu bar ▸ Screen arrangement** opens a window showing both Macs' screens to scale, with
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

A Thunderbolt cable between two Macs appears as an ordinary network interface, and Edge
prefers it on its own once it is plugged in — see [Over a cable](#over-a-cable). `edge doctor`
lists your interfaces and marks the bridge. This gets you a private, physically isolated,
very low latency path with no Wi-Fi involved, which is the best option if your office network
blocks peer-to-peer traffic.

## Commands

| | |
| --- | --- |
| `edge doctor` | environment, permissions, pairings, interfaces |
| `edge selftest` | full crypto + transport check, loopback only |
| `edge id` | this Mac's device identity |
| `edge pair nearby` | pair with another Mac — run it on both |
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
| `edge troubleshoot` | why the two Macs are not talking |
| `edge cursor-doctor` | measure whether this Mac's cursor can be held still |
| `edge controls` | check the Edge switch in Control Center is set up |
| `edge menubar` | run the menu-bar app (what double-clicking does) |
| `edge service install <ROLE>` | run headless at login (launch agent) as `listen` or `connect` |
| `edge service start` / `stop` / `uninstall` | control the launch agent |
| `edge config show` / `set` | settings |

Useful options: `--port`, `--pair <label>` (when you have more than one pairing),
`--duration <seconds>`, `--no-bonjour`, `--keys`, `--media`, `--link-only`, `--no-retry`, `--log debug`.

A dropped link reconnects on its own, backing off from one second up to twenty. `--no-retry`
turns that off.

`connect` takes a pairing label, a device id, a Bonjour name, or an address — and with a single
pairing it takes nothing at all. It looks for the Mac that pairing is pinned to, and falls back
to the address it was last seen on.

## Permissions

| | |
| --- | --- |
| Primary | **Input Monitoring** and **Accessibility** — to read events and to swallow them |
| Secondary | **Accessibility** — to synthesize events into its own apps |

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

With the app, tick **Start at login** in the menu. Without it — a Mac you only use from the
terminal:

```bash
edge service install listen      # on the secondary
edge service install connect     # on the primary
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

## Sleep and battery

Neither Mac is kept awake while nothing is connected, and the primary never is: it is the Mac
in front of you, and your own keyboard and mouse already count as activity. While the two are
linked, the secondary is kept from idle-sleeping, because it gets no input of its own while you
work on the primary and would otherwise drop off mid-session. Its display still sleeps as usual.

## Volume, playback and brightness keys

While the pointer is on the other Mac, the keyboard's volume, mute, play/pause, next/previous,
screen-brightness and keyboard-backlight keys work there too, whether they are on an Apple
keyboard's top row or on the fn layer of another keyboard. Power and eject always stay on the
Mac they were pressed on. Both Macs need this build; a Mac on an older one simply keeps those
keys for itself.

To check the other Mac can receive them, run `edge inject-test --media` there: it nudges the
volume up one step and back down, so the volume overlay appears twice.

## Clipboard sharing

Off by default — whatever you last copied is quite often a password. Turn it on in the menu,
or:

```bash
edge config set clipboardSharing true     # on BOTH Macs
edge config set clipboardImages true      # also carry images (a screenshot is megabytes)
edge config set clipboardLimit 4194304    # raise the 1 MiB ceiling
```

It has to be on at both ends: nothing is sent unless both Macs advertised the capability, so
switching it off on either one stops it. You are not relying on the other side to respect your
setting. Text, rich text and HTML travel together so a paste works wherever it lands; file
paths are never carried, because a path that means something on one Mac means nothing on the
other.

## Dragging files across

On by default, and unlike the clipboard nothing crosses unless you deliberately drag it.

Pick a file up and push it against the shared edge. The pointer goes through carrying the
file, and the moment you **let go** it lands in Downloads on the other Mac, with a Finder
window showing it. It is held in a staging folder until then: watching a file appear in
Downloads while you are still holding it is a confusing thing to see, because the drop
visibly has not happened yet. Bring the pointer back without letting go and nothing lands.

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
and notices a slow link long before a file transfer would.

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

## Where state lives

```
~/Library/Application Support/Edge/
    identity.json   this Mac's device id
    secrets.json    pairing keys — mode 0600, refuses to load if looser
    config.json     settings
```

Set `EDGE_HOME` to put that somewhere else.

## Security in one paragraph

Every link is TLS with a pre-shared key derived from the key the two Macs agreed when pairing, using
`ECDHE-PSK-CHACHA20-POLY1305`. A machine without the key cannot get past the TLS handshake, so
no unauthenticated party ever reaches code that parses input events. ECDHE means each session
has its own ephemeral key: recording the traffic today and stealing `secrets.json` later still
does not decrypt what was recorded. On top of that both ends prove possession of a separately
derived key over fresh nonces, and a pairing pins itself to the first Mac that uses it, so a
key that leaks after first use is no longer enough to impersonate anything. The full
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
