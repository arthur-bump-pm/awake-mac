# Awake

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

**Your laptop, always on. Wherever you work.** Awake is a small menu bar app for remote workers and digital nomads. It keeps your Mac running when you close the lid and move, switches to your iPhone hotspot when the internet drops, and lets Claude Code turn all of that on when you say "hey, I got to move."

## Versions

| Version | Status | Highlights |
|---|---|---|
| **1.0.0** | 🚧 in development | Four modes in a short panel (Off, Keep awake, Overnight, On the Move); Settings in four tabs, with shortcut pickers; Overnight (lid open or closed until the morning, when Claude finishes or when turned off); On the Move (lid-closed + keep awake + auto-hotspot, Low Power Mode and firewall shield, restores everything after), ends when Claude finishes; keep awake while Claude works; health warnings (disk almost full, low memory, busy CPU on battery); who's keeping your Mac awake; hot-bag guard; café Wi-Fi sign-in detection; desk detection; home vs public Wi-Fi shield; battery time left and weak-charger warning; reach from your phone (Tailscale + SSH); `awakectl` CLI and MCP server for Claude Code; Dimension-style panel and icon |

## What it does

The menu bar panel shows your connection and battery, anything that needs you, and four modes, one at a time: **Off**, **Keep awake**, **Overnight** and **On the Move**. Everything else is in Settings, in four tabs: General, Modes, Network and Setup.

- **Overnight**: for long jobs and nights. Your Mac keeps running with the lid open or closed (the display can still sleep) until the morning hour you pick in Settings (9 AM by default), until Claude finishes, or until you turn it off. It changes nothing else: Wi-Fi, the firewall and Low Power Mode stay as they are. On a charger only critical heat stops it; on battery the hot-bag guard still applies, in case it ends up in a bag.
- **On the Move**: one switch for when you leave your desk. Your Mac keeps running with the lid closed, stays awake, and switches to your iPhone hotspot if the internet drops. It also turns on Low Power Mode (on battery) and the macOS firewall with stealth mode. When you're back, everything goes back to how it was. By default it ends by itself once Claude Code has finished working.
- **Keep awake**: for 1 or 4 hours, always, or *while Claude works*: Awake watches Claude Code sessions and lets your Mac sleep a few minutes after the last one goes idle. Keep awake works with the lid open; to keep running with the lid closed, use Overnight or On the Move.
- **Who's keeping your Mac awake**: with Awake off, the panel names other apps holding your Mac awake, and it warns when lid-closed mode was left on by something else.
- **Hot-bag guard**: if your Mac warms up with the lid closed it turns on Low Power Mode; if it gets hot or the battery drops to 20%, it turns everything off and puts the Mac to sleep. Overnight on a charger counts as a desk, not a bag: only critical heat stops it.
- **Health warnings**: the panel (and one notification) warns when the startup disk has under 10 GB free, when memory pressure stays high for a minute, or when the CPU has averaged a full core or more for 10 minutes on battery (naming the busiest app). Turn them off in Settings → General. For live CPU, memory and network graphs, use a system monitor such as RunCat.
- **Café Wi-Fi**: Awake tells a Wi-Fi sign-in page apart from a dead connection, so it shows "Sign in" instead of burning your phone's data.
- **Auto-hotspot**: when Wi-Fi drops, or stays connected with no internet, Awake joins your iPhone's Personal Hotspot within seconds, and goes back to Wi-Fi when it's healthy again.
- **Home vs public Wi-Fi**: mark your own networks as trusted (your hotspot always is). On any other Wi-Fi, Awake turns on the macOS firewall with stealth mode, points out sharing that's on (Screen Sharing, File Sharing, Remote Login), and can run a Shortcut; back on a trusted network it puts the firewall back and can run another.
- **Battery**: time left on battery in the panel, one heads-up when it falls under the threshold you choose in Settings (15, 30 or 60 minutes; 30 by default), and a warning when a charger is too weak to keep up.
- **Reach from your phone**: with Tailscale installed (the app, or the Homebrew CLI), Settings shows whether your phone can reach this Mac over Tailscale + SSH (and that it stays on with the lid closed), with a Copy SSH button, or the first thing that's missing.
- **Desk detection**: unplug from your monitor or your charger (either counts) with the lid open and Awake offers On the Move; plug both back in and it offers to turn it off.
- **Claude Code integration**: an MCP server, so a Claude session can switch On the Move when you tell it you're leaving, turn on Overnight when you're off to bed, and check the Mac's health before a long job.

## Known limitations

