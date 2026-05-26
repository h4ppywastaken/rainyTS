param(
    [string]$HostAddr = "127.0.0.1",
    [int]$Port = 5899
)

# Load the WebSocket assembly if available.
# On powershell.exe (.NET Framework) this assembly might already be loaded
# by the runtime, so a failure here is non-fatal.
Add-Type -AssemblyName System.Net.WebSockets -ErrorAction SilentlyContinue

# PowerShell 5's ConvertTo-Json default depth is only 2, but our auth
# payload contains nested objects (content.apiKey, payload.connections).
$PSDefaultParameterValues['ConvertTo-Json:Depth'] = 10


# ==================== General helpers ====================

function Sanitize-Name {
    param([string]$Name)
    if (-not $Name) { return "?" }
    $Name = $Name -replace '[\x00-\x1F\x7F]', ''
    $Name = $Name -replace '[|]', '?'
    if ($Name.Trim() -eq '') { return '' }
    return $Name
}

function Get-JsonValue {
    param($Obj, [string]$Path)
    $c = $Obj
    foreach ($p in $Path.Split('.')) {
        if ($null -eq $c) { return $null }
        try { $c = $c.$p } catch { return $null }
    }
    return $c
}

# Read input_muted / output_muted from a TS6 properties object.
# Returns @{im=…; om=…} where each value may be $null if not present.
function Get-PropsMuteStatus {
    param($Props)
    $im = Get-JsonValue $Props "input_muted"
    if ($null -eq $im) { $im = Get-JsonValue $Props "inputMuted" }
    $om = Get-JsonValue $Props "output_muted"
    if ($null -eq $om) { $om = Get-JsonValue $Props "outputMuted" }
    return @{ im = $im; om = $om }
}

function Write-Log {
    param([string]$M)
    Write-Host "$(Get-Date -Format HH:mm:ss) $M"
}


# ==================== File paths ====================

$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataFile       = Join-Path $scriptDir "TS6Data.txt"
$keyFile        = Join-Path $scriptDir "TS6ApiKey.clixml"
$legacyKeyFile  = Join-Path $scriptDir "TS6ApiKey.txt"
$pidFile        = Join-Path $scriptDir "TS6Client.pid"

# Ensure at most one rainyTS script runs at a time.
if (Test-Path $pidFile) {
    try {
        $oldPid = (Get-Content $pidFile -Raw).Trim()
        if ($oldPid -match '^\d+$' -and [int]$oldPid -ne $PID) {
            $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match 'powershell|pwsh') {
                Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
        }
    } catch { }
}
try { [System.IO.File]::WriteAllText($pidFile, $PID.ToString()) } catch { }


# ==================== TS6 app identity ====================

$appId   = "rainy.ts.overlay"
$appName = "rainyTS Overlay"
$appDesc = "Rainmeter voice channel overlay"


# ==================== Script state ====================

$script:ws                   = $null   # ClientWebSocket instance
$script:activeConnectionId   = 0       # TS6 connection ID we are currently tracking
$script:myClientId           = 0       # Our own client ID on the active connection
$script:myChannelId          = 0       # Channel we are currently in
$script:myNickname           = ""
$script:channelName          = ""
$script:apiKey               = ""
$script:channelClients       = @{}     # cid -> @{n=name; t=talkStatus; im=inputMuted; om=outputMuted}
$script:cachedClientInfos    = @{}     # cid -> @{channelId=; nickname=} (active connection mirror)
$script:cachedChannelInfos   = @{}     # channelId -> name (active connection mirror)
$script:connectionsCache     = @{}     # connId -> @{clientId=; inputHardware=; clientInfos=@{}; channelInfos=@{}}
$script:authDone             = $false  # true once we've processed an auth response
$script:selfDisconnected     = $false  # true after we manually disconnect (suppresses refresh)
$script:lastTalkConn         = 0       # connection where we last heard ourselves talk
$script:pendingRefresh       = $false  # guard: stops Write-DataFile from clobbering a REFRESH signal


# ==================== API key persistence ====================

