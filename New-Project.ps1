<#
.SYNOPSIS
Register one project's isolated middleware names and generate local connection files.
.EXAMPLE
.\New-Project.ps1 -Name demo -Databases demo_app,demo_jobs -RedisDatabase 1
.NOTES
Reads the local .env created by infra.ps1 Init. projects/<name>.json contains no credentials.
Private .env and init-mysql.sql live under ignored .runtime/projects/<name>/.
SQL only creates the named databases and project user, then grants schema-scoped privileges.
This script never connects to Docker, MySQL, Redis or any remote service and never executes SQL.
Apply the generated SQL only to the new local development MySQL instance after review.
Existing registrations and passwords are preserved; mismatching registration arguments fail.
RabbitMQ vhost, MinIO bucket and Nacos namespace are registered names, not provisioned resources.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('(?-i)^[a-z](?:[a-z0-9-]{0,22}[a-z0-9])?$')]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Databases,
    [ValidateRange(0,15)]
    [Nullable[int]]$RedisDatabase
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProjectInfraRoot = $PSScriptRoot
$script:RequestedRedis = $PSBoundParameters.ContainsKey('RedisDatabase')

function Register-DevelopmentProject {
    $schemas = @($Databases | Sort-Object)
    if ($schemas.Count -eq 0) { throw 'Pass at least one explicit database name.' }
    foreach ($schema in $schemas) {
        if ($schema -cnotmatch '^[a-z][a-z0-9_]{0,63}$') { throw 'Database names must be lowercase SQL identifiers of at most 64 characters.' }
        if ($schema -in @('mysql','information_schema','performance_schema','sys')) { throw 'System databases cannot be registered to a development project.' }
    }
    if (@($schemas | Select-Object -Unique).Count -ne $schemas.Count) { throw 'Duplicate database name in the request.' }
    $runtime = Join-Path $script:ProjectInfraRoot '.runtime'
    $registry = Join-Path $script:ProjectInfraRoot 'projects'
    $null = New-Item -ItemType Directory -Path $runtime -Force
    # One short local file lock prevents simultaneous registrations choosing the same Redis index.
    $lock = [IO.File]::Open((Join-Path $runtime 'project-registration.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $registrations = @()
        if (Test-Path -LiteralPath $registry) {
            foreach ($file in Get-ChildItem -LiteralPath $registry -Filter '*.json' -File) {
                $item = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                foreach ($field in @('Name','Databases','RedisDatabase','RabbitVhost','MinioBucket','NacosNamespace')) {
                    if ($item.PSObject.Properties.Name -notcontains $field) { throw 'Invalid project registration; refusing to allocate resources.' }
                }
                $registrations += $item
            }
        }
        $existing = @($registrations | Where-Object { $_.Name -eq $Name })
        if ($existing.Count -gt 1) { throw 'Duplicate project registration; resolve it before continuing.' }
        $projectDir = Join-Path (Join-Path $runtime 'projects') $Name
        if ($existing.Count -eq 1) {
            $record = $existing[0]
            if ((@($record.Databases | Sort-Object) -join ',') -ne ($schemas -join ',') -or ($script:RequestedRedis -and [int]$record.RedisDatabase -ne [int]$RedisDatabase)) {
                throw 'Existing project registration differs from the request; no files were overwritten.'
            }
            foreach ($file in @('.env','init-mysql.sql')) {
                if (-not (Test-Path -LiteralPath (Join-Path $projectDir $file) -PathType Leaf)) { throw 'Project private files are missing; restore them instead of silently replacing a database password.' }
            }
            Write-Host ("Preserved existing registration and credentials: {0}" -f $Name)
            return
        }
        foreach ($item in $registrations) {
            foreach ($schema in $schemas) {
                if (@($item.Databases) -contains $schema) { throw "Database is already registered to another project: $schema" }
            }
        }
        if ($script:RequestedRedis) { $index = [int]$RedisDatabase }
        else {
            $index = -1
            foreach ($candidate in 1..15) {
                if (@($registrations | Where-Object { [int]$_.RedisDatabase -eq $candidate }).Count -eq 0) { $index = $candidate; break }
            }
            if ($index -eq -1) { throw 'All Redis database indices 1..15 are registered; request an explicit free index.' }
        }
        if (@($registrations | Where-Object { [int]$_.RedisDatabase -eq $index }).Count) { throw 'Redis database index is already registered to another project.' }
        if (Test-Path -LiteralPath $projectDir) { throw 'Unregistered private project directory exists; review it before creating a registration.' }
        $basePath = Join-Path $script:ProjectInfraRoot '.env'
        if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) { throw 'Run infra.ps1 Init first; the local .env is missing.' }
        $values = @{}
        foreach ($line in Get-Content -LiteralPath $basePath) {
            if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
                if ($values.ContainsKey($Matches[1])) { throw 'Duplicate setting in the base .env.' }
                $values[$Matches[1]] = $Matches[2]
            } elseif ($line.Trim() -and -not $line.TrimStart().StartsWith('#')) { throw 'Invalid base .env line.' }
        }
        $keys = @('MYSQL_PORT','REDIS_PORT','REDIS_PASSWORD','RABBITMQ_PORT','RABBITMQ_MANAGEMENT_PORT','RABBITMQ_DEFAULT_USER','RABBITMQ_DEFAULT_PASS','NACOS_PORT','NACOS_GRPC_PORT','MINIO_API_PORT','MINIO_CONSOLE_PORT','MINIO_ROOT_USER','MINIO_ROOT_PASSWORD')
        foreach ($key in $keys) {
            if (-not $values.ContainsKey($key) -or $values[$key] -notmatch '^[A-Za-z0-9_-]+$' -or $values[$key] -eq 'GENERATE') { throw "Missing or invalid base .env setting: $key" }
        }
        $bytes = New-Object byte[] 24
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        $password = ([BitConverter]::ToString($bytes)).Replace('-','').ToLowerInvariant()
        $mysqlUser = $Name.Replace('-','_') + '_dev'
        $resourceName = $Name + '-development'
        $record = [ordered]@{
            Name = $Name; Databases = $schemas; RedisDatabase = $index
            RabbitVhost = $resourceName; MinioBucket = $resourceName; NacosNamespace = $resourceName
        }
        $lines = @('# Generated local project credentials; do not commit or share.', 'MYSQL_HOST=127.0.0.1', ('MYSQL_USER=' + $mysqlUser), ('MYSQL_PASSWORD=' + $password))
        foreach ($key in $keys) { $lines += $key + '=' + $values[$key] }
        $lines += @('REDIS_HOST=127.0.0.1', ('REDIS_DATABASE=' + $index), 'RABBITMQ_HOST=127.0.0.1', ('RABBITMQ_VHOST=' + $resourceName), ('MINIO_BUCKET=' + $resourceName), ('NACOS_NAMESPACE=' + $resourceName))
        $sql = @('-- Generated only. Review and execute exclusively in the new local development MySQL instance.', '-- Existing users keep their passwords. No remote database is contacted by this generator.')
        foreach ($schema in $schemas) { $sql += ('CREATE DATABASE IF NOT EXISTS `{0}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;' -f $schema) }
        $sql += ("CREATE USER IF NOT EXISTS '{0}'@'%' IDENTIFIED BY '{1}';" -f $mysqlUser, $password)
        # MySQL interprets underscores as wildcards in schema-level GRANT, even within backticks.
        foreach ($schema in $schemas) { $sql += ('GRANT ALL PRIVILEGES ON `{0}`.* TO ''{1}''@''%'';' -f $schema.Replace('_','\_'), $mysqlUser) }
        $null = New-Item -ItemType Directory -Path $projectDir
        $null = New-Item -ItemType Directory -Path $registry -Force
        $utf8 = New-Object Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $projectDir '.env'), (($lines -join "`r`n") + "`r`n"), $utf8)
        [IO.File]::WriteAllText((Join-Path $projectDir 'init-mysql.sql'), (($sql -join "`r`n") + "`r`n"), $utf8)
        [IO.File]::WriteAllText((Join-Path $registry ($Name + '.json')), (($record | ConvertTo-Json -Depth 4) + "`r`n"), $utf8)
        Write-Host ("Registered {0}; Redis DB {1}. Private .env and unexecuted SQL: {2}" -f $Name, $index, $projectDir)
    } finally { $lock.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Register-DevelopmentProject }
    catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
}
