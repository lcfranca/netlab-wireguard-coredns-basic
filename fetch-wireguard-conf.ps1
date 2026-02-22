param(
  [Parameter(Mandatory = $true)]
  [string]$ServerSsh,

  [Parameter(Mandatory = $false)]
  [string]$ClientName,

  [Parameter(Mandatory = $false)]
  [string]$Interface = "wg0",

  [Parameter(Mandatory = $false)]
  [string]$RemoteDir = "/opt/netlab/wg-clients"
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

Write-Host "Downloading profile '$ClientName' from $ServerSsh ..." -ForegroundColor Cyan

$scpArgs = @(
  "-o", "BatchMode=yes",
  "-o", "StrictHostKeyChecking=accept-new",
  "-o", "ConnectTimeout=10",
  $remoteFile,
  $outputFile
)

& $scpCmd @scpArgs
if ($LASTEXITCODE -ne 0) {
  throw "Failed to download profile. Check SSH key access for '$ServerSsh' and profile name '$ClientName'."
}

Write-Host "Saved: $outputFile" -ForegroundColor Green
Write-Host "Next: open WireGuard for Windows -> Import tunnel(s) from file -> select $outputFile" -ForegroundColor Yellow
