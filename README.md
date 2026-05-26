# rainyTS

A **Rainmeter** skin that overlays your current **TeamSpeak 6** voice channel - showing who's in the channel and who's talking. Connects via the TS6 Remote Apps WebSocket API with automatic server switching when you use multiple TeamSpeak connections.

![Screenshot](assets/screenshot.png)

![Rainmeter](https://img.shields.io/badge/Rainmeter-4.5%2B-brightgreen)
![PowerShell](https://img.shields.io/badge/PowerShell-7%2B-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

---

## Features

- Displays the active voice channel name
- Lists all users in that channel with colored indicator icons &emsp; ![talking](https://img.shields.io/badge/talking-brightgreen) &nbsp; ![idle](https://img.shields.io/badge/idle-grey) &nbsp; ![mic--muted](https://img.shields.io/badge/mic--muted-yellow) &nbsp; ![fully%20muted](https://img.shields.io/badge/fully%20muted-red)
- Multi-server support - always displays the channel you talked in last
- Automatically hides when disconnected from TeamSpeak
- Dynamic height - expands/shrinks to fit the number of users
- Supports up to 24 simultaneous users in the overlay

---

## Requirements

| Dependency | Notes |
|---|---|
| [Rainmeter 4.5+](https://www.rainmeter.net/)  | The desktop widget engine |
| [PowerShell 7+](https://learn.microsoft.com/en-us/powershell/)  | Required - the skin invokes `pwsh` (PowerShell 7) |
| [TeamSpeak 6](https://www.teamspeak.com/) | Must have the **Remote Apps** feature enabled |

---

## Installation

### Teamspeak Remote Apps

1. Open TeamSpeak 6
2. Go to **Settings → Remote Apps**
3. Toggle on **"Enabled"**

### Before first run

1. Install [Rainmeter](https://www.rainmeter.net/) and [PowerShell 7](https://learn.microsoft.com/en-us/powershell/) 
2. Open TeamSpeak 6
3. Go to **Settings → Remote Apps** and keep this page opened

### Automatic (skin release download)

1. Download the latest `rainyTS.rmskin` from the [Releases](https://github.com/h4ppywastaken/rainyTS/releases) page
2. Double-click the `.rmskin` file - Rainmeter will install it automatically
3. Load the skin from Rainmeter's Manage dialog

### Manual (clone / extract)

1. Clone or download this repository into your Rainmeter `Skins` folder:

   ```
   %USERPROFILE%\Documents\Rainmeter\Skins
   ```

3. **Load the skin** in Rainmeter:
   - Right-click the Rainmeter tray icon → **Manage**
   - Find **rainyTS** in the list and load it

### Authorize the overlay (first run only)
1. TeamSpeak 6 will show a permission request notification (if not: try reloading the rainyTS skin in Rainmeter)
2. Click **Accept** - the overlay stores the API key encrypted in `@Resources\TS6ApiKey.clixml`

---

## Configuration

Edit `@Resources\Settings.inc` to customize colors, layout, and limits:

```ini
TS6_Host=127.0.0.1     ; TeamSpeak Remote Apps host
TS6_Port=5899          ; Remote Apps port
MaxUsers=24            ; maximum visible users

ColorBG=20,20,20,200   ; background
ColorTalk=0,230,80,255 ; talking indicator
ColorIdle=80,80,80,255 ; idle indicator
..., etc.
```

---

## How It Works

1. **PowerShell back-end** (`@Resources\TS6Client.ps1`)
   - Connects to TeamSpeak 6 via the Remote Apps WebSocket API
   - Authenticates with the TS6 API key
   - Listens for `clientMoved`, `talkStatusChanged`, `connectStatusChanged` and other events
   - Tracks multiple simultaneous TeamSpeak server connections
   - Writes channel/user data to `TS6Data.txt`

2. **Lua script** (`@Resources\Script.lua`)
   - Runs every Rainmeter update cycle (250 ms)
   - Reads `TS6Data.txt` and updates the UI
   - Hides the skin entirely when disconnected

3. **Data file format** (`TS6Data.txt`)
   ```
   ChannelName|UserCount
   ClientId|Nickname|TalkStatus|IsSelf|InputMuted|OutputMuted
   ClientId|Nickname|TalkStatus|IsSelf|InputMuted|OutputMuted
   ...
   ```

---

## Debugging

You can run the back-end outside Rainmeter for testing:

```cmd
Start-rainyTS.cmd
```

The console will display real-time WebSocket event logs.


---

## License

MIT
