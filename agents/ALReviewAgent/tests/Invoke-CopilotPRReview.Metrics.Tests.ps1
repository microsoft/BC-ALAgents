param()

BeforeAll {
    $scriptPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'Invoke-CopilotPRReview.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | ForEach-Object Message | Out-String)
    }

    $wantedFunctions = @(
        'Get-ObjectPropertyValue',
        'ConvertFrom-CopilotOtelJsonLines',
        'Get-CopilotRunMetrics',
        'Save-CopilotRunMetrics',
        'Clear-CopilotMetricsArtifacts'
    )
    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $wantedFunctions -contains $node.Name
    }, $true) | ForEach-Object {
        . ([scriptblock]::Create($_.Extent.Text))
    }

    function New-ChatSpan {
        param(
            [string] $Model,
            [int64] $InputTokens,
            [int64] $OutputTokens,
            [object] $CachedTokens = $null,
            [object] $CacheCreationTokens = $null,
            [object] $NanoAiu = $null,
            [int] $StatusCode = 0,
            [switch] $WithoutUsage
        )

        $attributes = [ordered]@{
            'gen_ai.operation.name' = 'chat'
            'gen_ai.request.model'  = $Model
            'gen_ai.response.model' = $Model
        }
        if (-not $WithoutUsage) {
            $attributes['gen_ai.usage.input_tokens'] = $InputTokens
            $attributes['gen_ai.usage.output_tokens'] = $OutputTokens
        }
        if ($null -ne $CachedTokens) {
            $attributes['gen_ai.usage.cache_read.input_tokens'] = [int64]$CachedTokens
        }
        if ($null -ne $CacheCreationTokens) {
            $attributes['gen_ai.usage.cache_creation.input_tokens'] = [int64]$CacheCreationTokens
        }
        if ($null -ne $NanoAiu) {
            $attributes['github.copilot.nano_aiu'] = [decimal]$NanoAiu
        }
        return [pscustomobject]@{
            type       = 'span'
            name       = "chat $Model"
            status     = [pscustomobject]@{ code = $StatusCode }
            attributes = [pscustomobject]$attributes
        }
    }
}

