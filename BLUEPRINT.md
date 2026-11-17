# Continuous — Blueprint

Share one keyboard + mouse between two Macs that **cannot** share an Apple ID.
Everything runs on your own machines. Nothing talks to any server but the other Mac.

---

## 1. Goal & threat model

**Goal.** Move the pointer off the edge of Mac A's screen and have it appear on Mac B,
with keyboard input following it. Sub-frame latency on a LAN. Negligible CPU when idle.

**What we are defending against**

| Threat | Mitigation |
| --- | --- |
| Anyone on the same Wi‑Fi connecting to the listener | TLS with a **pre-shared key** derived from the pairing code. Without the PSK the handshake fails before a single application byte is read. |
| Passive sniffing of keystrokes on the LAN | `ECDHE-PSK-CHACHA20-POLY1305` — an AEAD, with forward secrecy from the ephemeral ECDHE key. |
| Someone recording traffic now and stealing the key later | ECDHE again: session keys are ephemeral and are never recoverable from the PSK. |
| Replay of a recorded session | TLS sequence numbers + a per-connection HMAC challenge/response over nonces from both sides. |
| A paired-but-untrusted peer, or a stolen pairing code | Explicit peer allowlist keyed by device ID; `pair forget` revokes. |
| Third party reading my keystrokes | No third party exists. No analytics, no update check, no outbound connection other than to the paired peer. |
| A pairing code that leaks after it has been used | A pairing pins itself to the first Mac that completes a handshake and refuses any other device afterwards. |
| Secrets at rest | `~/Library/Application Support/Continuous/secrets.json`, mode `0600`, refuses to load if permissions are looser (same discipline as `~/.ssh`). |
| Accidental exposure to the internet | The listener refuses peers that are neither on a private address nor on a subnet this Mac is directly attached to, unless explicitly overridden. |

**What we are NOT defending against:** another process running as *you* on your own Mac.
That attacker already has your keychain and your files; it is out of scope for every tool in this class.

---

## 2. Why Swift, and why one static binary

* Direct, zero-overhead access to `CGEventTap` / `CGEventPost` / `Network.framework`.
  A Python build would need `pyobjc` and would add GC pauses to the hot path of every mouse move.
* No runtime, no interpreter, no third-party packages. The whole dependency list is Apple's own SDK,
  which matters when the entire point of the project is "I do not want to trust someone else's code
  with Accessibility access".
* Idle cost: an event-driven `CFRunLoop` + one TCP socket. ~0% CPU idle, ~15 MB RSS.

**Transport.** Plain TCP (`TCP_NODELAY`) over whatever IP path exists between the two Macs:
same Wi‑Fi, same Ethernet, or a **USB‑C / Thunderbolt bridge** — a Thunderbolt cable between two Macs
shows up as a normal network interface (`bridge0`), so the exact same code path gets you a private,
~10 Gbps, physically-isolated link with no Wi‑Fi involved. No special-casing needed.

---

## 3. Architecture

```
            MAC A  (host — your real keyboard & mouse)
  ┌───────────────────────────────────────────────────┐
  │  CGEventTap  ──►  EdgeDetector  ──►  InputRouter   │
  │  (listen+consume)   tracks cursor      local?      │
  │                      vs. screen        remote?     │
  └──────────────────────────┬────────────────────────┘
                             │  framed binary messages
                             │  over TLS 1.3 (PSK, mutual)
            MAC B  (client — screen being borrowed)
  ┌──────────────────────────┴────────────────────────┐
  │  SecureLink  ──►  EventInjector  ──►  CGEventPost  │
  │                   rebuilds the event on the HID tap │
  └───────────────────────────────────────────────────┘
```

* **Client listens and advertises** over Bonjour (`_continuous._tcp`); **host browses and connects**.
  The host is the one making the decision "attach that screen to my left edge", so it is the one
  that initiates.
* The **host owns the cursor position on both screens.** It tracks a virtual cursor inside the
  client's display bounds and sends absolute coordinates. No drift, no split-brain, one source of truth.
