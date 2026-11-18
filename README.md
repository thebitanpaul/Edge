<div align="center">

<h1>
  <img src="docs/assets/edge-icon.png"
       width="55"
       alt="Edge Logo"
       align="center"> Edge
</h1>

<h3><em>One keyboard and mouse across two Macs — even when they can't share an Apple ID.</em></h3>

<p>Push the pointer off the edge of one Mac and it appears on the other, with your keyboard, clipboard and files following it.</p>

</br>

[![Download for macOS](https://img.shields.io/badge/Download_for-macOS-000000?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/thebitanpaul/Edge/releases/latest/download/Edge.dmg)
[![Open on phiUture](https://img.shields.io/badge/Open%20on-phiUture-000000?style=for-the-badge)](https://phiuture.com)

![Version](https://img.shields.io/github/v/release/thebitanpaul/Edge?style=flat-square&label=version&color=0A84FF)
![macOS](https://img.shields.io/badge/macOS-13%2B-0A84FF?style=flat-square&logo=apple&logoColor=white)
![Universal](https://img.shields.io/badge/Apple_silicon_%2B_Intel-universal-0A84FF?style=flat-square)
![License](https://img.shields.io/badge/license-Apache_2.0-0A84FF?style=flat-square)

</div>

```
     Mac A (your keyboard)                 Mac B (its screen)
  ┌────────────────────────┐          ┌────────────────────────┐
  │  pointer hits the edge │  ──────► │  pointer appears here  │
  │  keystrokes forwarded  │   TLS    │  keystrokes injected   │
  └────────────────────────┘          └────────────────────────┘
          no cloud · no account · no third-party server
```

## Why Edge?

Apple's Universal Control needs the same Apple ID on both Macs. If one is managed by your
employer and the other is yours, that is not a trade you should have to make. Third-party
alternatives ask for permission to read every keystroke you type — and then you have to take
their word for what happens next.

**Edge is the same idea with the trust removed.** It runs only on your two Macs, talks only to
the other Mac, and every line of code that holds those permissions is in this repository.

<br/>

## Features

<table>
<tr>
<td width="50%" valign="top">

### 🖱️ Seamless crossing
Push the pointer against the shared edge and it glides onto the other Mac, keyboard and all.
A gentle push threshold stops stray movements from throwing it across.

</td>
<td width="50%" valign="top">

### 🔐 End-to-end encrypted
Every link is TLS 1.2 with `ECDHE-PSK-CHACHA20-POLY1305`. Forward secrecy per session, and an
unpaired machine never gets past the handshake.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🤝 One-tap pairing
Choose **Set up** on both Macs and confirm the same six digits. No codes to type, no account,
and neither Mac can end up with a key the other lacks.

</td>
<td width="50%" valign="top">

### 📂 Drag files across
Pick up a file, push it through the edge, let go — it lands in Downloads on the other Mac.
Folders are zipped on the way. Works in both directions.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 📋 Shared clipboard
Copy on one Mac, paste on the other. Text, rich text and HTML travel together; images on
request. Off by default, and must be on at both ends.

</td>
<td width="50%" valign="top">

### ⚡ Thunderbolt & USB-C cable
A cable between the Macs is picked up automatically — **1.2 ms** against 236 ms over Wi-Fi.
Private, physically isolated, and rock steady.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🖥️ Multi-display aware
Every screen on both Macs is combined into one desktop, including a monitor that switches
between them. Arrange it visually, to scale.

</td>
<td width="50%" valign="top">

### 🎛️ Menu bar & Control Center
Lives in the menu bar with no Dock icon. On macOS 26+, add the **Edge** switch and
**Edge Options** to Control Center.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🔊 Media keys follow you
Volume, mute, play/pause, track skip, screen brightness and keyboard backlight all act on the
Mac you're working on.

</td>
<td width="50%" valign="top">

### 🔄 Swap roles in one click
**Switch to Secondary** flips both Macs at once, with the screen arrangement already mirrored.

</td>
</tr>
<tr>
<td width="50%" valign="top">

### 🛟 Always a way back
Hold **⌘ ⌥ ⌃ ⇧** to bring the pointer home instantly. It also returns on its own if the link
drops or the other Mac goes quiet.

</td>
<td width="50%" valign="top">

### 🌙 Set and forget
Reconnects by itself, starts at login, and never keeps either Mac awake unless the two are
linked.

</td>
</tr>
</table>

<br/>

## Install

1. **[Download Edge.dmg](https://github.com/thebitanpaul/Edge/releases/latest/download/Edge.dmg)**
   on both Macs.
2. Open it and drag **Edge** onto **Applications**.
3. Open Edge from Applications. The first time, macOS will say it can't verify the developer —
   Edge is open source and not notarised by Apple. Go to **System Settings ▸ Privacy & Security**,
   scroll down and click **Open Anyway**.
4. Grant the permissions Edge asks for:

| Mac | Needs |
| --- | --- |
| **Primary** — the one whose keyboard you use | Input Monitoring and Accessibility |
| **Secondary** — the one it reaches onto | Accessibility |

> Requires **macOS 13 Ventura** or later. Control Center controls need **macOS 26** or later.

<br/>

## Get started

1. **Pair** — choose **Set up** on both Macs (same Wi-Fi network). Pick **Primary** on one and
   **Secondary** on the other, then confirm the matching six digits.
2. **Arrange** — on the primary, open **Screen arrangement** from the menu bar and place the
   other Mac to the left, right, top or bottom.
3. **Start** — choose **Start** on the primary. The secondary gets ready on its own.

Now push the pointer off the edge of your screen towards the other Mac.

```
  Primary · connected to Work Mac
  Cable · 1 ms · clipboard
  ─────────────────────────────
  Stop
  ─────────────────────────────
  Devices              ▸
  Screen arrangement
  Connect over         ▸  Whichever connects · Cable · Wi-Fi
  ─────────────────────────────
  ✓ Share clipboard
  ✓ Carry dragged files
  ✓ Start at login
  ─────────────────────────────
  Switch to Secondary
  Help                 ▸
  Quit Edge
```

<br/>

## Privacy & security

- **No cloud, no account, no telemetry.** Edge talks to exactly one machine: your other Mac.
- **The pairing key is the encryption key.** A machine without it cannot reach any code that
  parses input events.
- **Forward secrecy.** Recording traffic today and stealing the key later still decrypts nothing.
- **Pinned pairings.** A pairing binds to the first Mac that uses it, so a leaked key is not
  enough to impersonate it.
- **No root, no kernel extension.** Edge runs as you, in your login session.
- **Zero dependencies.** Built entirely on Apple's own SDK.

The full threat model, including what is deliberately *not* defended against, is in
[docs/SECURITY.md](docs/SECURITY.md).

<br/>

## When it won't connect

```bash
edge troubleshoot    # pairing keys, firewall, Bonjour, reachability, latency
edge doctor          # environment, permissions, pairings, network interfaces
```

If a connection takes more than ~150 ms, the pointer will feel sluggish whatever the software
does — connect a **Thunderbolt or USB-C cable** between the Macs. If your network blocks
Bonjour, use **Devices ▸ &lt;the Mac&gt; ▸ Set address** with the other Mac's IP.

<br/>

## Command line

Everything in the menu is also available from the terminal. The app ships the `edge` binary at
`/Applications/Edge.app/Contents/MacOS/edge`.

| Command | What it does |
| --- | --- |
| `edge pair nearby` | Pair with another Mac — run it on both |
| `edge listen` / `edge connect` | Run the secondary / primary side of a session |
| `edge layout set <edge>` | Where the other Mac sits: `left`, `right`, `top`, `bottom` |
| `edge status` | What is running, and which Mac has the pointer |
| `edge permissions` | What is granted, and how to grant the rest |
| `edge selftest` | Full crypto and transport check, on this Mac alone |
| `edge controls` | Check the Control Center setup |
| `edge service install <role>` | Run headless at login as `listen` or `connect` |
| `edge config set <key> <value>` | Settings — e.g. `edgePressure`, `clipboardSharing`, `preferredLink` |

<br/>

## Build from source

Needs only the Xcode Command Line Tools — no packages are downloaded.

```bash
git clone https://github.com/thebitanpaul/Edge.git && cd Edge
Scripts/build.sh               # builds build/Edge.app
build/edge selftest            # proves crypto and transport work on this Mac
Scripts/test.sh                # unit tests
Scripts/package-dmg.sh         # universal Edge.dmg in dist/
```

`Scripts/create-signing-identity.sh` creates a local signing certificate so macOS keeps your
permission grants across rebuilds. See [BLUEPRINT.md](BLUEPRINT.md) for how Edge is built.

<br/>

## Built with

<div align="center">

![Swift](https://img.shields.io/badge/Swift-F05138?style=for-the-badge&logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)
![Network.framework](https://img.shields.io/badge/Network.framework-0A84FF?style=for-the-badge&logo=apple&logoColor=white)
![WidgetKit](https://img.shields.io/badge/WidgetKit-34C759?style=for-the-badge&logo=apple&logoColor=white)

</div>

<br/>

## License

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Copyright (c) 2026 Bitan Paul, phiUture. All Rights Reserved.

## About phiUture


Welcome to phiUture — Beautiful Technology. Centered Around You. Shaping Tomorrow.

Inspired by the Golden Ratio (φ), our name represents beautiful, intelligent engineering, while the "U" stands for You—placing people at the center of every solution we build.

phiUture is an AI-first software company creating intelligent products, automation systems, and modern digital experiences. This channel documents the journey of building practical AI solutions, from concept to deployment.

```text
Here you'll find:
• AI applications and product demos
• AI agents and automation workflows
• Web and mobile app showcases
• Machine Learning and Data Engineering projects
• Product launches and development insights
• UI/UX and software engineering content
• Tutorials, experiments, and future innovations
```

| Personal | Business | Artist |
|----------|----------|--------|
| [![GitHub](https://img.shields.io/badge/GitHub-thebitanpaul-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/thebitanpaul) | [![Website](https://img.shields.io/badge/Website-phiUture-000000?style=for-the-badge&logo=googlechrome&logoColor=white)](https://phiuture.com) | [![YouTube](https://img.shields.io/badge/YouTube-thebitanpaul-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/@thebitanpaul) |
| [![LinkedIn](https://img.shields.io/badge/LinkedIn-thebitanpaul-0A66C2?style=for-the-badge&logo=linkedin&logoColor=white)](https://linkedin.com/in/thebitanpaul) | [![YouTube](https://img.shields.io/badge/YouTube-phiUture-FF0000?style=for-the-badge&logo=youtube&logoColor=white)](https://www.youtube.com/@phiuture) | [![Spotify](https://img.shields.io/badge/Spotify-1DB954?style=for-the-badge&logo=spotify&logoColor=white)](https://open.spotify.com/artist/6ghDcCBlKzJIgm3e586jpV) |
| [![Instagram](https://img.shields.io/badge/Instagram-E4405F?style=for-the-badge&logo=instagram&logoColor=white)](https://instagram.com/thebitanpaul) [![Threads](https://img.shields.io/badge/Threads-000000?style=for-the-badge&logo=threads&logoColor=white)](https://www.threads.com/@thebitanpaul) | [![Google Play](https://img.shields.io/badge/Google_Play-Developer-34A853?style=for-the-badge&logo=googleplay&logoColor=white)](https://play.google.com/store/apps/dev?id=6358474525178045834&hl=en) | [![YouTube Music](https://img.shields.io/badge/YouTube_Music-FF0000?style=for-the-badge&logo=youtubemusic&logoColor=white)](https://music.youtube.com/playlist?list=OLAK5uy_km3cjEB2zl59Etcgv9UBKWw800O9G3NdE) |
| [![Facebook](https://img.shields.io/badge/Facebook-1877F2?style=for-the-badge&logo=facebook&logoColor=white)](https://facebook.com/thebitanpaul) | [![Email](https://img.shields.io/badge/Business_Email-thephiuture%40gmail.com-D14836?style=for-the-badge&logo=gmail&logoColor=white)](mailto:thephiuture@gmail.com) | [![Amazon Music](https://img.shields.io/badge/Amazon_Music-46C3D0?style=for-the-badge&logo=amazonmusic&logoColor=white)](https://music.amazon.com/albums/B0G52QMYDC) |
| [![X](https://img.shields.io/badge/X-000000?style=for-the-badge&logo=x&logoColor=white)](https://x.com/thebitanpaul_) |  | [![Apple Music](https://img.shields.io/badge/Apple_Music-FA243C?style=for-the-badge&logo=applemusic&logoColor=white)](https://music.apple.com/us/artist/thebitanpaul/1858534880) |
| [![Snapchat](https://img.shields.io/badge/Snapchat-FFFC00?style=for-the-badge&logo=snapchat&logoColor=000000)](https://snapchat.com/t/UgO0Iywr) |  | [![JioSaavn](https://img.shields.io/badge/JioSaavn-2BC5B4?style=for-the-badge&logo=jiosaavn&logoColor=white)](https://www.jiosaavn.com/artist/thebitanpaul-songs/zuo0NgC65gQ_) |
| [![Email](https://img.shields.io/badge/Personal_Email-thebitanpaul%40gmail.com-EA4335?style=for-the-badge&logo=gmail&logoColor=white)](mailto:thebitanpaul@gmail.com) |  |  |



<div align="center">

**2024 · © phiUture · All Rights Reserved**

</div>
