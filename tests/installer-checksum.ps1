# Verifies install/install.ps1 FAILS CLOSED on a missing checksum (the
# hard-fail-on-missing-checksum fix) rather than installing an unverified
# binary. Dot-sources install.ps1 with a mocked Invoke-WebRequest under a temp
# HOME/TEMP; the missing-checksum throw happens BEFORE the PATH section, so no
# real environment is touched. Exits non-zero if it misbehaves.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installPs1 = Join-Path $here '..\install\install.ps1'
$fails = 0

function Test-MissingChecksum {
  # Isolate the temp download dir ($tmpExe lives under $env:TEMP). The
  # missing-checksum path throws BEFORE the binary is moved into ~/.local/bin,
  # so no install happens; we assert the throw + that the temp download is gone.
  $work = Join-Path ([System.IO.Path]::GetTempPath()) ("kq-inst-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Force -Path $work | Out-Null

  # Mock: serve the binary, but FAIL the .sha256 fetch (simulate a missing checksum).
  function Invoke-WebRequest {
    param([string]$Uri, [string]$OutFile, [switch]$UseBasicParsing)
    if ($Uri -match '\.sha256$') { throw "404 Not Found (simulated missing checksum)" }
    if ($OutFile) { Set-Content -Path $OutFile -Value 'BINARY-BYTES' -NoNewline }
  }

  $env:TEMP = $work
  $threw = $false; $msg = ''
  try { . $installPs1 -SkipStatusline } catch { $threw = $true; $msg = "$_" }

  $leftoverDownload = @(Get-ChildItem -Path $work -Filter 'kannaka-download-*.exe' -ErrorAction SilentlyContinue).Count
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

  if ($threw -and ($msg -match 'unverified|refusing') -and $leftoverDownload -eq 0) {
    Write-Host "ok   [missing-checksum-hard-fails]"
  } else {
    Write-Host "FAIL [missing-checksum-hard-fails]: threw=$threw leftover=$leftoverDownload msg=$msg"
    $script:fails++
  }
}

Test-MissingChecksum

if ($fails -ne 0) { Write-Error "installer-checksum.ps1: $fails failed"; exit 1 }
Write-Host "installer-checksum.ps1: all cases passed"
