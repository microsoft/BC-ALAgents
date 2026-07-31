<#
.SYNOPSIS
    Run the BC AL review agent locally against a codebase or a branch, and
    optionally launch a second Copilot CLI pass that fixes the findings.

.DESCRIPTION
    Thin wrapper around agents/ALReviewAgent/scripts/Invoke-CopilotPRReview.ps1 that handles
    the two local workflows:

      Mode = Branch  (default)
        Review committed + staged changes on the current branch against a
        base ref (typically main). Unstaged working-tree changes are ignored.
        If there are staged (but not yet committed) changes, they are folded
        into a temporary commit for the duration of the review, then the
        commit is undone with `git reset --soft HEAD~1` so the index is
        restored to exactly the state you started with.

      Mode = Existing
        Review the entire tree at HEAD (no base branch). Implemented by
        diffing against git's canonical empty tree
        (4b825dc642cb6eb9a060e54bf8d69288fbee4904) so every tracked file is
        considered "changed" and the agent sees the whole repo.

    Findings land in <OutputDir>/_review-report.json (raw agent JSON per the
    BCQuality skills/do.md contract). With -Fix, the script then invokes the
    Copilot CLI a second time with that JSON as input and asks it to apply
    the fixes to the same worktree.

.PARAMETER RepoPath
    Path to the git worktree to review. HEAD is what gets reviewed.

.PARAMETER Mode
    Branch (default) or Existing. See DESCRIPTION.

.PARAMETER BaseRef
    Only used for -Mode Branch. Defaults to the upstream merge-base of HEAD,
    falling back to 'main' if no upstream is configured.

