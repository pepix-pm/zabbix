
<#
.SYNOPSIS
  Zabbix/PowerShell checker for Oracle RMAN: last backup (datafile D/I) in 24h and last VALIDATE status.

.PARAMETER Connect
  SQL*Plus connect string, e.g. '/ as sysdba' or 'user/pass@service'

.PARAMETER Metric
  One of:
    - backup_within_24h       -> prints 1 (OK) / 0 (NOT OK)
    - validate_after_backup   -> prints 1 (OK) / 0 (NOT OK)
    - backup_age_hours        -> prints age (hours) or -1 if unknown
    - validate_age_hours      -> prints age (hours) or -1 if unknown
    - status_json             -> prints JSON with all above metrics

.NOTES
  Requires: sqlplus in PATH (Oracle Client), proper ORACLE_HOME/ORACLE_SID (if OS auth).
  Uses V$BACKUP_SET and V$RMAN_STATUS (no catalog). Adapt to RC_* if using recovery catalog.
#>

[CmdletBinding()]
param(
  [string]$Connect = "/ as sysdba",
  [ValidateSet(
    "backup_within_24h",
    "validate_after_backup",
    "backup_age_hours",
    "validate_age_hours",
    "status_json"
  )]
  [string]$Metric = "status_json"
)

$ErrorActionPreference = "Stop"

function Invoke-SqlPlus {
  param([string]$Connect, [string]$Query)

  $tempSql = [System.IO.Path]::GetTempFileName()
  try {
    @"
set head off feedback off pages 0 lines 300 trimspool on verify off echo off
$Query
exit
"@ | Set-Content -Path $tempSql -Encoding ASCII

    # Start sqlplus non-interactively
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "sqlplus"
    $psi.Arguments = "-s `"$Connect`" @$tempSql"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd().Trim()
    $stderr = $p.StandardError.ReadToEnd().Trim()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0 -or ($stderr -and $stderr -notmatch '^(?s)\s*$')) {
      throw "sqlplus error (code=$($p.ExitCode)): $stderr"
    }
    # Normalize whitespaces / newlines
    return ($stdout -replace '\s+', ' ').Trim()
  }
  finally {
    if (Test-Path $tempSql) { Remove-Item $tempSql -Force -ErrorAction SilentlyContinue }
  }
}

function Get-BackupAgeHours {
  $q = @"
SELECT NVL(ROUND((SYSDATE - MAX(completion_time))*24,2), -1)
FROM v\$backup_set
WHERE backup_type IN ('D','I')
"@
  (Invoke-SqlPlus -Connect $Connect -Query $q)
}

function Get-ValidateAgeHours {
  $q = @"
SELECT NVL(ROUND((SYSDATE - MAX(end_time))*24,2), -1)
FROM v\$rman_status
WHERE operation LIKE 'VALIDATE%' AND status='COMPLETED'
"@
  (Invoke-SqlPlus -Connect $Connect -Query $q)
}

function Test-BackupWithin24h {
  $q = @"
SELECT CASE
         WHEN MAX(completion_time) IS NULL THEN 0
         WHEN (SYSDATE - MAX(completion_time))*24 <= 24 THEN 1
         ELSE 0
       END
FROM v\$backup_set
WHERE backup_type IN ('D','I')
"@
  (Invoke-SqlPlus -Connect $Connect -Query $q)
}

function Test-ValidateAfterBackup {
  $q = @"
WITH b AS (
  SELECT MAX(completion_time) AS bkp_time
  FROM v\$backup_set
  WHERE backup_type IN ('D','I')
),
v AS (
  SELECT MAX(end_time) AS val_time
  FROM v\$rman_status
  WHERE operation LIKE 'VALIDATE%' AND status='COMPLETED'
)
SELECT CASE
         WHEN b.bkp_time IS NULL THEN 0
         WHEN v.val_time IS NULL THEN 0
         WHEN v.val_time < b.bkp_time THEN 0
         WHEN (SYSDATE - v.val_time)*24 > 24 THEN 0
         ELSE 1
       END
FROM b, v
"@
  (Invoke-SqlPlus -Connect $Connect -Query $q)
}

try {
  switch ($Metric) {
    "backup_age_hours"      { [Console]::Out.Write((Get-BackupAgeHours)); break }
    "validate_age_hours"    { [Console]::Out.Write((Get-ValidateAgeHours)); break }
    "backup_within_24h"     { [Console]::Out.Write((Test-BackupWithin24h)); break }
    "validate_after_backup" { [Console]::Out.Write((Test-ValidateAfterBackup)); break }
    "status_json" {
      $bage = Get-BackupAgeHours
      $vage = Get-ValidateAgeHours
      $bok  = Test-BackupWithin24h
      $vok  = Test-ValidateAfterBackup
      $obj = [ordered]@{
        backup_age_hours      = [double]$bage
        backup_within_24h     = [int]$bok
        validate_age_hours    = [double]$vage
        validate_after_backup = [int]$vok
      }
      $json = ($obj | ConvertTo-Json -Compress)
      [Console]::Out.Write($json)
      break
    }
  }
}
catch {
  # Zabbix friendly: print something and exit non-zero
  [Console]::Error.WriteLine("ERROR: $($_.Exception.Message)")
  exit 2
}
