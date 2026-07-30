param()

BeforeAll {
    $scriptPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'Invoke-LocalReview.ps1'
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
        'ConvertFrom-CopilotCompactNumber',
        'Get-CopilotSummaryMetrics'
    )
    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $wantedFunctions -contains $node.Name
    }, $true) | ForEach-Object {
        . ([scriptblock]::Create($_.Extent.Text))
    }
}

Describe 'ConvertFrom-CopilotCompactNumber' {
    It 'expands compact token and credit values' {
        ConvertFrom-CopilotCompactNumber '1.2m' | Should -Be 1200000
        ConvertFrom-CopilotCompactNumber '8.6k' | Should -Be 8600
        ConvertFrom-CopilotCompactNumber '1,234,567' | Should -Be 1234567
        ConvertFrom-CopilotCompactNumber '14.4' | Should -Be 14.4
    }
}

Describe 'Get-CopilotSummaryMetrics' {
    It 'parses aggregate credits and token counts from the captured CLI summary' {
        $transcript = Join-Path $TestDrive 'agent-transcript.log'
        @'
err: Changes    +0 -0
err: AI Credits 138 (4m 12s)
err: Tokens     ↑ 1.2m (1.1m cached) • ↓ 8.6k (2.6k reasoning)
err: Resume     copilot --resume=example
'@ | Set-Content -LiteralPath $transcript

        $metrics = Get-CopilotSummaryMetrics -TranscriptPath $transcript

        $metrics.input_tokens | Should -Be 1200000
        $metrics.cached_tokens | Should -Be 1100000
        $metrics.output_tokens | Should -Be 8600
        $metrics.reasoning_tokens | Should -Be 2600
        $metrics.total_tokens | Should -Be 1208600
        $metrics.credits | Should -Be 138
    }

    It 'parses comma-formatted values and ignores ANSI formatting' {
        $transcript = Join-Path $TestDrive 'formatted-agent-transcript.log'
        $escape = [char]27
        @"
err: ${escape}[36mAI Credits 800 (11m 15s)${escape}[0m
err: ${escape}[36mTokens     ↑ 1,234,567 (1,100,000 cached) • ↓ 86,543 (26,000 reasoning)${escape}[0m
"@ | Set-Content -LiteralPath $transcript

        $metrics = Get-CopilotSummaryMetrics -TranscriptPath $transcript

        $metrics.input_tokens | Should -Be 1234567
        $metrics.cached_tokens | Should -Be 1100000
        $metrics.output_tokens | Should -Be 86543
        $metrics.reasoning_tokens | Should -Be 26000
        $metrics.total_tokens | Should -Be 1321110
        $metrics.credits | Should -Be 800
    }

    It 'returns null when the transcript has no completion summary' {
        $transcript = Join-Path $TestDrive 'empty-transcript.log'
        'out: review completed' | Set-Content -LiteralPath $transcript

        Get-CopilotSummaryMetrics -TranscriptPath $transcript | Should -BeNullOrEmpty
    }
}

Describe 'Unavailable metrics representation' {
    It 'uses an explicit unavailable source and null values instead of zeros' {
        $source = Get-Content -LiteralPath $scriptPath -Raw

        $source | Should -Match "metrics_source\s+=\s+'unavailable'"
        $source | Should -Match '\$metrics\.total_tokens = \$null'
        $source | Should -Match '\$metrics\.estimated_credits = \$null'
    }
}
