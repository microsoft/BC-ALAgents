# Engine-owned, bounded projections only. Never serialize model objects directly.
function Initialize-ReviewTrace {
    $script:ReviewTrace = [ordered]@{
        schema_version = 1
        status = 'running'
        final_index_basis = '_review-report.json#/findings;zero-based;before-engine-filtering'
        disposition_status = 'not_requested'
        truncated = $false
        candidates = [Collections.Generic.List[object]]::new()
        final_findings = @()
        root_dispositions = @()
        diagnostics = [Collections.Generic.List[object]]::new()
    }
}

function Get-ReviewTraceState {
    $state = Get-Variable ReviewTrace -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($null -eq $state) { Initialize-ReviewTrace }
    return $script:ReviewTrace
}

function Get-TraceProperty {
    param([object] $Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return ,$Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return $null
}

function Get-TraceReferences {
    param([object] $References, [switch] $Paths)
    $result = [Collections.Generic.List[string]]::new()
    foreach ($reference in @($References)) {
        $path = if ($Paths) { $reference } else { Get-TraceProperty $reference 'path' }
        if ($path -isnot [string] -or $path.Length -gt 200 -or
            $path -cnotmatch '^(microsoft|community|custom)/knowledge/[a-z0-9-]+/[a-z0-9-]+\.md$') { continue }
        if (-not $result.Contains($path)) {
            if ($result.Count -eq 8) { (Get-ReviewTraceState).truncated = $true; break }
            $result.Add($path)
        }
    }
    if ($result.Count -eq 0) { return $null }
    return ,@($result.ToArray())
}

function Get-TraceFindingProjection {
    param([object] $Finding)
    $location = Get-TraceProperty $Finding 'location'
    $file = Get-TraceProperty $location 'file'
    $context = Get-Variable FindingsConsumerContext -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($file -isnot [string] -or $file.Length -gt 240 -or
        $file -cnotmatch '^(?!/)(?!.*(?:^|/)\.{1,2}(?:/|$))(?!.*//)[A-Za-z0-9_. /()\-]+$' -or
        $null -eq $context -or -not $context.SourceFiles.ContainsKey($file)) { $file = $null }
    $line = Get-TraceProperty $location 'line'
    $endLine = Get-TraceProperty (Get-TraceProperty $location 'range') 'end-line'
    if ($line -isnot [int] -and $line -isnot [long]) { $line = $null }
    if ($endLine -isnot [int] -and $endLine -isnot [long]) { $endLine = $null }
    if ($null -eq $file -or $line -lt 1 -or $line -gt 2147483647) { $line = $null }
    if ($null -eq $line -or $endLine -lt $line -or $endLine -gt 2147483647) { $endLine = $null }
    $severity = Get-TraceProperty $Finding 'severity'
    if ($severity -cnotin @('blocker', 'major', 'minor', 'info', 'Critical', 'High', 'Medium', 'Low')) { $severity = $null }
    return [ordered]@{
        article_refs = Get-TraceReferences (Get-TraceProperty $Finding 'references')
        location = [ordered]@{ file = $file; line = $line; end_line = $endLine }
        severity = $severity
    }
}

function Get-TraceCandidateBody {
    param([object] $Finding)
    $text = Get-TraceProperty $Finding 'message'
    if ($null -eq $text) { $text = Get-TraceProperty $Finding 'body' }
    if ($text -isnot [string] -or [string]::IsNullOrWhiteSpace($text)) {
        return @{ body = $null; body_status = 'omitted' }
    }
    # Keep the finding's prose, not its code suggestions or report envelope.
    # These are defense-in-depth patterns, not a guarantee against arbitrary secrets.
    $safe = [regex]::Replace($text, '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]', '')
    $safe = [regex]::Replace($safe, '(?i)\b(?:gh[pousr]_[a-z0-9_]+|github_pat_[a-z0-9_]+)\b', '[REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)\bBearer\s+[a-z0-9._~+/\-=]+', 'Bearer [REDACTED]')
    $safe = [regex]::Replace($safe, '(?i)\b(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*(?:"[^"]*"|''[^'']*''|[^\s,;]+)', '$1=[REDACTED]')
    $status = if ($safe -cne $text) { 'redacted' } else { 'retained' }
    if ($safe.Length -gt 1024) {
        $safe = $safe.Substring(0, 1024)
        if ([char]::IsHighSurrogate($safe[$safe.Length - 1])) { $safe = $safe.Substring(0, $safe.Length - 1) }
        if ($status -ne 'redacted') { $status = 'truncated' }
        (Get-ReviewTraceState).truncated = $true
    }
    return @{ body = $safe; body_status = $status }
}

function Add-ReviewTraceCandidates {
    param([object] $Leaf, [object] $Report, [string] $ReportHash)
    $trace = Get-ReviewTraceState
    $leafId = [string]$Leaf.id
    if ($leafId.Length -gt 80 -or $leafId -cnotmatch '^[a-z0-9-]+$') { $leafId = $null }
    $findings = Get-TraceProperty $Report 'findings'
    if ($null -eq $findings) { $findings = @() }
    for ($i = 0; $i -lt $findings.Count; $i++) {
        if ($null -eq $findings[$i]) { continue }
        if ($trace.candidates.Count -ge 1000) { $trace.truncated = $true; break }
        $projection = Get-TraceFindingProjection $findings[$i]
        $body = Get-TraceCandidateBody $findings[$i]
        $trace.candidates.Add([ordered]@{
            candidate_id = "l$($Leaf.ordinal)-f$i"
            leaf_id = $leafId
            leaf_ordinal = [int]$Leaf.ordinal
            finding_index = $i
            report_sha256 = if ($ReportHash -cmatch '^[a-f0-9]{64}$') { $ReportHash } else { $null }
            admission = 'unknown'
            body = $body.body
            body_status = $body.body_status
            article_refs = $projection.article_refs
            location = $projection.location
            severity = $projection.severity
            normalizations = @()
        })
    }
}

function Set-ReviewTraceAdmission {
    param([int] $Ordinal, [ValidateSet('accepted', 'rejected')][string] $Admission, [object[]] $Changes = @())
    foreach ($candidate in (Get-ReviewTraceState).candidates) {
        if ($candidate.leaf_ordinal -ne $Ordinal) { continue }
        $candidate.admission = $Admission
        $candidate.normalizations = @($Changes | Where-Object {
            $_.finding_index -eq $candidate.finding_index -and $_.kind -in @('finding-id', 'location-range')
        } | ForEach-Object { $_.kind } | Select-Object -Unique)
    }
}

function Add-ReviewTraceDiagnostic {
    param(
        [ValidateSet('leaf', 'root', 'run')][string] $Role,
        [object] $Ordinal,
        [ValidateSet('process-start', 'process-exit', 'telemetry', 'report-read', 'report-parse', 'report-validation', 'report-outcome', 'consolidation', 'unknown')][string] $Stage = 'unknown',
        [ValidateSet('start_failed', 'timeout', 'nonzero_exit', 'process_not_exited', 'telemetry_invalid', 'report_missing', 'report_invalid_json', 'report_invalid', 'report_failed', 'report_partial', 'coverage_partial', 'all_leaves_failed', 'unknown_failure')][string] $Code,
        [ValidateSet('completed', 'failed', 'unknown')][string] $ProcessStatus = 'unknown',
        [object] $ReportOutcome,
        [object] $ExitCode
    )
    $trace = Get-ReviewTraceState
    if ($trace.diagnostics.Count -ge 128) { $trace.truncated = $true; return }
    if ($ReportOutcome -cnotin @('completed', 'not-applicable', 'no-knowledge', 'partial', 'failed')) { $ReportOutcome = $null }
    $trace.diagnostics.Add([ordered]@{
        role = $Role; ordinal = $Ordinal; stage = $Stage
        code = if ($Code) { $Code } else { $null }
        process_status = $ProcessStatus; report_outcome = $ReportOutcome; exit_code = $ExitCode
    })
}

function Save-ReviewTrace {
    param([string] $OutputDir, [ValidateSet('running', 'completed', 'partial', 'failed')][string] $Status)
    $trace = Get-ReviewTraceState
    $trace.status = $Status
    $mappedIds = @($trace.root_dispositions | ForEach-Object { $_.candidate_id })
    $trace.root_dispositions = @($trace.root_dispositions) + @(
        foreach ($candidate in $trace.candidates) {
            if ($candidate.candidate_id -cin $mappedIds) { continue }
            [ordered]@{
                candidate_id = $candidate.candidate_id; disposition = 'unknown'
                final_indices = $null; basis = 'unknown'; reason_code = $null; article_refs = $null
            }
        }
    )
    $json = $trace | ConvertTo-Json -Depth 12 -Compress
    while ([Text.Encoding]::UTF8.GetByteCount($json) -gt 4194300 -and $trace.candidates.Count -gt 0) {
        $trace.truncated = $true
        $count = [Math]::Min(100, $trace.candidates.Count)
        $trace.candidates.RemoveRange($trace.candidates.Count - $count, $count)
        $ids = @($trace.candidates | ForEach-Object { $_.candidate_id })
        $trace.root_dispositions = @($trace.root_dispositions | Where-Object { $_.candidate_id -cin $ids })
        $json = $trace | ConvertTo-Json -Depth 12 -Compress
    }
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 4194300) { throw 'Bounded review trace exceeded 4 MiB.' }
    $schema = Join-Path $EngineRoot 'agents/ALReviewAgent/schemas/review-trace.schema.json'
    if (-not ($json | Test-Json -SchemaFile $schema -ErrorAction Stop)) { throw 'Engine review trace projection is invalid.' }
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $OutputDir '_review-trace.json') -Value $json -Encoding utf8
}

