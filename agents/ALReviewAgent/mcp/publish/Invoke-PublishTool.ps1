<#
.SYNOPSIS
    `publish` MCP tool - the POST phase entry point (PROD only). AB#645219.

.DESCRIPTION
    Target contract (see publish.tool.json): take the findings[] from the review
    tool and post them as inline PR comments - suggestion placement, location
    dedup, iteration numbering, comment rendering, POST. BC-Bench never loads this
    tool, so eval physically cannot post.

    CURRENT (interim) implementation: a behavior-preserving per-phase PASS-THROUGH.
    Until the post wiring physically moves out of Invoke-CopilotPRReview.ps1 (a
    later, load-bearing PR), this tool sets REVIEW_PHASE=post and delegates to the
    existing orchestrator, which reads the generate output from REVIEW_OUTPUT_DIR
    (the artifact the review job produced) and the PR context from the environment
    - exactly how PROD's review.yml already invokes it. Delegating means the
    pass-through produces the same posted comments as calling the script directly.

    This tool is ADDITIVE and opt-in: review.yml still calls
    Invoke-CopilotPRReview.ps1 directly, so the many pipelines on the old path are
    untouched. Consumers migrate to the tool one at a time.

    The read-only/write permission split stays a workflow property: review runs in
    a read-only job, publish in a write-scoped job. Keeping them as two tools in
    two jobs is what makes "eval never posts" structural rather than a flag.

.OUTPUTS
    Interim: none (the engine posts comments and writes its usual artifacts under
    REVIEW_OUTPUT_DIR). Target: { posted[], skipped[] }.
#>
[CmdletBinding()]
param(
    [string] $OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This tool owns the post phase regardless of how it was reached.
$env:REVIEW_PHASE = 'post'

if ($PSBoundParameters.ContainsKey('OutputDir')) { $env:REVIEW_OUTPUT_DIR = $OutputDir }

# Cross-platform path (PROD runs on ubuntu-latest) - never hard-code separators.
$engine = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Invoke-CopilotPRReview.ps1'
& $engine
