# CLAUDE.md

Awake is a macOS menu bar app for people who work from a laptop: four modes (Off, Keep awake, Overnight, On the Move), auto-hotspot failover and health warnings, all of which Claude Code can switch or read through MCP. Forked from [karansangha/Insomnia](https://github.com/karansangha/Insomnia) (MIT; keep the original copyright line).

## Build & run

```bash
swift build                      # debug build
swift test                       # all tests (core logic, socket round-trip, MCP handler)
./build_app.sh                   # build/Awake.app (release, ad-hoc signed)
./build_app.sh --install         # also quit the running copy, install to /Applications, relaunch
./Scripts/make_icon.sh           # regenerate Resources/AppIcon.icns from the shared mark geometry
build/Awake.app/Contents/MacOS/Awake --render-preview <dir>   # panel.png, panel-calm.png + settings-<tab>.png of made-up samples, off-screen; creates <dir>, reads no settings, changes nothing
```

## Layout

- `Sources/AwakeCore` — all logic, no UI. Testable with injected fakes; shell commands only through `CommandRunning`.
  - `KeepAwakeController` — IOPM assertion with optional end time (from Insomnia's SleepManager), through `PowerAssertionManaging` (`LivePowerAssertionManager`; fakes in tests and the preview).
  - `LidModeController` — `pmset -a disablesleep` plus the one-time sudoers rule at `/etc/sudoers.d/awake` that allows exactly `allowedCommands` (bump `ruleVersion` whenever that list changes). Installed through the macOS admin prompt, validated with `visudo -cf` first. Async: `refresh()` / `setEnabled` run `pmset` off the main actor on one serial queue, reads numbered so an older one never overwrites a newer one; the blocking `refreshNow()` / `setEnabledNow` are for launch and quit only.
  - `Overnight` — `OvernightSession` (pure): the end (morning hour at least an hour away, when Claude finishes, or manual) and `isOver`.
  - `Health` — `HealthWatch` (pure): disk under 10 GB (clears above 12), memory pressure up for 60 s (one notification an hour), CPU ≥ 1 busy core averaged over 10 min on battery (clears under 0.5 over the last minute or when plugged in); `CPUTicks` (wrapping counters), `HealthMonitor` (live readers: `host_statistics`, `kern.memorystatus_vm_pressure_level`, important-use free space, `ps` for the busiest process).
  - `PowerGuard` — hot-bag guard decisions (`HotBagGuard`; Overnight on a charger stops only at critical heat), `GuardEpisode` (one stop-and-sleep per episode, so a lid mode that won't turn off doesn't repeat it), Low Power Mode (`pmset -b lowpowermode`), `SystemSleep.sleepNow`.
  - `Firewall` — application firewall + stealth mode read/apply. `DeskDetector` — external display + power, debounced.
  - `FirewallShield` — pure state of the one firewall shield owner: reasons (On the Move, public Wi-Fi), one snapshot, restore only what it turned on. A snapshot isn't proof: each raise is read back (`didApply`), a relaunch reapplies, and "shielded" means `isOn(firewall:)` against the last unprivileged read.
  - `NetworkProfile` — home / public / unknown from the SSID, trusted list and hotspot (pure). `ProfileHold` — the profile the shield follows: held through short unknown gaps, lapses after 10 min or when Wi-Fi is off. `ShortcutRunner` — `shortcuts run <name>`.
  - `CommandRunner` — `CommandRunning` / `ProcessCommandRunner`, and `SerialCommandQueue`: one serial queue for the firewall's commands, which quitting closes after the command in flight.
  - `SharingCheck` — sharing services that are on, by TCP connects to 127.0.0.1 (`PortConnecting` is injectable).
  - `Power` — `PowerReading` (raw IOKit values → time left, draw, weak charger; pure), `PowerMonitor` (IOKit), `PowerAlerts` (one warning per discharge / plug-in), `TimeText`.
  - `RemoteReach` — `TailscaleStatus` (CLI JSON parsing), `TailscaleCLI` (the app's CLI, else Homebrew's `/opt/homebrew/bin` or `/usr/local/bin`), and the reach decision (Tailscale → Remote Login → lid-closed mode; keep-awake alone is "until it sleeps").
  - `AwakeWatch` — who holds sleep assertions (Claude Code = caffeinate whose parent runs from `~/.local/share/claude/versions/`), `ProcessAwakeHold`.
  - `EyeTransition` — the menu bar eyes' open/close timing (0.35 s ease-out open, 0.3 s ease-in close, scaled by the distance left so a reversal continues smoothly), Reduce Motion, and the openness → frame step (pure).
  - `FailoverEngine` — pure state machine for hotspot failover and return (backoff, captive-portal hold). Keep it pure.
  - `ConnectivityProbe` (captive-portal aware), `WiFi` (CoreWLAN; needs Location for SSIDs), `PowerSource`, `HotspotPasswordStore`.
  - `ControlProtocol` / `ControlSocket` — line-delimited JSON over `~/Library/Application Support/Awake/control.sock` (0600, same-uid peers). `ControlRequest.problem`: the app refuses a malformed request (a switch without "on", minutes out of range) instead of reading it as on. Single instance: `ControlServer.start()` throws `alreadyRunning` when another copy answers on the socket (a stale socket file is replaced), and `AppModel.start()` then exits before touching any setting. `MCPHandler` — minimal MCP server logic; `replies(toLine:)` answers a line that isn't JSON with a -32700 parse error (id null).
- `Sources/Awake` — the app (AppKit entry in `Support.swift`, SwiftUI views hosted in AppKit windows):
  - `AppModel` — all state: the panel's `AwakeMode` (one at a time; `setModeFromMenu`), Overnight (lid-closed mode first, ends at its time, a lid-closed mode an older build left on becomes Overnight-manual; `lid on` from the CLI/MCP is Overnight-manual), On the Move (snapshot → apply → restore), health (`HealthWatch` every tick, disk every 30 s off the main actor), the firewall shield (one owner, serialized steps on `firewallQueue`, retried every 30 s), network profile + shortcuts, power alerts, reach refresh (sharing ports only at launch, on panel open and on a profile change; Tailscale at most every 5 min otherwise), end conditions, guard, desk nudges, network loop, control handler, panel alerts (including the last failed lid-mode / permission / On the Move action, since notifications may be off).
  - `StatusPanel` — status item (VoiceOver value + tooltip follow `menuBarStatus`) + borderless panel (capped to the screen, scrolls past that) + Settings window. `PanelView` (header, alerts, the four modes, footer — keep it to that; everything else goes to Settings), `SettingsView` (four tabs: General, Modes, Network, Setup; ⌘1–⌘4; Setup shows a dot while a permission is missing; switches are a short title plus a one-line detail).
  - `DevPreview` — `--render-preview`: draws `PreviewSample` (long Wi-Fi name, five alerts, weak charger, disk almost full, Overnight on, fixed `/Applications` path) and `PreviewSample.calm` (home Wi-Fi, keep-awake, no alerts) from `AppModel.preview()`, which uses `MemoryDefaults` and fakes for `pmset`, Location and power assertions, so it never reads the user's settings or the system. AppKit-backed controls draw as stand-ins (`liveControls`).
  - `DesignSystem` — tokens and controls adapted from the Dimension style (Refero): void/graphite surfaces, hairlines, white = on, DM Sans + Geist (bundled, OFL). Inner corners are concentric: `Theme.innerRadius = panelRadius − panelPadding`; Settings cards use `Theme.cardRadius`. Switches always show their track (off tracks at least 3:1 against their surface). A selected chip is white with graphite text.
  - `AwakeMark` — Mochi, the two-eye character: shared face geometry (used by `Scripts/IconRenderer`) and the menu bar glyph, drawn at any openness: 0 = closed lids (55% ink), 1 = eyes open looking up; in between the lids lift into the eyes and the pupils grow in. No motion lines: On the Move looks like plain awake. `StatusPanel` animates the eyes open and closed through cached frames (`MenuBarIcon`, one per `EyeTransition` step); Reduce Motion jumps to the end; no idle motion.
- `Sources/awakectl` — CLI and MCP stdio server; bundled at `Awake.app/Contents/MacOS/awakectl`. Launches the app if it isn't running.

## Rules

- Design: follow `DesignSystem.swift` (Dimension style) for anything visual; macOS behaviour (keyboard, VoiceOver, template menu bar glyph) still follows Apple's HIG. Keep the panel short.
- Anything that needs root goes through the narrowly scoped sudoers rule, never a broad one; never store the user's password.
- Awake turns off only what it turned on (lid mode set by another tool or by hand survives quitting Awake).
- No personal data in the repo: no Wi-Fi names, user names or machine details in code, tests or docs.
- Update the README Versions table whenever a version's status changes.
