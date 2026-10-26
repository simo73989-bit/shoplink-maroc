# No connection, credentials or production data. Execute the helper against fake tools.
$ErrorActionPreference = 'Stop'
$source = Join-Path $PSScriptRoot '../ops/backup-shoplink-local.ps1'
$tokens=$null; $errors=$null
[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors) | Out-Null
if ($errors.Count) { throw 'Backup helper has PowerShell parse errors' }
# Functions impersonate native executable commands without creating binaries.
function global:pg_dump.exe {
  if ($args -contains '--version') { $global:LASTEXITCODE=0; return 'pg_dump (PostgreSQL) 17.6' }
  if ($env:PGSSLMODE -ne 'verify-full') { throw 'TLS verification missing' }
  if ($args -notcontains '--password' -or $args -notcontains 'postgres.lcxwsowyqzbhmlpxijsu') { throw 'Unsafe target/prompt arguments' }
  $script:dumpCalls++
  $file = $args[[Array]::IndexOf($args,'--file')+1]
  $size = if ($script:scenario -eq 'small') { 10 } else { 2048 }
  [IO.File]::WriteAllBytes($file,[byte[]]::new($size))
  $global:LASTEXITCODE = if ($script:scenario -eq 'dump-fail') { 1 } else { 0 }
}
function global:pg_restore.exe {
  if ($args -contains '--version') { $global:LASTEXITCODE=0; return 'pg_restore (PostgreSQL) 17.6' }
  $global:LASTEXITCODE = if ($script:scenario -eq 'list-fail') { 1 } else { 0 }
}
# Rewrite only executable path resolution in an in-memory test copy, so command
# invocation still executes the real helper's error handling and finally block.
$text = Get-Content -LiteralPath $source -Raw
$text = $text.Replace("`$pgDump = Join-Path `$PgBin 'pg_dump.exe'", "`$pgDump = 'pg_dump.exe'")
$text = $text.Replace("`$pgRestore = Join-Path `$PgBin 'pg_restore.exe'", "`$pgRestore = 'pg_restore.exe'")
$text = $text.Replace('if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {','if ($false) {')
# Sandbox /tmp itself has a platform .git marker; model the destination check.
$text = $text.Replace("if (Test-Path -LiteralPath (Join-Path `$ancestor '.git')) {", "if (`$script:scenario -eq 'git-destination') {")
$run = [ScriptBlock]::Create($text)
$root = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
try {
  foreach ($script:scenario in @('dump-fail','small','list-fail','success')) {
    $dest=Join-Path $root $script:scenario
    $env:PGSSLMODE='prior-mode'; $env:PGSSLROOTCERT='prior-root'; $env:PGCONNECT_TIMEOUT='9'
    $failed=$false; $script:dumpCalls=0
    try { & $run -Destination $dest } catch { $failed=$true }
    if ($script:dumpCalls -ne 1) { throw 'Wrong number of connection attempts' }
    if ($failed -ne ($script:scenario -ne 'success')) { throw "Wrong outcome: $script:scenario" }
    if (@(Get-ChildItem $dest -Filter '*.partial').Count) { throw 'Partial archive retained' }
    $expected=if($script:scenario -eq 'success'){1}else{0}
    if (@(Get-ChildItem $dest -Filter '*.dump').Count -ne $expected) { throw 'Invalid archive published or successful archive missing' }
    if ($env:PGSSLMODE -ne 'prior-mode' -or $env:PGSSLROOTCERT -ne 'prior-root' -or $env:PGCONNECT_TIMEOUT -ne '9') { throw 'Environment was not restored' }
  }
  $script:scenario='git-destination'
  $script:dumpCalls=0
  $blocked=$false
  try { & $run -Destination (Join-Path $root 'git-destination') } catch { $blocked=$_.Exception.Message -like '*Git checkout*' }
  if (-not $blocked -or $script:dumpCalls -ne 0) { throw 'Git backup destination was not rejected before connection' }
  Write-Host 'PASS backup helper: parse, pg_dump failure, short archive, bad catalog, success, cleanup, TLS and environment restoration (fake tools only).'
} finally {
  Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item Function:\pg_dump.exe,Function:\pg_restore.exe -ErrorAction SilentlyContinue
}
