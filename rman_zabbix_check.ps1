 
<#
.SYNOPSIS
  Zabbix/PowerShell checker for Oracle RMAN: last backup (datafile D/I) in 24h and last RESTORE VALIDATE status.
  Supported Oracle releases: tested on 12c database;

.PARAMETER Logon
  SQL*Plus <logon>
  <logon> is: {<username>[/<password>][@<connect_identifier>] | / }
              [AS {SYSDBA | SYSOPER | SYSASM | SYSBACKUP | SYSDG | SYSKM | SYSRAC}] [EDITION=value]

.PARAMETER Metric
  One of:
    - backup_within_24h               -> prints 1 (OK) / 0 (NOT OK)
    - restore_validate_after_backup   -> prints 1 (OK) / 0 (NOT OK)
    - backup_age_hours                -> prints age (hours) or -1 if unknown
    - restore_validate_age_hours      -> prints age (hours) or -1 if unknown
    - last_rman_session               -> prints 1 (OK) / 0 (NOT OK) - completed without errors
    - last_rman_session_age_hours     -> prints age (hours) or -1 if unknown
    - status_json                     -> prints JSON with all above metrics

.NOTES
  Requires: sqlplus in PATH (Oracle Client), proper ORACLE_HOME/ORACLE_SID (if OS auth).
  Uses V$BACKUP_SET and V$RMAN_STATUS views.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$Logon,

  [ValidateSet(
    "backup_within_24h",
    "restore_validate_after_backup",
    "backup_age_hours",
    "restore_validate_age_hours",
    "last_rman_session",
    "last_rman_session_age_hours",
    "status_json"
  )]
  [string]$Metric = "status_json"
)

$ErrorActionPreference = "Stop"

function Invoke-SqlPlus {
  param([string]$Logon, [string]$Query)

  $tmp = [System.IO.Path]::GetTempFileName()

  try {
    @"
set head off feedback off pages 0 lines 300 trimspool on verify off echo off
$Query
exit
"@ | Set-Content -Path $tmp -Encoding ASCII

    # Start sqlplus non-interactively
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "sqlplus"
    $psi.Arguments = "-s `"$Logon`" @$tmp"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $stdout = $p.StandardOutput.ReadToEnd()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit()

    if ($p.ExitCode -ne 0 -or ($stderr -and $stderr.Trim())) {      
      throw "sqlplus failed (code=$($p.ExitCode)): $stderr"    
    }
    
    # Normalize whitespaces / newlines
    return $stdout.Trim()
  }
  finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  }
}

function Get-BackupAgeHours {
  $q = @"
SELECT NVL(ROUND((SYSDATE - MAX(completion_time))*24,2), -1)
FROM v`$backup_set
WHERE backup_type IN ('D','I');
"@
  (Invoke-SqlPlus -Logon $Logon -Query $q)
}

function Get-RestoreValidateAgeHours {
  $q = @"
SELECT NVL(ROUND((SYSDATE - MAX(end_time))*24,2), -1)
FROM v'$rman_status
WHERE operation = 'RESTORE VALIDATE' AND status='COMPLETED';
"@
  (Invoke-SqlPlus -Logon $Logon -Query $q)
}

function Get-RestoreValidateAgeHours {
  $q = @"
SELECT NVL(ROUND((SYSDATE - MAX(end_time))*24,2), -1)
FROM v`$rman_status
WHERE operation = 'RESTORE VALIDATE' AND status='COMPLETED';
"@
  (Invoke-SqlPlus -Logon $Logon -Query $q)
}

function Get-LastRMANSessionAgeHours {
  $q = @"
SELECT NVL(ROUND((SYSDATE - MAX(end_time))*24,2), -1)
FROM v`$rman_status
WHERE ROW_TYPE= 'SESSION';
"@
  (Invoke-SqlPlus -Logon $Logon -Query $q)
}

function Test-BackupWithin24h {
  $q = @"
SELECT CASE
         WHEN MAX(completion_time) IS NULL THEN 0
         WHEN (SYSDATE - MAX(completion_time))*24 <= 24 THEN 1
         ELSE 0
       END
FROM v`$backup_set
WHERE backup_type IN ('D','I');
"@
  (Invoke-SqlPlus -Logon $Logon -Query $q)
}

function Test-LastRMANSession {
  $q = @"
SELECT DECODE(status, 'COMPLETED', 1, 0) FROM
(
select status from v`$rman_status WHERE ROW_TYPE = 'SESSION' order by recid desc
)
WHERE ROWNUM = 1;
"@
  (Invoke-SqlPlus -Logon $Logon -Query $q)
}

function Test-RestoreValidateAfterBackup {
  $q = @"
WITH b AS (
  SELECT MAX(completion_time) AS bkp_time
  FROM v`$backup_set
  WHERE backup_type IN ('D','I')
),
v AS (
  SELECT MAX(end_time) AS val_time
  FROM v`$rman_status
  WHERE operation = 'RESTORE VALIDATE' AND status='COMPLETED'
)
SELECT CASE
         WHEN b.bkp_time IS NULL THEN 0
         WHEN v.val_time IS NULL THEN 0
         WHEN v.val_time < b.bkp_time THEN 0
         WHEN (SYSDATE - v.val_time)*24 > 24 THEN 0
         ELSE 1
       END
FROM b, v;
"@
  (Invoke-SqlPlus -Logon $Logon -Query $q)
}

try {
  switch ($Metric) {
    "backup_age_hours"      { [Console]::Out.Write((Get-BackupAgeHours)); break }
    "restore_validate_age_hours"    { [Console]::Out.Write((Get-RestoreValidateAgeHours)); break }
    "backup_within_24h"     { [Console]::Out.Write((Test-BackupWithin24h)); break }
    "restore_validate_after_backup" { [Console]::Out.Write((Test-RestoreValidateAfterBackup)); break }
    "last_rman_session" { [Console]::Out.Write((Test-LastRMANSession)); break }
    "last_rman_session_age_hours" { [Console]::Out.Write((Get-LastRMANSessionAgeHours)); break }
    "status_json" {
      $bage = Get-BackupAgeHours
      $vage = Get-RestoreValidateAgeHours
      $bok  = Test-BackupWithin24h
      $vok  = Test-RestoreValidateAfterBackup
      $lrok  = Test-LastRMANSession
      $lrage = Get-LastRMANSessionAgeHours
      $obj = [ordered]@{
        backup_age_hours      = [double]$bage
        backup_within_24h     = [int]$bok
        restore_validate_age_hours    = [double]$vage
        restore_validate_after_backup = [int]$vok
        last_rman_session = [int]$lrok
        last_rman_session_age_hours = [double]$lrage
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
