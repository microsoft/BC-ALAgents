BeforeAll {
    $scriptPath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'Apply-LocalReviewSuggestions.ps1'
}

Describe 'Apply-LocalReviewSuggestions' {
    It 'applies mechanical suggestions without launching another review' {
        $repo = Join-Path $TestDrive 'repo'
        $output = Join-Path $repo '.bc-review'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $source = Join-Path $repo 'Example.Codeunit.al'
        [IO.File]::WriteAllText($source, "line one`r`nold line`r`nline three`r`n", [Text.UTF8Encoding]::new($false))
        $report = Join-Path $output '_review-report.json'
        @{
            findings = @(
                @{
                    id = 'mechanical'
                    severity = 'major'
                    location = @{ file = 'Example.Codeunit.al'; line = 2; range = @{ 'start-line' = 2; 'end-line' = 2 } }
                    'suggested-code' = 'new line'
                },
                @{
                    id = 'judgment'
                    severity = 'major'
                    location = @{ file = 'Example.Codeunit.al'; line = 3 }
                    'suggested-code-omission-reason' = 'requires design choice'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report

        $result = & $scriptPath -RepoPath $repo -ReportPath $report

        [IO.File]::ReadAllText($source) | Should -Be "line one`r`nnew line`r`nline three`r`n"
        $result.applied.Count | Should -Be 1
        $result.applied[0].id | Should -Be 'mechanical'
        $result.skipped.Count | Should -Be 1
        $result.skipped[0].reason | Should -Be 'no-suggested-code'
    }

    It 'applies multiple ranges from bottom to top' {
        $repo = Join-Path $TestDrive 'multi-repo'
        $output = Join-Path $repo '.bc-review'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $source = Join-Path $repo 'Example.al'
        Set-Content -LiteralPath $source -Value @('one', 'two', 'three', 'four', 'five')
        $report = Join-Path $output '_review-report.json'
        @{
            findings = @(
                @{
                    id = 'first'
                    severity = 'minor'
                    location = @{ file = 'Example.al'; line = 2 }
                    'suggested-code' = "two a`ntwo b"
                },
                @{
                    id = 'second'
                    severity = 'minor'
                    location = @{ file = 'Example.al'; line = 4; range = @{ 'start-line' = 4; 'end-line' = 5 } }
                    'suggested-code' = 'last'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report

        & $scriptPath -RepoPath $repo -ReportPath $report | Out-Null

        (Get-Content -LiteralPath $source) | Should -Be @('one', 'two a', 'two b', 'three', 'last')
    }

    It 'rejects suggestions that escape the repository' {
        $repo = Join-Path $TestDrive 'safe-repo'
        $output = Join-Path $repo '.bc-review'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $report = Join-Path $output '_review-report.json'
        @{
            findings = @(
                @{
                    id = 'escape'
                    severity = 'major'
                    location = @{ file = '../outside.al'; line = 1 }
                    'suggested-code' = 'malicious replacement'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report

        { & $scriptPath -RepoPath $repo -ReportPath $report } | Should -Throw '*outside RepoPath*'
    }

    It 'skips empty suggestions and malformed findings without deleting code' {
        $repo = Join-Path $TestDrive 'empty-repo'
        $output = Join-Path $repo '.bc-review'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $source = Join-Path $repo 'Example.al'
        Set-Content -LiteralPath $source -Value @('one', 'keep me', 'three')
        $report = Join-Path $output '_review-report.json'
        @{
            findings = @(
                @{
                    id = 'empty'
                    severity = 'minor'
                    location = @{ file = 'Example.al'; line = 2 }
                    'suggested-code' = ''
                },
                @{
                    id = 'malformed'
                    message = 'missing severity and location'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report

        $result = & $scriptPath -RepoPath $repo -ReportPath $report

        (Get-Content -LiteralPath $source) | Should -Be @('one', 'keep me', 'three')
        $result.applied.Count | Should -Be 0
        $result.skipped.Count | Should -Be 2
    }

    It 'validates every file before writing any changes' {
        $repo = Join-Path $TestDrive 'atomic-repo'
        $output = Join-Path $repo '.bc-review'
        New-Item -ItemType Directory -Path $output -Force | Out-Null
        $first = Join-Path $repo 'AAA.al'
        $second = Join-Path $repo 'ZZZ.al'
        Set-Content -LiteralPath $first -Value @('one', 'unchanged')
        Set-Content -LiteralPath $second -Value @('one', 'two')
        $report = Join-Path $output '_review-report.json'
        @{
            findings = @(
                @{
                    id = 'valid'
                    severity = 'minor'
                    location = @{ file = 'AAA.al'; line = 2 }
                    'suggested-code' = 'changed'
                },
                @{
                    id = 'invalid'
                    severity = 'minor'
                    location = @{ file = 'ZZZ.al'; line = 9 }
                    'suggested-code' = 'out of bounds'
                }
            )
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $report

        { & $scriptPath -RepoPath $repo -ReportPath $report } | Should -Throw '*line count*'
        (Get-Content -LiteralPath $first) | Should -Be @('one', 'unchanged')
    }
}
