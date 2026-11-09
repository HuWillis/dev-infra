# SQL routing regression tests; never contact a real database.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra.ps1')
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Invoke-Compose { param([string[]]$Arguments); return 'existing-mysql-id' }
function Invoke-Docker {
    param([string[]]$Arguments, [string]$InputText)
    Assert (($Arguments[0..2] -join ',') -eq 'exec,-i,existing-mysql-id') 'Bootstrap must execute inside the existing container.'
    if ($InputText -like 'SELECT COUNT(*)*') {
        if ($InputText -match 'table_name IN') { return [string]$script:MatchingCount }
        return [string]$script:TableCount
    }
    $script:WrittenSql = $InputText
    return ''
}
$values = @{XXL_JOB_USER='admin';XXL_JOB_PASSWORD='abcdefghijklmnopqrst';XXL_JOB_DB_PASSWORD='fake-database-password'}
$script:TableCount = 0; $script:MatchingCount = 8; $script:WrittenSql = ''
Initialize-XxlJobDatabase $values
Assert ($script:WrittenSql -match 'CREATE TABLE' -and $script:WrittenSql -match 'LOWER\(SHA2' -and $script:WrittenSql -match 'schedule_lock') 'Empty dedicated database must get versioned schema, SHA256 admin and schedule lock.'
Assert ($script:WrittenSql -notmatch 'DROP TABLE|DROP DATABASE|TRUNCATE|ALTER USER|123456|difyWorkflowJobHandler') 'Bootstrap must not reset data or introduce upstream demo credentials/jobs.'
$script:TableCount = 8; $script:WrittenSql = ''
Initialize-XxlJobDatabase $values
Assert ($script:WrittenSql -notmatch 'CREATE TABLE|INSERT INTO|UPDATE|ALTER') 'Repeat startup must preserve existing tables and admin credentials.'
$script:TableCount = 3; $script:MatchingCount = 3; $script:WrittenSql = ''
$failed = $false
try { Initialize-XxlJobDatabase $values } catch { $failed = $_.Exception.Message -match 'schema is incomplete' }
Assert ($failed -and -not $script:WrittenSql) 'Partial schema must be preserved and reported, never overwritten.'
Write-Host 'PASS: shared-container SQL bootstrap, repeat startup, partial-schema preservation.'