Describe 'Get-CopilotRunMetrics' {
    It 'aggregates raw model requests, nested invocations, tokens, and exact AI credits' {
        $records = @(
            [pscustomobject]@{
                type = 'span'
                name = 'invoke_agent'
                attributes = [pscustomobject]@{
                    'gen_ai.operation.name' = 'invoke_agent'
                    'gen_ai.agent.version' = '1.0.81-0'
                }
            },
            (New-ChatSpan -Model 'gpt-5.6-sol' -InputTokens 100 -OutputTokens 20 `
                -CachedTokens 40 -CacheCreationTokens 10 -NanoAiu 1500000000),
            (New-ChatSpan -Model 'gpt-5.4-mini' -InputTokens 50 -OutputTokens 8 `
                -CachedTokens 20 -CacheCreationTokens 0 -NanoAiu 250000000 `
                -StatusCode 2)
        )

        $metrics = Get-CopilotRunMetrics -Records $records -WallTimeSeconds 12.34567

        $metrics.schema_version | Should -Be 1
        $metrics.metrics_source | Should -Be 'copilot-cli-otel'
        $metrics.cli_version | Should -Be '1.0.81-0'
        $metrics.wall_time_seconds | Should -Be 12.346
        $metrics.prompt_tokens | Should -Be 150
        $metrics.cached_tokens | Should -Be 60
        $metrics.cache_creation_tokens | Should -Be 10
        $metrics.completion_tokens | Should -Be 28
        $metrics.reasoning_tokens | Should -BeNullOrEmpty
        $metrics.total_tokens | Should -Be 178
        $metrics.api_calls | Should -Be 2
        $metrics.failed_api_calls | Should -Be 1
        $metrics.usage_api_calls | Should -Be 2
        $metrics.ai_credits | Should -Be 1.75
        $metrics.premium_requests | Should -BeNullOrEmpty
        $metrics.models | Should -Be @('gpt-5.4-mini', 'gpt-5.6-sol')
        $metrics.usage_complete | Should -BeTrue
    }

    It 'keeps the schema stable' {
        $metrics = Get-CopilotRunMetrics

        $metrics.PSObject.Properties.Name | Should -Be @(
            'schema_version',
            'metrics_source',
            'cli_version',
            'wall_time_seconds',
            'prompt_tokens',
            'cached_tokens',
            'cache_creation_tokens',
            'completion_tokens',
            'reasoning_tokens',
            'total_tokens',
            'api_calls',
            'failed_api_calls',
            'usage_api_calls',
            'ai_credits',
            'premium_requests',
            'models',
            'usage_complete',
            'malformed_records'
        )
    }

    It 'ignores cumulative metric snapshots to avoid double counting' {
        $records = @(
            (New-ChatSpan -Model 'gpt-5.6-sol' -InputTokens 100 -OutputTokens 10 -NanoAiu 100000000),
            [pscustomobject]@{
                type = 'metric'
                name = 'gen_ai.client.token.usage'
                dataPoints = @([pscustomobject]@{ value = [pscustomobject]@{ sum = 999999 } })
            },
            [pscustomobject]@{
                type = 'metric'
                name = 'gen_ai.invoke_agent.inference_calls'
                dataPoints = @([pscustomobject]@{ value = [pscustomobject]@{ sum = 50 } })
            }
        )

        $metrics = Get-CopilotRunMetrics -Records $records

        $metrics.prompt_tokens | Should -Be 100
        $metrics.completion_tokens | Should -Be 10
        $metrics.api_calls | Should -Be 1
    }

    It 'uses null for optional fields absent from the structured source' {
        $metrics = Get-CopilotRunMetrics -Records @(
            (New-ChatSpan -Model 'gpt-5.6-sol' -InputTokens 25 -OutputTokens 5)
        )

        $metrics.cached_tokens | Should -BeNullOrEmpty
        $metrics.cache_creation_tokens | Should -BeNullOrEmpty
        $metrics.reasoning_tokens | Should -BeNullOrEmpty
        $metrics.ai_credits | Should -BeNullOrEmpty
        $metrics.premium_requests | Should -BeNullOrEmpty
    }

    It 'reports incomplete usage when a failed or retried request lacks usage fields' {
        $metrics = Get-CopilotRunMetrics -Records @(
            (New-ChatSpan -Model 'gpt-5.6-sol' -InputTokens 25 -OutputTokens 5 -NanoAiu 100000000),
            (New-ChatSpan -Model 'gpt-5.6-sol' -InputTokens 0 -OutputTokens 0 -StatusCode 2 -WithoutUsage)
        )

        $metrics.api_calls | Should -Be 2
        $metrics.failed_api_calls | Should -Be 1
        $metrics.usage_api_calls | Should -Be 1
        $metrics.prompt_tokens | Should -Be 25
        $metrics.usage_complete | Should -BeFalse
    }
}

Describe 'ConvertFrom-CopilotOtelJsonLines' {
    It 'retains valid records and counts malformed structured records' {
        $valid = (New-ChatSpan -Model 'gpt-5.6-sol' -InputTokens 10 -OutputTokens 2) |
            ConvertTo-Json -Depth 8 -Compress

        $parsed = ConvertFrom-CopilotOtelJsonLines -Lines @($valid, '{broken', '', 'null')

        $parsed.Records.Count | Should -Be 2
        $parsed.MalformedRecords | Should -Be 1
    }
}

Describe 'Copilot metrics artifact lifecycle' {
    It 'harvests OTel JSONL into the versioned output artifact' {
        $otelPath = Join-Path $TestDrive '_copilot-otel.jsonl'
        $outputDir = Join-Path $TestDrive 'harvest-output'
        @(
            (New-ChatSpan -Model 'gpt-5.6-sol' -InputTokens 80 -OutputTokens 12 `
                -CachedTokens 30 -NanoAiu 500000000)
        ) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress } |
            Set-Content -LiteralPath $otelPath -Encoding UTF8

        $metrics = Save-CopilotRunMetrics -OtelPath $otelPath -OutputDir $outputDir -WallTimeSeconds 4.2
        $saved = Get-Content -LiteralPath (Join-Path $outputDir '_run-metrics.json') -Raw |
            ConvertFrom-Json

        $metrics.api_calls | Should -Be 1
        $saved.schema_version | Should -Be 1
        $saved.prompt_tokens | Should -Be 80
        $saved.ai_credits | Should -Be 0.5
    }

    It 'clears stale source and output metrics before a new run' {
        $agentDir = Join-Path $TestDrive 'agent'
        $outputDir = Join-Path $TestDrive 'cleanup-output'
        New-Item -ItemType Directory -Path $agentDir, $outputDir | Out-Null
        $otelPath = Join-Path $agentDir '_copilot-otel.jsonl'
        $metricsPath = Join-Path $outputDir '_run-metrics.json'
        '{}' | Set-Content -LiteralPath $otelPath
        '{}' | Set-Content -LiteralPath $metricsPath

        Clear-CopilotMetricsArtifacts -AgentWorkDir $agentDir -OutputDir $outputDir

        $otelPath | Should -Not -Exist
        $metricsPath | Should -Not -Exist
    }

    It 'does not abort the review when a stale metrics file is locked' {
        $agentDir = Join-Path $TestDrive 'locked-agent'
        New-Item -ItemType Directory -Path $agentDir | Out-Null
        '{}' | Set-Content -LiteralPath (Join-Path $agentDir '_copilot-otel.jsonl')
        Mock Remove-Item { throw 'file is locked' }

        { Clear-CopilotMetricsArtifacts -AgentWorkDir $agentDir } | Should -Not -Throw

        Should -Invoke Remove-Item -Times 1
    }
}

Describe 'Copilot OTel wiring' {
    It 'enables the file exporter without parsing transcript prose' {
        $source = Get-Content -LiteralPath $scriptPath -Raw

        $source | Should -Match "COPILOT_OTEL_EXPORTER_TYPE'\]\s*=\s*'file'"
        $source | Should -Match "COPILOT_OTEL_FILE_EXPORTER_PATH"
        $source | Should -Not -Match 'Get-CopilotSummaryMetrics'
        $source | Should -Not -Match 'token_prices'
    }
}