function Read-Key {
    # Try DPAPI-encrypted Clixml (preferred).
    if (Test-Path $keyFile) {
        try {
            $cred = Import-Clixml $keyFile
            $pwd = $cred.GetNetworkCredential().Password
            Write-Log "Key read from clixml, len=$($pwd.Length)"
            return $pwd
        } catch { Write-Log "Key clixml failed: $_" }
    }
    # Fall back to the legacy plain-text file, then migrate it.
    if (Test-Path $legacyKeyFile) {
        try {
            $plain = (Get-Content $legacyKeyFile -Raw).Trim()
            if ($plain) {
                Write-Key $plain
                Remove-Item $legacyKeyFile -ErrorAction SilentlyContinue
                return $plain
            }
        } catch { }
    }
    Write-Log "No key file found"
    return ""
}

function Write-Key {
    param([string]$K)
    try {
        $cred = New-Object System.Management.Automation.PSCredential "apikey", ($K | ConvertTo-SecureString -AsPlainText -Force)
        $cred | Export-Clixml -Path $keyFile
    } catch { }
}


# ==================== Data file writer ====================

function Write-DataFile {
    # If a pendingRefresh flag is set, don't write — the REFRESH signal
    # from the previous event must be preserved until Lua reads it.
    if ($script:pendingRefresh) { return }

    $lines = New-Object System.Collections.ArrayList
    $sorted = $script:channelClients.GetEnumerator() | Sort-Object { $_.Value.n }
    foreach ($e in $sorted) {
        $isLocal = if ($e.Key -eq $script:myClientId) { "1" } else { "0" }
        $im = if ($e.Value.im -eq 1) { 1 } else { 0 }
        $om = if ($e.Value.om -eq 1) { 1 } else { 0 }
        [void]$lines.Add("$($e.Key)|$($e.Value.n)|$($e.Value.t)|$isLocal|$im|$om")
    }
    $chan = if ($script:channelName) { $script:channelName } else { "?" }
    $content = "$chan|$($lines.Count)`n$($lines -join "`n")"
    try { $content | Out-File $dataFile -Encoding utf8NoBOM } catch { }
    $script:prevState = $content
}

function Write-DisconnectedState {
    if ($script:pendingRefresh) { return }
    $content = "DISCONNECTED|0`n"
    try { $content | Out-File $dataFile -Encoding utf8NoBOM } catch { }
    $script:prevState = $content
}


# ==================== WebSocket ====================

# Wait-Task polls a .NET Task's IsCompleted flag instead of calling
# Wait(). On powershell.exe (.NET Framework), Task.Wait() can deadlock
# when the async continuation tries to marshal back to a captured
# SynchronizationContext (e.g. the Rainmeter RunCommand plugin thread).
# Polling avoids the deadlock by never blocking the thread indefinitely.
function Wait-Task {
    param(
        [System.Threading.Tasks.Task]$Task,
        [int]$TimeoutSeconds = 60
    )
    if ($Task.IsCompleted) { return $true }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $Task.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    return $Task.IsCompleted
}

function Connect-WS {
    try {
        if ($script:ws) { try { $script:ws.Dispose() } catch { }; $script:ws = $null }
        $script:ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $script:ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
        $uri = "ws://${HostAddr}:${Port}"
        Write-Log "Connecting to $uri"
        $task = $script:ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None)
        if (-not (Wait-Task $task -TimeoutSeconds 10)) { throw "Timeout" }
        if ($task.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) { throw "Failed" }
        Write-Log "Connected"
        return $true
    } catch { Write-Log "Connect: $_"; return $false }
}

function Read-WS-Msg {
    try {
        $buff = New-Object byte[] 65536
        $seg = [System.ArraySegment[byte]]::new($buff)
        $task = $script:ws.ReceiveAsync($seg, [System.Threading.CancellationToken]::None)
        while (-not $task.IsCompleted) { Start-Sleep -Milliseconds 100 }
        if ($task.Status -ne [System.Threading.Tasks.TaskStatus]::RanToCompletion) { return $null }
        $r = $task.Result
        if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { return $null }
        $text = [System.Text.Encoding]::UTF8.GetString($buff, 0, $r.Count)
        # Handle multi-frame messages (EndOfMessage is false for partial frames).
        while (-not $r.EndOfMessage) {
            $seg2 = [System.ArraySegment[byte]]::new($buff)
            $rt = $script:ws.ReceiveAsync($seg2, [System.Threading.CancellationToken]::None)
            while (-not $rt.IsCompleted) { Start-Sleep -Milliseconds 100 }
            $r2 = $rt.Result
            $text += [System.Text.Encoding]::UTF8.GetString($buff, 0, $r2.Count)
        }
        return $text
    } catch { return $null }
}

