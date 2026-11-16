# Security design

The premise of this project is that a keyboard-sharing tool sees every password you type, so
the question "who else could be reading this?" has to have a short, checkable answer.

## Threat model

**In scope.** Anyone who can reach your Macs over the network: a stranger on café Wi-Fi, a
colleague on the office LAN, someone with a packet capture, someone who finds a pairing code
on a whiteboard, someone who steals one Mac. Also: the authors of this tool — the design should
not require trusting them either, which is why there is no server, no update check, and no
outbound connection to anything but your own paired Mac.

**Out of scope.** A process already running as you on your own Mac. Such an attacker can read
`secrets.json`, install their own event tap, and read your keystrokes directly. No tool in this
category defends against that, and claiming otherwise would be dishonest.

## The layers

### 1. Pairing

`pair init` generates 128 bits from the system CSPRNG and shows it as 28 Crockford base32
characters. Crockford's alphabet omits `I`, `L`, `O` and `U` and the decoder treats the
look-alikes as their twins, so the usual transcription mistakes do not produce a different key.
An 8-bit checksum is appended, which catches over 99% of single-character typos and turns them
into "check the code for a typo" instead of an unexplained TLS failure ten minutes later.

Everything else is derived from that secret with HKDF-SHA256 under distinct salts:

```
pairing secret (128 bits)
  └─ HKDF ─► psk           (32 bytes)   the TLS pre-shared key
       ├─ HKDF ─► auth key (32 bytes)   the in-band challenge/response
       └─ HKDF ─► key id   (8 bytes)    public; selects which key a link uses
```

The key id is sent in the clear as the TLS PSK identity, which is what lets one Mac be paired
with several others and still run a single listener. It is a separate HKDF output rather than a
hash of the key, so it reveals nothing about the key itself.

### 2. Transport

`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 7905), and nothing else is accepted.

* **PSK** authenticates both ends. There is no certificate and no certificate authority in the
  design at all. An attacker without the key fails inside the TLS handshake, so no
  unauthenticated party ever reaches the code that parses input events.
* **ECDHE** gives forward secrecy. Each session negotiates an ephemeral key, so an adversary
  who records your traffic today and obtains `secrets.json` a year from now still cannot
  decrypt what they recorded. For a channel whose plaintext is your keystrokes, that is worth
  insisting on.
* **ChaCha20-Poly1305** is an AEAD: no CBC padding oracle, constant-time in software.

A note on the version. Network.framework only wires external pre-shared keys into TLS 1.2 —
pinning 1.3 makes the handshake fail outright. That was established by testing the
configurations on this machine rather than assumed, and the experiment is reproducible: a TLS
1.3 PSK handshake fails with `errSSLHandshakeFail (-9858)`. Restricted to a single ECDHE+AEAD
suite, TLS 1.2 has none of the weaknesses it usually gets blamed for, all of which come from
RSA key transport, CBC modes, or negotiation flexibility that is not present here.

Because a silent downgrade to a non-forward-secret PSK suite would be invisible, the link
re-checks what was actually negotiated when TLS comes up and drops the connection if it is not
the required suite — before a single application byte is read.

### 3. In-band mutual authentication

On top of TLS, both ends run an HMAC-SHA256 challenge/response over nonces contributed by
each side:

```
A → B   hello     deviceID_A, nonce_A, key id
A ← B   helloAck  deviceID_B, nonce_B, HMAC(authKey, "responder" ‖ nonce_A ‖ nonce_B ‖ deviceID_B)
A → B   authProof           HMAC(authKey, "initiator" ‖ nonce_A ‖ nonce_B ‖ deviceID_A)
A ← B   ready
```

This is deliberately redundant with the layer below. It exists for two reasons: it is a second
independent check if something is wrong in the TLS configuration, and it binds the session to a
specific *device id* rather than merely to a key. Each proof covers its direction, both nonces
and the prover's identity, so a proof captured in one direction or one session cannot be
replayed into another. Comparison is constant-time.

### 4. Device pinning

A pairing is unbound until the first successful handshake, then it records the peer's device id
and will refuse any other Mac presenting the same key. This is what makes a leaked pairing code
survivable: once you have used it, the code alone is no longer enough. Moving a pairing to a
different machine is possible but has to be deliberate (`--rebind`).

### 5. Exposure limits

The listener refuses connections from addresses that are neither private/link-local nor on a
subnet this Mac is directly attached to. This is not the security boundary — the key is — but
it keeps the TLS handshake code from being reachable by the internet at large.

Two practical notes. Address *ranges* alone are not enough: with IPv6 enabled, Bonjour offers
the peer's global address alongside its link-local one, and a range-only check refuses the Mac
sitting next to you. Hence the comparison against this Mac's own interface prefixes. And
`--allow-public` exists to turn the check off, with a warning, for anyone tunnelling the link
deliberately.

### 6. At rest

`secrets.json` is mode `0600` inside a `0700` directory, written atomically, and the loader
refuses to read it if the permissions are looser — the same stance OpenSSH takes with private
keys, for the same reason.

## What is verified, and how

`continuous selftest` runs the whole stack over loopback and checks the rejection paths, not
just the happy one:

* a handshake with the correct key succeeds, and reports the negotiated suite
* a handshake with a **wrong key** is refused at the TLS layer
* a handshake with the **right key but a different device id** is refused by the pinning check
* a single-character typo in a pairing code is caught by the checksum
* truncated frames, unknown message types and invalid enum values are rejected rather than
  half-decoded

`swift test` covers the key schedule, the proof construction (every input must change the
output), the codec, address classification and the permission check on the secrets file.

## Known limitations

* Ad-hoc code signing means a rebuild changes the binary's code identity, so macOS may ask you
  to re-grant Accessibility. A paid Developer ID certificate would fix this; trusting someone
  else's signed binary is the thing this project exists to avoid.
* Bonjour advertises this Mac's name and device id on the local network. Use `--no-bonjour` and
  connect by address if you would rather it did not.
* Nothing here protects against a compromised macOS account, as noted above.
