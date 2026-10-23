BeforeAll {
    $EngineRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/ReviewTrace.ps1')
    function New-TraceFinding {
        [pscustomobject]@{
            severity = 'major'
            location = [pscustomobject]@{ file = 'src/Example.al'; line = 12 }
            references = @([pscustomobject]@{ path = 'microsoft/knowledge/security/secrettext-for-credentials.md' })
            message = 'A real functional concern from the original leaf.'
            'suggested-code' = 'private code'
        }
    }
}

Describe 'Bounded reviewer trace' {
    BeforeEach {
        Initialize-ReviewTrace
        $script:FindingsConsumerContext = [pscustomobject]@{ SourceFiles = @{ 'src/Example.al' = @{ exists = $true; line_count = 40 } } }
        $leaf = [pscustomobject]@{ id = 'al-security-review'; ordinal = 1 }
        $finding = New-TraceFinding
        $report = [pscustomobject]@{ findings = @($finding) }
        $sidecar = Join-Path $TestDrive 'root.json'
        if (Test-Path $sidecar) { Remove-Item $sidecar }
    }

    It 'binds stable run-local identities to original leaf order and hash without mutating reports' {
        $before = $report | ConvertTo-Json -Depth 10
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        $candidate = (Get-ReviewTraceState).candidates[0]
        $candidate.candidate_id | Should -BeExactly 'l1-f0'
        $candidate.report_sha256 | Should -Be ('a' * 64)
        $candidate.article_refs | Should -HaveCount 1
        $candidate.article_refs[0] | Should -Be 'microsoft/knowledge/security/secrettext-for-credentials.md'
        ($report | ConvertTo-Json -Depth 10) | Should -BeExactly $before
        Initialize-ReviewTrace
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        (Get-ReviewTraceState).candidates[0].candidate_id | Should -BeExactly $candidate.candidate_id
    }

    It 'records a model-declared disposition without semantic guessing' -ForEach @('kept', 'merged', 'downgraded', 'removed') {
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        Set-ReviewTraceAdmission 1 accepted
        $indices = @()
        if ($_ -ne 'removed') { $indices = @(0) }
        @{ schema_version = 1; dispositions = @(@{
            candidate_id = 'l1-f0'; disposition = $_; final_indices = $indices
            reason_code = 'duplicate'; article_refs = $null
        }) } | ConvertTo-Json -Depth 6 | Set-Content $sidecar
        Complete-ReviewTrace $report $sidecar
        $row = (Get-ReviewTraceState).root_dispositions[0]
        $row.disposition | Should -BeExactly $_
        $row.basis | Should -BeExactly 'model_declared'
        $row.final_indices.Count | Should -Be $indices.Count
    }

    It 'supports explicit many-to-one merge while preserving individual sources' {
        Add-ReviewTraceCandidates $leaf ([pscustomobject]@{ findings = @($finding, $finding) }) ('a' * 64)
        Set-ReviewTraceAdmission 1 accepted
        @{ schema_version = 1; dispositions = @(
            @{ candidate_id = 'l1-f0'; disposition = 'merged'; final_indices = @(0) },
            @{ candidate_id = 'l1-f1'; disposition = 'merged'; final_indices = @(0) }
        ) } | ConvertTo-Json -Depth 6 | Set-Content $sidecar
        Complete-ReviewTrace $report $sidecar
        $rows = (Get-ReviewTraceState).root_dispositions
        $rows | Should -HaveCount 2
        $rows[0].final_indices[0] | Should -Be 0
        $rows[1].final_indices[0] | Should -Be 0
    }

    It 'does not infer removal or root origin from matching text or counts when lineage is absent' {
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        Set-ReviewTraceAdmission 1 accepted
        Complete-ReviewTrace ([pscustomobject]@{ findings = @() }) $sidecar
        $trace = Get-ReviewTraceState
        $trace.disposition_status | Should -Be 'missing'
        $trace.root_dispositions[0].disposition | Should -Be 'unknown'
        $trace.root_dispositions[0].final_indices | Should -BeNullOrEmpty
    }

    It 'rejects invalid links, duplicate decisions and non-admitted candidates as unknown' {
        Add-ReviewTraceCandidates $leaf ([pscustomobject]@{ findings = @($finding, $finding, $finding) }) ('a' * 64)
        Set-ReviewTraceAdmission 1 accepted
        (Get-ReviewTraceState).candidates[2].admission = 'rejected'
        @{ schema_version = 1; dispositions = @(
            @{ candidate_id = 'l1-f0'; disposition = 'kept'; final_indices = @(9) },
            @{ candidate_id = 'l1-f1'; disposition = 'removed'; final_indices = @() },
            @{ candidate_id = 'l1-f1'; disposition = 'kept'; final_indices = @(0) },
            @{ candidate_id = 'l1-f2'; disposition = 'kept'; final_indices = @(0) },
            @{ candidate_id = 'l9-f9'; disposition = 'kept'; final_indices = @(0) }
        ) } | ConvertTo-Json -Depth 6 | Set-Content $sidecar
        Complete-ReviewTrace $report $sidecar
        @((Get-ReviewTraceState).root_dispositions | Where-Object disposition -ne unknown) | Should -HaveCount 0
    }

    It 'retains deterministic normalization separately from model lineage' {
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        Set-ReviewTraceAdmission 1 accepted @([pscustomobject]@{ finding_index = 0; kind = 'finding-id' })
        $candidate = (Get-ReviewTraceState).candidates[0]
        $candidate.normalizations | Should -Be @('finding-id')
        $candidate.severity | Should -Be 'major'
    }

    It 'retains finding prose but never copies code, absolute paths, unknown refs or reasons' {
        $finding.location.file = 'C:/private/token.txt'
        $finding.references = @([pscustomobject]@{ path = 'https://example.test/?token=secret' })
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        Set-ReviewTraceAdmission 1 accepted
        @{ schema_version = 1; dispositions = @(@{
            candidate_id = 'l1-f0'; disposition = 'kept'; final_indices = @(0)
            reason_code = 'secret'; reason = 'private explanation'
            article_refs = @('C:/private/token.txt')
        }) } | ConvertTo-Json -Depth 6 | Set-Content $sidecar
        Complete-ReviewTrace $report $sidecar
        Save-ReviewTrace $TestDrive completed
        $json = Get-Content (Join-Path $TestDrive '_review-trace.json') -Raw
        $json | Should -Not -Match 'private|secret|example.test|message|suggested-code'
        $json | Should -Match 'A real functional concern'
        (Get-ReviewTraceState).candidates[0].article_refs | Should -BeNullOrEmpty
        (Get-ReviewTraceState).candidates[0].location.file | Should -BeNullOrEmpty
    }

    It 'bounds and redacts candidate text with explicit indicators' {
        $finding.message = 'token=ghp_sensitive_value ' + ('x' * 1100)
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        $candidate = (Get-ReviewTraceState).candidates[0]
        $candidate.body.Length | Should -BeLessOrEqual 1024
        $candidate.body | Should -Not -Match 'ghp_sensitive_value'
        $candidate.body_status | Should -Be redacted
        (Get-ReviewTraceState).truncated | Should -BeTrue
    }

    It 'keeps exit-zero report failures and all-completed partial status explicit' {
        Add-ReviewTraceDiagnostic -Role leaf -Ordinal 1 -Stage report-outcome -Code report_failed -ProcessStatus completed -ReportOutcome failed -ExitCode 0
        Add-ReviewTraceDiagnostic -Role root -Ordinal 2 -Stage report-outcome -Code report_partial -ProcessStatus completed -ReportOutcome partial -ExitCode 0
        Save-ReviewTrace $TestDrive partial
        $trace = Get-Content (Join-Path $TestDrive '_review-trace.json') -Raw | ConvertFrom-Json
        $trace.status | Should -Be 'partial'
        $trace.diagnostics[0].process_status | Should -Be 'completed'
        $trace.diagnostics[0].report_outcome | Should -Be 'failed'
        $trace.diagnostics[1].code | Should -Be 'report_partial'
    }

    It 'treats malformed or oversized optional root JSON as unknown without failing review' -ForEach @('invalid', 'large') {
        Add-ReviewTraceCandidates $leaf $report ('a' * 64)
        Set-ReviewTraceAdmission 1 accepted
        $(if ($_ -eq 'invalid') { '{invalid' } else { 'x' * 1048577 }) | Set-Content $sidecar
        { Complete-ReviewTrace $report $sidecar } | Should -Not -Throw
        (Get-ReviewTraceState).disposition_status | Should -Be 'invalid'
        (Get-ReviewTraceState).root_dispositions[0].basis | Should -Be 'unknown'
    }

    It 'bounds candidate/final/diagnostic counts and serialization with explicit truncation' {
        $many = [pscustomobject]@{ findings = @((1..1002) | ForEach-Object { $finding }) }
        Add-ReviewTraceCandidates $leaf $many ('a' * 64)
        1..130 | ForEach-Object { Add-ReviewTraceDiagnostic -Role run -Stage unknown -Code unknown_failure }
        Complete-ReviewTrace $many $sidecar
        Save-ReviewTrace $TestDrive failed
        $trace = Get-ReviewTraceState
        $trace.candidates.Count | Should -Be 1000
        $trace.final_findings.Count | Should -Be 1000
        $trace.diagnostics.Count | Should -Be 128
        $trace.truncated | Should -BeTrue
        (Get-Item (Join-Path $TestDrive '_review-trace.json')).Length | Should -BeLessThan 4194304
    }

    It 'validates the published collector fixture against the exact schema' {
        $json = Get-Content (Join-Path $PSScriptRoot 'fixtures/review-trace.v1.json') -Raw
        ($json | Test-Json -SchemaFile (Join-Path $EngineRoot 'agents/ALReviewAgent/schemas/review-trace.schema.json')) | Should -BeTrue
    }

    It 'serializes absent hashes and invalid ranges as null with unknown dispositions on failure' {
        $finding.location | Add-Member -NotePropertyName range -NotePropertyValue ([pscustomobject]@{ 'end-line' = 1 })
        Add-ReviewTraceCandidates $leaf $report ''
        Save-ReviewTrace $TestDrive failed
        $trace = Get-Content (Join-Path $TestDrive '_review-trace.json') -Raw | ConvertFrom-Json
        $trace.candidates[0].report_sha256 | Should -BeNullOrEmpty
        $trace.candidates[0].location.end_line | Should -BeNullOrEmpty
        $trace.root_dispositions[0].disposition | Should -Be unknown
    }

    It 'enforces total UTF-8 size and removes dangling relations on candidate truncation' {
        $finding.message = [string][char]0x4e2d * 1024
        $finding.references = @(1..8 | ForEach-Object {
            [pscustomobject]@{ path = "microsoft/knowledge/security/$('a' * 160)-$_.md" }
        })
        $many = [pscustomobject]@{ findings = @((1..1000) | ForEach-Object { $finding }) }
        Add-ReviewTraceCandidates $leaf $many ('a' * 64)
        Complete-ReviewTrace $many $sidecar
        Save-ReviewTrace $TestDrive completed
        $trace = Get-Content (Join-Path $TestDrive '_review-trace.json') -Raw | ConvertFrom-Json
        (Get-Item (Join-Path $TestDrive '_review-trace.json')).Length | Should -BeLessOrEqual 4194304
        $trace.truncated | Should -BeTrue
        $trace.candidates.Count | Should -BeLessThan 1000
        @($trace.root_dispositions | Where-Object candidate_id -NotIn $trace.candidates.candidate_id) | Should -HaveCount 0
    }
}