function Send-WS {
    param([string]$Json)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $seg = [System.ArraySegment[byte]]::new($bytes)
        $task = $script:ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None)
        if (-not (Wait-Task $task -TimeoutSeconds 10)) { return $false }
        return ($task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion)
    } catch { return $false }
}

function Disconnect-WS {
    param([switch]$DontWriteState)
    try {
        if ($script:ws -and ($script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -or
                $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::CloseReceived)) {
            $task = $script:ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "", [System.Threading.CancellationToken]::None)
            Wait-Task $task -TimeoutSeconds 2
        }
    } catch { }
    $script:ws = $null
    $script:activeConnectionId = 0; $script:myClientId = 0; $script:myChannelId = 0
    $script:channelClients.Clear(); $script:cachedClientInfos.Clear(); $script:cachedChannelInfos.Clear(); $script:connectionsCache.Clear()
    $script:lastTalkConn = 0
    if (-not $DontWriteState) { Write-DisconnectedState }
}


# ==================== Multi-server connection management ====================

# TS6 Remote Apps can maintain connections to multiple TeamSpeak servers
# simultaneously. Only one server can be "active" (i.e., has the microphone
# capture — inputHardware=false). We track every connection in
# $connectionsCache and maintain a subset of "active" state variables that
# drive the overlay display.

# Copy-ActiveFromCache reads the current activeConnectionId and populates
# the display-oriented state variables (channelClients, channelName, etc.)
# from that connection's data in connectionsCache.
function Copy-ActiveFromCache {
    $connId = $script:activeConnectionId
    if (-not $connId -or -not $script:connectionsCache.ContainsKey($connId)) { return }

    $connData = $script:connectionsCache[$connId]
    $script:myClientId = $connData.clientId

    # Reset display state, then rebuild from the cached connection data.
    $script:cachedClientInfos = @{}
    $script:channelClients.Clear()
    $script:myChannelId = 0
    $script:myNickname = ""
    $script:channelName = ""

    foreach ($entry in $connData.clientInfos.GetEnumerator()) {
        $script:cachedClientInfos[$entry.Key] = @{
            channelId=$entry.Value.channelId
            nickname=$entry.Value.nickname
            inputMuted=$entry.Value.inputMuted
            outputMuted=$entry.Value.outputMuted
        }
    }
    # Find our own client info from the caching pass above.
    foreach ($entry in $connData.clientInfos.GetEnumerator()) {
        if ($entry.Key -eq $script:myClientId) {
            $script:myChannelId   = $entry.Value.channelId
            $script:myNickname    = $entry.Value.nickname
        }
    }
    # Populate channelClients from the cached infos for our channel.
    foreach ($entry in $script:cachedClientInfos.GetEnumerator()) {
        if ($entry.Value.channelId -eq $script:myChannelId) {
            $im = if ($entry.Value.inputMuted -eq 1) { 1 } else { 0 }
            $om = if ($entry.Value.outputMuted -eq 1) { 1 } else { 0 }
            $script:channelClients[$entry.Key] = @{n=$entry.Value.nickname; t=0; im=$im; om=$om}
        }
    }
    $script:cachedChannelInfos = @{}
    foreach ($entry in $connData.channelInfos.GetEnumerator()) {
        $script:cachedChannelInfos[$entry.Key] = $entry.Value
        if ($entry.Key -eq $script:myChannelId) {
            $script:channelName = $entry.Value
        }
    }
    # Ensure we always appear in our own channel list.
    if ($script:myClientId -gt 0 -and -not $script:channelClients.ContainsKey($script:myClientId)) {
        $n = if ($script:myNickname) { $script:myNickname } else { "?" }
        $script:channelClients[$script:myClientId] = @{n=$n; t=0; im=0; om=0}
        if (-not $script:cachedClientInfos.ContainsKey($script:myClientId)) {
            $script:cachedClientInfos[$script:myClientId] = @{channelId=$script:myChannelId; nickname=$n}
        }
    }
}

