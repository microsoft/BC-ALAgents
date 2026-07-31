<#
.SYNOPSIS
    Apply mechanical suggested-code replacements from a local AL review.

.DESCRIPTION
    Reads the existing _review-report.json and applies only findings whose
    suggested-code is a literal replacement for a valid contiguous line range.
    No Copilot process is launched and the review is not rerun.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepoPath,
    [string] $ReportPath,
    [ValidateSet('Critical', 'High', 'Medium', 'Low')][string] $MinimumSeverity = 'Medium',
    [string] $ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TextFile {
    param([Parameter(Mandatory)][string] $Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    $encoding = [Text.UTF8Encoding]::new($false)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
        $encoding = [Text.UTF8Encoding]::new($true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $offset = 2
        $encoding = [Text.UnicodeEncoding]::new($false, $true)
    }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $offset = 2
        $encoding = [Text.UnicodeEncoding]::new($true, $true)
    }

    return [pscustomobject]@{
        text     = $encoding.GetString($bytes, $offset, $bytes.Length - $offset)
        encoding = $encoding
    }
}

function Get-SuggestedCodeProperty {
    param([Parameter(Mandatory)][object] $Finding)

    foreach ($name in @('suggested-code', 'suggested_code', 'suggestedCode', 'suggestion')) {
        $property = $Finding.PSObject.Properties[$name]
        if ($null -ne $property -and
            $null -ne $property.Value -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return $property
        }
    }
    return $null
}

function Resolve-SafeRepoFilePath {
    param(
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][string] $RelativeFile
    )

    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $repoPrefix = $RepoPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    $relativePath = $RelativeFile.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $filePath = [IO.Path]::GetFullPath((Join-Path $RepoPath $relativePath))
    if (-not $filePath.StartsWith($repoPrefix, $comparison)) {
        throw "Path points outside RepoPath: $RelativeFile"
    }

    $current = $RepoPath
    foreach ($segment in $relativePath.Split(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries
    )) {
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Path contains a symbolic link or junction: $RelativeFile"
            }
        }
    }
    return $filePath
}

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
if (-not $ReportPath) {
    $ReportPath = Join-Path $RepoPath '.bc-review/_review-report.json'
}
$ReportPath = (Resolve-Path -LiteralPath $ReportPath).Path
if (-not $ResultPath) {
    $ResultPath = Join-Path (Split-Path -Parent $ReportPath) '_fix-results.json'
}

$report = Get-Content -LiteralPath $ReportPath -Raw | ConvertFrom-Json
$findingsProperty = $report.PSObject.Properties['findings']
$findings = if ($null -ne $findingsProperty -and $null -ne $findingsProperty.Value) {
    @($findingsProperty.Value)
}
else {
    @()
}
$severityRank = @{
    blocker = 4
    major   = 3
    minor   = 2
    info    = 1
}
$minimumRank = @{
    Critical = 4
    High     = 3
    Medium   = 2
    Low      = 1
}[$MinimumSeverity]

$reportTime = (Get-Item -LiteralPath $ReportPath).LastWriteTimeUtc
$plans = [Collections.Generic.List[object]]::new()
$skipped = [Collections.Generic.List[object]]::new()

foreach ($finding in $findings) {
    $idProperty = $finding.PSObject.Properties['id']
    $findingId = if ($null -ne $idProperty) { [string]$idProperty.Value } else { '(unknown)' }
    $severityProperty = $finding.PSObject.Properties['severity']
    if ($null -eq $severityProperty -or [string]::IsNullOrWhiteSpace([string]$severityProperty.Value)) {
        $skipped.Add([pscustomobject]@{ id = $findingId; reason = 'missing-severity' })
        continue
    }
    $rank = $severityRank[([string]$severityProperty.Value).ToLowerInvariant()]
    if ($null -eq $rank -or $rank -lt $minimumRank) {
        continue
    }

    $suggestion = Get-SuggestedCodeProperty -Finding $finding
    if ($null -eq $suggestion) {
        $skipped.Add([pscustomobject]@{ id = $findingId; reason = 'no-suggested-code' })
        continue
    }
    $locationProperty = $finding.PSObject.Properties['location']
    if ($null -eq $locationProperty -or $null -eq $locationProperty.Value) {
        $skipped.Add([pscustomobject]@{ id = $findingId; reason = 'missing-location' })
        continue
    }
    $location = $locationProperty.Value
    $fileProperty = $location.PSObject.Properties['file']
    if ($null -eq $fileProperty -or [string]::IsNullOrWhiteSpace([string]$fileProperty.Value)) {
        $skipped.Add([pscustomobject]@{ id = $findingId; reason = 'missing-location' })
        continue
    }

    $relativeFile = [string]$fileProperty.Value
    $filePath = Resolve-SafeRepoFilePath -RepoPath $RepoPath -RelativeFile $relativeFile
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
        $skipped.Add([pscustomobject]@{ id = $findingId; reason = 'file-not-found' })
        continue
    }

    $lineProperty = $location.PSObject.Properties['line']
    $rangeProperty = $location.PSObject.Properties['range']
    if ($null -ne $rangeProperty -and $null -ne $rangeProperty.Value) {
        $startLine = [int]$rangeProperty.Value.'start-line'
        $endLine = [int]$rangeProperty.Value.'end-line'
    }
    elseif ($null -ne $lineProperty -and $null -ne $lineProperty.Value) {
        $startLine = [int]$lineProperty.Value
        $endLine = $startLine
    }
    else {
        $skipped.Add([pscustomobject]@{ id = $findingId; reason = 'missing-line-range' })
        continue
    }
    if ($startLine -lt 1 -or $endLine -lt $startLine) {
        $skipped.Add([pscustomobject]@{ id = $findingId; reason = 'invalid-range' })
        continue
    }

    $plans.Add([pscustomobject]@{
        id          = $findingId
        file        = $relativeFile
        filePath    = $filePath
        startLine   = $startLine
        endLine     = $endLine
        replacement = [string]$suggestion.Value
    })
}

