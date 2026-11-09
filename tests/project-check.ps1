[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('dev-project-selfcheck-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temp
function Assert { param([bool]$Condition, [string]$Message); if (-not $Condition) { throw $Message } }
function Must-Fail { param([scriptblock]$Code); $failed = $false; try { & $Code } catch { $failed = $true }; Assert $failed 'Expected registration conflict to fail.' }
try {
    Copy-Item -LiteralPath (Join-Path $root 'New-Project.ps1') -Destination $temp
    Copy-Item -LiteralPath (Join-Path $root '.env.example') -Destination $temp
    Copy-Item -LiteralPath (Join-Path $root 'infra.ps1') -Destination $temp
    & (Join-Path $temp 'infra.ps1') Init
    . (Join-Path $temp 'New-Project.ps1') -Name alpha -Databases alpha_db -RedisDatabase 1
    Register-DevelopmentProject
    $alphaEnv = Join-Path $temp '.runtime/projects/alpha/.env'
    $first = [IO.File]::ReadAllText($alphaEnv)
    Register-DevelopmentProject
    Assert ([IO.File]::ReadAllText($alphaEnv) -eq $first) 'Repeated registration must preserve passwords and files.'
    . (Join-Path $temp 'New-Project.ps1') -Name beta -Databases beta_db
    Register-DevelopmentProject
    $beta = Get-Content (Join-Path $temp 'projects/beta.json') -Raw | ConvertFrom-Json
    Assert ($beta.RedisDatabase -eq 2) 'Second project must receive the first free Redis DB.'
    $second = [IO.File]::ReadAllText((Join-Path $temp '.runtime/projects/beta/.env'))
    $alphaPassword = [regex]::Match($first, '(?m)^MYSQL_PASSWORD=(.+)$').Groups[1].Value
    $betaPassword = [regex]::Match($second, '(?m)^MYSQL_PASSWORD=(.+)$').Groups[1].Value
    Assert ($alphaPassword -ne $betaPassword) 'Project MySQL passwords must differ.'
    foreach ($test in @(
        @{Name='alpha'; Databases=@('changed_db'); RedisDatabase=1},
        @{Name='gamma'; Databases=@('alpha_db'); RedisDatabase=3},
        @{Name='gamma'; Databases=@('gamma_db'); RedisDatabase=1}
    )) {
        . (Join-Path $temp 'New-Project.ps1') @test
        Must-Fail { Register-DevelopmentProject }
    }
    Must-Fail { . (Join-Path $temp 'New-Project.ps1') -Name 'Uppercase' -Databases upper_db }
    . (Join-Path $temp 'New-Project.ps1') -Name gamma -Databases 'UppercaseDb'
    Must-Fail { Register-DevelopmentProject }
    $metadata = Get-Content (Join-Path $temp 'projects/alpha.json') -Raw
    Assert ($metadata -notmatch '(?i)password|secret|root_user') 'Public registration must not contain credentials.'
    $sql = Get-Content (Join-Path $temp '.runtime/projects/alpha/init-mysql.sql') -Raw
    Assert ($sql -notmatch '(?i)\bDROP\b|ALTER\s+USER|ON\s+\*\.\*') 'Generated SQL must not drop data, rotate users or grant global privileges.'
    Assert ($sql.Contains('CREATE DATABASE IF NOT EXISTS `alpha_db`') -and $sql.Contains('CREATE USER IF NOT EXISTS') -and $sql.Contains('GRANT ALL PRIVILEGES ON `alpha\_db`.*')) 'Expected only the explicit project schema and user, with SQL wildcard escaping.'
    Write-Host 'PASS: two isolated projects, automatic Redis allocation, independent passwords, idempotence and database/Redis/argument conflicts.'
} finally {
    $resolved = [IO.Path]::GetFullPath($temp)
    $expectedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($expectedRoot, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'dev-project-selfcheck-*') { throw 'Unsafe self-check cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