# Sync-ActiveConnection scans all cached connections and switches to the one
# with inputHardware=false (active mic). This is called after every
# clientPropertiesUpdated event so the overlay always tracks the active server.
function Sync-ActiveConnection {
    $best = 0
    foreach ($entry in $script:connectionsCache.GetEnumerator()) {
        if ($entry.Value.inputHardware -eq $false) {
            $best = $entry.Key
        }
    }
    if ($best -gt 0 -and $best -ne $script:activeConnectionId) {
        Write-Log "inputHardware: switching to conn $best"
        Switch-ActiveConnection $best
    }
}

# Switch-ActiveConnection changes which connection we are tracking and
# updates the overlay to show that server's channel and users.
function Switch-ActiveConnection {
    param($NewConnId)
    if ($NewConnId -eq $script:activeConnectionId) { return }
    if (-not $script:connectionsCache.ContainsKey($NewConnId)) { return }
    $script:activeConnectionId = $NewConnId
    Copy-ActiveFromCache
    Write-Log "Switched to connection $NewConnId — channel=''$script:channelName'' users=$($script:channelClients.Count)"
    Write-DataFile
}


# ==================== Event handlers ====================

function Handle-AuthMsg {
    param($data)
    Write-Log "Auth response received"

    # Persist the apiKey if the server sent one (future connections use it).
    $script:apiKey = Get-JsonValue $data "payload.apiKey"
    if (-not $script:apiKey) { $script:apiKey = Get-JsonValue $data "apiKey" }
    if ($script:apiKey) { Write-Key $script:apiKey }

    $connections = Get-JsonValue $data "payload.connections"
    if (-not $connections) { $connections = Get-JsonValue $data "connections" }

    $script:connectionsCache.Clear()
    $script:channelClients.Clear()
    $script:channelName = ""
    $script:pendingRefresh = $false

    if ($connections) {
        $activeCandidate = 0
        foreach ($conn in $connections) {
            $cid = $conn.id
            if (-not $cid -or $cid -eq 0) { continue }

            $selfId = Get-JsonValue $conn "clientId"
            $connData = @{
                clientId      = $selfId
                inputHardware = $null
                inputMuted    = $null
                clientInfos   = @{}
                channelInfos  = @{}
            }

            # Cache client infos (nickname, channelId) for this connection.
            $clientInfos = Get-JsonValue $conn "clientInfos"
            $ciFound = $false
            if ($clientInfos) {
                foreach ($ci in $clientInfos) {
                    $n  = Sanitize-Name (Get-JsonValue $ci "properties.nickname")
                    $connData.clientInfos[$ci.id] = @{channelId=$ci.channelId; nickname=$n}
                    if ($ci.id -eq $selfId) { $ciFound = $true }
                }
            }

            # Cache channel name -> id mappings.
            $channelInfos = Get-JsonValue $conn "channelInfos"
            if ($channelInfos) {
                $allChannels = @()
                $roots = Get-JsonValue $channelInfos "rootChannels"
                if ($roots) { $allChannels += $roots }
                $subs = Get-JsonValue $channelInfos "subChannels"
                if ($subs) {
                    foreach ($key in $subs.PSObject.Properties.Name) {
                        $allChannels += $subs.$key
                    }
                }
                foreach ($ch in $allChannels) {
                    $chName = Get-JsonValue $ch "properties.name"
                    if ($chName) { $chName = Sanitize-Name $chName } else { $chName = "Channel $($ch.id)" }
                    $connData.channelInfos[$ch.id] = $chName
                }
            }

            # If the auth response didn't include a nickname in clientInfos, try
            # the connection-level properties.
            if ($ciFound -and -not ($connData.clientInfos[$selfId].nickname -and $connData.clientInfos[$selfId].nickname -ne '?')) {
                $connNick = Get-JsonValue $conn "properties.nickname"
                if ($connNick) { $connData.clientInfos[$selfId].nickname = Sanitize-Name $connNick }
            }

            $script:connectionsCache[$cid] = $connData
            if ($connData.inputHardware -eq $false) {
                $activeCandidate = $cid
            }
        }

        # If no connection had inputHardware=false, pick the first one.
        if ($activeCandidate -eq 0 -and $script:connectionsCache.Count -gt 0) {
            $activeCandidate = ($script:connectionsCache.Keys | Sort-Object)[0]
            Write-Log "Auth default: picking conn $activeCandidate"
        }

        if ($activeCandidate -gt 0) {
            $script:activeConnectionId = $activeCandidate
            Copy-ActiveFromCache
        }

        # Reconnect scenario: if authDone is already true and we have no clients,
        # request a skin refresh so the Lua side re-reads fresh data.
        if ($script:authDone -and $script:channelClients.Count -eq 0) {
            $script:activeConnectionId = 0
            try { "REFRESH|0`n"| Out-File $dataFile -Encoding utf8NoBOM } catch { }
            return
        }

        Write-Log "Auth OK — conn=$($script:activeConnectionId) channel=''$script:channelName'' users=$($script:channelClients.Count)"
        Write-DataFile
        $script:authDone = $true
        return
    }

    # auth response with no connections.
    if (-not $script:authDone) {
        Write-Log "Auth OK — no connections"
        $script:authDone = $true
        $script:activeConnectionId = 0
        Write-DataFile
    } elseif ($script:channelName -eq '') {
        Write-Log "Auth OK (reconnect) — no connections, requesting refresh"
        $script:activeConnectionId = 0
        try { "REFRESH|0`n"| Out-File $dataFile -Encoding utf8NoBOM } catch { }
    }
}


