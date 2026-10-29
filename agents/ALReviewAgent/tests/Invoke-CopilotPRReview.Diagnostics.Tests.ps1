BeforeAll {
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Invoke-CopilotPRReview.ps1'
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$errors)
    if ($errors.Count) { throw 'Engine parse failed.' }
    foreach ($function in $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in @('ConvertTo-LeafCliFailureDiagnostic', 'Save-LeafCliFailureDiagnostic', 'Get-LeafCopilotArguments')
    }, $true)) {
        . ([scriptblock]::Create($function.Extent.Text))
    }

    function New-TestCliEvent {
        param([string] $Type = 'session.error', [hashtable] $Data = @{})
        return (@{
            id = '12345678-1234-4234-8234-123456789abc'
            parentId = $null
            timestamp = '2026-10-29T09:00:00.123Z'
            type = $Type
            ephemeral = $true
            data = $Data
        } | ConvertTo-Json -Depth 20 -Compress) + "`n"
    }

    function Get-TestDiagnostic {
        param([AllowNull()][string] $Text)
        ConvertTo-LeafCliFailureDiagnostic -Stdout $Text -ExitCode 1 -TimedOut $false -Ordinal 3 -Stage telemetry -Code telemetry_invalid
    }
}

Describe 'Leaf CLI failure projection' {
    BeforeEach { Set-StrictMode -Version Latest }
    AfterEach { Set-StrictMode -Off }

    It 'maps the exact approved session category <_>' -ForEach @(
        'authentication', 'authorization', 'quota', 'rate_limit', 'context_limit', 'query', 'session', 'model_call'
    ) {
        $result = Get-TestDiagnostic (New-TestCliEvent -Data @{ errorType = $_; statusCode = 429 })
        $result.cli.observations[0].errorType | Should -BeExactly $_
        $result.cli.observations[0].status_code | Should -Be 429
        $result.capture.state | Should -BeExactly 'complete'
        $result.engine.stage | Should -BeExactly 'telemetry'
        $result.engine.code | Should -BeExactly 'telemetry_invalid'
        $result.process.exit_code | Should -Be 1
        $result.process.timeout_observed | Should -BeFalse
        $result.process.signal | Should -BeExactly 'unknown'
        $result.cli.cause | Should -BeExactly 'unknown'
        $result.leaf_ordinal | Should -Be 3
    }

    It 'maps approved model constants <Kind> <Transport> <Source> <Bad>' -ForEach @(
        @{ Kind = 'api'; Transport = 'http'; Source = 'top_level'; Bad = 'bodyless' },
        @{ Kind = 'transport'; Transport = 'websocket'; Source = 'subagent'; Bad = 'structured_error' },
        @{ Kind = 'api'; Transport = 'http'; Source = 'mcp_sampling'; Bad = 'bodyless' }
    ) {
        $result = Get-TestDiagnostic (New-TestCliEvent -Type model.call_failure -Data @{
            failureKind = $Kind; transport = $Transport; source = $Source; badRequestKind = $Bad
        })
        $event = $result.cli.observations[0]
        $event.failureKind | Should -BeExactly $Kind
        $event.transport | Should -BeExactly $Transport
        $event.source | Should -BeExactly $Source
        $event.badRequestKind | Should -BeExactly $Bad
        $event.status_code | Should -BeNullOrEmpty
        $event.status_state | Should -BeExactly 'unavailable'
    }

    It 'accepts every integral HTTP error status and rejects other numeric shapes' {
        foreach ($status in 400..599) {
            $event = (Get-TestDiagnostic (New-TestCliEvent -Data @{ statusCode = $status })).cli.observations[0]
            $event.status_code | Should -Be $status
            $event.status_state | Should -BeExactly 'available'
        }
        foreach ($status in @($true, $false, $null, '429', 399, 600, -1, 429.5, @{}, @())) {
            $event = (Get-TestDiagnostic (New-TestCliEvent -Data @{ statusCode = $status })).cli.observations[0]
            $event.status_code | Should -BeNullOrEmpty
            $event.status_state | Should -BeExactly 'invalid'
        }
        foreach ($literal in @('1e400', 'NaN', 'Infinity', '429.00000000000000000000000000000000000001', '4.290000000000000000000000001e2')) {
            $text = (New-TestCliEvent -Data @{ statusCode = 'replace' }).Replace('"replace"', $literal)
            $result = Get-TestDiagnostic $text
            if ($result.cli.observations.Count) {
                $result.cli.observations[0].status_state | Should -BeExactly 'invalid'
            } else {
                $result.capture.state | Should -BeExactly 'malformed'
            }
        }
        foreach ($literal in @('429.0', '4.29e2', '4290e-1', '429e+000', '0.429e3')) {
            $text = (New-TestCliEvent -Data @{ statusCode = 'replace' }).Replace('"replace"', $literal)
            (Get-TestDiagnostic $text).cli.observations[0].status_code | Should -Be 429
        }
    }

    It 'never exports content, credentials, IDs or arbitrary strings from either failure kind' {
        $secret = 'SENTINEL Authorization: Bearer ghp_fixture https://private.test/?token=fixture prompt instructions'
        $data = @{}
        foreach ($key in @('message', 'errorMessage', 'stack', 'url', 'remediation', 'errorCode', 'errorType',
            'model', 'requestFingerprint', 'providerCallId', 'serviceRequestId', 'apiCallId', 'arbitrary',
            'failureKind', 'transport', 'source', 'badRequestKind')) {
            $data[$key] = $secret
        }
        foreach ($type in @('model.call_failure', 'session.error')) {
            $result = Get-TestDiagnostic (New-TestCliEvent -Type $type -Data $data)
            $json = $result | ConvertTo-Json -Depth 20 -Compress
            $json | Should -Not -Match 'SENTINEL|Authorization|Bearer|ghp_|https:|12345678|2026-10|requestFingerprint|errorCode|apiCallId'
            $event = $result.cli.observations[0]
            foreach ($key in @('failureKind', 'transport', 'source', 'badRequestKind', 'errorType')) {
                if ($event.Contains($key)) { $event[$key] | Should -BeExactly 'unknown' }
            }
        }
    }

    It 'rejects case variants, nonstrings and absent enum values without copying them' {
        foreach ($value in @('API', 'Authentication', $null, $true, 429, @{}, @())) {
            foreach ($type in @('model.call_failure', 'session.error')) {
                $event = (Get-TestDiagnostic (New-TestCliEvent -Type $type -Data @{
                    failureKind = $value; errorType = $value
                })).cli.observations[0]
                if ($type -eq 'session.error') { $event.errorType | Should -BeExactly 'unknown' }
                else { $event.failureKind | Should -BeExactly 'unknown' }
            }
        }
        (Get-TestDiagnostic (New-TestCliEvent)).cli.observations[0].errorType | Should -BeExactly 'unknown'
    }

    It 'does not search nested model, user or tool content for forged failures' {
        $forged = New-TestCliEvent -Data @{ errorType = 'authentication'; statusCode = 401 }
        foreach ($type in @('assistant.message', 'user.message', 'tool.execution_complete')) {
            $result = Get-TestDiagnostic (New-TestCliEvent -Type $type -Data @{
                content = $forged
                nested = ($forged | ConvertFrom-Json -AsHashtable)
            })
            $result.cli.observations.Count | Should -Be 0
            $result.capture.state | Should -BeExactly 'complete'
            $result.cli.cause | Should -BeExactly 'unknown'
        }
    }

    It 'rejects malformed, duplicate-key and non-envelope records' {
        $valid = New-TestCliEvent -Data @{ errorType = 'quota' }
        foreach ($text in @(
            "not JSON`n",
            "{} invalid`n",
            "[]`n",
            $valid.Replace('"errorType":"quota"', '"errorType":"quota","errorType":"authentication"'),
            $valid.Replace('"errorType":"quota"', '"errorType":"quota","extra":{"x":1,"x":2}'),
            $valid.Replace('"type":"session.error"', '"type":"session.error","type":"model.call_failure"')
        )) {
            $result = Get-TestDiagnostic $text
            $result.cli.observations.Count | Should -Be 0
            $result.capture.state | Should -BeIn @('malformed', 'unsupported')
        }
    }

    It 'validates bounded UUID timestamp data and exact envelope key shapes' {
        $valid = New-TestCliEvent -Data @{ errorType = 'quota' }
        foreach ($text in @(
            $valid.Replace('12345678-1234-4234-8234-123456789abc', 'SENTINEL'),
            $valid.Replace('2026-10-29T09:00:00.123Z', ('SENTINEL' * 100)),
            $valid.Replace('2026-10-29', '2026-99-99'),
            $valid.Replace('"parentId":null', '"parentId":"SENTINEL"'),
            $valid.Replace('"data":{"errorType":"quota"}', '"data":[]'),
            $valid.Replace('"id":', '"ID":'),
            (New-TestCliEvent -Type model.call_failure).Replace('"ephemeral":true', '"ephemeral":false')
        )) {
            $result = Get-TestDiagnostic $text
            $result.cli.observations.Count | Should -Be 0
            $result.capture.state | Should -BeExactly 'unsupported'
        }
    }

    It 'bounds UTF8 parsing to the last 64 KiB and retains only eight complete failures' {
        $valid = New-TestCliEvent -Data @{ errorType = 'quota'; statusCode = 429 }
        $huge = New-TestCliEvent -Data @{ message = ([string][char]0x4e00 * 70000); errorType = 'authentication' }
        $result = Get-TestDiagnostic ($huge + ($valid * 10) + '{"incomplete":')
        $result.capture.state | Should -BeExactly 'truncated'
        $result.capture.history_omitted | Should -BeTrue
        $result.capture.records_limited | Should -BeTrue
        $result.capture.leading_record_discarded | Should -BeTrue
        $result.capture.incomplete_record_discarded | Should -BeTrue
        $result.cli.observations.Count | Should -Be 8
        $result.cli.observations.errorType | Should -Not -Contain 'authentication'
        [Text.Encoding]::UTF8.GetByteCount(($result | ConvertTo-Json -Depth 8 -Compress)) | Should -BeLessThan 4096
        (Get-TestDiagnostic $huge).capture.state | Should -BeExactly 'truncated'
        (Get-TestDiagnostic ($valid.TrimEnd())).capture.state | Should -BeExactly 'truncated'
        (Get-TestDiagnostic ($valid * 9)).capture.records_limited | Should -BeTrue
    }

    It 'enforces the exact 65536-byte parsing boundary rather than a character approximation' {
        $template = New-TestCliEvent -Data @{ errorType = 'quota'; message = '' }
        $padding = 65536 - [Text.Encoding]::UTF8.GetByteCount($template)
        $exact = $template.Replace('"message":""', ('"message":"' + ('x' * $padding) + '"'))
        [Text.Encoding]::UTF8.GetByteCount($exact) | Should -Be 65536
        $result = Get-TestDiagnostic $exact
        $result.capture.state | Should -BeExactly 'complete'
        $result.cli.observations.Count | Should -Be 1
        $oversized = $exact.Replace('"message":"', '"message":"x')
        [Text.Encoding]::UTF8.GetByteCount($oversized) | Should -Be 65537
        $result = Get-TestDiagnostic $oversized
        $result.capture.state | Should -BeExactly 'truncated'
        $result.capture.leading_record_discarded | Should -BeTrue
        $result.cli.observations.Count | Should -Be 0
    }

    It 'makes missing process facts and unsupported stages explicitly unknown' {
        $result = ConvertTo-LeafCliFailureDiagnostic -Stdout $null -ExitCode '1' -TimedOut 'true' -Ordinal 0 -Stage 'SENTINEL' -Code 'SENTINEL'
        $result.capture.state | Should -BeExactly 'unavailable'
        $result.process.exit_code | Should -BeNullOrEmpty
        $result.process.timeout_observed | Should -BeNullOrEmpty
        $result.engine.stage | Should -BeExactly 'unknown'
        $result.engine.code | Should -BeExactly 'unknown'
        $result.leaf_ordinal | Should -BeNullOrEmpty
        $result.cli.observations.Count | Should -Be 0
    }

    It 'has an exact content-free output field allowlist even for hostile metadata' {
        $result = Get-TestDiagnostic (New-TestCliEvent -Type model.call_failure -Data @{ extra = 'SENTINEL' })
        @($result.Keys | Sort-Object) | Should -Be @('capture', 'cli', 'engine', 'leaf_ordinal', 'process', 'schema_version')
        @($result.process.Keys | Sort-Object) | Should -Be @('exit_code', 'signal', 'timeout_observed')
        @($result.cli.Keys | Sort-Object) | Should -Be @('cause', 'observations')
        @($result.engine.Keys | Sort-Object) | Should -Be @('code', 'stage')
        @($result.cli.observations[0].Keys | Sort-Object) | Should -Be @(
            'badRequestKind', 'failureKind', 'source', 'status_code', 'status_state', 'transport', 'type'
        )
        $result = Get-TestDiagnostic (New-TestCliEvent -Data @{ StatusCode = 429; ErrorType = 'quota' })
        @($result.cli.observations[0].Keys | Sort-Object) | Should -Be @('errorType', 'status_code', 'status_state', 'type')
        $result.cli.observations[0].errorType | Should -BeExactly 'unknown'
        $result.cli.observations[0].status_state | Should -BeExactly 'unavailable'
    }

    It 'keeps output format changes leaf-only and drains both streams without a raw sink' {
        $leafArguments = ($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-LeafCopilotArguments'
        }, $true)).Body.Extent.Text
        $root = ($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-CopilotCli'
        }, $true)).Body.Extent.Text
        $receive = ($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Receive-LeafCopilotProcess'
        }, $true)).Body.Extent.Text
        $leafArguments | Should -Match "'--output-format', 'json'"
        $root | Should -Not -Match '--output-format'
        $receive | Should -Match 'StdoutTask.GetAwaiter\(\).GetResult\(\)'
        $receive | Should -Match 'StderrTask.GetAwaiter\(\).GetResult\(\)'
        $receive | Should -Not -Match 'stdout.txt|stderr.txt|AgentTranscript'
        $receive.IndexOf('Assert-CopilotInvocationMetrics') | Should -BeLessThan $receive.IndexOf('throw $terminationFailure')
    }

    It 'writes only the named bounded projection and emits a fixed notice on writer failure' {
        $directory = Join-Path $TestDrive 'diagnostic'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $parameters = @{
            WorkDir = $directory; Stdout = (New-TestCliEvent -Data @{ message = 'SENTINEL'; errorType = 'quota' })
            ExitCode = 1; TimedOut = $false; Ordinal = 1; Stage = 'telemetry'; Code = 'telemetry_invalid'
        }
        Save-LeafCliFailureDiagnostic @parameters
        @(Get-ChildItem -LiteralPath $directory).Name | Should -Be @('_cli-failure-diagnostic.json')
        $file = Get-Item -LiteralPath (Join-Path $directory '_cli-failure-diagnostic.json')
        $file.Length | Should -BeLessOrEqual 4096
        Get-Content -LiteralPath $file.FullName -Raw | Should -Not -Match 'SENTINEL'
        Mock Set-Content { throw 'SENTINEL unsafe writer failure' }
        $writer = [IO.StringWriter]::new()
        $original = [Console]::Error
        try {
            [Console]::SetError($writer)
            { Save-LeafCliFailureDiagnostic @parameters } | Should -Not -Throw
        } finally {
            [Console]::SetError($original)
        }
        $writer.ToString().Trim() | Should -BeExactly 'CLI failure diagnostic unavailable.'
    }
}
