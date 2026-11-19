# Edge — Blueprint

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
| Secrets at rest | `~/Library/Application Support/Edge/secrets.json`, mode `0600`, refuses to load if permissions are looser (same discipline as `~/.ssh`). |
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

* **Client listens and advertises** over Bonjour (`_edge._tcp`); **host browses and connects**.
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
  `edge layout set right center` if you prefer straight-line crossings.

Both sides watch for display reconfiguration and re-send their layout, so switching the monitor
updates the arrangement without reconnecting.

### Why TLS 1.2 and not 1.3

TLS 1.3 with an external pre-shared key is not available:
Network.framework only wires external PSKs into **TLS 1.2**, and pinning 1.3 makes the
handshake fail with `errSSLHandshakeFail (-9858)`. However, `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) *is* supported — which
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

The binary ships inside a real `Edge.app` bundle (`LSUIElement`, no Dock icon) so macOS
attributes those grants to *Edge* rather than to Terminal.

---

## 4. Features

* **Secure link** — device identity, X25519 pairing over the network with a six-digit numeric
  comparison on both screens, `0600` secret storage, ECDHE-PSK transport, mutual HMAC
  challenge/response, device pinning, Bonjour discovery, RTT measurement.
* **Injection** — `CGEventPost` on the secondary: absolute pointer moves, drag, buttons with click
  counts, scroll, keys by virtual key code, modifiers, and release-everything if the link drops.
* **Capture & edge switching** — an active `CGEventTap` at `.cghidEventTap` on the primary; the
  hardware is detached from the local cursor, which is parked and hidden; crossing requires edge
  pressure and is blocked while a mouse button is held.
* **Living with it** — auto-reconnect with backoff, a LaunchAgent for login, `status`, a stable
  code-signing identity so permissions survive updates.
* **Menu bar app** — supervises the session as a child process (`connect` / `listen`) and watches
  its state file, so there is exactly one session implementation. One *Set up…* flow chooses the
  role (primary drives, secondary lends its screen) and pairs. The arrangement is drawn to scale
  and editable on the primary only.
* **Clipboard sharing** — off by default, negotiated (both Macs must opt in), several
  representations richest first, images a separate opt-in, file URLs never carried.
* **Cable links** — each Mac advertises its addresses in its Bonjour record; when a cable is
  preferred the `169.254` Thunderbolt/USB-C address is dialled (≈1 ms vs. tens of ms over Wi-Fi).
  `auto` prefers a cable when one is advertised. Pairing always happens over Wi-Fi.

## 5. Getting your Mac back

While the pointer is away every event is swallowed, so there are four independent routes back,
decided by `PointerRouter` — a plain value type with no sockets, CoreGraphics or clock, so it is
tested exhaustively:

| Route back | Trigger |
| --- | --- |
| the link closes | peer quit, network dropped, process killed |
| the heartbeat goes quiet | no pong for 4 s |
| the escape chord | ⌘ ⌥ ⌃ ⇧ held together, checked before anything else |
| the tap is disabled | macOS turns off a tap whose handler was too slow |

Nothing is swallowed unless the link is up *and* the other Mac's arrangement is known, and every
route back goes through one function. Input sharing is refused when both ends are the same Mac.

## 6. Platform notes

* **Hiding the cursor from a background process.** `CGDisplayHideCursor` silently does nothing
  unless the window-server connection property `SetsCursorInBackground` is set, and hiding
  re-couples the cursor to the mouse — so the order is hide, *then* detach. Both live in
  `LocalPointer.beginCapture`; visibility is confirmed afterwards via `CGCursorIsVisible`.
* **The hide count is global.** The display argument is ignored, so every successful hide is
  recorded and undone exactly. Both sides re-assert the hide at 50 Hz while the pointer is away,
  because anything sharing the window server (an `NSStatusItem` redraw, an app changing its
  cursor) can undo it.
* **App Nap.** Sessions started from the menu bar are background processes; both sides use
  `ProcessInfo.beginActivity(.latencyCritical)`.
* **Pointer moves are coalesced.** At most two frames are in flight; a waiting move is replaced,
  never queued (deltas are summed). Clicks, keys, scrolls and control messages are never dropped.
* **Wi-Fi latency.** `LinkWarmer` sends a tiny ping when the link has been idle for 25 ms while the
  pointer is away, so neither radio dozes. Traffic is marked `.interactiveVideo` and the link
  queues are `.userInteractive`. Timed pointer moves let the secondary log arrival jitter.
* **Key reload.** Sessions restart when the set of pairing key identifiers changes (not the
  file's timestamp, which a successful connection also touches).
* **Windows from a menu-bar app.** Windows are opened one run-loop turn after the menu action and
  owned by the app (no `NSAlert` for typing), or text fields never become key.

## 7. Future work

Dead keys and input methods, drag-and-drop of files, a preferences window, per-peer layouts.

---

## 8. Layout

```
Package.swift
Sources/EdgeCore/      the library (transport, crypto, protocol, config)
Sources/edge/          the CLI front-end
Tests/EdgeCoreTests/   unit tests
Scripts/               build, app bundle, release and LaunchAgent helpers
```