function Handle-TalkStatus {
    param($data)
    $cid    = Get-JsonValue $data "payload.clientId"
    $status = Get-JsonValue $data "payload.status"
    $connId = Get-JsonValue $data "payload.connectionId"

    # Self-talk on a non-active connection triggers a switch.
    # This is a reliable indicator that the user is now active on that server.
    if ($status -eq 1 -and $connId -ne $script:activeConnectionId) {
        if ($script:connectionsCache.ContainsKey($connId) -and $script:connectionsCache[$connId].clientId -eq $cid) {
            Write-Log "Self talk on conn $connId — switching"
            Switch-ActiveConnection $connId
            $script:lastTalkConn = $connId
        }
    }

    # Forward talk status for display on the active channel.
    if ($cid -and $connId -eq $script:activeConnectionId -and $script:channelClients.ContainsKey($cid)) {
        $script:channelClients[$cid].t = $status
        Write-DataFile
    }
}


function Handle-ClientMoved {
    param($data)
    $p = $data.payload
    $cid = $p.clientId; $connId = $p.connectionId
    $newChan = $p.newChannelId; $oldChan = $p.oldChannelId

    # Try multiple paths for the nickname — some events omit properties.nickname
    $nick = Get-JsonValue $p "properties.nickname"
    if (-not $nick) { $nick = Get-JsonValue $p "nickname" }
    if (-not $nick) { $nick = Get-JsonValue $p "name" }
    $nick = Sanitize-Name $nick

    # Update the per-connection cache regardless of active connection.
    if ($script:connectionsCache.ContainsKey($connId)) {
        $connData = $script:connectionsCache[$connId]
        if (-not $connData.clientInfos.ContainsKey($cid)) {
            $connData.clientInfos[$cid] = @{channelId=$newChan; nickname=$nick; inputMuted=$null}
        } else {
            $connData.clientInfos[$cid].channelId = $newChan
            if ($nick -and $nick -ne '?') { $connData.clientInfos[$cid].nickname = $nick }
            if ($nick -eq '?' -and $connData.clientInfos[$cid].nickname -and $connData.clientInfos[$cid].nickname -ne '?') {
                $nick = $connData.clientInfos[$cid].nickname
            }
        }
    }

    # Ignore events from non-active connections for display purposes.
    if ($connId -ne $script:activeConnectionId) { return }

    # Self-moved: we switched channels or disconnected.
    if ($cid -eq $script:myClientId) {
        $script:myChannelId = $newChan
        if (-not $script:cachedClientInfos.ContainsKey($cid)) {
            $script:cachedClientInfos[$cid] = @{channelId=$newChan; nickname=$script:myNickname}
        } else {
            $script:cachedClientInfos[$cid].channelId = $newChan
        }
        if ($newChan -gt 0) {
            $script:channelClients.Clear()
            if ($script:cachedChannelInfos.ContainsKey($newChan)) {
                $script:channelName = $script:cachedChannelInfos[$newChan]
            }
            foreach ($entry in $script:cachedClientInfos.GetEnumerator()) {
                if ($entry.Value.channelId -eq $newChan) {
                    $script:channelClients[$entry.Key] = @{n=$entry.Value.nickname; t=0; im=0; om=0}
                }
            }
            if (-not $script:channelClients.ContainsKey($cid)) {
                $n = if ($script:myNickname -and $script:myNickname -ne '?') { $script:myNickname } else { $nick }
                $script:channelClients[$cid] = @{n=$n; t=0; im=0; om=0}
            }
            Write-Log "Moved to $script:channelName ($newChan) — $($script:channelClients.Count) users"
            Write-DataFile
        } else {
            Write-Log "Disconnected from server"
            $script:channelName = ""
            $script:channelClients.Clear()
            $script:selfDisconnected = $true
            Write-DisconnectedState
        }
        return
    }

    # Someone left the server (newChan=0) or left our channel.
    if ($newChan -eq 0 -or ($oldChan -eq $script:myChannelId -and $script:myChannelId -gt 0)) {
        if ($script:channelClients.ContainsKey($cid)) {
            $gone = $script:channelClients[$cid].n
            $script:channelClients.Remove($cid)
        }
        if ($script:cachedClientInfos.ContainsKey($cid)) {
            $script:cachedClientInfos[$cid].channelId = $newChan
        }
        if ($oldChan -eq $script:myChannelId -and $script:myChannelId -gt 0) {
            Write-Log "  - $gone"
            Write-DataFile
        }
        return
    }

    # Someone joined our channel.
    if ($newChan -eq $script:myChannelId -and -not $script:channelClients.ContainsKey($cid)) {
        if ($nick -eq '?' -and $script:cachedClientInfos.ContainsKey($cid)) {
            $nick = $script:cachedClientInfos[$cid].nickname
        }
        $script:channelClients[$cid] = @{n=$nick; t=0; im=0; om=0}
        if ($script:cachedClientInfos.ContainsKey($cid)) {
            $script:cachedClientInfos[$cid].channelId = $newChan
            $script:cachedClientInfos[$cid].nickname  = $nick
        } else {
            $script:cachedClientInfos[$cid] = @{channelId=$newChan; nickname=$nick}
        }
        Write-Log "  + $nick"
        Write-DataFile
    }
}


