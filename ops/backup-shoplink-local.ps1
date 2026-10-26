# ShopLink Maroc — local logical PostgreSQL backup; no passwords stored.
# Intended for trusted user's Windows PC only. No database writes.
# Storage objects, role globals, secrets, and restore test are separate tasks.
param(
  [string]$PgBin = "$env:USERPROFILE\Desktop\postgresql-17.11-5-windows-x64-binaries\pgsql\bin",
  [string]$Destination = "$env:USERPROFILE\Documents\ShopLinkBackup"
)
$ErrorActionPreference = 'Stop'
$pgDump = Join-Path $PgBin 'pg_dump.exe'
$pgRestore = Join-Path $PgBin 'pg_restore.exe'
if (-not (Test-Path -LiteralPath $pgDump -PathType Leaf)) {
  throw "pg_dump.exe not found in $PgBin"
}
if (-not (Test-Path -LiteralPath $pgRestore -PathType Leaf)) {
  throw "pg_restore.exe not found in $PgBin"
}
$version = & $pgDump --version
if ($LASTEXITCODE -ne 0 -or $version -notmatch 'PostgreSQL\)\s+17\.') {
  throw "PostgreSQL 17 client required. Found: $version"
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$target = Join-Path $Destination ("ShopLinkMaroc_{0}.dump" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$env:PGSSLMODE = 'require'
Write-Host 'ShopLink: password is entered only in the hidden prompt, never pasted into chat.'
Write-Host 'If authentication fails, STOP. Do not repeatedly retry or reset your password.'
$arguments = @('--host','aws-1-eu-west-1.pooler.supabase.com','--port','5432','--username','postgres.lcxwsowyqzbhmlpxijsu','--dbname','postgres','--format=custom','--no-owner','--no-acl','--password','--file',$target)
& $pgDump @arguments
$code = $LASTEXITCODE
if ($code -ne 0) {
  # Remove incomplete output created by this failed invocation, even if nonzero bytes.
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
  throw "Backup failed (exit $code). No validated backup was created."
}
$item = Get-Item -LiteralPath $target
if ($item.Length -lt 1024) {
  throw "Backup is too small ($($item.Length) bytes); do NOT consider it valid."
}
& $pgRestore --list $target | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "pg_restore could not read this archive."
}
Write-Host ("ARCHIVE CREATED: {0}" -f $target)
Write-Host ("SIZE: {0} bytes" -f $item.Length)
Write-Host ("SHA256: {0}" -f (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash)
Write-Warning 'This is a logical PostgreSQL dump, NOT a validated full Supabase recovery. Test an isolated restoration before migration.'
Write-Warning 'This dump contains private records. Never upload it to GitHub or share its contents.'
