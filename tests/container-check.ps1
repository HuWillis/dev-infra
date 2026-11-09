# Regression: PS 5.1 ConvertFrom-Json arrays must not become nested container arrays.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra.ps1')
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Invoke-Docker {
    param([string[]]$Arguments)
    if ($Arguments[0] -eq 'ps') { return "mysql-id`nxxl-id" }
    return @'
[
 {"Config":{"Labels":{"com.docker.compose.service":"mysql"}},"State":{"Running":true},"NetworkSettings":{"Ports":{"3306/tcp":[{"HostIp":"127.0.0.1","HostPort":"3306"}]}}},
 {"Config":{"Labels":{"com.docker.compose.service":"xxl-job"}},"State":{"Running":true},"NetworkSettings":{"Ports":{}}}
]
'@
}
$containers = @(Get-ProjectContainers)
Assert ($containers.Count -eq 2) 'JSON array must yield two separate containers in both PowerShell versions.'
Assert-PortsAvailable @{MYSQL_PORT='3306'} @('mysql')
$failed = $false
try { Assert-StopSafe @('mysql') } catch { $failed = $_.Exception.Message -match 'dependency-in-use' }
Assert $failed 'Running XXL-JOB must block stopping shared MySQL alone.'
Assert-StopSafe @('mysql','xxl-job')
Write-Host 'PASS: real Docker JSON shape, owned ports and shared database stop guard.'
