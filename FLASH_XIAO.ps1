param(
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$firmware = Join-Path $PSScriptRoot 'XIAO_ANCS_AppBridge\firmware\XIAO-Notify-nRF52840.uf2'
$source = Join-Path $PSScriptRoot 'XIAO_ANCS_AppBridge\XIAO_ANCS_AppBridge.ino'

if (-not (Test-Path -LiteralPath $firmware)) {
    throw "Firmware file not found: $firmware"
}

if ((Test-Path -LiteralPath $source) -and
    (Get-Item -LiteralPath $source).LastWriteTimeUtc -gt (Get-Item -LiteralPath $firmware).LastWriteTimeUtc) {
    throw 'Firmware is older than the source sketch. Rebuild XIAO-Notify-nRF52840.uf2 before flashing.'
}

function Get-Uf2Drive {
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady) { continue }
        $info = Join-Path $drive.RootDirectory.FullName 'INFO_UF2.TXT'
        if (Test-Path -LiteralPath $info) {
            return $drive.RootDirectory.FullName
        }
    }
    return $null
}

function Touch-SerialBootloader {
    $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    foreach ($portName in $ports) {
        try {
            $port = New-Object System.IO.Ports.SerialPort $portName, 1200, 'None', 8, 'one'
            $port.ReadTimeout = 250
            $port.WriteTimeout = 250
            $port.DtrEnable = $true
            $port.RtsEnable = $true
            $port.Open()
            Start-Sleep -Milliseconds 200
            $port.Close()
            Write-Host "Bootloader touch sent to $portName" -ForegroundColor Yellow
            return $true
        } catch {
            continue
        } finally {
            if ($port) {
                try { $port.Dispose() } catch {}
            }
        }
    }
    return $false
}

Write-Host 'XIAO Notify resilient firmware flasher' -ForegroundColor Cyan
Write-Host '1. Connect the XIAO by USB.'
Write-Host '2. Close Arduino IDE Serial Monitor and any program using the COM port.'

$target = Get-Uf2Drive
if (-not $target) {
    $ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
    if ($ports.Count -eq 0) {
        Write-Host 'Windows does not see any serial ports right now.' -ForegroundColor Yellow
    } else {
        Write-Host ("Visible serial ports: " + ($ports -join ', ')) -ForegroundColor DarkGray
    }
    Write-Host 'Trying automatic bootloader entry over USB serial...' -ForegroundColor Cyan
    $touched = Touch-SerialBootloader
    if (-not $touched) {
        Write-Host 'Could not toggle any serial port automatically.' -ForegroundColor Yellow
    }
}

if (-not $target) {
    Write-Host 'Double-press the tiny RST button next to USB-C to enter the UF2 bootloader.' -ForegroundColor Yellow
    Write-Host "Waiting up to $TimeoutSeconds seconds for the XIAO boot drive..."
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline -and -not $target) {
    $target = Get-Uf2Drive
    if (-not $target) {
        Write-Host '.' -NoNewline
        Start-Sleep -Milliseconds 500
    }
}
Write-Host ''

if (-not $target) {
    throw 'XIAO UF2 boot drive was not found. Windows is not enumerating the board for flashing right now.'
}

$destination = Join-Path $target 'XIAO-Notify-nRF52840.uf2'
Write-Host "Found bootloader drive: $target" -ForegroundColor Green
Copy-Item -LiteralPath $firmware -Destination $destination -Force
Write-Host 'Firmware copied. The drive may disappear while XIAO restarts; this is normal.' -ForegroundColor Green
Start-Sleep -Seconds 3
