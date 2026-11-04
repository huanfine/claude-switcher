<div align="center">

# ClaudeSwitcher

**Claude 环境检查器 — a fail-closed local environment manager for multiple Claude accounts**

[中文](README.md) · [GitHub](https://github.com/huanfine/claude-switcher) · [Issues](https://github.com/huanfine/claude-switcher/issues)

> Based on [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher) (MIT) — see [Origin and License](#origin-and-license).

<img src="assets/icon-256.png" width="120" alt="Claude 环境检查器">

</div>

---

## What it is

ClaudeSwitcher keeps several Claude accounts on one Mac without letting their
local state mix. Each account has its own device fingerprint, sign-in
credentials, and application data; switching swaps those directories atomically
instead of signing out and back in.

Before Claude starts, the app runs a **16-point audit** of the machine's network
and regional environment. If a blocking check fails, the app is not launched. A
resident bodyguard stops the protected application when the tunnel drops, and a
runtime watchdog compares the live egress against the baseline captured at
launch time.

The desktop window is titled **Claude 环境检查器**. `ClaudeSwitcher` remains the
repository, command-line script, and build artifact name.

## Features

- **16-point preflight audit** — proxy core, TUN interface, exit country, IP
  stability, time zone, locale, IPv6, DNS tunnel, WebRTC candidates, bodyguard
  status, pinned routing, client language, ASN type, IP purity score, Claude
  reachability, and better-node availability. Results are `ok` / `fail` /
  `config` / `warn` / `skip`; both `fail` and `config` block launch, and `skip`
  never counts as a pass.
- **Snapshot switching (A–D)** — archives and restores whole account
  directories; APFS copy-on-write cloning avoids duplicating unchanged data.
- **Fail-closed bodyguard** — checks the proxy kernel and virtual interface
  every ten seconds and terminates protected processes when the tunnel is lost.
- **Runtime egress watchdog** — samples the exit every 10s, runs a full audit
  every 60s, and stops Claude if the egress changes or the audit fails twice.
- **Drift watchdog** — records a baseline for time zone and proxy settings and
  rolls back silent changes made by other software.
- **Multiple proxy clients** — Clash Verge, FlClash, Shadowrocket, sing-box,
  ClashX, Surge, and an automatic mode. Clash Verge and FlClash repairs install
  and verify routing rules with rollback; other clients keep their own rules.
- **Region adaptation** — captures the exit country, time zone, and locale at
  install time and re-locks all three after moving to a different node.
- **Pinned routing** — places Claude domains and supporting services above
  third-party rule sets, with a CIDR fallback that does not depend on a client
  database.
- **WebRTC leak probe** — a standard-library STUN client that compares global
  and local vantage points to distinguish a proxied path from a direct one.
- **IP purity score** — an explainable 0–100 score from four independent data
  sources plus local PTR, with degraded verdicts when sources are unreachable.
- **Node scan and gated apply** — read-only ranking of the current Selector's
  candidate nodes; applying the best node requires a fresh real-time gate,
  re-checks the exit country, and rolls back on any failed step.
- **Automatic updates** — a user-level LaunchAgent checks every 12 hours,
  verifies artifact hashes against `SHA256SUMS`, and rolls back if the
  post-update self-check fails.
- **Diagnostics and inspection** — standalone proxy transport diagnosis, device
  fingerprint report, Claude Code CLI inspection, one-shot isolated browser,
  encrypted snapshot export/import, and redacted diagnostic bundles.
- **Native menu bar UI** — a single-file SwiftUI app with no Xcode project and
  no third-party dependencies; the icon is generated from `assets/icon-gen.swift`.
- **Web check page** — a static browser-side check for exit IP, time zone,
  language, WebRTC, IPv6, DNS reachability, and common fingerprint signals.
- **Windows and Linux ports (beta)** — PowerShell and bash implementations with
  the same audit and switching model. Windows also includes A–D accounts,
  proxy-client switching, read-only inspection tools, isolated browsing,
  standalone proxy diagnostics, and encrypted `.csnap` snapshots (not
  compatible with macOS DMG). New Windows UI and runtime flows still require
  hardware verification; static checks are not a substitute.

## Install

Requirements: macOS 13 or later, a proxy client with TUN support (Clash Verge,
FlClash, Shadowrocket, sing-box, ClashX, or Surge), the Claude desktop app, and
Python 3. The exit country must not be `CN` — the installer derives the target
country, time zone, and locale from the current egress.

```bash
git clone https://github.com/huanfine/claude-switcher.git
cd claude-switcher
# Then double-click installer/安装.command
```

The installer detects the proxy client, proxy group, and regional target, then
builds the desktop app locally and installs the core script, bodyguard, and
time-zone watchdog. The command-line entry point is
`~/.local/bin/claude-switch.sh`. To build and package manually:

```bash
bash scripts/package-macos.sh 1.0.0
```

Artifacts are written to `build/`. macOS builds are ad-hoc signed and not
notarized. If Gatekeeper blocks the first launch, open the app from the context
menu or allow it under **System Settings → Privacy & Security**.

For Windows, see [`windows/README.md`](windows/README.md); for Linux, see
[`linux/README.md`](linux/README.md).

## Usage

1. Open the desktop app and wait for the 16 checks.
2. If everything is green, choose an account and launch Claude. If a blocking
   check is red, use the one-click repair action.
3. Sign in once for each additional account; later switches keep sessions
   independent.
4. After changing to a node in another country, run
   `~/.local/bin/claude-switch.sh set-region`.

The full command set, menu bar behavior, and troubleshooting notes are in the
[Chinese README](README.md) and [AGENTS.md](AGENTS.md).

## Disclaimer

This project is intended for managing the local environment and sign-in state of
multiple Claude accounts in supported regions, for people who are traveling,
living abroad, or otherwise legitimately located in a supported region. Please
follow Anthropic's Terms of Service. Do not use it for account resale, account
sharing, registering accounts on behalf of others, or circumventing regional
restrictions.

Local environment checks only inspect and configure this machine. They do not
change server-side records and do not guarantee that an account will not be
restricted. The software is provided as-is under the MIT license; you are
responsible for how you use it.

## Links

- [中文说明](README.md)
- [GitHub 仓库](https://github.com/huanfine/claude-switcher)
- [Issues](https://github.com/huanfine/claude-switcher/issues)
- [Security policy](SECURITY.md)
- [Agent handoff guide](AGENTS.md)
- [Web environment check](https://huanfine.github.io/claude-switcher/) — published
  from `docs/`; enable GitHub Pages (`Deploy from a branch` / `main` / `/docs`)
  before the link resolves.
- [Windows beta](windows/README.md) · [Linux beta](linux/README.md)

## Origin and License

This project is a fork of [YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher) (MIT License). The original copyright and permission notice are kept in [LICENSE](LICENSE). The UI redesign, additional checks, node scanning and documentation maintenance in this repository are maintained by huanfine.

MIT © Claude Switcher Contributors
