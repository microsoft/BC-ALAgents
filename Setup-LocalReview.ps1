<#
.SYNOPSIS
    Check or install the prerequisites for running the BC AL reviewer locally.

.DESCRIPTION
    By default, this script only checks the machine and reports missing
    prerequisites. Pass -Install to install missing tools on Windows with
    WinGet, install the Copilot CLI with npm, install powershell-yaml from the
    PowerShell Gallery, and authenticate GitHub interactively when needed.

.PARAMETER Install
    Install missing prerequisites. Without this switch, no machine state is
    changed.

.PARAMETER SkipAuthentication
    Do not start an interactive `gh auth login` when GitHub authentication is
    missing. GH_TOKEN is accepted as an alternative to a GitHub CLI login.

.EXAMPLE
    .\Setup-LocalReview.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Setup-LocalReview.ps1 -Install
#>
[CmdletBinding()]
param(
    [switch] $Install,
    [switch] $SkipAuthentication
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-CommandAvailable {
    param([Parameter(Mandatory)][string] $Name)

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Update-ProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $pathParts = @($machinePath, $userPath) |
        Where-Object { $_ } |
        ForEach-Object { $_.TrimEnd(';') }
    $env:Path = [string]::Join(';', $pathParts)
}

function Install-WinGetPackage {
    param(
        [Parameter(Mandatory)][string] $Id,
        [Parameter(Mandatory)][string] $DisplayName
    )

    Write-Host "[setup] Installing $DisplayName..."
    & winget install --id $Id --exact --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet failed to install $DisplayName (exit $LASTEXITCODE)."
    }
    Update-ProcessPath
}

function Get-PwshPath {
    $command = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    $defaultPath = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    if (Test-Path -LiteralPath $defaultPath) { return $defaultPath }
    return $null
}

function Test-GitHubAuthentication {
    if ($env:GH_TOKEN) { return $true }
    if (-not (Test-CommandAvailable -Name gh)) { return $false }

    & gh auth token 1>$null 2>$null
    return $LASTEXITCODE -eq 0
}

function Write-DependencyStatus {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][bool] $Available,
        [string] $Details
    )

    $state = if ($Available) { 'OK' } else { 'MISSING' }
    $suffix = if ($Details) { " ($Details)" } else { '' }
    Write-Host ("[{0,-7}] {1}{2}" -f $state, $Name, $suffix)
}

$runningOnWindows = $env:OS -eq 'Windows_NT'
if ($Install -and -not $runningOnWindows) {
    throw 'Automatic installation currently supports Windows only. Run without -Install to check dependencies.'
}

$nativeDependencies = @(
    [pscustomobject]@{ Command = 'git'; Name = 'Git'; WinGetId = 'Git.Git' }
    [pscustomobject]@{ Command = 'pwsh'; Name = 'PowerShell 7+'; WinGetId = 'Microsoft.PowerShell' }
    [pscustomobject]@{ Command = 'node'; Name = 'Node.js'; WinGetId = 'OpenJS.NodeJS.LTS' }
    [pscustomobject]@{ Command = 'npm'; Name = 'npm'; WinGetId = 'OpenJS.NodeJS.LTS' }
    [pscustomobject]@{ Command = 'gh'; Name = 'GitHub CLI'; WinGetId = 'GitHub.cli' }
)

if ($Install) {
    if (-not (Test-CommandAvailable -Name winget)) {
        throw 'WinGet is required for automatic installation. Install or update App Installer from Microsoft Store.'
    }

    foreach ($dependency in $nativeDependencies) {
        if (-not (Test-CommandAvailable -Name $dependency.Command)) {
            Install-WinGetPackage -Id $dependency.WinGetId -DisplayName $dependency.Name
        }
    }

    $pwshPath = Get-PwshPath
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        if (-not $pwshPath) {
            throw 'PowerShell 7 was installed but pwsh.exe could not be located. Open a new terminal and rerun this script.'
        }

        Write-Host '[setup] Continuing setup in PowerShell 7...'
        $arguments = @('-NoProfile', '-File', $PSCommandPath, '-Install')
        if ($SkipAuthentication) { $arguments += '-SkipAuthentication' }
        & $pwshPath @arguments
        exit $LASTEXITCODE
    }

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Write-Host '[setup] Installing powershell-yaml...'
        Install-Module powershell-yaml -Scope CurrentUser -Force -AllowClobber
    }

    if (-not (Test-CommandAvailable -Name copilot)) {
        Write-Host '[setup] Installing GitHub Copilot CLI...'
        & npm install --global '@github/copilot'
        if ($LASTEXITCODE -ne 0) {
            throw "npm failed to install GitHub Copilot CLI (exit $LASTEXITCODE)."
        }
        Update-ProcessPath
    }

    if (-not $SkipAuthentication -and -not (Test-GitHubAuthentication)) {
        Write-Host '[setup] Starting GitHub authentication...'
        & gh auth login
        if ($LASTEXITCODE -ne 0) {
            throw "GitHub authentication failed (exit $LASTEXITCODE)."
        }
    }
}

$statuses = [System.Collections.Generic.List[object]]::new()
foreach ($dependency in $nativeDependencies) {
    $available = Test-CommandAvailable -Name $dependency.Command
    $statuses.Add([pscustomobject]@{
        Name = $dependency.Name
        Available = $available
        Details = if ($available) { (& $dependency.Command --version 2>$null | Select-Object -First 1) } else { $null }
    })
}

$pwshVersionValid = $false
$pwshDetails = $null
$pwshPath = Get-PwshPath
if ($pwshPath) {
    $pwshDetails = (& $pwshPath -NoProfile -Command '$PSVersionTable.PSVersion.ToString()').Trim()
    $pwshVersionValid = [version]$pwshDetails -ge [version]'7.0'
}
$statuses | Where-Object Name -eq 'PowerShell 7+' | ForEach-Object {
    $_.Available = $pwshVersionValid
    $_.Details = $pwshDetails
}

$module = Get-Module -ListAvailable -Name powershell-yaml |
    Sort-Object Version -Descending |
    Select-Object -First 1
$statuses.Add([pscustomobject]@{
    Name = 'powershell-yaml module'
    Available = $null -ne $module
    Details = if ($module) { $module.Version.ToString() } else { $null }
})

$copilotAvailable = Test-CommandAvailable -Name copilot
$statuses.Add([pscustomobject]@{
    Name = 'GitHub Copilot CLI'
    Available = $copilotAvailable
    Details = if ($copilotAvailable) { (& copilot --version 2>$null | Select-Object -First 1) } else { $null }
})

$authenticated = Test-GitHubAuthentication
$statuses.Add([pscustomobject]@{
    Name = 'GitHub authentication'
    Available = $authenticated
    Details = if ($env:GH_TOKEN) { 'GH_TOKEN' } elseif ($authenticated) { 'gh auth' } else { $null }
})

Write-Host ''
Write-Host 'Local reviewer prerequisites'
Write-Host '----------------------------'
foreach ($status in $statuses) {
    Write-DependencyStatus -Name $status.Name -Available $status.Available -Details $status.Details
}

$missing = @($statuses | Where-Object { -not $_.Available })
if ($missing.Count -gt 0) {
    Write-Host ''
    if ($Install) {
        Write-Error "$($missing.Count) prerequisite(s) remain missing."
    }
    else {
        Write-Host "Run '.\Setup-LocalReview.ps1 -Install' to install missing prerequisites."
    }
    exit 1
}

Write-Host ''
Write-Host 'The machine is ready to run the local BC AL reviewer.'
