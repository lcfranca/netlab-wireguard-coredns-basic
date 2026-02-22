param(
  [Parameter(Mandatory = $true)]
  [string]$ServerSsh,

  [Parameter(Mandatory = $false)]
  [string]$ClientName,

  [Parameter(Mandatory = $false)]
  [string]$Interface = "wg0",

  [Parameter(Mandatory = $false)]
  [string]$RemoteDir = "/opt/netlab/wg-clients",

  [Parameter(Mandatory = $false)]
  [switch]$InteractiveSsh,

  [Parameter(Mandatory = $false)]
  [switch]$SkipTunnelActivation,

  [Parameter(Mandatory = $false)]
  [switch]$SkipHostsFallback
)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
  return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScpExe {
  $candidates = @(
    "$env:WINDIR\System32\OpenSSH\scp.exe",
    "$env:WINDIR\SysNative\OpenSSH\scp.exe"
  )

  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path $candidate)) {
      return $candidate
    }
  }

  $cmd = Get-Command scp.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    return $cmd.Source
  }

  return $null
}

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

  $cmd = Get-Command wireguard.exe -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    return $cmd.Source
  }

  return $null
}

function Invoke-WireGuardExe {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WireGuardExe,
    [Parameter(Mandatory = $true)]
    [string[]]$ArgumentList
  )

  if (Test-IsAdmin) {
    & $WireGuardExe @ArgumentList | Out-Null
    return $LASTEXITCODE
  }

  $proc = Start-Process -FilePath $WireGuardExe -ArgumentList $ArgumentList -Verb RunAs -PassThru -Wait
  return $proc.ExitCode
}

function Install-TunnelService {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WireGuardExe,
    [Parameter(Mandatory = $true)]
    [string]$ConfPath
  )

  return (Invoke-WireGuardExe -WireGuardExe $WireGuardExe -ArgumentList @('/installtunnelservice', $ConfPath))
}

function Reinstall-TunnelService {
  param(
    [Parameter(Mandatory = $true)]
    [string]$WireGuardExe,
    [Parameter(Mandatory = $true)]
    [string]$InterfaceName,
    [Parameter(Mandatory = $true)]
    [string]$ConfPath
  )

  Write-Host "Reinstalling tunnel service '$InterfaceName' ..." -ForegroundColor Yellow
  [void](Invoke-WireGuardExe -WireGuardExe $WireGuardExe -ArgumentList @('/uninstalltunnelservice', $InterfaceName))
  Start-Sleep -Seconds 1
  return (Install-TunnelService -WireGuardExe $WireGuardExe -ConfPath $ConfPath)
}

function Get-TunnelService {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InterfaceName
  )

  return (Get-Service -Name "WireGuardTunnel`$$InterfaceName" -ErrorAction SilentlyContinue)
}

function Ensure-TunnelServiceRunning {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InterfaceName
  )

  $service = Get-TunnelService -InterfaceName $InterfaceName
  if (-not $service) {
    return $false
  }

  if ($service.Status -ne 'Running') {
    try {
      Start-Service -Name $service.Name -ErrorAction Stop
    }
    catch {
      return $false
    }
  }

  return $true
}

function Get-ConfigValues {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ConfPath
  )

  $values = @{
    DnsServer = "10.0.0.1"
    AllowedIp = "10.0.0.0/24"
  }

  $inInterface = $false
  $inPeer = $false

  foreach ($lineRaw in Get-Content -Path $ConfPath) {
    $line = $lineRaw.Trim()
    if (-not $line) { continue }
    if ($line.StartsWith("#") -or $line.StartsWith(";")) { continue }

    if ($line -match '^\[Interface\]$') {
      $inInterface = $true
      $inPeer = $false
      continue
    }

    if ($line -match '^\[Peer\]$') {
      $inInterface = $false
      $inPeer = $true
      continue
    }

    if ($line -match '^\[') {
      $inInterface = $false
      $inPeer = $false
      continue
    }

    if ($inInterface -and $line -match '^DNS\s*=\s*(.+)$') {
      $firstDns = ($Matches[1].Split(',')[0]).Trim()
      if ($firstDns) {
        $values.DnsServer = $firstDns
      }
    }

    if ($inPeer -and $line -match '^AllowedIPs\s*=\s*(.+)$') {
      $candidate = ($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+\/\d+$' } | Select-Object -First 1)
      if ($candidate) {
        $values.AllowedIp = $candidate
      }
    }
  }

  return $values
}

