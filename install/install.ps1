# Kannaka one-shot installer (Windows). Detect-and-install: brings up Node +
# Claude Code if missing, then the kannaka binary, plugin, and live statusline.
# Idempotent — safe to re-run. The .msi wraps this; you can also run it directly.
[CmdletBinding()]
param(
  [string]$ReleaseRepo = "NickFlach/kannaka-memory",
  [switch]$SkipStatusline
)
$ErrorActionPreference = "Stop"
function Say($m) { Write-Host "▸ $m" -ForegroundColor Cyan }
function Have($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

Say "Kannaka installer"

# 1. Node.js
if (-not (Have node)) {
  Say "Node.js not found — installing via winget…"
  if (Have winget) {
    winget install -e --id OpenJS.NodeJS.LTS --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [Environment]::GetEnvironmentVariable("Path","User")
  } else {
    throw "Node.js is required. Install it from https://nodejs.org/ and re-run."
  }
}

# 2. Claude Code
if (-not (Have claude)) {
  Say "Installing Claude Code (npm -g)…"
  npm install -g @anthropic-ai/claude-code
}

# 3. kannaka binary → ~/.local/bin
$dest = Join-Path $HOME ".local\bin"
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$asset = "kannaka-windows-x86_64.exe"
$base  = "https://github.com/$ReleaseRepo/releases/latest/download"
$exe   = Join-Path $dest "kannaka.exe"
Say "Downloading kannaka binary…"
Invoke-WebRequest -Uri "$base/$asset" -OutFile $exe -UseBasicParsing
try {
  $want = (((Invoke-WebRequest -Uri "$base/$asset.sha256" -UseBasicParsing).Content) -split '\s+')[0]
  $got  = (Get-FileHash $exe -Algorithm SHA256).Hash
  if ($want -and ($want.ToLower() -ne $got.ToLower())) { throw "kannaka.exe sha256 mismatch" }
  Say "sha256 verified"
} catch { Say "sha256 check skipped ($_)" }

# 4. Plugin marketplace + install (idempotent)
Say "Registering marketplace + installing plugin…"
claude plugin marketplace add NickFlach/kannaka-plugin 2>$null | Out-Null
claude plugin install kannaka@kannaka 2>$null | Out-Null

# 5. Enable the live statusline (runs the plugin's bash setup via git-bash)
if (-not $SkipStatusline) {
  $setup = Get-ChildItem -Path (Join-Path $HOME ".claude\plugins\cache\kannaka") -Recurse -Filter setup.sh -ErrorAction SilentlyContinue |
           Sort-Object FullName | Select-Object -Last 1
  if ($setup -and (Have bash)) {
    Say "Enabling statusline…"
    bash ($setup.FullName -replace '\\','/') on
  } else {
    Say "Statusline: run '/kannaka statusline on' inside Claude Code to enable."
  }
}

Write-Host ""
Say "Kannaka installed. Restart Claude Code (or open a new session) to see the statusline + swarm/memory tools."