* Keyboard is forwarded as **virtual key codes + modifier flags**, not as characters, so the key you
  press lands on the same physical key on the other Mac regardless of each machine's keyboard layout.

### Wire protocol

Length-prefixed binary frames — `[u32be length][u8 type][payload]`, 64 KiB cap.
A mouse move is 21 bytes on the wire. No JSON anywhere in the hot path.

### Screens, and a monitor that moves between the two Macs

Each Mac reports **all** of its displays, and the layout works on the *union* of them rather
than on any single screen. That one decision is what handles the intended desk: a monitor
sitting physically between the two Macs, switched from one input to the other.

```
   personal Mac        external monitor        work Mac
   ┌──────────┐        ┌──────────────┐        ┌──────────┐
   │ built-in │        │   switchable │        │ built-in │
   └──────────┘        └──────────────┘        └──────────┘
   └── when the monitor is on the personal Mac ──┘
                   └── when it is on the work Mac ──────┘
```

Plugged into the left Mac, the monitor simply widens that Mac's union and the handover point
moves right. Switched to the right Mac, it widens the right one instead and the handover point
moves left. Neither side needs to know the monitor exists, and the combined desktop keeps the
same total shape either way — which is tested, not assumed.

Two details that matter in practice:

* **Unions are not rectangles.** A laptop screen beside a taller monitor leaves corners that
  are inside the bounding box but on no actual screen. Every coordinate handed to the other Mac
  is snapped to the nearest real display, so the pointer can never be parked in a gap.
* **Alignment, when the screens are different heights.** The default is `proportional`: the
  pointer leaves at the same fraction of the way down the edge as it arrives. With fixed
  alignments, parts of a taller screen simply cannot be reached from a shorter one.
  `continuous layout set right center` if you prefer straight-line crossings.

Both sides watch for display reconfiguration and re-send their layout, so switching the monitor
updates the arrangement without reconnecting.

### A finding worth recording