- A network is trusted by its Wi-Fi name, which anyone can copy: a stranger's hotspot with the same name as one of your trusted networks counts as trusted, and the shield stays down there.
- Failing over between public Wi-Fi and your own hotspot switches the shield each time: down on the hotspot, up again back on the public Wi-Fi.

## Install

Awake is built from source for now (Xcode command-line tools required):

```bash
git clone https://github.com/arthur-bump-pm/awake-mac.git
cd awake-mac
./build_app.sh --install
```

Awake appears in the menu bar as Mochi's two eyes: closed while Awake is off, and open and looking up while Awake keeps your Mac awake (On the Move included). Its tooltip and VoiceOver say which. When that changes, the eyes animate open or closed; with Reduce Motion on (System Settings → Accessibility → Display) they switch without animating. If you use a menu bar manager (Hidden Bar, Bartender, Ice), drag Awake's icon to the visible side.

### Connect Claude Code

```bash
claude mcp add --scope user awake -- /Applications/Awake.app/Contents/MacOS/awakectl mcp
```

New Claude Code sessions then understand things like "hey, I got to move", "heading out", "going to bed, keep it running" or "I'm back at my desk", and can report Awake's status, the Mac's health included. The command is also in Awake's Settings with a Copy button.

### Command line

`awakectl` lives inside the app. To type it as plain `awakectl`, link it into a folder on your PATH, for example `ln -s /Applications/Awake.app/Contents/MacOS/awakectl ~/.local/bin/awakectl`.

```bash
/Applications/Awake.app/Contents/MacOS/awakectl status
awakectl move on|off                   # On the Move
awakectl awake on|off|claude|<minutes> # keep awake (lid open); "claude" = while Claude works
awakectl overnight on|off|claude|always # Overnight: until the morning hour in Settings, until Claude finishes, or until turned off
awakectl lid on|off                    # lid-closed mode (on = overnight always)
awakectl hotspot on|off|join           # auto-hotspot, or join now
```

## Permissions, and why

| What | When | Why |
|---|---|---|
| Your password, once | First time something needs it | Installs `/etc/sudoers.d/awake`, which allows exactly these commands without a password, and nothing else: `pmset -a disablesleep 0/1`, `pmset -b lowpowermode 0/1`, `pmset sleepnow`, and the firewall's `--setglobalstate on/off` and `--setstealthmode on/off`. It is checked with `visudo` before it goes live. |
| Location access | When you set up auto-hotspot or trusted networks | macOS hides Wi-Fi network names from apps without it. Awake never reads your location. |
| Notifications | First launch | Tells you when it switched networks, ended On the Move, or turned something off for safety. |
| Login item | First launch | Starts Awake when you log in. Turn it off in Awake Settings → General. |
| Hotspot password | Optional, in Settings | Stored in your login keychain. |

Like any sudoers rule, those exact commands then work without a password for anything running as your user, not only Awake. None of them can read your data or widen access; the worst a misbehaving app could do is keep your Mac awake, put it to sleep, or switch the firewall off. Remove the rule with the uninstall command below if that trade-off doesn't suit you.

On your iPhone, keep **Settings → Personal Hotspot → Allow Others to Join** on, so the hotspot is visible to your Mac.

## Uninstall

1. Quit Awake first. Quitting puts back everything it changed (lid-closed mode, Low Power Mode, the firewall):

   ```bash
   osascript -e 'quit app "Awake"'
   ```

2. Turn off Launch at login: System Settings → General → Login Items, switch Awake off (or turn it off in Awake Settings → General before you quit).
3. Remove the MCP entry, the sudoers rule and the app:

   ```bash
   claude mcp remove awake -s user        # if you connected Claude Code
   sudo rm /etc/sudoers.d/awake            # if you set up the admin permission
   rm -rf /Applications/Awake.app
   rm -f ~/.local/bin/awakectl             # if you linked awakectl
   ```

Optional cleanup:

```bash
defaults delete io.github.arthur-bump-pm.Awake        # settings
security delete-generic-password -s "Awake Hotspot"    # saved hotspot password
rm -rf ~/Library/Application\ Support/Awake            # control socket folder
sudo pmset -a disablesleep 0                           # fallback: only if lid-closed mode is still on
```

## Credits

- Built on [Insomnia](https://github.com/karansangha/Insomnia) by Karan Sangha (MIT).
- Visual style adapted from the Dimension style on [Refero](https://styles.refero.design).
- Fonts: [DM Sans](https://github.com/googlefonts/dm-fonts) and [Geist](https://github.com/vercel/geist-font), both under the SIL Open Font License (license files in `Resources/Fonts`).
