Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'infra.ps1')
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Start-Sleep { param($Seconds) }
function Invoke-Compose {
    param([string[]]$Arguments)
    $script:Calls++
    Assert ($Arguments[-1] -eq 'nginx') 'Retry must preserve the selected service.'
    if ($script:Calls -le $script:Failures) { throw $script:FailureMessage }
    return ''
}
$script:Calls=0; $script:Failures=2; $script:FailureMessage='Get https://registry-1.docker.io/v2/: EOF'
Invoke-ComposeUp @('nginx') 300
Assert ($script:Calls -eq 3) 'Transient registry EOF must retry and recover.'
foreach ($message in @('manifest unknown','container nginx is unhealthy','unauthorized: incorrect password','database connection: EOF')) {
    $script:Calls=0; $script:Failures=10; $script:FailureMessage=$message
    $failed=$false
    try { Invoke-ComposeUp @('nginx') 300 } catch { $failed=$true }
    Assert ($failed -and $script:Calls -eq 1) 'Configuration/auth/database failures must fail without network retries.'
}
$script:Calls=0; $script:Failures=10; $script:FailureMessage='registry: TLS handshake timeout'
$failed=$false
try { Invoke-ComposeUp @('nginx') 300 } catch { $failed=$true }
Assert ($failed -and $script:Calls -eq 3) 'Network retries must be bounded.'
Write-Host 'PASS: transient registry recovery, non-network errors and bounded retries.'
