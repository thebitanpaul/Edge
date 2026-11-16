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

### M3 — Capture & edge switching  *(next)*
`CGEventTap` on the sending Mac, consume-and-forward, cursor park/hide, and the switch at the
shared edge driven by the layout built in M2.
**Verify:** the real thing — pointer and keyboard cross between the two Macs.

### M4 — Fidelity & robustness
Key repeat, dead keys, multi-display layouts, auto-reconnect with backoff, a hotkey to force
a switch, LaunchAgent so it starts at login, latency instrumentation.

### M5 — Comfort (optional, each opt-in)
Clipboard sync, a menu-bar status item, a small config UI.

---

## 5. Layout

```
Package.swift
Sources/ContinuousCore/      the library (transport, crypto, protocol, config)
Sources/continuous/          the CLI front-end
Tests/ContinuousCoreTests/   unit tests
Scripts/                     build + app-bundle + launchagent helpers
```
