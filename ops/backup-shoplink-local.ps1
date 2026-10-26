# Local logical backup only. NEVER runs migrations or resets credentials.
[CmdletBinding()]
param(
  [string]$PgBin = "$env:USERPROFILE\Desktop\postgresql-17.11-5-windows-x64-binaries\pgsql\bin",
  [string]$Destination = "$env:USERPROFILE\Documents\ShopLinkBackup",
  [string]$SslRootCert = 'system'
)
$ErrorActionPreference = 'Stop'
# PS 7.3+: inspect native exit codes ourselves so all failures get cleanup.
$PSNativeCommandUseErrorActionPreference = $false
$pgDump = Join-Path $PgBin 'pg_dump.exe'
$pgRestore = Join-Path $PgBin 'pg_restore.exe'
foreach ($tool in @($pgDump,$pgRestore)) {
  if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
    throw 'PostgreSQL 17 pg_dump.exe and pg_restore.exe are required. Check -PgBin.'
  }
  $version = & $tool --version
  if ($LASTEXITCODE -ne 0 -or $version -notmatch 'PostgreSQL\)\s+17\.') {
    throw 'Both backup tools must be PostgreSQL 17. No connection was attempted.'
  }
}
if ($SslRootCert -ne 'system' -and -not (Test-Path -LiteralPath $SslRootCert -PathType Leaf)) {
  throw 'TLS root certificate missing. Supply a trusted CA file with -SslRootCert. Do not disable TLS verification.'
}
$Destination = [IO.Path]::GetFullPath($Destination)
$ancestor = $Destination
while ($ancestor) {
  if (Test-Path -LiteralPath (Join-Path $ancestor '.git')) {
    throw 'Backup destination is inside a Git checkout. Choose a private directory outside the repository.'
  }
  $parent = Split-Path -Parent $ancestor
  if ($parent -eq $ancestor) { break }
  $ancestor = $parent
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$target = Join-Path $Destination ('ShopLinkMaroc_{0}_{1}.dump' -f (Get-Date -Format 'yyyyMMdd_HHmmss'),[Guid]::NewGuid().ToString('N'))
$partial = "$target.partial"
$oldSslMode = $env:PGSSLMODE
$oldSslRoot = $env:PGSSLROOTCERT
$oldTimeout = $env:PGCONNECT_TIMEOUT
try {
  $env:PGSSLMODE = 'verify-full'
  $env:PGSSLROOTCERT = $SslRootCert
  $env:PGCONNECT_TIMEOUT = '15'
  Write-Host 'Password: enter it only in the hidden PostgreSQL prompt. Never paste it into chat.'
  Write-Host 'One attempt only. On authentication failure, STOP and check the project Session Pooler settings; do not reset passwords.'
  $arguments = @('--host','aws-1-eu-west-1.pooler.supabase.com','--port','5432',
    '--username','postgres.lcxwsowyqzbhmlpxijsu','--dbname','postgres','--format=custom',
    '--no-owner','--no-acl','--password','--file',$partial)
  & $pgDump @arguments
  if ($LASTEXITCODE -ne 0) {
    throw 'pg_dump failed. No validated backup exists. Check authentication, network and CA trust locally; no automatic retry was made.'
  }
  if (-not (Test-Path -LiteralPath $partial -PathType Leaf) -or (Get-Item -LiteralPath $partial).Length -lt 1024) {
    throw 'Archive missing or unexpectedly small. No validated backup was created.'
  }
  & $pgRestore --list $partial | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Archive catalog cannot be read. No validated backup was created.' }
  $hash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
  Move-Item -LiteralPath $partial -Destination $target # unique name, no overwrite
  Write-Host ("ARCHIVE CREATED (catalog readable, restoration NOT tested): {0}" -f $target)
  Write-Host ("SIZE: {0} bytes" -f (Get-Item -LiteralPath $target).Length)
  Write-Host ("SHA256: {0}" -f $hash)
  Write-Warning 'Private, unencrypted logical archive. Protect/encrypt it locally. Never upload to GitHub.'
  Write-Warning 'No full Supabase recovery is validated: isolated restore, roles, secrets and storage objects are separate requirements.'
} finally {
  # Any failure (including size/catalog/hash) removes this invocation\'s partial file.
  try {
    if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
  } finally {
    $env:PGSSLMODE = $oldSslMode
    $env:PGSSLROOTCERT = $oldSslRoot
    $env:PGCONNECT_TIMEOUT = $oldTimeout
  }
}
