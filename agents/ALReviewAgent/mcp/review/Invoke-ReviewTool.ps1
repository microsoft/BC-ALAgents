<#
.SYNOPSIS
    Stub handler for the shared `review` MCP tool. Skeleton for AB#645219.

.DESCRIPTION
    Target contract (see review.tool.json): filter BCQuality @ ref -> run the
    model with the one shared prompt/skills wiring -> parse findings -> apply
    content-level dedup + cap. Returns findings[] plus resolved{} provenance.
    This is the single source of truth for the *generate* half of the engine,
    consumed identically by PROD and BC-Bench.

    STATUS: stub. The real body will lift the generate path currently inlined in
    scripts/Invoke-CopilotPRReview.ps1 (BCQuality filter -> Copilot CLI run ->
    Parse-BCQualityReport -> Get-FindingSignature dedup / MAX_TOTAL_FINDINGS cap)
    into this handler so the wiring lives in exactly one place. Until then this
    throws so callers cannot mistake an unimplemented tool for an empty review.

.OUTPUTS
    [pscustomobject] @{
        findings = @( @{ file; line_start; line_end; severity; domain; issue; recommendation; suggested_code } )
        resolved = @{ bcquality_sha; engine_version; plugin_version; model; min_severity }
    }
#>
[CmdletBinding(DefaultParameterSetName = 'Repo')]
param(
    [Parameter(ParameterSetName = 'Repo', Mandatory)]
    [string] $RepoRef,

    [Parameter(ParameterSetName = 'Local', Mandatory)]
    [string] $LocalPath,

    [string] $BaseRef,

    [string] $Diff,

    [string] $BcqualityRef,

    [string] $Model,

    [ValidateSet('Critical', 'High', 'Medium', 'Low')]
    [string] $MinSeverity = 'Medium'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

throw [System.NotImplementedException]::new(
    "review MCP tool is a skeleton stub (AB#645219). The generate wiring in " +
    "agents/ALReviewAgent/scripts/Invoke-CopilotPRReview.ps1 (BCQuality filter, " +
    "Copilot CLI run, Parse-BCQualityReport, Get-FindingSignature dedup + cap) " +
    "will move here in a subsequent PR. Contract: agents/ALReviewAgent/mcp/review/review.tool.json.")