function Get-RouteProbePrefix {
  param(
    [Parameter(Mandatory = $true)]
    [string]$AllowedIp,
    [Parameter(Mandatory = $true)]
    [string]$DnsServer
  )

  if ($AllowedIp -and $AllowedIp -ne "0.0.0.0/0") {
    return $AllowedIp
  }

  return "$DnsServer/32"
}

function Wait-TunnelReady {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InterfaceName,
    [Parameter(Mandatory = $true)]
    [string]$RouteProbePrefix,
    [int]$TimeoutSeconds = 25
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $service = Get-TunnelService -InterfaceName $InterfaceName
    if ($service -and $service.Status -eq 'Running') {
      $route = Get-NetRoute -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -eq $RouteProbePrefix -or ($RouteProbePrefix -like '*/24' -and $_.DestinationPrefix -like (($RouteProbePrefix -replace '/24$', '') + '*')) } |
        Select-Object -First 1
      if ($route) {
        return $true
      }
    }
    Start-Sleep -Seconds 1
  }

  return $false
}

function Set-WireGuardAdapterDns {
  param(
    [Parameter(Mandatory = $true)]
    [string]$InterfaceName,
    [Parameter(Mandatory = $true)]
    [string]$DnsServer
  )

  if (-not (Test-IsAdmin)) {
    return $false
  }

  $adapters = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object {
      $_.Status -eq 'Up' -and (
        $_.Name -ieq $InterfaceName -or
        $_.Name -like "*$InterfaceName*" -or
        $_.InterfaceDescription -like "*WireGuard*"
      )
    }

  if (-not $adapters) {
    return $false
  }

  foreach ($adapter in $adapters) {
    try {
      Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses @($DnsServer) -ErrorAction Stop
      return $true
    }
    catch {
      continue
    }
  }

  return $false
}

function Test-IntranetDns {
  param(
    [Parameter(Mandatory = $true)]
    [string]$HostName,
    [Parameter(Mandatory = $true)]
    [string]$DnsServer
  )

  try {
    Resolve-DnsName -Name $HostName -Server $DnsServer -DnsOnly -Type A -ErrorAction Stop | Out-Null
    return $true
  }
  catch {
    return $false
  }
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
    return $false
  }

  $content = Get-Content -Path $hostsPath -ErrorAction SilentlyContinue
  if ($content -match "(^|\s)$([regex]::Escape($HostName))(\s|$)") {
    return $true
  }

  try {
    Add-Content -Path $hostsPath -Value "`n$IpAddress`t$HostName"
    return $true
  }
  catch {
    return $false
  }
}

function Test-HttpReachability {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Uri,
    [hashtable]$Headers = @{}
  )

  try {
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $Headers -TimeoutSec 10 | Out-Null
    return $true
  }
  catch {
    return $false
  }
}

if ([string]::IsNullOrWhiteSpace($ClientName)) {
  $ClientName = Read-Host "WireGuard client profile name (example: demo-client)"
}

if ([string]::IsNullOrWhiteSpace($ClientName)) {
  throw "ClientName cannot be empty."
}

$scpCmd = Get-ScpExe
if (-not $scpCmd) {
  throw "scp.exe not found. Install OpenSSH Client: Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
}

$outputDir = Join-Path $env:USERPROFILE ".config\netlab-wireguard"
New-Item -Path $outputDir -ItemType Directory -Force | Out-Null

$outputFile = Join-Path $outputDir ("{0}.conf" -f $Interface)
$remoteFile = "{0}:{1}/{2}.conf" -f $ServerSsh, $RemoteDir.TrimEnd('/'), $ClientName

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
    if ($LASTEXITCODE -ne 0) {
      throw "Failed to download profile. Check SSH credentials for '$ServerSsh' and profile name '$ClientName'."
    }
  }
  else {
    throw "Failed to download profile. Check SSH credentials for '$ServerSsh' and profile name '$ClientName'."
  }
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

$configValues = Get-ConfigValues -ConfPath $outputFile
$dnsServer = $configValues.DnsServer
$routeProbePrefix = Get-RouteProbePrefix -AllowedIp $configValues.AllowedIp -DnsServer $dnsServer
$intranetHost = "service1.intranet.local"