function Handle-ConnectStatus {
    param($data)
    $status = Get-JsonValue $data "payload.status"
    $connId  = Get-JsonValue $data "payload.connectionId"

    # Status 4 = fully connected; status 0 = disconnected.
    if ($status -eq 4 -and $connId -gt 0) {
        $oldConnId = $script:activeConnectionId
        $clientId = Get-JsonValue $data "payload.info.clientId"

        if (-not $script:connectionsCache.ContainsKey($connId)) {
            $script:connectionsCache[$connId] = @{
                clientId      = $clientId
                inputHardware = $null
                inputMuted    = $null
                clientInfos   = @{}
                channelInfos  = @{}
            }
        } elseif ($clientId) {
            $script:connectionsCache[$connId].clientId = $clientId
        }

        if ($script:authDone) {
            if ($oldConnId -eq 0) {
                # First server connection after auth -> refresh for client infos.
                $script:activeConnectionId = $connId
                $script:myClientId = $clientId
                try { "REFRESH|0`n"| Out-File $dataFile -Encoding utf8NoBOM } catch { }
            } elseif ($script:selfDisconnected) {
                try { "REFRESH|0`n"| Out-File $dataFile -Encoding utf8NoBOM } catch { }
                $script:selfDisconnected = $false
            } elseif ($connId -ne $oldConnId) {
                # A secondary connection came online. Switch if we have cached data.
                if ($script:connectionsCache.ContainsKey($connId) -and $script:connectionsCache[$connId].channelInfos.Count -gt 0) {
                    Switch-ActiveConnection $connId
                }
            }
        }
    } elseif ($status -eq 0 -and $connId -eq $script:activeConnectionId) {
        Write-DisconnectedState
    }
}


