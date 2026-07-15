# Codex Usage Widget

A native macOS menu bar companion and WidgetKit widget for monitoring and switching between Codex accounts.

![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- Current Codex account and plan
- Save multiple Codex accounts and refresh their quotas independently
- One-click account switching from the menu bar or medium/large widget
- Weekly remaining quota, used percentage, and reset time
- Lifetime and daily token summaries when provided by Codex
- Native small, medium, and large macOS widgets
- Menu bar remaining-percentage indicator
- Automatic refresh every 45 seconds
- Near-immediate refresh after a Codex account change
- Optional notifications at 20% and 10% remaining
- Displays earned Codex reset-credit count
- Two-step interactive widget action to redeem an available reset credit
- Launch at login

## Privacy

Codex Usage Widget is local-only. It starts the official local `codex app-server` process and requests account and rate-limit snapshots through its JSON-RPC interface.

The app:

- does not read browser cookies;
- does not upload account or usage data;
- does not bundle API keys, access tokens, email addresses, or machine-specific paths;
- reads the current `~/.codex/auth.json` only when you explicitly choose **Save Current Codex Account**;
- stores saved login credentials in macOS Keychain and never in the repository or usage snapshot;
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

## Multiple accounts

1. Sign in to the first account in Codex and choose **Save Current Codex Account** from the menu bar.
2. Sign in to another account in Codex, then save it the same way.
3. Use **Codex Accounts** in the menu bar, or **Switch** on a medium/large widget, to change accounts.

Each saved account gets an isolated local Codex home for quota refresh. Credentials are stored in macOS Keychain. Removing an account from the menu deletes the widget's saved Keychain item; it does not delete the account itself.

## Reset credits

When Codex reports an earned reset credit, the widget displays the available count. Redeeming is intentionally a two-step action:

1. Click **Reset Credit N**.
2. Click **Confirm Reset** within 30 seconds.

The menu bar synchronizer then calls Codex's local `account/rateLimitResetCredit/consume` method with a unique idempotency key and refreshes the rate-limit snapshot. If no current window is eligible, Codex returns `nothingToReset` and no successful reset is reported.

## Security

Please report security issues privately through GitHub's security advisory feature rather than opening a public issue.

## License

MIT