Write-Host "Activating WireGuard tunnel from $outputFile ..." -ForegroundColor Cyan
$installExitCode = Install-TunnelService -WireGuardExe $wireGuardExe -ConfPath $outputFile
if ($installExitCode -ne 0) {
  Write-Host "WireGuard returned exit code $installExitCode. Checking existing tunnel service..." -ForegroundColor Yellow
  if (-not (Ensure-TunnelServiceRunning -InterfaceName $Interface)) {
    throw "WireGuard tunnel activation failed (exit code $installExitCode). Tunnel '$Interface' could not be started."
  }
  Write-Host "Existing tunnel '$Interface' is active." -ForegroundColor Green
}

Write-Host "Waiting for tunnel routes to become available..." -ForegroundColor Cyan
$tunnelReady = Wait-TunnelReady -InterfaceName $Interface -RouteProbePrefix $routeProbePrefix -TimeoutSeconds 25
if (-not $tunnelReady) {
  Write-Host "Route verification failed after activation. Reinstalling tunnel service..." -ForegroundColor Yellow
  $reinstallExitCode = Reinstall-TunnelService -WireGuardExe $wireGuardExe -InterfaceName $Interface -ConfPath $outputFile
  if ($reinstallExitCode -ne 0 -and -not (Ensure-TunnelServiceRunning -InterfaceName $Interface)) {
    throw "WireGuard tunnel reinstall failed (exit code $reinstallExitCode)."
  }

  $tunnelReady = Wait-TunnelReady -InterfaceName $Interface -RouteProbePrefix $routeProbePrefix -TimeoutSeconds 25
  if (-not $tunnelReady) {
    Write-Host "Tunnel service is present but route '$routeProbePrefix' was not observed." -ForegroundColor Red
    Write-Host "Run diagnostics:" -ForegroundColor Yellow
    Write-Host "  Get-NetRoute | Where-Object DestinationPrefix -like '10.*'" -ForegroundColor Gray
    Write-Host "  Get-Service -Name 'WireGuardTunnel`$$Interface'" -ForegroundColor Gray
    exit 1
  }
}

$dnsApplied = Set-WireGuardAdapterDns -InterfaceName $Interface -DnsServer $dnsServer
if ($dnsApplied) {
  Write-Host "Applied DNS server $dnsServer to WireGuard adapter." -ForegroundColor Green
}
else {
  Write-Host "Could not apply adapter DNS automatically. Run as Administrator for full DNS/hosts fallback support." -ForegroundColor Yellow
}

Start-Sleep -Seconds 2
$dnsOk = $false
for ($i = 0; $i -lt 3; $i++) {
  if (Test-IntranetDns -HostName $intranetHost -DnsServer $dnsServer) {
    $dnsOk = $true
    break
  }
  Start-Sleep -Seconds 2
}

if (-not $dnsOk -and -not $SkipHostsFallback) {
  Write-Host "DNS resolution not ready. Applying hosts fallback for $intranetHost ..." -ForegroundColor Yellow
  $hostsOk = Ensure-HostsEntry -HostName $intranetHost -IpAddress $dnsServer
  if ($hostsOk) {
    ipconfig /flushdns | Out-Null
    Write-Host "Hosts fallback applied." -ForegroundColor Green
  }
  else {
    Write-Host "Tunnel active, but DNS resolution failed." -ForegroundColor Yellow
    Write-Host "Run script as Administrator to update hosts file." -ForegroundColor Yellow
  }
}

$httpByName = Test-HttpReachability -Uri "http://$intranetHost"
$httpByIp = Test-HttpReachability -Uri "http://$dnsServer" -Headers @{ Host = $intranetHost }

if (-not $dnsOk) {
  Write-Host "DNS check failed: nslookup $intranetHost $dnsServer" -ForegroundColor Yellow
}

if ($httpByName -or $httpByIp) {
  Write-Host "WireGuard tunnel activated." -ForegroundColor Green
  Write-Host "Open: http://service1.intranet.local" -ForegroundColor Yellow
  exit 0
}

Write-Host "Tunnel is active, but HTTP test failed. Check server-side service, DNS on 10.0.0.1, and firewall." -ForegroundColor Yellow
Write-Host "Suggested diagnostics:" -ForegroundColor Yellow
Write-Host "  nslookup $intranetHost $dnsServer" -ForegroundColor Gray
Write-Host "  Test-NetConnection -ComputerName $dnsServer -Port 53" -ForegroundColor Gray
Write-Host "  Test-NetConnection -ComputerName $dnsServer -Port 80" -ForegroundColor Gray
Write-Host "  Get-NetRoute | Where-Object DestinationPrefix -like '10.*'" -ForegroundColor Gray
exit 1
