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

**Status: milestone 1 of 5 — the secure link.** Pairing, encryption, discovery and the
connection between the two Macs all work and are tested. Input capture and injection are
milestones 2 and 3. See [BLUEPRINT.md](BLUEPRINT.md) for the plan and
[docs/SECURITY.md](docs/SECURITY.md) for the design of the security model.

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

      HQT5-GTRX-RQ7X-AZTV-9038-QRZ7-YRM8
```

On the Mac with the **keyboard and mouse**, type that code:

```bash
continuous pair join HQT5-GTRX-RQ7X-AZTV-9038-QRZ7-YRM8 --label "Work Mac"
```

The code carries 128 bits of secret and is the only thing the two Macs ever share. It is
checksummed, so a typo is reported as a typo instead of failing later as an unexplained
connection error.

## Connect

On the Mac lending its screen:

```bash
continuous listen
```

On the Mac with the keyboard:

```bash
continuous connect "Personal Mac"      # by Bonjour name
continuous connect 192.168.1.42        # or straight by address
```

```
✓ link up  →  Personal Mac  [Z0P8GCY3]  192.168.1.42:52777
· TLS 1.2 / ECDHE-PSK-CHACHA20-POLY1305-SHA256  ·  key 4447f0c4  ·  role client

  rtt   0.29 ms   last 0.29 ms · min 0.29 · mean 0.48 · max 0.69 · 3 sent, 0 lost
```

That round-trip number is worth watching. Under about 5 ms the pointer will feel attached to
your hand; much above that and you will notice it.

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
| `continuous listen` | accept links from a paired Mac |
| `continuous connect <HOST\|NAME>` | dial a listening Mac |
| `continuous discover` | browse the network for listening Macs |
| `continuous config show` / `set` | settings |

Useful options: `--port`, `--pair <label>` (when you have more than one pairing),
`--duration <seconds>`, `--no-bonjour`, `--log debug`.

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
swift test              # 41 unit tests
build/continuous selftest   # end-to-end, including the two rejection paths
```

If you switch between `swift test` and `Scripts/build.sh` and the build system gets confused
about macro plugins, `rm -rf .build` clears it.

## Licence

Do what you like with it.