function Initialize-RootTraceInput {
    param([string] $WorkDir)
    $trace = Get-ReviewTraceState
    $trace.disposition_status = 'missing'
    $inputObject = [ordered]@{ schema_version = 1; candidates = @($trace.candidates | Where-Object { $_.admission -eq 'accepted' }) }
    $inputObject | ConvertTo-Json -Depth 10 -Compress |
        Set-Content -LiteralPath (Join-Path $WorkDir '_trace-candidates.json') -Encoding utf8
    $path = Join-Path $WorkDir '_root-dispositions.json'
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Complete-ReviewTrace {
    param([object] $Report, [string] $DispositionPath)
    $trace = Get-ReviewTraceState
    $final = [Collections.Generic.List[object]]::new()
    $findings = Get-TraceProperty $Report 'findings'
    if ($null -eq $findings) { $findings = @() }
    for ($i = 0; $i -lt $findings.Count; $i++) {
        if ($null -eq $findings[$i]) { continue }
        if ($final.Count -eq 1000) { $trace.truncated = $true; break }
        $projection = Get-TraceFindingProjection $findings[$i]
        $projection['final_index'] = $i
        $final.Add($projection)
    }
    $trace.final_findings = @($final.ToArray())
    $decisions = @()
    $trace.disposition_status = 'missing'
    if (Test-Path -LiteralPath $DispositionPath -PathType Leaf) {
        $trace.disposition_status = 'invalid'
        if ((Get-Item -LiteralPath $DispositionPath).Length -le 1048576) {
            try {
                $parsed = Get-Content -LiteralPath $DispositionPath -Raw | ConvertFrom-Json -Depth 12 -ErrorAction Stop
                if ((Get-TraceProperty $parsed 'schema_version') -eq 1) {
                    $supplied = Get-TraceProperty $parsed 'dispositions'
                    if ($supplied -is [array] -and $supplied.Count -le 1000) {
                        $decisions = $supplied
                        $trace.disposition_status = 'provided'
                    }
                }
            }
            catch {
                # This optional model output never changes review eligibility.
                Write-Warning 'Optional root trace could not be read as bounded JSON; lineage remains unknown.'
            }
        }
    }
    $mapped = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $trace.candidates) {
        $row = [ordered]@{
            candidate_id = $candidate.candidate_id; disposition = 'unknown'
            final_indices = $null; basis = 'unknown'; reason_code = $null; article_refs = $null
        }
        $declarations = @($decisions | Where-Object { (Get-TraceProperty $_ 'candidate_id') -ceq $candidate.candidate_id })
        if ($declarations.Count -eq 1 -and $candidate.admission -eq 'accepted') {
            $decision = $declarations[0]
            $action = Get-TraceProperty $decision 'disposition'
            $indices = Get-TraceProperty $decision 'final_indices'
            $valid = $indices -is [array] -and $indices.Count -le 8
            foreach ($index in @($indices)) {
                if (($index -isnot [int] -and $index -isnot [long]) -or $index -lt 0 -or $index -ge $final.Count) { $valid = $false }
            }
            if (@($indices | Select-Object -Unique).Count -ne @($indices).Count) { $valid = $false }
            if (($action -ceq 'removed' -and @($indices).Count -ne 0) -or
                ($action -cin @('kept', 'merged', 'downgraded') -and @($indices).Count -eq 0)) { $valid = $false }
            if ($valid -and $action -cin @('kept', 'merged', 'downgraded', 'removed')) {
                $row.disposition = $action
                $row.final_indices = $indices
                $row.basis = 'model_declared'
                $reason = Get-TraceProperty $decision 'reason_code'
                if ($reason -cin @('duplicate', 'severity_reassessment', 'unsupported', 'out_of_scope', 'not_actionable')) { $row.reason_code = $reason }
                $row.article_refs = Get-TraceReferences (Get-TraceProperty $decision 'article_refs') -Paths
            }
        }
        $mapped.Add($row)
    }
    $trace.root_dispositions = @($mapped.ToArray())
}
