# Network Quality Monitor
# Pings gateway and external targets every second using ping.exe.
# Logs latency, packet loss, NIC errors, and NIC link state changes.
# Usage: powershell -ExecutionPolicy Bypass -File network_monitor.ps1
# Stop:  Ctrl+C

param(
    [int]$IntervalMs = 1000,
    [int]$SpikeThresholdMs = 50,
    [string]$LogDir = "$env:USERPROFILE\Desktop\udp_logs"
)

if (!(Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

$netLog = Join-Path $LogDir "network_quality.csv"

if (!(Test-Path $netLog)) {
    "Timestamp,GatewayMs,GoogleMs,CloudflareMs,GatewayLoss,ExternalLoss,NicErrors,NicDiscards,LinkSpeed" |
        Out-File $netLog -Encoding UTF8
}

$gateway = "192.168.130.254"
$external1 = "8.8.8.8"
$external2 = "1.1.1.1"

# Resolve NIC name dynamically to avoid encoding issues
$nic = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -like 'Realtek*' } | Select-Object -First 1
$nicName = $nic.Name

# Helper: single ping using .NET Ping class, returns latency in ms or -1 for timeout
$pinger = New-Object System.Net.NetworkInformation.Ping
function Get-PingMs {
    param([string]$Target)
    try {
        $reply = $pinger.Send($Target, 1000)
        if ($reply.Status -eq 'Success') {
            return [int]$reply.RoundtripTime
        } else {
            return -1
        }
    } catch {
        return -1
    }
}

# Track NIC error/discard baseline
$nicStats = Get-NetAdapterStatistics -Name $nicName -ErrorAction SilentlyContinue
$baseErrors = $nicStats.ReceivedPacketErrors
$baseDiscards = $nicStats.ReceivedDiscardedPackets
$lastLinkSpeed = (Get-NetAdapter -Name $nicName).LinkSpeed

Write-Host "=== Network Quality Monitor ===" -ForegroundColor Cyan
Write-Host "NIC:       $nicName ($($nic.InterfaceDescription))"
Write-Host "LinkSpeed: $lastLinkSpeed"
Write-Host "Gateway:   $gateway"
Write-Host "External:  $external1, $external2"
Write-Host "Interval:  ${IntervalMs}ms"
Write-Host "Spike:     >${SpikeThresholdMs}ms"
Write-Host "Log:       $netLog"
Write-Host "Press Ctrl+C to stop.`n"

$gatewayLossCount = 0
$externalLossCount = 0
$totalCount = 0
$consecutiveLoss = 0

while ($true) {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $totalCount++

    # Ping all targets using ping.exe
    $gwMs = Get-PingMs $gateway
    $ext1Ms = Get-PingMs $external1
    $ext2Ms = Get-PingMs $external2

    $gwLoss = if ($gwMs -eq -1) { 1 } else { 0 }
    $extLoss = if ($ext1Ms -eq -1 -and $ext2Ms -eq -1) { 1 } else { 0 }

    $gatewayLossCount += $gwLoss
    $externalLossCount += $extLoss

    # Track consecutive gateway losses
    if ($gwLoss -eq 1) { $consecutiveLoss++ } else { $consecutiveLoss = 0 }

    # NIC error/discard delta
    $nicStats = Get-NetAdapterStatistics -Name $nicName -ErrorAction SilentlyContinue
    $errorDelta = $nicStats.ReceivedPacketErrors - $baseErrors
    $discardDelta = $nicStats.ReceivedDiscardedPackets - $baseDiscards

    # Check link speed change (renegotiation = cable/NIC issue)
    $currentLinkSpeed = (Get-NetAdapter -Name $nicName -ErrorAction SilentlyContinue).LinkSpeed
    $linkChanged = $currentLinkSpeed -ne $lastLinkSpeed

    # Determine display
    # Gateway-only loss is likely router ignoring ICMP (NEC Aterm known behavior),
    # so only flag as real LOSS when external targets also fail.
    $isSpike = ($gwMs -gt $SpikeThresholdMs) -or ($ext1Ms -gt $SpikeThresholdMs)
    $anyExtLoss = ($ext1Ms -eq -1) -or ($ext2Ms -eq -1)
    $gwOnlyLoss = ($gwLoss -eq 1) -and (-not $anyExtLoss)
    $realLoss = $anyExtLoss
    $bothLoss = ($gwLoss -eq 1) -and $anyExtLoss

    if ($linkChanged) {
        $color = "Magenta"
        $status = "LINK"
    } elseif ($bothLoss) {
        $color = "Red"
        $status = "LOSS"
    } elseif ($realLoss) {
        $color = "Red"
        $status = "EXT-LOSS"
    } elseif ($gwOnlyLoss) {
        $color = "DarkYellow"
        $status = "GW-SKIP"
    } elseif ($isSpike) {
        $color = "Yellow"
        $status = "SPIKE"
    } else {
        $color = "Green"
        $status = "OK"
    }

    $line = "[$timestamp] GW:${gwMs}ms  G:${ext1Ms}ms  CF:${ext2Ms}ms  Err:+$errorDelta Disc:+$discardDelta"
    if ($linkChanged) {
        $line += "  LINK:$lastLinkSpeed->$currentLinkSpeed"
    }
    Write-Host "$line  [$status]" -ForegroundColor $color

    # Log to CSV
    "$timestamp,$gwMs,$ext1Ms,$ext2Ms,$gwLoss,$extLoss,$errorDelta,$discardDelta,$currentLinkSpeed" |
        Out-File $netLog -Append -Encoding UTF8

    # On real incident, log detailed dump (ignore GW-only loss = router ICMP deprioritization)
    if ($realLoss -or $bothLoss -or $isSpike -or $linkChanged) {
        $dumpFile = Join-Path $LogDir "net_incident_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

        # Only write dump if file doesn't already exist (avoid spam within same second)
        if (!(Test-Path $dumpFile)) {
            $lines = @()
            $lines += "=== Network Incident ==="
            $lines += "Timestamp:        $timestamp"
            $lines += "Status:           $status"
            $lines += "Gateway:          ${gwMs}ms"
            $lines += "Google DNS:       ${ext1Ms}ms"
            $lines += "Cloudflare:       ${ext2Ms}ms"
            $lines += "NIC Errors:       +$errorDelta (total: $($nicStats.ReceivedPacketErrors))"
            $lines += "NIC Discards:     +$discardDelta (total: $($nicStats.ReceivedDiscardedPackets))"
            $lines += "Link Speed:       $currentLinkSpeed"
            $lines += "Consecutive Loss: $consecutiveLoss"
            $lines += "Total Loss:       GW=$gatewayLossCount  Ext=$externalLossCount / $totalCount"
            $lines += ""

            if ($linkChanged) {
                $lines += ">>> LINK SPEED CHANGED: $lastLinkSpeed -> $currentLinkSpeed"
                $lines += ">>> This indicates cable issue or NIC renegotiation!"
            }

            if ($gwLoss -eq 1 -and $errorDelta -gt 0) {
                $lines += ">>> DIAGNOSIS: Gateway lost + NIC errors increasing = NIC/DRIVER ISSUE"
            } elseif ($gwLoss -eq 1 -and $errorDelta -eq 0) {
                $lines += ">>> DIAGNOSIS: Gateway lost but no NIC errors = CABLE or ROUTER issue"
            } elseif ($gwLoss -eq 0 -and $extLoss -eq 1) {
                $lines += ">>> DIAGNOSIS: Gateway OK but external lost = ISP/ROUTER issue"
            } elseif ($isSpike -and $gwMs -gt $SpikeThresholdMs) {
                $lines += ">>> DIAGNOSIS: Gateway latency spike = LOCAL congestion or NIC issue"
            } elseif ($isSpike) {
                $lines += ">>> DIAGNOSIS: External latency spike (GW OK) = ISP/routing issue"
            }

            $lines += ""
            $lines += "=== NIC Statistics ==="
            $lines += ($nicStats | Format-List | Out-String)

            $lines | Out-File $dumpFile -Encoding UTF8
            Write-Host "  >> INCIDENT LOGGED: $dumpFile" -ForegroundColor Magenta
        }
    }

    if ($linkChanged) { $lastLinkSpeed = $currentLinkSpeed }

    Start-Sleep -Milliseconds $IntervalMs
}
