BeforeAll {
    $scriptPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'Invoke-LocalReviewFixes.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | ForEach-Object Message | Out-String)
    }
    $function = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-AIFixFindings'
    }, $true)
    . ([scriptblock]::Create($function.Extent.Text))
}

Describe 'Get-AIFixFindings' {
    It 'selects only remaining findings at the requested severity' {
        $findings = @(
            [pscustomobject]@{ id = 'mechanical'; severity = 'major'; 'suggested-code' = 'replacement' },
            [pscustomobject]@{ id = 'needs-ai'; severity = 'major' },
            [pscustomobject]@{ id = 'too-low'; severity = 'info' }
        )

        $selected = Get-AIFixFindings `
            -Findings $findings `
            -MinimumSeverity Medium `
            -OnlyWithoutSuggestedCode

        $selected.Count | Should -Be 1
        $selected[0].id | Should -Be 'needs-ai'
    }

    It 'can target a specific finding id' {
        $findings = @(
            [pscustomobject]@{ id = 'first'; severity = 'major' },
            [pscustomobject]@{ id = 'second'; severity = 'major' }
        )

        $selected = Get-AIFixFindings `
            -Findings $findings `
            -MinimumSeverity Medium `
            -FindingId second

        $selected.Count | Should -Be 1
        $selected[0].id | Should -Be 'second'
    }

    It 'accepts an empty findings list' {
        $selected = Get-AIFixFindings -Findings @() -MinimumSeverity Medium

        $selected.Count | Should -Be 0
    }
}

Describe 'Hidden AI fix process' {
    It 'uses the native Copilot executable without a visible console window' {
        $source = Get-Content -LiteralPath $scriptPath -Raw

        $source | Should -Match 'Get-Command copilot\.exe'
        $source | Should -Match '\$startInfo\.CreateNoWindow\s*=\s*\$true'
    }

    It 'returns cleanly for a report with no findings' {
        $repo = Join-Path $TestDrive 'clean-repo'
        New-Item -ItemType Directory -Path $repo | Out-Null
        $report = Join-Path $repo '_review-report.json'
        '{"findings":[]}' | Set-Content -LiteralPath $report

        $result = & $scriptPath -RepoPath $repo -ReportPath $report

        $result.exit_code | Should -Be 0
        $result.selected_finding_ids.Count | Should -Be 0
    }
}
