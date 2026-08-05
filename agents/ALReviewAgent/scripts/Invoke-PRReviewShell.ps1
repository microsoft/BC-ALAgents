<#
.SYNOPSIS
    Target thin-shell call site for the review/publish MCP split. Skeleton for AB#645219.

.DESCRIPTION
    Shows the shape the monolithic scripts/Invoke-CopilotPRReview.ps1 collapses to
    once the two MCP servers own the wiring:

        $r = review(target, base/diff, bcquality_ref, model, min_severity)
        publish($r.findings, pr, iteration_ctx)     # PROD only

    generate = call `review`; post = call `publish` with review's findings. The
    generate/post handoff is just review's findings[] - stateless and tokenless,
    which is why BC-Bench can call `review` alone and never load `publish`.

    STATUS: skeleton. This delegates to the two stub handlers (which throw
    NotImplemented) and is intentionally NOT wired into .github/workflows/review.yml
    or ci.yml yet. It exists to pin the target call shape; the monolith stays the
    live path and behavior is unchanged. Removing the monolith's inline wiring is a
    later, load-bearing PR.

.PARAMETER RepoRef
    owner/repo@ref of the review target (PROD path). Mutually exclusive with LocalPath.

.PARAMETER LocalPath
    Local checkout of the review target (BC-Bench / local path). Mutually exclusive with RepoRef.

.PARAMETER BaseRef
    Base ref of the change; the three-dot merge-base is computed inside `review`.

.PARAMETER BcqualityRef
    BCQuality branch / SHA / worktree / customer layer. Omit for the engine default (Z). PROD does not override it.

.PARAMETER Model
    Copilot model to review with.

.PARAMETER MinSeverity
    Severity floor for returned findings.

.PARAMETER Pr
    Target PR for publishing: @{ repo; pr_number; head_sha }. Omit to run generate-only (no post), like BC-Bench.
#>
[CmdletBinding(DefaultParameterSetName = 'Repo')]
param(
    [Parameter(ParameterSetName = 'Repo', Mandatory)]
    [string] $RepoRef,

    [Parameter(ParameterSetName = 'Local', Mandatory)]
    [string] $LocalPath,

    [string] $BaseRef,

    [string] $BcqualityRef,

    [string] $Model,

    [ValidateSet('Critical', 'High', 'Medium', 'Low')]
    [string] $MinSeverity = 'Medium',

    [hashtable] $Pr
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$mcpRoot        = Join-Path $PSScriptRoot '..\mcp'
$reviewHandler  = Join-Path $mcpRoot 'review\Invoke-ReviewTool.ps1'
$publishHandler = Join-Path $mcpRoot 'publish\Invoke-PublishTool.ps1'

# --- generate: the ONE shared review call (PROD + BC-Bench + customers) ---
$reviewArgs = @{ MinSeverity = $MinSeverity }
if ($PSCmdlet.ParameterSetName -eq 'Local') { $reviewArgs.LocalPath = $LocalPath }
else { $reviewArgs.RepoRef = $RepoRef }
if ($BaseRef)      { $reviewArgs.BaseRef = $BaseRef }
if ($BcqualityRef) { $reviewArgs.BcqualityRef = $BcqualityRef }
if ($Model)        { $reviewArgs.Model = $Model }

$reviewResult = & $reviewHandler @reviewArgs

# --- post: PROD only. BC-Bench passes no -Pr and stops after generate. ---
if (-not $Pr) {
    Write-Verbose 'No -Pr supplied: generate-only (eval path). Skipping publish.'
    return $reviewResult
}

& $publishHandler -Findings $reviewResult.findings -Pr $Pr
