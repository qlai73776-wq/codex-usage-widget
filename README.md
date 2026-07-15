# Codex Usage Widget

A native macOS menu bar companion and WidgetKit widget for monitoring the currently signed-in Codex account.

![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- Current Codex account and plan
- Weekly remaining quota, used percentage, and reset time
- Lifetime and daily token summaries when provided by Codex
- Native small, medium, and large macOS widgets
- Menu bar remaining-percentage indicator
- Automatic refresh every 45 seconds
- Near-immediate refresh after a Codex account change
- Optional notifications at 20% and 10% remaining
- Launch at login

## Privacy

Codex Usage Widget is local-only. It starts the official local `codex app-server` process and requests account and rate-limit snapshots through its documented JSON-RPC interface.

The app:

- does not read browser cookies;
- does not upload account or usage data;
- does not bundle API keys, access tokens, email addresses, or machine-specific paths;
- does not read `~/.codex/auth.json` directly;
- writes only a short-lived usage snapshot to `/private/tmp/io.github.codexusage/usage.json` so the sandboxed WidgetKit extension can render it.

The snapshot contains display data such as email, plan, remaining percentage, reset time, and aggregate token counts. macOS normally clears `/private/tmp` during restart; the menu bar app recreates the snapshot after login.

## Install

Download the latest ZIP from [Releases](../../releases), unzip it, and move **Codex Usage.app** to `/Applications`.

On first launch, macOS may require confirmation because community builds are ad-hoc signed. Then:

1. Open **Codex Usage** once.
2. Right-click the desktop and select **Edit Widgets**.
3. Search for **Codex Usage**.
4. Add the preferred size.

Keep the menu bar app running; it is the local data synchronizer for the system widget.

## Build from source

Requirements:

- macOS 14 or later
- Xcode 16 or later
- Codex/ChatGPT desktop app with its bundled `codex` executable, or `codex` installed in a standard command-line location

```bash
chmod +x build.sh
./build.sh
```

The release archive is written to `dist/Codex-Usage-macOS.zip`.

## How synchronization works

```text
Codex app-server
      ↓ JSON-RPC
Menu bar synchronizer (45-second refresh)
      ↓ local temporary snapshot + WidgetCenter reload
Native WidgetKit widget
```

The menu bar's **Refresh Now** action uses the same path as automatic refresh; it is optional and intended for diagnostics.

## Security

Please report security issues privately through GitHub's security advisory feature rather than opening a public issue.

## License

MIT