function Handle-SelfPropUpdate {
    param($data)
    $cid    = Get-JsonValue $data "payload.clientId"
    $connId = Get-JsonValue $data "payload.connectionId"
    $props  = Get-JsonValue $data "payload.properties"
    if (-not $props -or -not $connId) { return }

    # Nickname update.
    $nick = Get-JsonValue $props "nickname"
    if (-not $nick) { $nick = Get-JsonValue $props "nick_name" }
    if ($nick) {
        $sanitized = Sanitize-Name $nick
        if ($script:cachedClientInfos.ContainsKey($cid)) {
            $script:cachedClientInfos[$cid].nickname = $sanitized
        }
        if ($cid -eq $script:myClientId) {
            $script:myNickname = $sanitized
        }
        if ($connId -eq $script:activeConnectionId -and $script:channelClients.ContainsKey($cid)) {
            $script:channelClients[$cid].n = $sanitized
            Write-DataFile
        }
    }

    # inputHardware=true/false tells us whether this connection has the mic.
    # false = active (the server where the user is currently talking).
    $active = Get-JsonValue $props "inputHardware"
    if ($null -eq $active) { $active = Get-JsonValue $props "input_hardware" }
    if ($null -ne $active) {
        if ($script:connectionsCache.ContainsKey($connId)) {
            $script:connectionsCache[$connId].inputHardware = $active
            if ($script:connectionsCache[$connId].clientInfos.ContainsKey($cid)) {
                $script:connectionsCache[$connId].clientInfos[$cid].inputHardware = $active
            }
        }
        if ($active -eq $false -and $connId -ne $script:activeConnectionId) {
            Write-Log "Active on conn $connId (inputHardware=false via SelfProp) — switching"
            Switch-ActiveConnection $connId
        } elseif ($active -eq $true -and $connId -eq $script:activeConnectionId) {
            # The current connection lost the mic. Find another active connection.
            $found = 0
            foreach ($entry in $script:connectionsCache.GetEnumerator()) {
                if ($entry.Key -ne $script:activeConnectionId -and $entry.Value.inputHardware -eq $false) {
                    $found = $entry.Key; break
                }
            }
            if ($found -gt 0) {
                Write-Log "Lost active on $connId — switching to conn $found"
                Switch-ActiveConnection $found
            }
        }
    }

    # Mute status for self.
    $mute = Get-PropsMuteStatus $props
    if ($connId -eq $script:activeConnectionId -and $script:channelClients.ContainsKey($cid)) {
        if ($null -ne $mute.im) { $script:channelClients[$cid].im = $mute.im; Write-DataFile }
        if ($null -ne $mute.om) { $script:channelClients[$cid].om = $mute.om; Write-DataFile }
    }
}


