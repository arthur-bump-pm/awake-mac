# CLAUDE.md

Awake is a macOS menu bar app for people who work from a laptop: keep-awake, lid-closed mode, auto-hotspot failover, and an "On the Move" mode that Claude Code can switch through MCP. Forked from [karansangha/Insomnia](https://github.com/karansangha/Insomnia) (MIT; keep the original copyright line).

## Build & run

```bash
swift build                      # debug build
swift test                       # all tests (core logic, socket round-trip, MCP handler)
./build_app.sh                   # build/Awake.app (release, ad-hoc signed)
./build_app.sh --install         # also quit the running copy, install to /Applications, relaunch
./Scripts/make_icon.sh           # regenerate Resources/AppIcon.icns from the shared mark geometry
build/Awake.app/Contents/MacOS/Awake --render-preview <dir>   # panel.png + settings.png, off-screen, no side effects
```

## Layout

- `Sources/AwakeCore` — all logic, no UI. Testable with injected fakes; shell commands only through `CommandRunning`.
  - `KeepAwakeController` — IOPM assertion with optional end time (from Insomnia's SleepManager).
  - `LidModeController` — `pmset -a disablesleep` plus the one-time sudoers rule at `/etc/sudoers.d/awake` that allows exactly `allowedCommands` (bump `ruleVersion` whenever that list changes). Installed through the macOS admin prompt, validated with `visudo -cf` first.
  - `PowerGuard` — hot-bag guard decisions, Low Power Mode (`pmset -b lowpowermode`), `SystemSleep.sleepNow`.
  - `Firewall` — application firewall + stealth mode read/apply. `DeskDetector` — external display + power, debounced.
  - `AwakeWatch` — who holds sleep assertions (Claude Code = caffeinate whose parent runs from `~/.local/share/claude/versions/`), `ProcessAwakeHold`.
  - `FailoverEngine` — pure state machine for hotspot failover and return (backoff, captive-portal hold). Keep it pure.
  - `ConnectivityProbe` (captive-portal aware), `WiFi` (CoreWLAN; needs Location for SSIDs), `PowerSource`, `HotspotPasswordStore`.
  - `ControlProtocol` / `ControlSocket` — line-delimited JSON over `~/Library/Application Support/Awake/control.sock` (0600, same-uid peers). `MCPHandler` — minimal MCP server logic.
- `Sources/Awake` — the app (AppKit entry in `Support.swift`, SwiftUI views hosted in AppKit windows):
  - `AppModel` — all state: On the Move (snapshot → apply → restore), end conditions, guard, desk nudges, network loop, control handler.
  - `StatusPanel` — status item + borderless panel + Settings window. `PanelView`, `SettingsView`.
  - `DesignSystem` — tokens and controls adapted from the Dimension style (Refero): void/graphite surfaces, hairlines, white = on, DM Sans + Geist (bundled, OFL). Inner corners are concentric: `Theme.innerRadius = panelRadius − panelPadding`. Switches always show their track.
  - `AwakeMark` — Mochi, the two-eye character: shared face geometry (used by `Scripts/IconRenderer`) and the menu bar glyph (asleep = closed lids, awake = eyes up, moving = eyes forward + motion lines).
- `Sources/awakectl` — CLI and MCP stdio server; bundled at `Awake.app/Contents/MacOS/awakectl`. Launches the app if it isn't running.

## Rules

- Design: follow `DesignSystem.swift` (Dimension style) for anything visual; macOS behaviour (keyboard, VoiceOver, template menu bar glyph) still follows Apple's HIG. Keep the panel short.
- Anything that needs root goes through the narrowly scoped sudoers rule, never a broad one; never store the user's password.
- Awake turns off only what it turned on (lid mode set by `lidawake` or by hand survives quitting Awake).
- No personal data in the repo: no Wi-Fi names, user names or machine details in code, tests or docs.
- Update the README Versions table whenever a version's status changes.
