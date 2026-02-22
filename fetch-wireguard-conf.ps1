param(
  [Parameter(Mandatory = $true)]
  [string]$ServerSsh,

  [Parameter(Mandatory = $false)]
  [string]$ClientName,

  [Parameter(Mandatory = $false)]
  [string]$Interface = "wg0",

  [Parameter(Mandatory = $false)]
  [string]$RemoteDir = "/opt/netlab/wg-clients"
,
  [Parameter(Mandatory = $false)]
  [switch]$InteractiveSsh
,
  [Parameter(Mandatory = $false)]
  [switch]$SkipTunnelActivation
,
  [Parameter(Mandatory = $false)]
  [switch]$SkipHostsFallback
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ClientName)) {
  $ClientName = Read-Host "WireGuard client profile name (example: demo-client)"
}

if ([string]::IsNullOrWhiteSpace($ClientName)) {
  throw "ClientName cannot be empty."
}

$scpCandidates = @(
  "$env:WINDIR\System32\OpenSSH\scp.exe",
  "$env:WINDIR\SysNative\OpenSSH\scp.exe"
)

$scpCmd = $null
foreach ($candidate in $scpCandidates) {
  if ($candidate -and (Test-Path $candidate)) {
    $scpCmd = $candidate
    break
  }
}

if (-not $scpCmd) {
  $scpInPath = Get-Command scp.exe -ErrorAction SilentlyContinue
  if ($scpInPath -and $scpInPath.Source) {
    $scpCmd = $scpInPath.Source
  }
}

if (-not $scpCmd) {
  throw "scp.exe not found. Install OpenSSH Client: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
}

$outputDir = Join-Path $env:USERPROFILE ".config\netlab-wireguard"
New-Item -Path $outputDir -ItemType Directory -Force | Out-Null

$outputFile = Join-Path $outputDir ("{0}.conf" -f $Interface)
$remoteFile = "{0}:{1}/{2}.conf" -f $ServerSsh, $RemoteDir.TrimEnd('/'), $ClientName

function Get-WireGuardExe {
  $candidates = @(
    "$env:ProgramFiles\WireGuard\wireguard.exe",
    "$env:ProgramW6432\WireGuard\wireguard.exe",
    "$env:LOCALAPPDATA\Programs\WireGuard\wireguard.exe"
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return $candidate
    }
  }

  $wgCmd = Get-Command wireguard.exe -ErrorAction SilentlyContinue
  if ($wgCmd -and $wgCmd.Source) {
    return $wgCmd.Source
  }

  return $null
}

function Install-TunnelService {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WireGuardExe,
    [Parameter(Mandatory = $true)]
    [string]$ConfPath
  )

  $argList = @('/installtunnelservice', $ConfPath)
  $admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

  if ($admin) {
    & $WireGuardExe @argList
    return $LASTEXITCODE
  }

  $proc = Start-Process -FilePath $WireGuardExe -ArgumentList $argList -Verb RunAs -PassThru -Wait
  return $proc.ExitCode
}

function Ensure-HostsEntry {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,
    [Parameter(Mandatory = $true)]
    [string]$IpAddress
  )

  $hostsPath = Join-Path $env:WINDIR "System32\drivers\etc\hosts"
  if (-not (Test-Path $hostsPath)) {
    return
  }

  $content = Get-Content -Path $hostsPath -ErrorAction SilentlyContinue
  if ($content -match "(^|\s)$([regex]::Escape($HostName))(\s|$)") {
    return
  }

  Add-Content -Path $hostsPath -Value "`n$IpAddress`t$HostName"
}

function Test-IntranetDns {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,
    [Parameter(Mandatory = $true)]
    [string]$DnsServer
  )

  try {
    Resolve-DnsName -Name $HostName -Server $DnsServer -DnsOnly -ErrorAction Stop | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

Write-Host "Downloading profile '$ClientName' from $ServerSsh ..." -ForegroundColor Cyan

$scpArgs = @(
  "-o", "StrictHostKeyChecking=accept-new",
  "-o", "ConnectTimeout=10"
)

if (-not $InteractiveSsh) {
  $scpArgs += @("-o", "BatchMode=yes")
}

$scpArgs += @($remoteFile, $outputFile)

& $scpCmd @scpArgs
if ($LASTEXITCODE -ne 0) {
  if (-not $InteractiveSsh) {
    Write-Host "Retrying with interactive SSH authentication..." -ForegroundColor Yellow
    $interactiveArgs = @(
      "-o", "StrictHostKeyChecking=accept-new",
      "-o", "ConnectTimeout=10",
      $remoteFile,
      $outputFile
    )
    & $scpCmd @interactiveArgs
    if ($LASTEXITCODE -eq 0) {
      Write-Host "Saved: $outputFile" -ForegroundColor Green
      Write-Host "Next: open WireGuard for Windows -> Import tunnel(s) from file -> select $outputFile" -ForegroundColor Yellow
      exit 0
    }
  }
  if (-not $InteractiveSsh) {
    throw "Failed to download profile. Check SSH key access for '$ServerSsh', profile name '$ClientName', or retry with -InteractiveSsh."
  }
  throw "Failed to download profile. Check SSH credentials for '$ServerSsh' and profile name '$ClientName'."
}

Write-Host "Saved: $outputFile" -ForegroundColor Green

if ($SkipTunnelActivation) {
  Write-Host "Next: open WireGuard for Windows -> Import tunnel(s) from file -> select $outputFile" -ForegroundColor Yellow
  exit 0
}

$wireGuardExe = Get-WireGuardExe
if (-not $wireGuardExe) {
  Write-Host "WireGuard for Windows not found. Install it from https://www.wireguard.com/install/ and import $outputFile" -ForegroundColor Yellow
  exit 0
}

Write-Host "Activating WireGuard tunnel from $outputFile ..." -ForegroundColor Cyan
$installExitCode = Install-TunnelService -WireGuardExe $wireGuardExe -ConfPath $outputFile
if ($installExitCode -ne 0) {
  throw "WireGuard tunnel activation failed (exit code $installExitCode)."
}

Start-Sleep -Seconds 2

$intranetHost = "service1.intranet.local"
$dnsServer = "10.0.0.1"
$dnsOk = Test-IntranetDns -HostName $intranetHost -DnsServer $dnsServer

if (-not $dnsOk -and -not $SkipHostsFallback) {
  Write-Host "DNS resolution not ready. Applying hosts fallback for $intranetHost ..." -ForegroundColor Yellow
  Ensure-HostsEntry -HostName $intranetHost -IpAddress $dnsServer
  ipconfig /flushdns | Out-Null
}

try {
  Invoke-WebRequest -UseBasicParsing -Uri "http://$intranetHost" -TimeoutSec 10 | Out-Null
}
catch {
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "http://$dnsServer" -Headers @{ Host = $intranetHost } -TimeoutSec 10 | Out-Null
  }
  catch {
    Write-Host "Tunnel is active, but HTTP test failed. Check server-side service and firewall." -ForegroundColor Yellow
  }
}

Write-Host "WireGuard tunnel activated." -ForegroundColor Green
Write-Host "Open: http://service1.intranet.local" -ForegroundColor Yellow
