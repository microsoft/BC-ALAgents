<#
.SYNOPSIS
    Stub handler for the PROD-only `publish` MCP tool. Skeleton for AB#645219.

.DESCRIPTION
    Target contract (see publish.tool.json): take the raw findings[] from the
    review tool and post them as inline PR comments - suggestion placement,
    location dedup vs existing comments, iteration numbering, comment rendering,
    and POST. BC-Bench never loads this server, so eval physically cannot post;
    that is the whole point of the split (no mode flag to get wrong).

    STATUS: stub. The real body will lift the post path from
    scripts/Invoke-CopilotPRReview.ps1: Resolve-SuggestionPlacement +
    Build-CommentBody (rendering), Test-NearDuplicateLocation (location dedup),
    Resolve-ReviewIteration (iteration numbering), and Post-Findings (the POST
    loop). Until then this throws so a missing implementation can never be read
    as "nothing to post".

.OUTPUTS
    [pscustomobject] @{
        posted  = @( @{ file; line; comment_id; url } )
        skipped = @( @{ file; line; reason } )
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [object[]] $Findings,

    [Parameter(Mandatory)]
    [hashtable] $Pr,

    [hashtable] $IterationCtx
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

throw [System.NotImplementedException]::new(
    "publish MCP tool is a skeleton stub (AB#645219). The post wiring in " +
    "agents/ALReviewAgent/scripts/Invoke-CopilotPRReview.ps1 " +
    "(Resolve-SuggestionPlacement, Build-CommentBody, Test-NearDuplicateLocation, " +
    "Resolve-ReviewIteration, Post-Findings) will move here in a subsequent PR. " +
    "Contract: agents/ALReviewAgent/mcp/publish/publish.tool.json.")
