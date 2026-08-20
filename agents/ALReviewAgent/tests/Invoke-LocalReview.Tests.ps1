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

Describe 'Structured metrics ownership' {
    It 'leaves metrics harvesting to the production orchestrator' {
        $source = Get-Content -LiteralPath $scriptPath -Raw

        $source | Should -Not -Match 'Get-CopilotSummaryMetrics'
        $source | Should -Not -Match 'process-\*\.log'
        $source | Should -Not -Match 'token_prices'
        $source | Should -Match "Reviewer produced no structured metrics"
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