.PARAMETER BCQualityRoot
    Path to a BCQuality checkout (https://github.com/microsoft/BCQuality).
    Optional. When omitted, BCQuality is cloned/refreshed into a local cache
    (~/.copilot/cache/bc-review/BCQuality) automatically. Pass an explicit
    path (e.g. from CI or BC-Bench) to use a checkout you already manage.

.PARAMETER MaxAgeDays
    Only used when -BCQualityRoot is omitted. If the cached BCQuality clone's
    HEAD is older than this many days, it is fast-forwarded. Default 7. Set to
    a negative value to never auto-update the cache.

.PARAMETER RefreshBCQuality
    Only used when -BCQualityRoot is omitted. Force a fetch + reset of the
    cached BCQuality clone regardless of age (e.g. "use the latest rules").

.PARAMETER ConfigPath
    Path to a bcquality.config.yaml. Defaults to agents/ALReviewAgent/bcquality.config.yaml
    in this engine repo.

.PARAMETER OutputDir
    Where to write findings + transcript. Defaults to <RepoPath>/.bc-review.

.PARAMETER MinimumSeverity
    Critical | High | Medium | Low. Default Medium.

.PARAMETER Model
    Optional Copilot model override (COPILOT_MODEL).

.PARAMETER LeafModel
    Optional faster/cheaper model for the super-skill's leaf sub-skill child
    agents (COPILOT_REVIEW_LEAF_MODEL). Leaves do the bulk of the work, so a
    lighter triage model here is the biggest per-leaf speedup. Empty = leaves
    use the CLI's default child-agent model.

.PARAMETER NoPruneDomains
    Disable the relevance pre-pass. By default, feature-gated review domains
    (telemetry, query, web-services, testing, events, interfaces) with ZERO
    signal tokens in the reviewed AL are skipped via BCQuality's contract-legal
    disabled-skills (reason: configuration), saving one leaf run each. Always-
    applicable domains (style, performance, privacy, security, etc.) are never
    pruned. Pass this switch to run every domain unconditionally.

.PARAMETER NoParallelLeaves
    Disable concurrent leaf dispatch (COPILOT_REVIEW_PARALLEL_LEAVES=false).
    By default leaves run as isolated parallel child agents, which is both
    faster and a stronger guard against the collapsed-scan pathology than
    serial in-context passes.

.PARAMETER Path
    Optional folder (or glob) to scope the reviewed diff and findings, relative
    to RepoPath. Examples:
      -Path src\FooModule            → src/FooModule/**
      -Path 'app/**/*.al'            → passed through as-is
    Uses REVIEW_PATH_SPEC to narrow the git diff and REVIEW_APPLY_TO as a
    defensive findings filter.

.PARAMETER Fix
    After review, launch a second Copilot CLI pass that reads the findings
    JSON and applies fixes to RepoPath. Does not commit; leaves the changes
    in your working tree for review.

.PARAMETER SkipBCQualityFilter
    Skip the BCQuality pre-filter step. Use when BCQualityRoot is already
    filtered or you want the full skill set.

.EXAMPLE
    # Scenario 2: pre-commit review of the current branch (committed + staged)
    .\Invoke-LocalReview.ps1 `
        -RepoPath C:\repo\MyBCApp `
        -BCQualityRoot C:\repo\BCQuality

.EXAMPLE
    # Scenario 1: review the whole codebase at HEAD and auto-apply fixes
    .\Invoke-LocalReview.ps1 `
        -RepoPath C:\repo\MyBCApp `
        -Mode Existing `
        -BCQualityRoot C:\repo\BCQuality `
        -Fix

.EXAMPLE
    # Invoked from another agent: just get the JSON, no fix pass
    $out = 'C:\temp\review-run-42'
    .\Invoke-LocalReview.ps1 -RepoPath . -BCQualityRoot C:\repo\BCQuality -OutputDir $out
    $findings = Get-Content "$out\_review-report.json" -Raw | ConvertFrom-Json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepoPath,
    [ValidateSet('Branch', 'Existing')][string] $Mode = 'Branch',
    [string] $BaseRef,
    [string] $BCQualityRoot,
    [int]    $MaxAgeDays = 7,
    [switch] $RefreshBCQuality,
    [string] $ConfigPath,
    [string] $OutputDir,
    [ValidateSet('Critical', 'High', 'Medium', 'Low')][string] $MinimumSeverity = 'Medium',
    [string] $Model,
    [string] $LeafModel,
    [string] $Path,
    [switch] $Fix,
    [switch] $SkipBCQualityFilter,
    [switch] $NoPruneDomains,
    [switch] $NoParallelLeaves
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# git's canonical empty-tree SHA: diffing anything against this yields the
# full tree, so "Existing" mode reviews every tracked file.
$EmptyTreeSha = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'

# ---------------------------------------------------------------------------
# BCQuality knowledge base. It is NOT bundled with the reviewer engine, so
# when the caller does not pass -BCQualityRoot we clone/refresh it into a
# local cache (~/.copilot/cache/bc-review/BCQuality) here. Age-gated by
# -MaxAgeDays (default 7; <0 disables auto-update); -RefreshBCQuality forces
# a fetch. Callers that already have a checkout (CI, BC-Bench) pass
# -BCQualityRoot and this is skipped entirely.
# ---------------------------------------------------------------------------
function Resolve-BCQualityRoot {
    param([int] $MaxAgeDays = 7, [switch] $Force)

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'git is required to fetch BCQuality but was not found on PATH. Pass -BCQualityRoot to use an existing checkout.'
    }
    # GetFolderPath('UserProfile') is cross-platform (returns $HOME off-Windows);
    # $env:USERPROFILE is unset on non-Windows PowerShell.
    $cacheDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.copilot/cache/bc-review'
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $bcqPath = Join-Path $cacheDir 'BCQuality'
    $bcqUrl  = 'https://github.com/microsoft/BCQuality.git'

    if (-not (Test-Path (Join-Path $bcqPath '.git'))) {
        Write-Host "[local-review] Cloning BCQuality into $bcqPath"
        & git clone --depth 1 $bcqUrl $bcqPath 2>&1 | ForEach-Object { Write-Host "[local-review] $_" }
        if ($LASTEXITCODE -ne 0) { throw "git clone of $bcqUrl failed" }
        return $bcqPath
    }

    if ($MaxAgeDays -lt 0 -and -not $Force) {
        Write-Host "[local-review] BCQuality: update skipped (MaxAgeDays=$MaxAgeDays)."
        return $bcqPath
    }

    $headEpoch = & git -C $bcqPath log -1 --format=%ct 2>$null
    $ageDays = if ($headEpoch) {
        [int](([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$headEpoch) / 86400)
    } else { 9999 }

    if ($Force -or $ageDays -ge $MaxAgeDays) {
        Write-Host "[local-review] BCQuality: HEAD is $ageDays day(s) old, updating."
        # Refetch + reset is robust for a shallow read-only cache mirror
        # (a plain ff-only pull fails on divergent shallow history).
        & git -C $bcqPath fetch --depth 1 origin HEAD 2>&1 | ForEach-Object { Write-Host "[local-review] $_" }
        if ($LASTEXITCODE -eq 0) {
            & git -C $bcqPath reset --hard FETCH_HEAD 2>&1 | Out-Null
        }
        else {
            Write-Host "[local-review] BCQuality: fetch failed, using existing clone."
        }
    }
    else {
        Write-Host "[local-review] BCQuality: up to date ($ageDays day(s) old)."
    }
    return $bcqPath
}

$agentRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$reviewScript = Join-Path $agentRoot 'scripts/Invoke-CopilotPRReview.ps1'
$configScript = Join-Path $agentRoot 'scripts/Get-BCQualityConfig.ps1'
$filterScript = Join-Path $agentRoot 'scripts/Invoke-BCQualityFilter.ps1'
if (-not $ConfigPath) { $ConfigPath = Join-Path $agentRoot 'bcquality.config.yaml' }

$RepoPath      = (Resolve-Path $RepoPath).Path
if (-not $BCQualityRoot) {
    $BCQualityRoot = Resolve-BCQualityRoot -MaxAgeDays $MaxAgeDays -Force:$RefreshBCQuality
}
$BCQualityRoot = (Resolve-Path $BCQualityRoot).Path
$ConfigPath    = (Resolve-Path $ConfigPath).Path

# Best-effort: exclude the BCQuality cache from Windows Defender real-time
# scanning. The reviewer touches thousands of small files under the cache and
# the per-tool-call Defender hooks (12s timeout) add measurable drag to every
# leaf. Requires elevation; failure is non-fatal and silently tolerated.
if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
    $defenderPaths = @($BCQualityRoot, (Split-Path -Parent $BCQualityRoot)) |
        Where-Object { $_ } | Select-Object -Unique
    foreach ($dp in $defenderPaths) {
        try {
            Add-MpPreference -ExclusionPath $dp -ErrorAction Stop
            Write-Host "[local-review] Defender exclusion added: $dp"
        }
        catch {
            Write-Host "[local-review] Defender exclusion skipped ($dp): $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# Non-git shadow: if RepoPath isn't a git repo, mirror it into a throwaway
# git repo under $env:TEMP so the diff-driven reviewer has something to work
# with. Findings paths are relative, so they map cleanly back to the source.
# ---------------------------------------------------------------------------
$shadowRepo = $null
$sourceForOutput = $RepoPath
$isGitRepo = $false
$autoPathSpec = $null
& git -C $RepoPath rev-parse --is-inside-work-tree 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { $isGitRepo = $true }

if ($isGitRepo) {
    # If RepoPath is a subfolder of the git repo (not the top level), git
    # commands still operate on the full repo. Auto-derive a pathspec so the
    # diff is scoped to just that subfolder — unless the user already passed
    # an explicit -Path (which takes precedence).
    $gitTop = (& git -C $RepoPath rev-parse --show-toplevel 2>$null).Trim()
    $relPrefix = (& git -C $RepoPath rev-parse --show-prefix 2>$null).Trim().TrimEnd('/')
    if ($gitTop -and $relPrefix -and -not $Path) {
        $autoPathSpec = $relPrefix
        Write-Host "[local-review] Detected subfolder of $gitTop — auto-scoping diff to: $relPrefix"
        # Operate from the repo root so pathspec expansion is unambiguous.
        $RepoPath = $gitTop
    }
}

if (-not $isGitRepo) {
    if ($Mode -eq 'Branch') {
        Write-Host "[local-review] $RepoPath is not a git repo — forcing Mode=Existing."
        $Mode = 'Existing'
    }
    $shadowRepo = Join-Path $env:TEMP ("bc-review-shadow-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    Write-Host "[local-review] Shadowing $RepoPath -> $shadowRepo"
    New-Item -ItemType Directory -Force -Path $shadowRepo | Out-Null
    # Robocopy is fastest on Windows and handles long paths; skip .git if present.
    $rc = & robocopy $RepoPath $shadowRepo /MIR /NFL /NDL /NJH /NJS /NP /XD .git 2>&1
    # Robocopy exit codes 0-7 are success (files copied / no-op / extra files).
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE): $rc" }
    Push-Location $shadowRepo
    try {
        & git init -q
        & git config user.email 'local-review@invalid'
        & git config user.name  'BC Local Review'
        & git add -A
        & git commit -q -m 'shadow: bc-local-review snapshot' --allow-empty
        if ($LASTEXITCODE -ne 0) { throw "shadow git commit failed" }
    }
    finally { Pop-Location }
    $RepoPath = $shadowRepo
}

if (-not $OutputDir) { $OutputDir = Join-Path $sourceForOutput '.bc-review' }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path

function Invoke-Git {
    param([string[]] $GitArgs, [switch] $AllowFail)
    $out = & git -C $RepoPath @GitArgs 2>&1
    if (-not $AllowFail -and $LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed (exit $LASTEXITCODE): $out"
    }
    return ($out -join "`n").Trim()
}

function Get-LocalGitConfigSnapshot {
    param([Parameter(Mandatory)][string] $Key)

    $values = @(& git -C $RepoPath config --local --get-all $Key 2>$null)
    return [pscustomobject]@{
        Key    = $Key
        Exists = ($LASTEXITCODE -eq 0)
        Values = $values
    }
}

function Restore-LocalGitConfig {
    param([Parameter(Mandatory)][object[]] $Snapshots)

    foreach ($snapshot in $Snapshots) {
        & git -C $RepoPath config --local --unset-all $snapshot.Key 2>$null | Out-Null
        if ($snapshot.Exists) {
            foreach ($value in $snapshot.Values) {
                & git -C $RepoPath config --local --add $snapshot.Key $value
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "Failed to restore git config '$($snapshot.Key)'."
                }
            }
        }
    }
}

function ConvertFrom-CopilotCompactNumber {
    param([Parameter(Mandatory)][string] $Value)

    $normalized = $Value.Trim().Replace(',', '')
    if ($normalized -notmatch '^([0-9]+(?:\.[0-9]+)?)([kKmM]?)$') {
        throw "Unsupported Copilot metric value: '$Value'"
    }

    $number = [double]::Parse(
        $Matches[1],
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    $multiplier = switch ($Matches[2].ToLowerInvariant()) {
        'k' { 1000 }
        'm' { 1000000 }
        default { 1 }
    }
    return $number * $multiplier
}

function Get-CopilotSummaryMetrics {
    param([Parameter(Mandatory)][string] $TranscriptPath)

    if (-not (Test-Path -LiteralPath $TranscriptPath -PathType Leaf)) {
        return $null
    }

    $raw = Get-Content -LiteralPath $TranscriptPath -Raw
    $raw = $raw -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
    $metricNumberPattern = '[0-9][0-9,]*(?:\.[0-9]+)?[kKmM]?'
    $creditMatches = [regex]::Matches(
        $raw,
        "(?m)^(?:err:\s*)?AI Credits\s+($metricNumberPattern)"
    )
    $tokenMatches = [regex]::Matches(
        $raw,
        "(?m)^(?:err:\s*)?Tokens\s+↑\s*($metricNumberPattern)(?:\s+\(($metricNumberPattern)\s+cached(?:,\s*$metricNumberPattern\s+written)?\))?\s+•\s+↓\s*($metricNumberPattern)(?:\s+\(($metricNumberPattern)\s+reasoning\))?"
    )
    if ($creditMatches.Count -eq 0 -and $tokenMatches.Count -eq 0) {
        return $null
    }

    $credits = 0.0
    if ($creditMatches.Count -gt 0) {
        $credits = ConvertFrom-CopilotCompactNumber $creditMatches[-1].Groups[1].Value
    }

    $inputTokens = 0L
    $cachedTokens = 0L
    $outputTokens = 0L
    $reasoningTokens = 0L
    if ($tokenMatches.Count -gt 0) {
        $match = $tokenMatches[-1]
        $inputTokens = [int64](ConvertFrom-CopilotCompactNumber $match.Groups[1].Value)
        if ($match.Groups[2].Success) {
            $cachedTokens = [int64](ConvertFrom-CopilotCompactNumber $match.Groups[2].Value)
        }
        $outputTokens = [int64](ConvertFrom-CopilotCompactNumber $match.Groups[3].Value)
        if ($match.Groups[4].Success) {
            $reasoningTokens = [int64](ConvertFrom-CopilotCompactNumber $match.Groups[4].Value)
        }
    }

    return [pscustomobject]@{
        input_tokens     = $inputTokens
        cached_tokens    = $cachedTokens
        output_tokens    = $outputTokens
        reasoning_tokens = $reasoningTokens
        total_tokens     = $inputTokens + $outputTokens
        credits          = $credits
    }
}

function Resolve-BranchBase {
    if ($BaseRef) { return $BaseRef }
    $upstream = & git -C $RepoPath rev-parse --abbrev-ref '@{u}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $upstream) {
        $mb = & git -C $RepoPath merge-base HEAD $upstream 2>$null
        if ($LASTEXITCODE -eq 0 -and $mb) { return $mb.Trim() }
    }
    $mb = & git -C $RepoPath merge-base HEAD main 2>$null
    if ($LASTEXITCODE -eq 0 -and $mb) { return $mb.Trim() }
    throw "Could not determine base ref. Pass -BaseRef explicitly."
}

function Get-AlReviewFilePaths {
    param([object[]] $Paths = @())

    return @($Paths | ForEach-Object { ([string]$_).Trim() } |
        Where-Object { $_ -and $_.EndsWith('.al', [StringComparison]::OrdinalIgnoreCase) })
}

function ConvertFrom-GitNameStatus {
    param([object[]] $Lines = @())

    $paths = [Collections.Generic.List[string]]::new()
    foreach ($lineValue in $Lines) {
        $line = [string]$lineValue
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = $line -split "`t"
        if ($parts.Count -lt 2) {
            continue
        }
        $paths.Add($parts[1])
        if ($parts[0] -match '^[RC]' -and $parts.Count -ge 3) {
            $paths.Add($parts[2])
        }
    }
    return @($paths)
}

# ---------------------------------------------------------------------------
# Prep: figure out base + optionally stage staged-changes into a temp commit
# ---------------------------------------------------------------------------
$tempCommitMade = $false
$originalHead   = Invoke-Git -GitArgs @('rev-parse', 'HEAD')
$pagerConfigSnapshots = @(
    Get-LocalGitConfigSnapshot -Key 'core.pager'
    Get-LocalGitConfigSnapshot -Key 'pager.diff'
)

try {
    # Copilot's shell tool can invoke git.exe by absolute path in a real
    # terminal, bypassing command-line guidance and environment variables.
    # Repository-local config is the only reliable way to prevent Git from
    # launching an interactive pager. The original values are restored below.
    & git -C $RepoPath config --local --replace-all core.pager cat
    if ($LASTEXITCODE -ne 0) { throw "Failed to disable the repository Git pager." }
    & git -C $RepoPath config --local --replace-all pager.diff false
    if ($LASTEXITCODE -ne 0) { throw "Failed to disable the Git diff pager." }

    if ($Mode -eq 'Existing') {
        # Create a throwaway commit whose tree is empty, and diff HEAD against
        # that. The plain empty-tree SHA can't be used with `A...HEAD` syntax
        # because `...` requires commits on both sides. `commit-tree` gives us
        # a real commit object with no parents; it becomes dangling after the
        # run and gets garbage-collected. Uses env vars to avoid needing
        # user.name/email config in the target repo.
        $env:GIT_COMMITTER_NAME  = 'BC Local Review'
        $env:GIT_COMMITTER_EMAIL = 'local-review@invalid'
        $env:GIT_AUTHOR_NAME     = 'BC Local Review'
        $env:GIT_AUTHOR_EMAIL    = 'local-review@invalid'
        $emptyCommit = (& git -C $RepoPath commit-tree $EmptyTreeSha -m 'bc-local-review empty base' 2>&1 | Select-Object -Last 1).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $emptyCommit) {
            throw "Failed to synthesize empty base commit: $emptyCommit"
        }
        $effectiveBase = $emptyCommit
        Write-Host "[local-review] Mode=Existing: reviewing whole tree at $originalHead (base $emptyCommit)"
    }
    else {
        $effectiveBase = Resolve-BranchBase
        Write-Host "[local-review] Mode=Branch: base=$effectiveBase, head=$originalHead"

        # Fold staged (index) changes into a throwaway commit so they appear
        # in `git diff BASE...HEAD`. Unstaged working-tree changes are left
        # alone. `git diff --cached --quiet` exits non-zero when the index
        # differs from HEAD.
        & git -C $RepoPath diff --cached --quiet 2>$null
        $hasStaged = ($LASTEXITCODE -ne 0)
        if ($hasStaged) {
            Write-Host "[local-review] Staged changes detected — creating temp commit for review."
            $env:GIT_COMMITTER_NAME  = 'BC Local Review'
            $env:GIT_COMMITTER_EMAIL = 'local-review@invalid'
            $env:GIT_AUTHOR_NAME     = 'BC Local Review'
            $env:GIT_AUTHOR_EMAIL    = 'local-review@invalid'
            Invoke-Git -GitArgs @('commit', '-m', 'temp: bc-local-review staged snapshot', '--no-verify', '--allow-empty') | Out-Null
            $tempCommitMade = $true
        }
    }

    # Stop before BCQuality filtering and Copilot startup when the selected
    # review diff contains no AL source. The AL reviewer cannot produce useful
    # findings for non-AL changes, so launching its multi-agent pass would only
    # waste time and AI credits.
    $effectivePath = if ($Path) { $Path } else { $autoPathSpec }
    $diffRange = if ($Mode -eq 'Existing') {
        "$effectiveBase..HEAD"
    }
    else {
        "$effectiveBase...HEAD"
    }
    $nameStatusArgs = @(
        '-C', $RepoPath, 'diff', '--name-status', '--find-renames',
        '--diff-filter=ACMRTD', $diffRange, '--'
    )
    if ($effectivePath) {
        $nameStatusArgs += @($effectivePath -split ';' | ForEach-Object {
            ($_ -replace '\\', '/').Trim()
        } | Where-Object { $_ })
    }
    $nameStatusLines = @(& git @nameStatusArgs 2>$null)
    if ($LASTEXITCODE -ne 0) {
        throw "Could not enumerate files in review diff '$diffRange'."
    }
    $reviewPaths = ConvertFrom-GitNameStatus -Lines $nameStatusLines
    $alReviewFiles = Get-AlReviewFilePaths -Paths $reviewPaths
    if ($alReviewFiles.Count -eq 0) {
        $reportPath = Join-Path $OutputDir '_review-report.json'
        [pscustomobject]@{
            skill            = [pscustomobject]@{ id = 'al-code-review'; version = 1 }
            outcome          = 'not-applicable'
            'outcome-reason' = 'The selected review diff contains no AL (.al) files.'
            summary          = [pscustomobject]@{
                counts   = [pscustomobject]@{ blocker = 0; major = 0; minor = 0; info = 0 }
                coverage = [pscustomobject]@{ 'worklist-size' = 0; 'items-evaluated' = 0 }
            }
            findings         = @()
            suppressed       = @()
            'sub-results'    = @()
            'skipped-sub-skills' = @()
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8

        $metricsPath = Join-Path $OutputDir '_run-metrics.json'
        [pscustomobject]@{
            wall_time_seconds   = 0
            wall_time_display   = '00:00'
            model               = $null
            prompt_tokens       = 0
            cached_tokens       = 0
            completion_tokens   = 0
            reasoning_tokens    = 0
            total_tokens        = 0
            api_calls           = 0
            estimated_credits   = 0.0
            metrics_source      = 'not-applicable'
            cost_note           = 'No Copilot process was launched because the selected diff contains no AL files.'
            log_files_scanned   = @()
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metricsPath -Encoding utf8

        Write-Host '[local-review] No AL (.al) files found in the selected diff; review skipped.'
        Write-Host "[local-review] Findings: $reportPath"
        Write-Host "[local-review] Metrics: $metricsPath"
        if ($shadowRepo -and (Test-Path $shadowRepo)) {
            Remove-Item -Recurse -Force $shadowRepo -ErrorAction SilentlyContinue
        }
        return
    }
    Write-Host "[local-review] AL files in selected diff: $($alReviewFiles.Count)"

    # -----------------------------------------------------------------------
    # Relevance pre-pass: skip feature-gated review domains that have zero
    # signal tokens in the reviewed AL. This is BCQuality-contract-legal —
    # the super-skill forbids filtering leaves by *content*, but explicitly
    # permits the orchestrator to disable a sub-skill via *configuration*
    # (recorded as skipped reason=configuration). We only prune domains that
    # are genuinely feature-gated; always-applicable domains (style, perf,
    # privacy, security, ui, data-modeling, error-handling, upgrade, breaking,
    # appsource) are never pruned here.
    # -----------------------------------------------------------------------
    if (-not $NoPruneDomains) {
        $pruneScopeRel = $null
        if ($Path)             { $pruneScopeRel = ($Path -replace '\\', '/').Trim().TrimEnd('/') }
        elseif ($autoPathSpec) { $pruneScopeRel = ($autoPathSpec -replace '\\', '/').Trim().TrimEnd('/') }
        $alScope =
            if ($pruneScopeRel -and $pruneScopeRel -notmatch '[\*\?\[]') { ":(glob)$pruneScopeRel/**/*.al" }
            elseif ($pruneScopeRel)                                      { ":(glob)$pruneScopeRel" }
            else                                                         { '*.al' }

        $pruneMap = [ordered]@{
            'microsoft/skills/review/al-telemetry-review.md'    = @('Session.LogMessage', 'FeatureTelemetry', 'LogMessage', 'TelemetryScope', 'LogUptake', 'LogUsage')
            'microsoft/skills/review/al-query-review.md'        = @('query')
            'microsoft/skills/review/al-web-services-review.md' = @('PageType = API', 'PageType=API', 'EntitySetName', 'ODataKeyFields', 'WebService', 'tenantwebservice', 'APIPublisher')
            'microsoft/skills/review/al-testing-review.md'      = @('Subtype = Test', 'Subtype=Test', '[Test]', 'Assert', 'TestPage')
            'microsoft/skills/review/al-events-review.md'       = @('IntegrationEvent', 'BusinessEvent', 'EventSubscriber')
            'microsoft/skills/review/al-interfaces-review.md'   = @('interface', 'implements')
        }

        $toDisable = @()
        foreach ($skillPath in $pruneMap.Keys) {
            $grepArgs = @('-C', $RepoPath, 'grep', '-I', '-q', '-i', '-F')
            foreach ($tok in $pruneMap[$skillPath]) { $grepArgs += @('-e', $tok) }
            $grepArgs += @('--', $alScope)
            & git @grepArgs 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { $toDisable += $skillPath }  # exit 1 = no match
        }

        if ($toDisable.Count -gt 0) {
            $existingDisabled = @(($env:BCQUALITY_DISABLED_SKILLS ?? '') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            $env:BCQUALITY_DISABLED_SKILLS = ((@($existingDisabled) + $toDisable) | Select-Object -Unique) -join ','
            $shortNames = $toDisable | ForEach-Object { ($_ -replace '^microsoft/skills/review/al-', '') -replace '-review\.md$', '' }
            Write-Host "[local-review] Domain prune: skipping $($toDisable.Count) zero-signal domain(s): $($shortNames -join ', ')"
        }
        else {
            Write-Host "[local-review] Domain prune: all candidate domains have signal; none pruned."
        }
    }

    # -----------------------------------------------------------------------
    # Optional: filter BCQuality per config (matches the CI workflow)
    # -----------------------------------------------------------------------
    if (-not $SkipBCQualityFilter) {
        Write-Host "[local-review] Filtering BCQuality per $ConfigPath"
        $env:BCQUALITY_CONFIG_PATH = $ConfigPath
        $cfg = & $configScript
        & $filterScript -BCQualityRoot $BCQualityRoot -Config $cfg | Out-Null
    }

    # -----------------------------------------------------------------------
    # Run the reviewer
    # -----------------------------------------------------------------------
    $env:REVIEW_SOURCE           = 'local'
    $env:REVIEW_PHASE            = 'all'
    $env:REVIEW_TARGET_WORKSPACE = $RepoPath
    $env:REVIEW_WORKSPACE        = $RepoPath
    $env:REVIEW_OUTPUT_DIR       = $OutputDir
    $env:BASE_REF                = $effectiveBase
    $env:BCQUALITY_ROOT          = $BCQualityRoot
    $env:BCQUALITY_CONFIG_PATH   = $ConfigPath
    $env:GITHUB_REPOSITORY       = 'local/local'    # placeholder, unused in local mode
    $env:MINIMUM_SEVERITY        = $MinimumSeverity
    # Local runs commonly need the agent to touch git.exe / pwsh.exe outside
    # the target folder. Broaden the CLI sandbox for the local path only.
    $env:COPILOT_ALLOW_ALL_PATHS = 'true'
    # Info-level process logs include usage and token_prices for run metrics.
    $env:COPILOT_REVIEW_LOG_LEVEL = 'info'
    # Existing mode's base is a parent-less synthesized commit → no merge-base
    # exists, so we must use direct `A..B` diff instead of `A...B`.
    if ($Mode -eq 'Existing') { $env:REVIEW_DIFF_STYLE = 'direct' }
    else { Remove-Item Env:REVIEW_DIFF_STYLE -ErrorAction SilentlyContinue }
    if ($Model) { $env:COPILOT_MODEL = $Model }
    # Leaf sub-skill child-agent model (triage tier) + concurrent leaf dispatch.
    if ($LeafModel) { $env:COPILOT_REVIEW_LEAF_MODEL = $LeafModel }
    else { Remove-Item Env:COPILOT_REVIEW_LEAF_MODEL -ErrorAction SilentlyContinue }
    $env:COPILOT_REVIEW_PARALLEL_LEAVES = if ($NoParallelLeaves) { 'false' } else { 'true' }

    if ($effectivePath) {
        # Prefer the engine's diff-scoping (REVIEW_PATH_SPEC) — narrows what
        # the agent sees, not just what it reports. Also set REVIEW_APPLY_TO
        # as a belt-and-suspenders findings filter for anything the agent
        # surfaces from outside the scope.
        $specs = @($effectivePath -split ';' | ForEach-Object {
            ($_ -replace '\\', '/').Trim().TrimEnd('/')
        } | Where-Object { $_ })
        $env:REVIEW_PATH_SPEC = $specs -join ';'
        if ($specs.Count -eq 1) {
            $env:REVIEW_APPLY_TO = if ($specs[0] -match '[\*\?\[]') { $specs[0] } else { "$($specs[0])/**" }
        }
        else {
            # The changed-file set already enforces all pathspecs. The engine's
            # findings glob accepts only one pattern, so do not collapse a
            # semicolon-delimited list into an invalid glob.
            $env:REVIEW_APPLY_TO = '**'
        }
        Write-Host "[local-review] Scoping diff + findings to: $($specs -join '; ')"
    }
    else {
        Remove-Item Env:REVIEW_APPLY_TO -ErrorAction SilentlyContinue
        Remove-Item Env:REVIEW_PATH_SPEC -ErrorAction SilentlyContinue
    }

    Write-Host "[local-review] Invoking $reviewScript"
    $sourceReportPath = Join-Path $BCQualityRoot '_review-report.json'
    $reportPath = Join-Path $OutputDir '_review-report.json'
    Remove-Item -LiteralPath $sourceReportPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    $copilotLogDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.copilot/logs'
    $preexistingLogs = @{}
    if (Test-Path $copilotLogDir) {
        Get-ChildItem $copilotLogDir -File -ErrorAction SilentlyContinue |
            ForEach-Object { $preexistingLogs[$_.Name] = $true }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $reviewScript
    $sw.Stop()
    if ($LASTEXITCODE -ne 0) {
        throw "Reviewer script failed (exit $LASTEXITCODE)"
    }

    if (Test-Path -LiteralPath $sourceReportPath) {
        Copy-Item -LiteralPath $sourceReportPath -Destination $reportPath -Force
    }
    $reportPresent = Test-Path $reportPath
    if (-not $reportPresent) {
        Write-Warning "Reviewer produced no JSON report at $reportPath. Falling back to agent-output.txt (stdout scrape)."
    }
    else {
        Write-Host "[local-review] Findings: $reportPath"
    }

    # -----------------------------------------------------------------------
    # Metrics: wall time + token usage + estimated credit cost from Copilot
    # CLI logs. The reviewer subprocess writes JSONL-ish log files into
    # ~/.copilot/logs; usage blocks and per-model token_prices live there.
    # -----------------------------------------------------------------------
    $metrics = [ordered]@{
        wall_time_seconds  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        wall_time_display  = ('{0:mm\:ss}' -f $sw.Elapsed)
        model              = $env:COPILOT_MODEL
        prompt_tokens      = 0
        cached_tokens      = 0
        completion_tokens  = 0
        reasoning_tokens   = 0
        total_tokens       = 0
        api_calls          = 0
        estimated_credits  = 0.0
        metrics_source     = 'unavailable'
        cost_note          = 'Credits derived from Copilot CLI token_prices (per 1M tokens). These are AI-credit units, not USD.'
        log_files_scanned  = @()
    }

    if (Test-Path $copilotLogDir) {
        $runLogs = @(Get-ChildItem $copilotLogDir -File -Filter 'process-*.log' -ErrorAction SilentlyContinue |
            Where-Object { -not $preexistingLogs.ContainsKey($_.Name) })
        $metrics.log_files_scanned = @($runLogs | ForEach-Object { $_.Name })

        # Grab the most recently seen token_prices block for input/output rates.
        $inputRate  = 0.0
        $outputRate = 0.0
        $batchSize  = 1000000

        foreach ($lf in $runLogs) {
            $raw = Get-Content $lf.FullName -Raw
            # token_prices is embedded JSON — parse just enough of it.
            $priceMatch = [regex]::Match($raw, '"token_prices"\s*:\s*\{[^}]*?"batch_size"\s*:\s*(\d+)[^}]*?"default"\s*:\s*\{[^}]*?"input_price"\s*:\s*(\d+)[^}]*?"output_price"\s*:\s*(\d+)', 'Singleline')
            if ($priceMatch.Success) {
                $batchSize  = [double]$priceMatch.Groups[1].Value
                $inputRate  = [double]$priceMatch.Groups[2].Value
                $outputRate = [double]$priceMatch.Groups[3].Value
            }
            # Each API response logs a `"usage": { "prompt_tokens": .., "completion_tokens": .., "total_tokens": .. }` block.
            foreach ($m in [regex]::Matches($raw, '"usage"\s*:\s*\{\s*"prompt_tokens"\s*:\s*(\d+)\s*,\s*"completion_tokens"\s*:\s*(\d+)\s*,\s*"total_tokens"\s*:\s*(\d+)')) {
                $metrics.prompt_tokens     += [int64]$m.Groups[1].Value
                $metrics.completion_tokens += [int64]$m.Groups[2].Value
                $metrics.total_tokens      += [int64]$m.Groups[3].Value
                $metrics.api_calls         += 1
            }
        }

        if ($batchSize -gt 0 -and ($inputRate + $outputRate) -gt 0) {
            $credits = ($metrics.prompt_tokens * $inputRate + $metrics.completion_tokens * $outputRate) / $batchSize
            $metrics.estimated_credits = [math]::Round($credits, 4)
            $metrics['token_price_input_per_batch']  = $inputRate
            $metrics['token_price_output_per_batch'] = $outputRate
            $metrics['token_price_batch_size']       = $batchSize
        }
        if ($metrics.total_tokens -gt 0 -or $metrics.estimated_credits -gt 0) {
            $metrics.metrics_source = 'process-logs'
        }
    }

    # Copilot CLI always prints its aggregate token and AI-credit summary at
    # process exit. Newer CLI log files may omit per-call usage records, so use
    # the captured transcript as an authoritative aggregate fallback.
    $transcriptMetrics = Get-CopilotSummaryMetrics -TranscriptPath (Join-Path $OutputDir 'agent-transcript.log')
    if ($transcriptMetrics) {
        $usedTranscript = $false
        if ($metrics.total_tokens -eq 0 -and $transcriptMetrics.total_tokens -gt 0) {
            $metrics.prompt_tokens = $transcriptMetrics.input_tokens
            $metrics.cached_tokens = $transcriptMetrics.cached_tokens
            $metrics.completion_tokens = $transcriptMetrics.output_tokens
            $metrics.reasoning_tokens = $transcriptMetrics.reasoning_tokens
            $metrics.total_tokens = $transcriptMetrics.total_tokens
            $usedTranscript = $true
        }
        if ($metrics.estimated_credits -eq 0 -and $transcriptMetrics.credits -gt 0) {
            $metrics.estimated_credits = $transcriptMetrics.credits
            $usedTranscript = $true
        }
        if ($usedTranscript) {
            $metrics.metrics_source = if ($metrics.metrics_source -eq 'process-logs') {
                'process-logs+copilot-cli-summary'
            }
            else {
                'copilot-cli-summary'
            }
            $metrics.cost_note = 'Credits and aggregate tokens reported by the Copilot CLI completion summary. Credits are AI-credit units, not USD.'
        }
    }

    if ($metrics.metrics_source -eq 'unavailable') {
        $metrics.prompt_tokens = $null
        $metrics.cached_tokens = $null
        $metrics.completion_tokens = $null
        $metrics.reasoning_tokens = $null
        $metrics.total_tokens = $null
        $metrics.estimated_credits = $null
        $metrics.cost_note = 'Copilot CLI usage metrics were unavailable from both process logs and the completion summary.'
    }

    $metricsPath = Join-Path $OutputDir '_run-metrics.json'
    $metrics | ConvertTo-Json -Depth 5 | Set-Content -Path $metricsPath -Encoding UTF8
    Write-Host ''
    Write-Host "[local-review] === Run metrics ==="
    Write-Host ("  wall time     : {0}" -f $metrics.wall_time_display)
    Write-Host ("  api calls     : {0}" -f $metrics.api_calls)
    Write-Host ("  tokens        : prompt={0}  completion={1}  total={2}" -f $metrics.prompt_tokens, $metrics.completion_tokens, $metrics.total_tokens)
    Write-Host ("  est. credits  : {0}  (per Copilot CLI token_prices)" -f $metrics.estimated_credits)
    Write-Host ("  written to    : {0}" -f $metricsPath)
    Write-Host ''
}
finally {
    if ($tempCommitMade) {
        Write-Host "[local-review] Restoring original index (undoing temp commit)."
        & git -C $RepoPath reset --soft HEAD~1 | Out-Null
    }
    Restore-LocalGitConfig -Snapshots $pagerConfigSnapshots
}

# ---------------------------------------------------------------------------
# Optional fix pass — always targets the SOURCE folder, never the shadow.
# ---------------------------------------------------------------------------
if ($Fix) {
    $reportPath = Join-Path $OutputDir '_review-report.json'
    $suggestionScript = Join-Path $PSScriptRoot 'Apply-LocalReviewSuggestions.ps1'
    $fixScript = Join-Path $PSScriptRoot 'Invoke-LocalReviewFixes.ps1'
    $appliedFindingIds = @()
    try {
        $mechanicalResult = & $suggestionScript `
            -RepoPath $sourceForOutput `
            -ReportPath $reportPath `
            -MinimumSeverity $MinimumSeverity
        $appliedFindingIds = @($mechanicalResult.applied | ForEach-Object id)
    }
    catch {
        Write-Warning "Mechanical fix pass failed; AI will receive all findings: $_"
    }

    try {
        & $fixScript `
            -RepoPath $sourceForOutput `
            -ReportPath $reportPath `
            -MinimumSeverity $MinimumSeverity `
            -ExcludeFindingId $appliedFindingIds `
            -Model $Model | Out-Null
    }
    catch {
        Write-Warning "AI fix pass failed (review results remain valid): $_"
    }
    Write-Host "[local-review] Fix pass complete. Changes are in: $sourceForOutput"
}

if ($shadowRepo -and (Test-Path $shadowRepo)) {
    Write-Host "[local-review] Removing shadow repo: $shadowRepo"
    Remove-Item -Recurse -Force $shadowRepo -ErrorAction SilentlyContinue
}

Write-Host "[local-review] Done."
