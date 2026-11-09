<#
.SYNOPSIS
Manage optional local middleware. Init preserves existing .env values and appends missing settings.
.EXAMPLE
.\infra.ps1 Up -Services mysql,redis,rabbitmq
.EXAMPLE
.\infra.ps1 Doctor
.EXAMPLE
.\infra.ps1 Up -Services elasticsearch,rocketmq,mongodb
.EXAMPLE
.\infra.ps1 Up -Stack microservice
.EXAMPLE
.\infra.ps1 Stop -Services mongodb
.NOTES
Stop/Down preserve containers and volumes. Without a selector they stop all dev-infra services.
Stacks share middleware instances; stopping one affects other projects using those services.
No command imports application data or accesses a remote Docker engine.
#>
[CmdletBinding()]
param(
    [ValidateSet('Init','List','Up','Stop','Down','Status','Doctor','Logs')]
    [string]$Action = 'Status',
    [ValidateNotNullOrEmpty()]
    [string[]]$Services = @(),
    [ValidatePattern('^[a-zA-Z0-9_-]+$')]
    [string]$Stack,
    [switch]$All,
    [ValidateRange(30,1800)]
    [int]$WaitTimeout = 300,
    [ValidateRange(1,10000)]
    [int]$Tail = 100
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:InfraRoot = $PSScriptRoot
$script:DockerExe = $null
$script:Catalog = @('mysql','redis','rabbitmq','nacos','minio','elasticsearch','rocketmq','mongodb','nginx','xxl-job','kibana','rocketmq-dashboard','postgresql','mailpit','prometheus','grafana','sentinel','seata','kafka')
$script:Dependencies = @{
    'kibana' = @('elasticsearch')
    'xxl-job' = @('mysql')
    'rocketmq-dashboard' = @('rocketmq')
    'grafana' = @('prometheus')
}
$script:SecretKeys = @('MYSQL_ROOT_PASSWORD','MYSQL_PASSWORD','REDIS_PASSWORD','RABBITMQ_DEFAULT_PASS','MINIO_ROOT_PASSWORD','ELASTIC_PASSWORD','MONGO_ROOT_PASSWORD','KIBANA_SYSTEM_PASSWORD','KIBANA_SECURITY_KEY','KIBANA_SAVED_OBJECTS_KEY','KIBANA_REPORTING_KEY','POSTGRES_PASSWORD','GRAFANA_PASSWORD','XXL_JOB_PASSWORD','XXL_JOB_DB_PASSWORD','XXL_JOB_ACCESS_TOKEN','SENTINEL_PASSWORD','SEATA_PASSWORD','SEATA_TOKEN_SECRET','ROCKETMQ_DASHBOARD_PASSWORD')
$script:ServicePorts = @{
    mysql = @('MYSQL_PORT'); redis = @('REDIS_PORT')
    rabbitmq = @('RABBITMQ_PORT','RABBITMQ_MANAGEMENT_PORT')
    nacos = @('NACOS_PORT','NACOS_GRPC_PORT')
    minio = @('MINIO_API_PORT','MINIO_CONSOLE_PORT')
    elasticsearch = @('ELASTIC_PORT')
    mongodb = @('MONGO_PORT')
    'rocketmq-namesrv' = @('ROCKETMQ_NAMESRV_PORT')
    'rocketmq-broker' = @('ROCKETMQ_BROKER_PORT','ROCKETMQ_FAST_PORT','ROCKETMQ_PROXY_REMOTING_PORT','ROCKETMQ_PROXY_GRPC_PORT','ROCKETMQ_DASHBOARD_PORT')
    nginx = @('NGINX_PORT')
    'xxl-job' = @('XXL_JOB_PORT')
    kibana = @('KIBANA_PORT')
    'kibana-setup' = @()
    'rocketmq-dashboard' = @()
    postgresql = @('POSTGRES_PORT')
    mailpit = @('MAILPIT_SMTP_PORT','MAILPIT_WEB_PORT')
    prometheus = @('PROMETHEUS_PORT')
    grafana = @('GRAFANA_PORT')
    sentinel = @('SENTINEL_PORT')
    seata = @('SEATA_PORT','SEATA_CONSOLE_PORT')
    kafka = @('KAFKA_PORT')
}

function Initialize-Environment {
    $path = Join-Path $script:InfraRoot '.env'
    $template = Get-Content -LiteralPath (Join-Path $script:InfraRoot '.env.example') -Raw
    $stream = [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $existingBytes = New-Object byte[] ([int]$stream.Length)
        $null = $stream.Read($existingBytes, 0, $existingBytes.Length)
        $existing = [Text.Encoding]::UTF8.GetString($existingBytes)
        $present = @{}
        foreach ($line in $existing -split '\r?\n') {
            if ($line -match '^([A-Z][A-Z0-9_]*)=') { $present[$Matches[1]] = $true }
        }
        $missing = @()
        foreach ($line in $template -split '\r?\n') {
            if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { continue }
            $key = $Matches[1]; $value = $Matches[2]
            if ($present.ContainsKey($key)) { continue }
            if ($value -eq 'GENERATE') {
                $secretBytes = 24
                if ($key -eq 'XXL_JOB_PASSWORD') { $secretBytes = 10 }
                $randomBytes = New-Object byte[] $secretBytes
                $rng.GetBytes($randomBytes)
                $value = ([BitConverter]::ToString($randomBytes)).Replace('-','').ToLowerInvariant()
            }
            $missing += "$key=$value"
        }
        if (-not $missing.Count) { Write-Host '.env already complete; preserved.'; return }
        $prefix = ''
        if ($existing.Length -and -not $existing.EndsWith("`n")) { $prefix = "`r`n" }
        $content = $prefix + ($missing -join "`r`n") + "`r`n"
        $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($content)
        $null = $stream.Seek(0, [IO.SeekOrigin]::End)
        $stream.Write($bytes, 0, $bytes.Length)
        Write-Host ("Added {0} missing .env settings; existing values preserved. Secrets are not printed." -f $missing.Count)
    } finally { $stream.Dispose(); $rng.Dispose() }
}

function Read-Environment {
    $path = Join-Path $script:InfraRoot '.env'
    if (-not (Test-Path -LiteralPath $path)) { throw '[not-initialized] Run .\infra.ps1 Init first.' }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
            if ($values.ContainsKey($Matches[1])) { throw 'Duplicate key in .env.' }
            $values[$Matches[1]] = $Matches[2]
        } elseif ($line.Trim() -and -not $line.TrimStart().StartsWith('#')) { throw 'Invalid .env line; use KEY=value.' }
    }
    foreach ($key in ($script:SecretKeys + @('MYSQL_USER','RABBITMQ_DEFAULT_USER','MINIO_ROOT_USER','MONGO_ROOT_USER','POSTGRES_USER','POSTGRES_DB','GRAFANA_USER','XXL_JOB_USER','SENTINEL_USER','SEATA_USER','ROCKETMQ_DASHBOARD_USER'))) {
        if (-not $values.ContainsKey($key) -or $values[$key] -notmatch '^[A-Za-z0-9_-]{3,128}$' -or $values[$key] -eq 'GENERATE') { throw "Missing or invalid .env setting: $key" }
    }
    foreach ($key in $script:SecretKeys) {
        if ($values[$key].Length -lt 16) { throw "Use a password of at least 16 characters: $key" }
    }
    if ($values.XXL_JOB_PASSWORD.Length -gt 20) { throw 'XXL-JOB login passwords must be 16-20 characters.' }
    foreach ($key in @('KIBANA_SECURITY_KEY','KIBANA_SAVED_OBJECTS_KEY','KIBANA_REPORTING_KEY','SEATA_TOKEN_SECRET')) {
        if ($values[$key].Length -lt 32) { throw "Use at least 32 characters: $key" }
    }
    $ports = @()
    foreach ($key in @($script:ServicePorts.Values | ForEach-Object { $_ })) {
        $port = 0
        if (-not $values.ContainsKey($key) -or -not [int]::TryParse($values[$key], [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw "Invalid .env port: $key" }
        if ($ports -contains $port) { throw "Duplicate host port in .env: $key" }
        $ports += $port
    }
    if ([int]$values.NACOS_GRPC_PORT -ne ([int]$values.NACOS_PORT + 1000)) { throw 'NACOS_GRPC_PORT must equal NACOS_PORT + 1000.' }
    if ([int]$values.ROCKETMQ_FAST_PORT -ne ([int]$values.ROCKETMQ_BROKER_PORT - 2)) { throw 'ROCKETMQ_FAST_PORT must equal ROCKETMQ_BROKER_PORT - 2.' }
    if ([int]$values.ROCKETMQ_BROKER_PORT -gt 65534) { throw 'ROCKETMQ_BROKER_PORT must leave room for the internal HA port at broker port + 1.' }
    foreach ($key in @('ELASTIC_VERSION','MONGO_VERSION','ROCKETMQ_VERSION','NGINX_VERSION','POSTGRES_VERSION','MAILPIT_VERSION','PROMETHEUS_VERSION','GRAFANA_VERSION','XXL_JOB_VERSION','SENTINEL_VERSION','SEATA_VERSION','KAFKA_VERSION','ROCKETMQ_DASHBOARD_VERSION')) {
        if (-not $values.ContainsKey($key) -or $values[$key] -notmatch '^\d+\.\d+(\.\d+)?$') { throw "Use an explicit numeric image version for $key." }
    }
    $appPort = 0
    if (-not $values.ContainsKey('JAVA_APP_PORT') -or -not [int]::TryParse($values.JAVA_APP_PORT,[ref]$appPort) -or $appPort -lt 1 -or $appPort -gt 65535) { throw 'Invalid JAVA_APP_PORT.' }
    if ($ports -contains $appPort) { throw 'JAVA_APP_PORT conflicts with a published middleware port.' }
    $brokerIp = $null
    if (-not $values.ContainsKey('ROCKETMQ_BROKER_IP') -or -not [Net.IPAddress]::TryParse($values.ROCKETMQ_BROKER_IP, [ref]$brokerIp) -or $brokerIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'ROCKETMQ_BROKER_IP must be an IPv4 address reachable by the client.' }
    return $values
}

function Read-Stacks {
    $path = Join-Path $script:InfraRoot 'stacks.json'
    if (-not (Test-Path -LiteralPath $path)) { throw 'Missing stacks.json.' }
    $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($null -eq $result -or $result -isnot [pscustomobject]) { throw 'stacks.json must be a JSON object mapping names to service arrays.' }
    return $result
}

function Resolve-Services {
    if ($All -and ($Services.Count -or $Stack)) { throw 'Use -All by itself, or select -Services / -Stack.' }
    $selected = @($Services)
    if ($Stack) {
        $stacks = Read-Stacks
        $property = $stacks.PSObject.Properties[$Stack]
        if ($null -eq $property) { throw "Unknown stack: $Stack. Run .\infra.ps1 List." }
        if ($property.Value -isnot [array] -or -not $property.Value.Count) { throw "Stack $Stack must be a nonempty array of service names." }
        $selected += @($property.Value)
    }
    if ($All) { $selected = @($script:Catalog) }
    if (-not $selected.Count) {
        if ($Action -in @('Up','Logs')) { $selected = @('mysql','redis') }
        else { return @() }
    }
    $normalized = @()
    foreach ($entry in $selected) {
        # Also accepts a quoted CSV argument with powershell.exe -File.
        foreach ($item in ([string]$entry -split ',')) {
            $service = $item.Trim().ToLowerInvariant()
            switch ($service) { 'es' { $service = 'elasticsearch' }; 'mongo' { $service = 'mongodb' }; 'rmq' { $service = 'rocketmq' }; 'postgres' { $service = 'postgresql' }; 'pg' { $service = 'postgresql' }; 'xxljob' { $service = 'xxl-job' } }
            if ($service -notin $script:Catalog) { throw "Unknown service: $service. Run .\infra.ps1 List." }
            if ($service -notin $normalized) { $normalized += $service }
        }
    }
    return $normalized
}

function Expand-Services {
    param([string[]]$Selected)
    foreach ($service in $Selected) {
        if ($service -eq 'rocketmq') { 'rocketmq-namesrv'; 'rocketmq-broker' }
        elseif ($service -eq 'kibana') { 'kibana-setup'; 'kibana' }
        else { $service }
    }
}

function Add-ServiceDependencies {
    param([string[]]$Selected)
    $result = @()
    foreach ($service in $Selected) {
        if ($script:Dependencies.ContainsKey($service)) {
            foreach ($dependency in @(Add-ServiceDependencies $script:Dependencies[$service])) {
                if ($dependency -notin $result) { $result += $dependency }
            }
        }
        if ($service -notin $result) { $result += $service }
    }
    return $result
}

function Assert-StopSafe {
    param([string[]]$Selected)
    if (-not $Selected.Count) { return }
    $running = @(Get-ProjectContainers | Where-Object { $_.State.Running } | ForEach-Object { $_.Config.Labels.'com.docker.compose.service' })
    foreach ($dependent in $script:Dependencies.Keys) {
        if ($dependent -in $Selected -or $dependent -notin $running) { continue }
        foreach ($dependency in $script:Dependencies[$dependent]) {
            if ($dependency -in $Selected) { throw "[dependency-in-use] $dependent is running and depends on $dependency. Select both services to stop them together." }
        }
    }
}

function Show-Catalog {
    Write-Host ('Services: ' + ($script:Catalog -join ', '))
    Write-Host 'Aliases: es=elasticsearch, mongo=mongodb, rmq=rocketmq'
    Write-Host 'Stacks (edit stacks.json to add your project):'
    foreach ($property in (Read-Stacks).PSObject.Properties) {
        Write-Host ("  {0}: {1}" -f $property.Name, (@($property.Value) -join ', '))
    }
}

function Find-Docker {
    $command = Get-Command docker -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        foreach ($candidate in @((Join-Path $HOME '.docker/bin/docker'), (Join-Path $HOME '.rd/bin/docker'), '/usr/local/bin/docker', '/opt/homebrew/bin/docker', '/Applications/Docker.app/Contents/Resources/bin/docker')) {
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
        throw '[not-installed] Docker CLI was not found. Start Docker Desktop or Rancher Desktop (Moby), then reopen the terminal.'
    }
    $candidates = @(
        (Join-Path $env:USERPROFILE '.rd\bin\docker.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Rancher Desktop\resources\resources\win32\bin\docker.exe'),
        (Join-Path $env:ProgramFiles 'Rancher Desktop\resources\resources\win32\bin\docker.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe')
    )
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate) { return $candidate } }
    throw '[not-installed] Docker CLI was not found. Install/start the approved local container runtime.'
}

