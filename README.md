# Outpost

![License: MIT](https://img.shields.io/badge/license-MIT-blue)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)

**Your laptop, always on. Wherever you work.** Outpost is a small menu bar app for remote workers and digital nomads. It keeps your Mac running when you close the lid and move, switches to your iPhone hotspot when the internet drops, and lets Claude Code turn all of that on when you say "hey, I got to move."

## Versions

| Version | Status | Highlights |
|---|---|---|
| **1.0.0** | 🚧 in development | On the Move (lid-closed + keep awake + auto-hotspot, Low Power Mode and firewall shield, restores everything after), ends when Claude finishes; keep awake while Claude works; who's keeping your Mac awake; hot-bag guard; café Wi-Fi sign-in detection; desk detection; `outpostctl` CLI and MCP server for Claude Code; Dimension-style panel and icon |

## What it does

- **On the Move**: one switch for when you leave your desk. Your Mac keeps running with the lid closed, stays awake, and switches to your iPhone hotspot if the internet drops. On battery it also turns on Low Power Mode, and on public Wi-Fi it turns on the macOS firewall with stealth mode. When you're back, everything goes back to how it was. By default it ends by itself once Claude Code has finished working.
- **Keep awake**: for 1 or 4 hours, always, or *while Claude works*: Outpost watches Claude Code sessions and lets your Mac sleep a few minutes after the last one goes idle.
- **Who's keeping your Mac awake**: the panel names other apps holding your Mac awake, and warns when lid-closed mode was left on by something else.
- **Hot-bag guard**: if your Mac warms up with the lid closed it turns on Low Power Mode; if it gets hot or the battery drops to 20%, it turns everything off and puts the Mac to sleep.
- **Café Wi-Fi**: Outpost tells a Wi-Fi sign-in page apart from a dead connection, so it shows "Sign in" instead of burning your phone's data.
- **Auto-hotspot**: when Wi-Fi drops, or stays connected with no internet, Outpost joins your iPhone's Personal Hotspot within seconds, and goes back to Wi-Fi when it's healthy again.
- **Desk detection**: unplug from your monitor and charger with the lid open and Outpost offers On the Move; come back and it offers to turn it off.
- **Claude Code integration**: an MCP server, so a Claude session can switch On the Move when you tell it you're leaving.

## Install

Outpost is built from source for now (Xcode command-line tools required):

```bash
git clone https://github.com/arthur-bump-pm/outpost.git
cd outpost
./build_app.sh --install
```

Outpost appears in the menu bar as its icon's pill-shaped eye: dimmed when your Mac sleeps normally, bright while it's kept awake, and with motion lines while you're On the Move. If you use a menu bar manager (Hidden Bar, Bartender, Ice), drag Outpost's icon to the visible side.

### Connect Claude Code

```bash
claude mcp add --scope user outpost -- /Applications/Outpost.app/Contents/MacOS/outpostctl mcp
```

New Claude Code sessions then understand things like "hey, I got to move", "heading out", or "I'm back at my desk", and can report Outpost's status. The command is also in Outpost's Settings with a Copy button.

### Command line

```bash
/Applications/Outpost.app/Contents/MacOS/outpostctl status
outpostctl move on|off                   # On the Move
outpostctl awake on|off|claude|<minutes> # keep awake (lid open); "claude" = while Claude works
outpostctl lid on|off                    # lid-closed mode
outpostctl hotspot on|off|join           # auto-hotspot, or join now
```

## Permissions, and why

| What | When | Why |
|---|---|---|
| Your password, once | First time something needs it | Installs `/etc/sudoers.d/outpost`, which allows exactly these commands without a password, and nothing else: `pmset -a disablesleep 0/1`, `pmset -b lowpowermode 0/1`, `pmset sleepnow`, and the firewall's `--setglobalstate on/off` and `--setstealthmode on/off`. It is checked with `visudo` before it goes live. |
| Location access | When you set up auto-hotspot | macOS hides Wi-Fi network names from apps without it. Outpost never reads your location. |
| Notifications | First launch | Tells you when it switched networks, ended On the Move, or turned something off for safety. |
| Hotspot password | Optional, in Settings | Stored in your login keychain. |

Like any sudoers rule, those exact commands then work without a password for anything running as your user, not only Outpost. None of them can read your data or widen access; the worst a misbehaving app could do is keep your Mac awake, put it to sleep, or switch the firewall off. Remove the rule with the uninstall command below if that trade-off doesn't suit you.

On your iPhone, keep **Settings → Personal Hotspot → Allow Others to Join** on, so the hotspot is visible to your Mac.

## Uninstall

```bash
claude mcp remove outpost -s user        # if you connected Claude Code
sudo rm /etc/sudoers.d/outpost            # if you set up the admin permission
rm -rf /Applications/Outpost.app
```

## Credits

- Built on [Insomnia](https://github.com/karansangha/Insomnia) by Karan Sangha (MIT).
- Visual style adapted from the Dimension style on [Refero](https://styles.refero.design).
- Fonts: [DM Sans](https://github.com/googlefonts/dm-fonts) and [Geist](https://github.com/vercel/geist-font), both under the SIL Open Font License (license files in `Resources/Fonts`).
