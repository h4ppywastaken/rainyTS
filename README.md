![Project Name](https://img.shields.io/badge/Project-rainyTS-blue)

# TeamSpeak 6 Overlay Skin for Rainmeter (TS6 Desktop Widget / rainyTS)

A lightweight, fully customizable **Rainmeter skin** that acts as a real-time **TeamSpeak 6 (TS6)** voice channel overlay widget. Monitor your active voice server, see who is connected, and track live talking status indicators directly on your desktop window - eliminating the need to tab out of games.

It connects securely via the TS6 Remote Apps WebSocket API and features automatic server switching when handling multiple simultaneous TeamSpeak connections.

![TeamSpeak 6 Rainmeter Overlay UI Skin Screenshot](assets/screenshot.png)

![Rainmeter](https://img.shields.io/badge/Rainmeter-4.5%2B-brightgreen)
![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

---

## Key Features

- **Live TS6 Speaker Status:** Users who are talking light up with a green avatar, ring and row highlight.
- **Voice Channel Monitor:** Shows your current channel name, a user count and everyone in the channel, each with an initial avatar. Your own name is shown in semibold.
- **Status Indicators:** &emsp; ![talking](https://img.shields.io/badge/talking-34D378) &nbsp; ![idle](https://img.shields.io/badge/idle-grey) &nbsp; ![mic--muted](https://img.shields.io/badge/mic--muted-F5B43C) &nbsp; ![fully%20muted](https://img.shields.io/badge/fully%20muted-F05A5A) &nbsp; Muted users are dimmed and get a mic or speaker icon.
- **Multi-Server Support:** Automatically shifts focus to display the TS6 channel you spoke in last.
- **Smart Auto-Hide:** The desktop widget automatically hides itself when disconnected from TeamSpeak.
- **Dynamic UI Height:** The card grows and shrinks with the number of users in the channel (up to 24).
- **Self-Healing Back-end:** The connection script restarts automatically if it ever exits.
- **Themeable:** Every color, size and font lives in one settings file (right-click the skin > **Edit settings**).

---

## Prerequisites & Dependencies

Before setting up the TeamSpeak 6 overlay, ensure your system has the following core components installed:

| Dependency | Required Version | Purpose |
|---|---|---|
| [Rainmeter](https://www.rainmeter.net/)  | `4.5+` | The open-source desktop widget customization engine |
| [PowerShell](https://learn.microsoft.com/en-us/powershell/)  | `7+ (pwsh)` | Required back-end environment for skin execution |
| [TeamSpeak 6](https://www.teamspeak.com/) | Client App | Must support and have the **Remote Apps** feature enabled |
| Windows | 11 (or 10) | Status icons use the *Segoe Fluent Icons* font that ships with Windows 11; on Windows 10 see [UI Customization](#ui-customization--configuration) |

---

## Installation & Setup Guide

### 1. Enable TeamSpeak Remote Apps API
1. Open your **TeamSpeak 6** client.
2. Navigate to **Settings** > **Remote Apps**.
3. Toggle the option to **"Enabled"**. Keep this settings window open during the initial skin launch.

### 2. Install the Rainmeter Skin

#### Method A: Automatic Installation (Recommended)
1. Download the latest `.rmskin` package from the [GitHub Releases](https://github.com/h4ppywastaken/rainyTS/releases) page.
2. Double-click the downloaded `rainyTS.rmskin` file. Rainmeter will handle the installation automatically.
3. Load the skin using the Rainmeter Manage dialog.

#### Method B: Manual Installation (Git Clone)
1. Clone or extract this repository directly into your local Rainmeter `Skins` directory:
   ```cmd
   %USERPROFILE%\Documents\Rainmeter\Skins
   ```
2. Open the Rainmeter Manage window (right-click Rainmeter system tray icon > **Manage**).
3. Click **Refresh all**, locate **rainyTS** in the skin library list, and click **Load**.

### 3. Authorize the TS6 Desktop Widget
1. Upon first run, TeamSpeak 6 will display an incoming connection permission request notification. *(If it does not appear, try reloading the skin in Rainmeter).*
2. Click **Accept**. The voice overlay will securely encrypt and store your authorized API key inside `@Resources\TS6ApiKey.clixml`.

---

## UI Customization & Configuration

You can customize connection settings, colors (`R,G,B,A`), layout and fonts by editing `@Resources\Settings.inc` (or right-click the skin > **Edit settings**), then refreshing the skin:

```ini
; TeamSpeak Remote Apps host and WebSocket port
TS6_Host=127.0.0.1
TS6_Port=5899

; Card background gradient (top / bottom) and channel accent color
ColorBGTop=32,34,41,246
ColorBGBottom=21,22,27,246
ColorAccent=110,168,255,255

; Status colors: talking, mic muted, fully muted
ColorTalk=52,211,120,255
ColorMicMute=245,180,60,255
ColorFullMute=240,90,90,255

; Card width, row height and avatar size (px)
SkinWidth=240
LineHeight=26
AvatarSize=20
```

The status icons use **Segoe Fluent Icons** (Windows 11). On Windows 10, set `IconFont=Segoe MDL2 Assets`.

> Rainmeter only supports comments on their own line; don't put `;` comments after a value.

---

## Technical Architecture & How It Works

This TeamSpeak widget relies on a multi-tier script framework to ensure low CPU usage and lightweight rendering:

1. **PowerShell Core Back-end** (`@Resources\TS6Client.ps1`)
   - Establishes a persistent connection to TS6 via the WebSocket API.
   - Listens for server events such as `clientMoved`, `talkStatusChanged`, and `connectStatusChanged`.
   - Constantly writes the normalized channel payload state directly into `TS6Data.txt`.

2. **Lua Controller Script** (`@Resources\Script.lua`)
   - Ticks on a 250 ms Rainmeter update cycle to read `TS6Data.txt`.
   - Only redraws the rows whose content changed, and triggers the auto-hide state when the connection drops.

3. **Data Buffer Interface** (`TS6Data.txt`)
   ```text
   ChannelName|UserCount
   ClientId|Nickname|TalkStatus|IsSelf|InputMuted|OutputMuted
   ClientId|Nickname|TalkStatus|IsSelf|InputMuted|OutputMuted
   ...
   ```

---

## Troubleshooting & Debugging

If the voice overlay is not displaying active channel data, you can debug the WebSocket back-end connection independently from Rainmeter:

```cmd
Start-rainyTS.cmd
```
This execution script spins up a dedicated terminal window displaying real-time stream logs from the TeamSpeak Remote Apps API. While it is open, the skin's own back-end waits in the background and takes over again once you close the console.

The skin connects to `TS6_Host` / `TS6_Port` from `Settings.inc`; `Start-rainyTS.cmd` always uses the defaults (`127.0.0.1:5899`).

---

## Support & Contributions

If you find this overlay useful for your gaming setup, considerations for donations are greatly appreciated:

[![PayPal](https://img.shields.io/badge/Donate-PayPal-blue)](https://paypal.me/h4ppywastaken)

## License

Distributed under the open-source **MIT License**. See `LICENSE` for details.