function Invoke-Docker {
    param([string[]]$Arguments, [string]$InputText)
    $previousPreference = $ErrorActionPreference
    $previousPath = $env:PATH
    $previousOutputEncoding = $OutputEncoding
    try {
        # Docker also launches credential helpers from PATH after a fresh runtime installation.
        $env:PATH = (Split-Path -Parent $script:DockerExe) + [IO.Path]::PathSeparator + $previousPath
        # Windows PowerShell treats native progress on stderr as ErrorRecord even for exit 0.
        $ErrorActionPreference = 'Continue'
        if ($PSBoundParameters.ContainsKey('InputText')) {
            $OutputEncoding = New-Object Text.UTF8Encoding $false
            $result = @($InputText | & $script:DockerExe @Arguments 2>&1)
        } else { $result = @(& $script:DockerExe @Arguments 2>&1) }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference; $env:PATH = $previousPath; $OutputEncoding = $previousOutputEncoding }
    if ($code -ne 0) {
        $diagnostic = $result -join "`n"
        $envFile = Join-Path $script:InfraRoot '.env'
        if (Test-Path -LiteralPath $envFile) {
            foreach ($line in Get-Content -LiteralPath $envFile) {
                if ($line -match '^[A-Z0-9_]*(PASSWORD|PASS|TOKEN|SECRET|KEY)[A-Z0-9_]*=(.+)$') {
                    $diagnostic = $diagnostic.Replace($Matches[2], '[redacted]')
                }
            }
        }
        throw "Docker command failed (exit $code): $($Arguments[0]). $diagnostic"
    }
    return ($result -join "`n")
}