$fileStates = @{}
foreach ($fileGroup in @($plans | Group-Object filePath)) {
    $fileItem = Get-Item -LiteralPath $fileGroup.Name
    if ($fileItem.LastWriteTimeUtc -gt $reportTime.AddSeconds(1)) {
        throw "Refusing stale suggestions because '$($fileGroup.Group[0].file)' changed after the review report."
    }

    $ascending = @($fileGroup.Group | Sort-Object startLine, endLine)
    for ($index = 1; $index -lt $ascending.Count; $index++) {
        if ($ascending[$index].startLine -le $ascending[$index - 1].endLine) {
            throw "Overlapping suggestions for '$($ascending[$index].file)' cannot be applied safely."
        }
    }

    $file = Get-TextFile -Path $fileGroup.Name
    $lines = [Collections.Generic.List[string]]::new(
        [string[]]([regex]::Split($file.text, '\r?\n'))
    )
    foreach ($plan in $fileGroup.Group) {
        if ($plan.endLine -gt $lines.Count) {
            throw "Finding '$($plan.id)' range exceeds '$($plan.file)' line count."
        }
    }
    $fileStates[$fileGroup.Name] = [pscustomobject]@{
        originalText = $file.text
        encoding     = $file.encoding
        newLine      = $(if ($file.text.Contains("`r`n")) { "`r`n" } else { "`n" })
        lines        = $lines
        newText      = $null
    }
}

$applied = [Collections.Generic.List[object]]::new()
foreach ($fileGroup in @($plans | Group-Object filePath)) {
    $state = $fileStates[$fileGroup.Name]

    foreach ($plan in @($fileGroup.Group | Sort-Object startLine -Descending)) {
        $replacement = $plan.replacement.TrimEnd("`r", "`n")
        [string[]]$replacementLines = @()
        if ($replacement.Length -gt 0) {
            $replacementLines = [regex]::Split($replacement, '\r?\n')
        }
        $startIndex = $plan.startLine - 1
        $state.lines.RemoveRange($startIndex, $plan.endLine - $plan.startLine + 1)
        if ($replacementLines.Count -gt 0) {
            $state.lines.InsertRange($startIndex, $replacementLines)
        }
        $applied.Add([pscustomobject]@{
            id         = $plan.id
            file       = $plan.file
            start_line = $plan.startLine
            end_line   = $plan.endLine
        })
    }
    $state.newText = $state.lines -join $state.newLine
}

$writePlans = [Collections.Generic.List[object]]::new()
try {
    foreach ($fileGroup in @($plans | Group-Object filePath)) {
        $state = $fileStates[$fileGroup.Name]
        $directory = Split-Path -Parent $fileGroup.Name
        $name = Split-Path -Leaf $fileGroup.Name
        $token = [Guid]::NewGuid().ToString('N')
        $tempPath = Join-Path $directory ".$name.$token.tmp"
        $backupPath = Join-Path $directory ".$name.$token.bak"
        $writePlan = [pscustomobject]@{
            target = $fileGroup.Name
            temp   = $tempPath
            backup = $backupPath
        }
        $writePlans.Add($writePlan)
        [IO.File]::WriteAllText($tempPath, $state.newText, $state.encoding)
        [IO.File]::Copy($fileGroup.Name, $backupPath, $false)
    }

    $replaced = [Collections.Generic.List[object]]::new()
    try {
        foreach ($writePlan in $writePlans) {
            [IO.File]::Move($writePlan.temp, $writePlan.target, $true)
            $replaced.Add($writePlan)
        }
    }
    catch {
        foreach ($writePlan in $replaced) {
            [IO.File]::Move($writePlan.backup, $writePlan.target, $true)
        }
        throw
    }
}
finally {
    foreach ($writePlan in $writePlans) {
        foreach ($cleanupPath in @($writePlan.temp, $writePlan.backup)) {
            if (Test-Path -LiteralPath $cleanupPath) {
                Remove-Item -LiteralPath $cleanupPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$result = [pscustomobject]@{
    report_path = $ReportPath
    applied     = @($applied)
    skipped     = @($skipped)
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8

Write-Host "[local-review] Applied $($applied.Count) mechanical suggestion(s); skipped $($skipped.Count)."
Write-Host "[local-review] Results: $ResultPath"
$result
