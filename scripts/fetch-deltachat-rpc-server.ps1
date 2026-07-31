# Downloads a standalone deltachat-rpc-server binary for Windows
# from https://github.com/chatmail/core/releases and stores it under .deps/.
# URL is fully predictable from RPC_VERSION + asset name.
#
# Usage:
#   scripts\fetch-deltachat-rpc-server.ps1            # fetch if missing
#   scripts\fetch-deltachat-rpc-server.ps1 --print-path   # echo path
#
# Override via env: RPC_VERSION (default v2.57.0), RPC_REPO (default chatmail/core)

$ErrorActionPreference = 'Stop'

$RPC_VERSION = if ($env:RPC_VERSION) { $env:RPC_VERSION } else { 'v2.57.0' }
$RPC_REPO    = if ($env:RPC_REPO)    { $env:RPC_REPO }    else { 'chatmail/core' }

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$DepsDir    = Join-Path (Split-Path -Parent $ScriptDir) '.deps'
$Asset      = 'deltachat-rpc-server-win64.exe'
$OutPath    = Join-Path $DepsDir $Asset
$Url        = "https://github.com/$RPC_REPO/releases/download/$RPC_VERSION/$Asset"

if ($args -contains '--print-path') {
  if (-not (Test-Path $OutPath)) {
    Write-Error "Run 'make deps' first to download $Asset"
    exit 1
  }
  Write-Output $OutPath
  return
}

if (-not (Test-Path $OutPath)) {
  if (-not (Test-Path $DepsDir)) {
    New-Item -ItemType Directory -Force -Path $DepsDir | Out-Null
  }
  Write-Host "Fetching $Url ..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing
  } catch {
    Remove-Item -Force -ErrorAction SilentlyContinue $OutPath
    Write-Error "Failed to download $Asset from $Url"
  }
  $size = (Get-Item $OutPath).Length
  Write-Host "Saved to $OutPath ($size bytes)"
} else {
  Write-Host "$OutPath (cached)"
}
