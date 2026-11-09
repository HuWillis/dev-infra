# Verifies command routing without starting/stopping real services or contacting Docker.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'infra.ps1')
# Dot-sourced parameter variables retain validation attributes; use ordinary test variables.
Remove-Variable Services,Stack -Force
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Must-Fail { param([scriptblock]$Code); $failed = $false; try { & $Code } catch { $failed = $true }; Assert $failed 'Expected validation failure.' }
function Connect-LocalDocker { }
function Initialize-Environment { }
function Read-Environment { return @{} }
function Assert-PortsAvailable { param($Values,$Selected); $script:CheckedPorts = @($Selected) }
function Invoke-Compose { param([string[]]$Arguments); $script:Captured = @($Arguments); return '' }
function Get-ProjectContainers { return @() }
function Initialize-XxlJobDatabase { param($Values); $script:XxlInitialized = $true }
function Initialize-DashboardCredentials { param($Values); $script:DashboardInitialized = $true }

$Action = 'Up'; $Services = @(); $Stack = ''; $All = $false
Invoke-Infra
Assert (($script:Captured[-2..-1] -join ',') -eq 'mysql,redis') 'Default Up must start only MySQL and Redis.'
$Services = @('es,mongo,rmq','redis','mongodb')
Invoke-Infra
Assert (($script:CheckedPorts -join ',') -eq 'elasticsearch,mongodb,rocketmq-namesrv,rocketmq-broker,redis') 'Aliases and CSV selection must expand dependencies and deduplicate.'
Assert ($script:Captured -notcontains 'mysql') 'Explicit selection must not start default MySQL.'
Assert ($script:Captured -notcontains '--profile') 'Up must not enable unrelated profile services.'

$Action = 'Stop'; $Services = @('rocketmq')
Invoke-Infra
Assert (($script:Captured -join ',') -eq '--profile,*,stop,rocketmq-namesrv,rocketmq-broker') 'Stopping RocketMQ must stop only its two containers.'
$Action = 'Down'; $Services = @('mongodb')
Invoke-Infra
Assert (($script:Captured -join ',') -eq '--profile,*,stop,mongodb') 'Selected Down must never stop other services.'
$Services = @()
Invoke-Infra
Assert (($script:Captured -join ',') -eq '--profile,*,stop') 'Unselected Down must preserve the legacy stop-all behavior.'

$Action = 'Up'; $Stack = 'microservice'
Invoke-Infra
Assert (($script:CheckedPorts -join ',') -eq 'mysql,redis,nacos,rocketmq-namesrv,rocketmq-broker') 'A project stack must start precisely its service list and dependencies.'
$Services = @('mongodb')
Assert ((@(Resolve-Services) -join ',') -eq 'mongodb,mysql,redis,nacos,rocketmq') 'Stack and additional services must combine.'
$Stack = 'does-not-exist'
Must-Fail { Resolve-Services }
$Stack = ''; $Services = @('typo')
Must-Fail { Resolve-Services }
$All = $true
Must-Fail { Resolve-Services }
$Services = @()
Assert (@(Resolve-Services).Count -eq 19) 'Explicit All must include all 19 middleware choices.'
$All = $false; $Action = 'Status'
Assert (@(Resolve-Services).Count -eq 0) 'Unfiltered Status must show every service.'

$Action = 'Up'; $Services = @('xxl-job','grafana','kibana','rocketmq-dashboard'); $Stack = ''
Invoke-Infra
Assert (($script:CheckedPorts -join ',') -eq 'mysql,xxl-job,prometheus,grafana,elasticsearch,kibana-setup,kibana,rocketmq-namesrv,rocketmq-broker,rocketmq-dashboard') 'Dependencies must start before dependents, without duplicates.'
Assert ($script:XxlInitialized -and $script:DashboardInitialized) 'Selected services must prepare their own credentials/schema.'
Assert ($script:Captured -notcontains 'xxl-job-mysql') 'XXL-JOB must reuse the existing MySQL service.'

function Get-ProjectContainers {
    @([pscustomobject]@{
        Config = [pscustomobject]@{ Labels = [pscustomobject]@{ 'com.docker.compose.service' = 'xxl-job' } }
        State = [pscustomobject]@{ Running = $true }
    })
}
$Action = 'Stop'; $Services = @('mysql')
Must-Fail { Invoke-Infra }
$Services = @('mysql','xxl-job')
Invoke-Infra
Assert (($script:Captured -join ',') -eq '--profile,*,stop,mysql,xxl-job') 'Explicitly selecting both must allow stopping the shared database and scheduler.'
$Services = @('xxl-job')
Invoke-Infra
Assert (($script:Captured -join ',') -eq '--profile,*,stop,xxl-job') 'Stopping a dependent must preserve its shared dependency.'

# A stopped container's historical failed healthcheck must not appear as a live failure.
function Get-ProjectContainers {
    @([pscustomobject]@{
        Config = [pscustomobject]@{ Labels = [pscustomobject]@{ 'com.docker.compose.service' = 'mongodb' } }
        State = [pscustomobject]@{ Running = $false; Status = 'exited'; Health = [pscustomobject]@{ Status = 'unhealthy' } }
    })
}
$doctorOutput = (Show-Doctor 6>&1 | Out-String)
Assert ($doctorOutput -match 'mongodb: exited' -and $doctorOutput -notmatch 'mongodb: unhealthy') 'Doctor must distinguish stopped from unhealthy.'
Write-Host 'PASS: default/explicit selection, aliases, dependencies, selective stopping, stacks, invalid choices, and stopped health.'
