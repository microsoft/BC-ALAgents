<#
.SYNOPSIS
    `review` MCP tool - the GENERATE phase entry point. AB#645219.

.DESCRIPTION
    Target contract (see review.tool.json): filter BCQuality @ ref -> run the
    model with the one shared prompt/skills wiring -> parse findings -> content
    dedup + cap -> return findings[] + resolved{}. This is the single source of
    truth for the generate half, consumed identically by PROD and BC-Bench.

    CURRENT (interim) implementation: a behavior-preserving per-phase PASS-THROUGH.
    Until the generate wiring physically moves out of Invoke-CopilotPRReview.ps1
    (a later, load-bearing PR), this tool sets REVIEW_PHASE=generate and delegates
    to the existing orchestrator, which reads every other input from the
    environment - exactly how PROD's review.yml and the local harness already
    invoke it. Delegating means the pass-through produces byte-for-byte the same
    result as calling the script directly.

    Optional parameters override the matching environment variable ONLY when
    explicitly supplied (single-process callers such as BC-Bench); PROD passes
    none, keeping this a pure pass-through. Source / PR context stay env-driven
    for now; the repo_ref|local_path contract in review.tool.json is honored once
    the generate logic moves into this tool.

    This tool is ADDITIVE and opt-in: review.yml still calls
    Invoke-CopilotPRReview.ps1 directly, so the many pipelines on the old path are
    untouched. Consumers migrate to the tool one at a time.

.OUTPUTS
    Interim: none (the engine writes agent-output.txt to REVIEW_OUTPUT_DIR - the
    same artifact the publish phase consumes). Target: findings[] + resolved{}.
#>
[CmdletBinding()]
param(
    [string] $BcqualityRef,

    [string] $Model,

    [ValidateSet('Critical', 'High', 'Medium', 'Low')]
    [string] $MinSeverity,

    [string] $OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This tool owns the generate phase regardless of how it was reached.
$env:REVIEW_PHASE = 'generate'

if ($PSBoundParameters.ContainsKey('BcqualityRef')) { $env:BCQUALITY_REF = $BcqualityRef }
if ($PSBoundParameters.ContainsKey('Model'))        { $env:COPILOT_MODEL = $Model }
if ($PSBoundParameters.ContainsKey('MinSeverity'))  { $env:AGENT_MINIMUM_SEVERITY = $MinSeverity }
if ($PSBoundParameters.ContainsKey('OutputDir'))    { $env:REVIEW_OUTPUT_DIR = $OutputDir }

# Cross-platform path (PROD runs on ubuntu-latest) - never hard-code separators.
$engine = Join-Path $PSScriptRoot '..' '..' 'scripts' 'Invoke-CopilotPRReview.ps1'
& $engine
