<#
.SYNOPSIS
    Single-process caller shape for the review/publish tools. Skeleton for AB#645219.

.DESCRIPTION
    The shape a single-process caller (BC-Bench / local harness) uses to drive the
    two MCP tools in sequence:

        Invoke-ReviewTool  -OutputDir $dir     # generate -> writes agent-output.txt
        Invoke-PublishTool -OutputDir $dir     # post     -> reads it back, posts

    The generate/post handoff is the review output directory (the same artifact
    PROD passes between its two jobs), so this mirrors PROD without an in-memory
    findings hand-off.

    This is NOT the PROD path. PROD keeps the two tools in two separate,
    permission-isolated jobs (review = read-only, publish = write) with an artifact
    handoff between runners - see .github/workflows/review.yml. That job split is
    what makes "eval never posts" structural. This single-process shell is for
    callers that do not need that isolation (BC-Bench runs generate-only and never
    calls the publish tool at all).

    The caller supplies the engine's environment (REVIEW_SOURCE / REVIEW_WORKSPACE /
    PR context / BCQUALITY_* / GH_TOKEN) exactly as review.yml does; this shell only
    fixes the tool call order and the shared output directory.

.PARAMETER OutputDir
    Directory for the generate output / post input. Defaults to a per-process temp dir.

.PARAMETER GenerateOnly
    Stop after the review (generate) tool - the BC-Bench / eval shape that never posts.
#>
[CmdletBinding()]
param(
    [string] $OutputDir = (Join-Path ([System.IO.Path]::GetTempPath()) "al-review-$PID"),

    [switch] $GenerateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mcpRoot        = Join-Path $PSScriptRoot '..' 'mcp'
$reviewTool     = Join-Path $mcpRoot 'review' 'Invoke-ReviewTool.ps1'
$publishTool    = Join-Path $mcpRoot 'publish' 'Invoke-PublishTool.ps1'

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# generate: the ONE shared review call (PROD + BC-Bench + customers).
& $reviewTool -OutputDir $OutputDir

# post: PROD / real-PR only. BC-Bench passes -GenerateOnly and never loads publish.
if ($GenerateOnly) {
    Write-Verbose 'GenerateOnly: stopping after review (eval path). Skipping publish.'
    return
}

& $publishTool -OutputDir $OutputDir