function Assert-LocalEndpoint {
    param([string]$Endpoint)
    # A named pipe can only target this Windows computer; allow the local Unix socket for Linux/WSL CLIs.
    if ($Endpoint -match '^npipe:////\./pipe/[A-Za-z0-9_.-]+$' -or $Endpoint -match '^unix:///[^\r\n]+$') { return }
    $uri = $null
    if ([Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -in @('tcp','http','https') -and $uri.Host -in @('localhost','127.0.0.1','[::1]','::1')) { return }
    throw '[non-local-context] Refusing Docker endpoint outside this computer.'
}

function Connect-LocalDocker {
    $script:DockerExe = Find-Docker
    if ($env:DOCKER_CONTEXT) {
        $context = $env:DOCKER_CONTEXT
        $endpoint = Invoke-Docker @('context','inspect',$context,'--format','{{.Endpoints.docker.Host}}')
    } elseif ($env:DOCKER_HOST) {
        $endpoint = $env:DOCKER_HOST
    } else {
        $context = (Invoke-Docker @('context','show')).Trim()
        $endpoint = Invoke-Docker @('context','inspect',$context,'--format','{{.Endpoints.docker.Host}}')
    }
    Assert-LocalEndpoint $endpoint.Trim()
    try { $null = Invoke-Docker @('info','--format','{{.ServerVersion}}') }
    catch { throw '[engine-offline] Local Docker CLI exists but the engine is unavailable.' }
    $null = Invoke-Docker @('compose','version','--short')
}

function Invoke-Compose {
    param([string[]]$Arguments)
    # Explicit project, file and env prevent accidental selection through COMPOSE_* variables.
    $values = Read-Environment
    $saved = @{}
    try {
        # Compose gives shell variables priority over --env-file; the local file is authoritative here.
        foreach ($key in $values.Keys) {
            $saved[$key] = [Environment]::GetEnvironmentVariable($key, 'Process')
            Remove-Item -LiteralPath ('Env:\' + $key) -ErrorAction SilentlyContinue
        }
        return Invoke-Docker (@('compose','--project-name','dev-infra','--project-directory',$script:InfraRoot,'--env-file',(Join-Path $script:InfraRoot '.env'),'-f',(Join-Path $script:InfraRoot 'compose.yaml')) + $Arguments)
    } finally {
        foreach ($key in $saved.Keys) {
            if ($null -eq $saved[$key]) { Remove-Item -LiteralPath ('Env:\' + $key) -ErrorAction SilentlyContinue }
            else { [Environment]::SetEnvironmentVariable($key, $saved[$key], 'Process') }
        }
    }
}

function Get-ProjectContainers {
    $ids = Invoke-Docker @('ps','-aq','--filter','label=com.docker.compose.project=dev-infra')
    if (-not $ids.Trim()) { return @() }
    $json = Invoke-Docker (@('inspect') + @($ids -split '\r?\n'))
    # Windows PowerShell 5.1 emits a JSON array as one pipeline object.
    # Explicitly enumerate it so port ownership and dependency guards see containers.
    foreach ($container in (ConvertFrom-Json $json)) { $container }
}

function Invoke-ComposeUp {
    param([string[]]$Selected, [int]$TimeoutSeconds = 300)
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $null = Invoke-Compose (@('up','-d','--wait','--wait-timeout',[string]$TimeoutSeconds) + $Selected)
            return
        } catch {
            $message = $_.Exception.Message
            $networkFailure = $message -match '(?i)\bEOF\b|TLS handshake timeout|connection reset|i/o timeout|Client\.Timeout|temporary failure in name resolution'
            $registryOperation = $message -match '(?i)registry|docker\.io|pull|manifest|failed to (fetch|resolve)'
            if ($attempt -eq 3 -or -not $networkFailure -or -not $registryOperation) { throw }
            Write-Host ("[network-retry] Registry connection interrupted. Retrying {0}/3; downloaded layers are reused." -f ($attempt + 1))
            Start-Sleep -Seconds ($attempt * 2)
        }
    }
}

function Assert-PortsAvailable {
    param([hashtable]$Values, [string[]]$Selected)
    $containers = @(Get-ProjectContainers)
    foreach ($service in $Selected) {
        foreach ($key in $script:ServicePorts[$service]) {
            $port = [int]$Values[$key]
            $owned = $false
            foreach ($container in $containers) {
                if (-not $container.State.Running -or $container.Config.Labels.'com.docker.compose.service' -ne $service) { continue }
                foreach ($binding in $container.NetworkSettings.Ports.PSObject.Properties) {
                    foreach ($mapping in @($binding.Value)) {
                        if ($mapping -and $mapping.HostIp -eq '127.0.0.1' -and [int]$mapping.HostPort -eq $port) { $owned = $true }
                    }
                }
            }
            if ($owned) { continue }
            $listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback), $port
            try { $listener.Start() }
            catch { throw "[port-in-use] Host port $port for $service is unavailable. Change $key in .env or stop its owner." }
            finally { $listener.Stop() }
        }
    }
}

function Show-Doctor {
    param([string[]]$Selected = @())
    $containers = @(Get-ProjectContainers)
    if ($Selected.Count) {
        $containers = @($containers | Where-Object { $_.Config.Labels.'com.docker.compose.service' -in $Selected })
    }
    if ($containers.Count -eq 0) { Write-Host '[ready] Local engine and Compose available; no containers found for this selection.'; return }
    $bad = @()
    foreach ($container in $containers) {
        $service = $container.Config.Labels.'com.docker.compose.service'
        $health = $container.State.Status
        if ($container.State.Running -and $container.State.PSObject.Properties.Name -contains 'Health') { $health = $container.State.Health.Status }
        Write-Host ("{0}: {1}" -f $service, $health)
        if ($container.State.Running -and $health -ne 'healthy') { $bad += $service }
    }
    if ($bad.Count) { throw '[container-unhealthy] One or more running containers are unhealthy or still starting.' }
    Write-Host '[ready] Running containers are healthy. Stopped services remain stopped.'
}

function Initialize-XxlJobDatabase {
    param([hashtable]$Values)
    # Reuse the running MySQL container. No extra database server or helper container.
    $id = (Invoke-Compose @('ps','-q','mysql')).Trim()
    if (-not $id) { throw 'XXL-JOB requires the existing local MySQL service.' }
    $mysqlArguments = @('exec','-i',$id,'sh','-ec','MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot --default-character-set=utf8mb4 --batch --skip-column-names')
    $countText = Invoke-Docker -Arguments $mysqlArguments -InputText "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='devinfra_xxl_job';"
    $tableCount = 0
    if (-not [int]::TryParse($countText.Trim(),[ref]$tableCount)) { throw 'Cannot inspect the dedicated XXL-JOB database.' }
    $sql = "CREATE DATABASE IF NOT EXISTS devinfra_xxl_job CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;`n"
    $sql += "CREATE USER IF NOT EXISTS 'dev_xxl_job'@'%' IDENTIFIED BY '$($Values.XXL_JOB_DB_PASSWORD)';`n"
    $sql += 'GRANT ALL PRIVILEGES ON `devinfra\_xxl\_job`.* TO ''dev_xxl_job''@''%'';' + "`n"
    if ($tableCount -eq 0) {
        $sql += Get-Content -LiteralPath (Join-Path $script:InfraRoot 'xxl-job/schema.sql') -Raw -Encoding UTF8
        $sql += "`nINSERT INTO devinfra_xxl_job.xxl_job_user (id,username,password,role,permission,token) VALUES (1,'$($Values.XXL_JOB_USER)',LOWER(SHA2('$($Values.XXL_JOB_PASSWORD)',256)),1,NULL,NULL);`n"
    } else {
        # Validate against the actual versioned schema table names instead of assuming an empty DB.
        $schemaText = Get-Content -LiteralPath (Join-Path $script:InfraRoot 'xxl-job/schema.sql') -Raw -Encoding UTF8
        $tableNames = @([regex]::Matches($schemaText, 'CREATE TABLE\s+`([^`]+)`') | ForEach-Object { "'" + $_.Groups[1].Value + "'" })
        $expected = $tableNames -join ','
        $matching = Invoke-Docker -Arguments $mysqlArguments -InputText "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='devinfra_xxl_job' AND table_name IN ($expected);"
        if ([int]$matching.Trim() -ne $tableNames.Count) { throw 'Existing devinfra_xxl_job schema is incomplete or a different version; preserved without importing SQL.' }
    }
    $null = Invoke-Docker -Arguments $mysqlArguments -InputText $sql
    Write-Host 'XXL-JOB uses the existing MySQL container and its dedicated devinfra_xxl_job database; existing tables/accounts preserved.'
}

function Initialize-DashboardCredentials {
    param([hashtable]$Values)
    $directory = Join-Path $script:InfraRoot '.runtime/rocketmq-dashboard'
    $null = New-Item -ItemType Directory -Path $directory -Force
    $content = "$($Values.ROCKETMQ_DASHBOARD_USER)=$($Values.ROCKETMQ_DASHBOARD_PASSWORD),1`n"
    [IO.File]::WriteAllText((Join-Path $directory 'users.properties'),$content,(New-Object Text.UTF8Encoding $false))
}

function Invoke-Infra {
    if ($Action -eq 'Init') { Initialize-Environment; return }
    if ($Action -eq 'List') { Show-Catalog; return }
    $selected = @(Resolve-Services)
    if ($Action -eq 'Up') { $selected = @(Add-ServiceDependencies $selected) }
    $expanded = @(Expand-Services $selected)
    Connect-LocalDocker
    if ($Action -eq 'Doctor') { Show-Doctor $expanded; return }
    if ($Action -eq 'Up') { Initialize-Environment }
    $values = Read-Environment
    switch ($Action) {
        'Up' {
            Assert-PortsAvailable $values $expanded
            if ('rocketmq-dashboard' -in $selected) { Initialize-DashboardCredentials $values }
            if ('xxl-job' -in $selected) {
                Invoke-ComposeUp @('mysql') $WaitTimeout
                Initialize-XxlJobDatabase $values
            }
            Write-Host ('Starting: ' + ($selected -join ', ') + '. First use downloads missing images; please wait.')
            Invoke-ComposeUp $expanded $WaitTimeout
            Write-Host ('Healthy: ' + ($selected -join ', '))
        }
        # Retain IP assignments: Rancher 1.24 can retain stale forwarding rules after recreation.
        { $_ -in @('Stop','Down') } {
            Assert-StopSafe $selected
            $null = Invoke-Compose (@('--profile','*','stop') + $expanded)
            $label = 'all dev-infra services'
            if ($selected.Count) { $label = $selected -join ', ' }
            Write-Host ("Stopped: $label. Containers, network and data volumes are preserved.")
        }
        'Status' { Write-Output (Invoke-Compose (@('--profile','*','ps','-a') + $expanded)) }
        'Logs' {
            $output = Invoke-Compose (@('--profile','*','logs','--tail',[string]$Tail) + $expanded)
            foreach ($key in $script:SecretKeys) { $output = $output.Replace($values[$key], '[redacted]') }
            Write-Output $output
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-Infra }
    catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
}
