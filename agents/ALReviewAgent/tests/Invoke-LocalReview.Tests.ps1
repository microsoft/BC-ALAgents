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
        'Get-CopilotSummaryMetrics',
        'Get-AlReviewFilePaths',
        'ConvertFrom-GitNameStatus'
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

    It 'parses summaries that include written cache tokens' {
        $transcript = Join-Path $TestDrive 'written-cache-agent-transcript.log'
        @'
err: AI Credits 1383 (7m 11s)
err: Tokens     ↑ 9.8m (8.8m cached, 1.0m written) • ↓ 97.8k (29.2k reasoning)
'@ | Set-Content -LiteralPath $transcript

        $metrics = Get-CopilotSummaryMetrics -TranscriptPath $transcript

        $metrics.input_tokens | Should -Be 9800000
        $metrics.cached_tokens | Should -Be 8800000
        $metrics.output_tokens | Should -Be 97800
        $metrics.reasoning_tokens | Should -Be 29200
        $metrics.total_tokens | Should -Be 9897800
        $metrics.credits | Should -Be 1383
    }

    It 'returns null when the transcript has no completion summary' {
        $transcript = Join-Path $TestDrive 'empty-transcript.log'
        'out: review completed' | Set-Content -LiteralPath $transcript

        Get-CopilotSummaryMetrics -TranscriptPath $transcript | Should -BeNullOrEmpty
    }
}

Describe 'Get-AlReviewFilePaths' {
    It 'keeps only AL files regardless of extension casing' {
        $paths = Get-AlReviewFilePaths -Paths @(
            'src/App.Codeunit.al',
            'src/Upper.Table.AL',
            'README.md',
            'scripts/build.ps1'
        )

        $paths | Should -Be @('src/App.Codeunit.al', 'src/Upper.Table.AL')
    }

    Describe 'ConvertFrom-GitNameStatus' {
        It 'includes deleted paths and both sides of renames' {
            $paths = ConvertFrom-GitNameStatus -Lines @(
                "D`tRemoved.Codeunit.al",
                "R100`tOld.Table.al`tNew.Table.md",
                "M`tREADME.md"
            )

            $paths | Should -Be @(
                'Removed.Codeunit.al',
                'Old.Table.al',
                'New.Table.md',
                'README.md'
            )
            (Get-AlReviewFilePaths -Paths $paths) |
                Should -Be @('Removed.Codeunit.al', 'Old.Table.al')
        }
    }

    It 'returns an empty array for a non-AL diff' {
        @(Get-AlReviewFilePaths -Paths @('README.md', 'src/app.json')).Count | Should -Be 0
    }

    It 'keeps a single AL review path in an array before checking Count' {
        $source = Get-Content -LiteralPath $scriptPath -Raw

        $source | Should -Match '\$alReviewFiles\s*=\s*@\(Get-AlReviewFilePaths -Paths \$reviewPaths\)'
        $paths = @(Get-AlReviewFilePaths -Paths @('src/Only.Codeunit.al'))
        $paths.Count | Should -Be 1
        $paths[0] | Should -Be 'src/Only.Codeunit.al'
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

Describe 'Initial review and fix flow' {
    It 'applies mechanical suggestions before sending only remaining findings to AI' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $suggestionIndex = $source.IndexOf('& $suggestionScript')
        $aiFixIndex = $source.IndexOf('& $fixScript')

        $suggestionIndex | Should -BeGreaterOrEqual 0
        $aiFixIndex | Should -BeGreaterThan $suggestionIndex
        $source | Should -Match '-ExcludeFindingId \$appliedFindingIds'
        $source | Should -Match 'AI fix pass failed \(review results remain valid\)'
    }
}

Describe 'Skill fix choices' {
    It 'offers four explicit post-review fix workflows' {
        $skillPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/al-review/SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw

        $skill | Should -Match '1\. \*\*Apply reviewer fixes\*\*'
        $skill | Should -Match '2\. \*\*Fix with an AI agent\*\*'
        $skill | Should -Match '3\. \*\*Fix and verify\*\*'
        $skill | Should -Match '4\. \*\*Fix and review again\*\*'
        $skill | Should -Match 'Do not silently choose the expensive path'
    }
}

Describe 'No-AL review preflight' {
    It 'checks the selected diff before invoking the reviewer' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $preflightIndex = $source.IndexOf('No AL (.al) files found in the selected diff; review skipped.')
        $reviewIndex = $source.IndexOf('Write-Host "[local-review] Invoking $reviewScript"')

        $preflightIndex | Should -BeGreaterOrEqual 0
        $reviewIndex | Should -BeGreaterThan $preflightIndex
        $source | Should -Match "'--name-status', '--find-renames'"
        $source | Should -Match "'--diff-filter=ACMRTD'"
        $source | Should -Match "metrics_source\s+=\s+'not-applicable'"
    }
}

Describe 'Hidden local Windows review execution' {
    It 'does not launch a nested PowerShell process from the skill' {
        $skillPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'skills/al-review/SKILL.md'
        $skill = Get-Content -LiteralPath $skillPath -Raw

        $skill | Should -Not -Match 'pwsh\s+-NoProfile\s+-File'
        $skill | Should -Match '& \$reviewScript @reviewParameters'
    }

    It 'disables Copilot PowerShell tools for local Windows reviews' {
        $reviewScriptPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'Invoke-CopilotPRReview.ps1'
        $source = Get-Content -LiteralPath $reviewScriptPath -Raw

        $source | Should -Match '\$ReviewSource -eq ''local'' -and \$IsWindows'
        $source | Should -Match "'--excluded-tools'"
        $source | Should -Match 'powershell,read_powershell,write_powershell,stop_powershell,list_powershell'
    }
}