The original plan said "TLS 1.3 with a pre-shared key". That turns out not to be available:
Network.framework only wires external PSKs into **TLS 1.2**, and pinning 1.3 makes the
handshake fail with `errSSLHandshakeFail (-9858)`. This was established by testing the
configurations rather than reading documentation, and the useful part of the result was the
discovery that `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) *is* supported — which
is better than the plain PSK suite Apple's own sample code uses, because ECDHE gives forward
secrecy. That is what the link pins, and it verifies the negotiated suite at runtime so a
silent downgrade cannot happen unnoticed.

### Permissions required

| Side | Permission | Why |
| --- | --- | --- |
| Host | Input Monitoring | read keyboard events in the event tap |
| Host | Accessibility | consume events so they don't also hit the local machine |
| Client | Accessibility | synthesize events into other apps |
| Both | Local Network | macOS 15+ gates Bonjour *and* outbound LAN connections; the bundle declares `NSLocalNetworkUsageDescription` |

The binary ships inside a real `Continuous.app` bundle (`LSUIElement`, no Dock icon) so macOS
attributes those grants to *Continuous* rather than to Terminal.

---

## 4. Milestones

Each milestone ends in something you can run and verify by yourself.

### ✅ M1 — Secure link  *(delivered)*
Device identity, pairing codes, secret storage, ECDHE-PSK transport, mutual HMAC
challenge/response, device pinning, framed codec, Bonjour discovery, RTT measurement,
`doctor` + `selftest`. 41 unit tests; 13 end-to-end checks including both rejection paths.
**Verify:** `continuous selftest` passes on one Mac; then pair the two Macs and
`continuous connect` reports a live link with a round-trip time.

### ✅ M2 — Injection and screen geometry  *(delivered)*
`CGEventPost` synthesis on the receiving Mac: absolute pointer moves, drag, buttons with click
counts, scroll, keys by virtual key code, modifier changes, and a release-everything safety net
for a link that drops mid-drag. Display enumeration on both sides, live `screenInfo` exchange,
reconfiguration watching, and the combined-desktop maths with an ASCII plan of the arrangement.
**Verify:** `continuous inject-test` moves this Mac's own pointer; `continuous remote-test`
drives the *other* Mac's pointer across the link; `continuous layout` draws the arrangement.

### ✅ M3 — Capture & edge switching  *(delivered)*
`CGEventTap` in active mode on the sending Mac: pointer, buttons, drag, scroll, keys and
modifiers are consumed and forwarded while the pointer is away. The hardware is detached from
the local pointer so movement arrives as deltas, the local cursor is parked and hidden, and the
switch at the shared edge is driven by the M2 layout.
**Verify:** `continuous capture-test` proves this Mac can capture; then `continuous connect`
and push the pointer off the edge towards the other Mac.

#### Not being able to get your Mac back is the real failure mode

While the pointer is away, every event is swallowed. If that outlived the link, the Mac would
be left with no keyboard and no pointer. So there are four independent routes back, and the
decision logic lives in `PointerRouter` — a plain value type with no sockets, no CoreGraphics
and no clock, so it can be tested exhaustively rather than by getting locked out:

| Route back | Trigger |
| --- | --- |
| the link closes | peer quit, network dropped, process killed |
| the heartbeat goes quiet | no pong for 4 s |
| the escape chord | ⌘ ⌥ ⌃ ⇧ held together, checked before anything else |
| the tap is disabled | macOS turns off a tap whose handler was too slow |

Two invariants hold above all: nothing is ever swallowed unless the link is up *and* the other
Mac's screen arrangement is known, and every route back goes through one function, so none of
them can forget to re-attach the hardware or un-hide the cursor.

Input sharing is also refused when both ends turn out to be the same Mac — over loopback, or
with a matching device id. The events one end injects would re-enter the tap that produced
them, and each lap round that loop makes another event.

### ✅ M4 — Living with it  *(delivered)*

Auto-reconnect with exponential backoff, a user LaunchAgent so it starts at login, a `status`
command backed by a small state file, a stable self-signed code identity so macOS stops asking
for permissions after every rebuild, and an app icon.

#### The two-pointers bug: three attempts

A second cursor kept mirroring your hand on the sending Mac while the pointer was on the other
one. It took three goes, and the first two were reasonable-sounding theories that happened to
be wrong.

**Attempt 1 — the tap level.** `.cgSessionEventTap` sees an event only after the window server
has moved the cursor, so deleting it hides the movement from applications but not from your
eyes. Moved to `.cghidEventTap`. Correct, necessary, and insufficient.

**Attempt 2 — the ordering, and the entry inset.** Warping the cursor re-couples it to the
hardware, so detaching and *then* parking undid the detach; parking first fixed that.
Separately the pointer arrived two pixels inside the far screen, so the smallest movement back
threw it home, leaving a stranded cursor on each machine. That became edge pressure: you must
lean on an edge to go through it. Both were real bugs. Neither was *this* bug.

**Attempt 3 — stop trusting the APIs.** `CGAssociateMouseAndMouseCursorPosition(0)` returns
success, `CGDisplayHideCursor` returns success, and the cursor moved anyway, so the position
was corrected after every movement instead. This made it worse, for a reason that took a
fourth attempt to see.

**Attempt 4 — measure, badly.** `cursor-doctor` reported 447 movements deleted and the cursor
held at one position with no drift, and the conclusion drawn was that deleting the event is
sufficient on its own. It was not a sound conclusion: that run also had an 8 ms re-parking
timer going, and sampled the cursor every 10 ms. A sampler slower than the thing it measures
can only report success. The timer was doing the work and the sampler could not see it.

**Attempt 5 — read someone else's working implementation.** Deskflow has solved this, so the
question became what it does that this did not. Two things, neither of which was going to be
arrived at by reasoning about the documented API.

First: **`CGDisplayHideCursor` does nothing for a background process.** It is documented to
apply "while the application is active", and a command-line tool never is. It returns
`kCGErrorSuccess` regardless. The window server has a private connection property,
`SetsCursorInBackground`, that lifts the restriction; set it and the call starts working.
So for four attempts this Mac's cursor was never hidden at all, and the argument about whether
it was *moving* was beside the point — there was always a second pointer on screen.

Second: **hiding the cursor re-couples it to the mouse.** Deskflow's `leave()` carries a
comment saying the uncoupling must come after the hide for exactly this reason. This code did
it the other way round, so the uncoupling was undone immediately afterwards and the cursor
followed the hand.

Both are now in one function, `LocalPointer.beginCapture`, because the ordering is the whole
difficulty and three separate calls is three chances to get it wrong. And because
`CGDisplayHideCursor` lies about what it did, the capture asks the window server afterwards —
via `CGCursorIsVisible`, withdrawn from the SDK but still present — and reports
`cursor confirmed hidden` or `CURSOR STILL VISIBLE`. `continuous capture-test` prints it.

The lesson, recorded because it was expensive: five attempts, four of them reasoned from
documentation and measurements, against an API that reports success for work it did not do.
The thing that settled it was half an hour reading an implementation that already worked.

**Also fixed:** a drag towards the far edge used to hand the pointer over mid-drag, stranding
whatever you were moving. Crossing is now blocked while any mouse button is held.

### ✅ M5 — Comfort  *(delivered)*

A menu-bar front end and clipboard sharing, so none of this has to live in a terminal.

**The menu bar supervises rather than reimplements.** The session runs as a child process — the
same binary with `connect` or `listen` — and the menu watches the state file the session
already publishes. Two reasons that is worth an extra process: a session that dies takes the
pointer with it but not the interface, so there is always something left to click *Start* on;
and there is exactly one implementation of a session, so what you debug from the terminal is
what the menu runs. Double-clicking the app, or `open -a Continuous`, starts it; typing
`continuous` in a shell still prints the usage, because there a person is waiting to read it.

**Clipboard sharing is off by default, and that is the point.** Whatever you last copied is
frequently a password, and this sends it to the other machine every time it changes. It is
also negotiated: nothing is sent unless *both* Macs advertised the capability, so switching it
off on either one is enough — you do not have to trust the other side to honour your setting.
Several representations travel together, richest first, so styled text still pastes somewhere
that only takes plain. File URLs are deliberately not carried: a path that means something on
one Mac means nothing, or something else, on the other. Images are a separate opt-in because a
screenshot is megabytes. Applying the other Mac's clipboard records the change count it
produced, or the two would hand the same clipboard back and forth for ever.

Frames grew from 64 KiB to 4 MiB to carry a clipboard; input events are unchanged at 21 bytes
for a mouse move. The protocol version went to 3, so a mismatched pair is refused at the
handshake with a clear message rather than failing later as an odd frame error.

#### Why the menu bar felt worse than the terminal

Reported after the first version: via the menu bar the pointer lagged on the other Mac, and
this Mac was left with a visible — though no longer moving — cursor. Both from the same binary
that behaved perfectly when run from a shell. Three causes, none of them in the session logic:

* **App Nap.** Run from a terminal, the session inherits the foreground application's
  treatment. Run as a child of a menu-bar accessory it is just another background process, so
  the system throttles it and coalesces its timers. `ProcessInfo.beginActivity` with
  `.latencyCritical` opts out; that is the lag.
* **A diagnostic left running at full tilt.** The drift sampler added while chasing the
  two-pointers bug ran at 1 kHz, and reading the pointer is a round trip to the window server.
  A thousand a second competes with the event tap for the very thing it is measuring. Now 50 Hz.
* **The menu redrawing itself.** The status item was being redrawn twice a second whether or
  not it had changed, and touching an `NSStatusItem` button makes AppKit reconsider the cursor
  — which un-hid the cursor the session was holding hidden. It now redraws only when it would
  look different, and the session re-asserts the hide within a frame if anything else undoes it.

The third is worth keeping in mind generally: the front end and the session are different
processes, but they share a window server, and that is enough for one to undo the other.

### M6 — If it is wanted
Dead keys and input methods, drag-and-drop of files, a preferences window, per-peer layouts.

---

## 5. Layout

```
Package.swift
Sources/ContinuousCore/      the library (transport, crypto, protocol, config)
Sources/continuous/          the CLI front-end
Tests/ContinuousCoreTests/   unit tests
Scripts/                     build + app-bundle + launchagent helpers
```