function Handle-ClientProps {
    param($data)
    $cid    = Get-JsonValue $data "payload.clientId"
    $connId = Get-JsonValue $data "payload.connectionId"
    $props  = Get-JsonValue $data "payload.properties"
    if (-not $props) { return }

    # Update the per-connection cache.
    if ($script:connectionsCache.ContainsKey($connId)) {
        $connData = $script:connectionsCache[$connId]
        if (-not $connData.clientInfos.ContainsKey($cid)) {
            $nick = Get-JsonValue $props "nickname"
            $connData.clientInfos[$cid] = @{channelId=0; nickname=$(if($nick){Sanitize-Name $nick}else{'?'}); inputMuted=$null; outputMuted=$null}
        }
        $nick = Get-JsonValue $props "nickname"
        if ($nick) { $connData.clientInfos[$cid].nickname = Sanitize-Name $nick }

        $mute = Get-PropsMuteStatus $props
        if ($null -ne $mute.im) { $connData.clientInfos[$cid].inputMuted = $mute.im }
        if ($null -ne $mute.om) { $connData.clientInfos[$cid].outputMuted = $mute.om }

        $active = Get-JsonValue $props "inputHardware"
        if ($null -eq $active) { $active = Get-JsonValue $props "input_hardware" }
        if ($null -ne $active) {
            $connData.inputHardware = $active
            Sync-ActiveConnection
        }
    }

    # Update the display state if this client is on the active connection.
    if ($connId -ne $script:activeConnectionId) { return }

    # Mute-only props: handle and return early.
    if ($script:channelClients.ContainsKey($cid)) {
        $mute = Get-PropsMuteStatus $props
        $changed = $false
        if ($null -ne $mute.im) { $script:channelClients[$cid].im = $mute.im; $changed = $true }
        if ($null -ne $mute.om) { $script:channelClients[$cid].om = $mute.om; $changed = $true }
        $nick = Get-JsonValue $props "nickname"
        if ($changed -and -not $nick) { Write-DataFile; return }
    }

    $nick = Get-JsonValue $props "nickname"
    if (-not $nick) { return }
    $sanitized = Sanitize-Name $nick
    if ($script:channelClients.ContainsKey($cid)) {
        $script:channelClients[$cid].n = $sanitized
    } elseif ($sanitized -and $sanitized -ne '?') {
        $script:channelClients[$cid] = @{n=$sanitized; t=0; im=0; om=0}
    }
    if ($script:cachedClientInfos.ContainsKey($cid)) { $script:cachedClientInfos[$cid].nickname = $sanitized }
    if ($cid -eq $script:myClientId) { $script:myNickname = $sanitized }
    Write-DataFile
}


# ==================== Main loop ====================

$script:apiKey = Read-Key

Write-Log "=== rainyTS Client ==="
Write-Log "Target: ws://${HostAddr}:${Port}"

$reconnectDelay = 5
while ($true) {
    if (-not (Connect-WS)) {
        Start-Sleep -Seconds $reconnectDelay
        continue
    }
    # Build and send the auth payload.
    $auth = @{
        type="auth"
        payload=@{
            identifier=$appId
            version="1.0"
            name=$appName
            description=$appDesc
            content=@{apiKey=$script:apiKey}
        }
    } | ConvertTo-Json -Compress

    if (-not (Send-WS $auth)) { Write-Log "Auth send failed"; Disconnect-WS; continue }
    Write-Log "Auth sent — check TS6 notifications for permission request"
    Write-Log "Listening..."

    while ($script:ws -and $script:ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $msg = Read-WS-Msg
        if (-not $msg) { Write-Log "Disconnected"; break }

        try {
            $data = $msg | ConvertFrom-Json
            switch ($data.type) {
                "auth"                      { Handle-AuthMsg $data }
                "talkStatusChanged"         { Handle-TalkStatus $data }
                "clientMoved"               { Handle-ClientMoved $data }
                "connectStatusChanged"      { Handle-ConnectStatus $data }
                "clientPropertiesUpdated"   { Handle-ClientProps $data }
                "clientSelfPropertyUpdated" { Handle-SelfPropUpdate $data }
                "channels"                  {
                    # Channel list changed. Reconnect in-place so we get fresh
                    # auth data with updated connection info.
                    if ($script:authDone) {
                        $script:pendingRefresh = $true
                    }
                }
                "log" {
                    $logMsg = Get-JsonValue $data "payload.message"
                    if (-not $logMsg) { $logMsg = Get-JsonValue $data "message" }
                    if (-not $logMsg) { $logMsg = Get-JsonValue $data "payload.text" }
                    if (-not $logMsg) {
                        $logMsg = $data | ConvertTo-Json -Compress
                        if ($logMsg.Length -gt 200) { $logMsg = $logMsg.Substring(0, 200) + "..." }
                    }
                    Write-Log "LOG: $logMsg"
                }
                default { }
            }
            if ($script:pendingRefresh) { break }
        } catch { }
    }

    # pendingRefresh means we need to reconnect to get fresh auth data for
    # a newly-added connection. We disconnect without writing state so the
    # old data stays visible in the overlay during the brief reconnect.
    if ($script:pendingRefresh) {
        Disconnect-WS -DontWriteState
        continue
    }

    Disconnect-WS
    Start-Sleep -Seconds $reconnectDelay
}
