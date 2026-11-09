# No Docker engine, containers, network calls or database operations are required.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$errors = $null
$null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'infra.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'infra.ps1 parser check failed.' }
. (Join-Path $root 'infra.ps1')
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Must-Fail { param([scriptblock]$Code, [string]$Message); $failed = $false; try { & $Code } catch { $failed = $true }; Assert $failed $Message }

$temp = Join-Path ([IO.Path]::GetTempPath()) ('dev-infra-selfcheck-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
try {
    $script:InfraRoot = $temp
    Copy-Item -LiteralPath (Join-Path $root '.env.example') -Destination (Join-Path $temp '.env.example')
    Must-Fail { Read-Environment } 'Missing .env must fail.'
    Initialize-Environment
    $first = [IO.File]::ReadAllBytes((Join-Path $temp '.env'))
    $values = Read-Environment
    Assert ($values.MYSQL_ROOT_PASSWORD -ne $values.MYSQL_PASSWORD) 'Root and app passwords must differ.'
    Initialize-Environment
    $second = [IO.File]::ReadAllBytes((Join-Path $temp '.env'))
    Assert ([Convert]::ToBase64String($first) -eq [Convert]::ToBase64String($second)) 'Init must preserve existing .env byte-for-byte.'
    # Upgrade a real legacy-format file and keep every existing byte and password.
    $legacy = ($values.Keys | Where-Object { $_ -notmatch '^(ELASTIC|MONGO|ROCKETMQ)_' } | Sort-Object | ForEach-Object { "$_=$($values[$_])" }) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $temp '.env'), $legacy, (New-Object Text.UTF8Encoding $false))
    Initialize-Environment
    $upgraded = [IO.File]::ReadAllText((Join-Path $temp '.env'))
    Assert ($upgraded.StartsWith($legacy + "`r`n")) 'Upgrade must append, preserving the entire legacy prefix.'
    $upgradeValues = Read-Environment
    Assert ($upgradeValues.MYSQL_ROOT_PASSWORD -eq $values.MYSQL_ROOT_PASSWORD) 'Upgrade must preserve database credentials.'
    Assert ($upgradeValues.MONGO_ROOT_PASSWORD.Length -ge 16) 'Upgrade must initialize MongoDB authentication.'
    [IO.File]::WriteAllBytes((Join-Path $temp '.env'), $first)
    Add-Content -LiteralPath (Join-Path $temp '.env') -Value "`nMYSQL_PORT=3307"
    Must-Fail { Read-Environment } 'Duplicate .env keys must fail.'
    [IO.File]::WriteAllBytes((Join-Path $temp '.env'), $first)
    $content = [IO.File]::ReadAllText((Join-Path $temp '.env'))
    [IO.File]::WriteAllText((Join-Path $temp '.env'), $content.Replace('NACOS_GRPC_PORT=9848','NACOS_GRPC_PORT=9849'))
    Must-Fail { Read-Environment } 'Nacos gRPC offset must remain 1000.'

    foreach ($endpoint in @('npipe:////./pipe/docker_engine','unix:///var/run/docker.sock','tcp://127.0.0.1:2375','tcp://localhost:2375')) { Assert-LocalEndpoint $endpoint }
    foreach ($endpoint in @('ssh://example.com','tcp://192.168.132.44:2375','npipe:////remote/pipe/docker_engine','garbage')) {
        Must-Fail { Assert-LocalEndpoint $endpoint } 'Remote or invalid Docker endpoint must fail.'
    }
    # The host port check must reject a real local listener without contacting Docker.
    function Get-ProjectContainers { return @() }
    $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), 0
    try {
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        Must-Fail { Assert-PortsAvailable @{MYSQL_PORT = $port} @('mysql') } 'Occupied local port must fail.'
        $script:OwnedPort = $port
        function Get-ProjectContainers {
            return @([pscustomobject]@{
                State = [pscustomobject]@{ Running = $true }
                Config = [pscustomobject]@{ Labels = [pscustomobject]@{ 'com.docker.compose.service' = 'mysql' } }
                NetworkSettings = [pscustomobject]@{ Ports = [pscustomobject]@{ '3306/tcp' = @([pscustomobject]@{ HostIp = '127.0.0.1'; HostPort = [string]$script:OwnedPort }) } }
            })
        }
        Assert-PortsAvailable @{MYSQL_PORT = $port} @('mysql')
        Must-Fail { Assert-PortsAvailable @{REDIS_PORT = $port} @('redis') } 'Another service must not claim an owned port.'
    } finally { $listener.Stop() }
    $shellName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
    $script:DockerExe = (Get-Command $shellName -CommandType Application | Select-Object -First 1).Source
    $originalPath = $env:PATH
    Must-Fail { Invoke-Docker @('-NoProfile','-Command','exit 7') } 'Native command failure must throw.'
    Assert ($env:PATH -eq $originalPath) 'Native failure must restore PATH.'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('[Console]::Error.WriteLine("progress"); exit 0'))
    $progress = Invoke-Docker @('-NoProfile','-EncodedCommand',$encoded)
    Assert ($progress -match 'progress') 'Successful native stderr must remain available without failing.'
    Assert ($env:PATH -eq $originalPath) 'Successful native invocation must restore PATH.'
    [IO.File]::WriteAllBytes((Join-Path $temp '.env'), $first)
    $secretError = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('[Console]::Error.WriteLine("' + $values.MYSQL_ROOT_PASSWORD + '"); exit 1'))
    try { $null = Invoke-Docker @('-NoProfile','-EncodedCommand',$secretError); throw 'Expected failure.' }
    catch {
        Assert (-not $_.Exception.Message.Contains($values.MYSQL_ROOT_PASSWORD)) 'Native errors must mask local passwords.'
        Assert ($_.Exception.Message.Contains('[redacted]')) 'Native error must retain a masked diagnostic.'
    }
    $savedMysqlUser = [Environment]::GetEnvironmentVariable('MYSQL_USER', 'Process')
    $savedMinioUser = [Environment]::GetEnvironmentVariable('MINIO_ROOT_USER', 'Process')
    try {
        $env:MYSQL_USER = 'conflicting-shell-user'
        Remove-Item Env:\MINIO_ROOT_USER -ErrorAction SilentlyContinue
        function Invoke-Docker {
            param([string[]]$Arguments)
            Assert (-not (Test-Path Env:\MYSQL_USER)) 'Conflicting variables must be absent, not empty.'
            Assert (-not (Test-Path Env:\MINIO_ROOT_USER)) 'Unconfigured variables must remain absent.'
            Assert ($Arguments -contains '--env-file') 'Compose must select its own env file.'
            return 'captured'
        }
        $null = Invoke-Compose @('ps')
        Assert ($env:MYSQL_USER -eq 'conflicting-shell-user') 'Compose must restore caller variables.'
        Assert (-not (Test-Path Env:\MINIO_ROOT_USER)) 'Compose must restore absent variables as absent.'
    } finally {
        foreach ($entry in @(@('MYSQL_USER',$savedMysqlUser), @('MINIO_ROOT_USER',$savedMinioUser))) {
            if ($null -eq $entry[1]) { Remove-Item -LiteralPath ('Env:\' + $entry[0]) -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($entry[0], $entry[1], 'Process') }
        }
    }

    $compose = Get-Content -LiteralPath (Join-Path $root 'compose.yaml') -Raw
    Assert ($compose -match '(?m)^name: dev-infra\r?$') 'Compose project must be fixed.'
    Assert ($compose -notmatch '(?m)^\s*privileged:|network_mode:\s*host|docker\.sock|:latest\b') 'Compose must avoid privileged/host/latest/socket access.'
    Assert (@([regex]::Matches($compose,'(?m)^\s*network_mode:')).Count -eq 1 -and $compose.Contains('network_mode: service:rocketmq-broker')) 'Only Dashboard may share the broker network.'
    Assert (@([regex]::Matches($compose,'(?m)^\s+image: mysql:')).Count -eq 1) 'XXL-JOB must not introduce another MySQL container.'
    $portLines = @($compose -split '\r?\n' | Where-Object { $_ -match '^\s+- "[^" ]+:[^" ]+:[^" ]+"$' })
    Assert ($portLines.Count -ge 8) 'Existing published ports must remain configured.'
    Assert (@($portLines | Where-Object { $_ -notmatch '"127\.0\.0\.1:' }).Count -eq 0) 'Every published port must bind loopback.'
    foreach ($profile in @('messaging','registry','storage','search','document','rocketmq')) { Assert ($compose.Contains(('profiles: [' + $profile + ']'))) "Missing optional profile: $profile" }
    Assert ($compose -match 'nacos-data:/home/nacos/data') 'Nacos Derby data must persist.'
    $scriptText = Get-Content -LiteralPath (Join-Path $root 'infra.ps1') -Raw
    Assert ($scriptText -notmatch '--volumes|down[^\r\n]* -v\b') 'Down must preserve volumes.'
    Write-Host 'PASS: parser, env generation/idempotence, validation failures, local endpoints, occupied/owned ports, native failure and Compose isolation.'
} finally {
    # The random temporary directory is the only recursive deletion target.
    $resolved = [IO.Path]::GetFullPath($temp)
    $expectedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'dev-infra-selfcheck-*') { throw 'Unsafe self-check cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
