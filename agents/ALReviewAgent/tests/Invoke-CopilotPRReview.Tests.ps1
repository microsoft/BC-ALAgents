[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseDeclaredVarsMoreThanAssignments',
    '',
    Justification = 'The imported functions resolve these test fixtures through PowerShell dynamic scope.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseBOMForUnicodeEncodedFile',
    '',
    Justification = 'The test intentionally covers Unicode domain labels and rendered Unicode output.'
)]
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

    $ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true) | ForEach-Object {
        $functionDefinition = [scriptblock]::Create($_.Extent.Text)
        . $functionDefinition
    }

    $DomainMap = @{
        'al-security-review'    = 'Security'
        'al-performance-review' = 'Performance'
        'agent'                 = 'Agent'
    }
    $SeverityOrder = @{ Critical = 0; High = 1; Medium = 2; Low = 3 }
    $BCQualitySeverityMap = @{ blocker = 'Critical'; major = 'High'; minor = 'Medium'; info = 'Low' }
    $MinimumSeverity = 'Low'
    $AgentMinimumSeverity = 'Low'
    $MaxFindings = 25
    $script:LastParsingErrors = [System.Collections.Generic.List[string]]::new()

    $AgentVersion = '1'
    $AgentLabel = 'copilot-pr-review'
    $ReviewIteration = 2
    $AgentCommentDocUrl = 'https://example.test/review'
    $BCQualitySha = ''
    $script:BCQualityWebRepoUrl = 'https://github.com/microsoft/BCQuality'
}

Describe 'Resolve-FindingDomain' {
    It 'prefers the explicit lowercase domain over the legacy map' {
        $finding = [pscustomobject]@{
            domain = 'Breaking Changes'
            'from-sub-skill' = 'al-security-review'
        }
        Resolve-FindingDomain -Finding $finding | Should -Be 'Breaking Changes'
    }

    It 'accepts the capitalized Domain property' {
        Resolve-FindingDomain -Finding ([pscustomobject]@{ Domain = 'Web Services' }) |
            Should -Be 'Web Services'
    }

    It 'uses from-sub-skill and from_sub_skill legacy fallbacks' {
        Resolve-FindingDomain -Finding ([pscustomobject]@{ 'from-sub-skill' = 'al-security-review' }) |
            Should -Be 'Security'
        Resolve-FindingDomain -Finding ([pscustomobject]@{ from_sub_skill = 'al-performance-review' }) |
            Should -Be 'Performance'
    }

    It 'uses the legacy map when an explicit label is whitespace' {
        $finding = [pscustomobject]@{
            domain = "`t "
            'from-sub-skill' = 'al-security-review'
        }
        Resolve-FindingDomain -Finding $finding | Should -Be 'Security'
    }

    It 'falls back safely for missing and unusable labels' -ForEach @(
        @{ Explicit = $null }
        @{ Explicit = '' }
        @{ Explicit = '   ' }
    ) {
        $finding = [pscustomobject]@{ domain = $Explicit; 'from-sub-skill' = 'unknown-review' }
        Resolve-FindingDomain -Finding $finding | Should -Be 'Other'
    }
}

Describe 'Agent domain normalization' {
    It 'preserves an explicit leaf domain for an agent finding' {
        $json = @{
            outcome = 'completed'
            findings = @(@{
                id = 'agent:security'
                domain = 'Security'
                'from-sub-skill' = 'al-security-review'
                severity = 'major'
                message = 'Issue'
                location = @{ file = 'src/a.al'; line = 1 }
                references = @()
            })
        } | ConvertTo-Json -Depth 8

        $finding = (Parse-BCQualityReport -Output $json).Findings[0]
        $finding.isAgentFinding | Should -BeTrue
        $finding.domain | Should -Be 'Security'
    }

    It 'uses Agent only for an unlabeled legacy agent finding without a mapped domain' {
        $json = @{
            outcome = 'completed'
            findings = @(@{
                id = 'legacy'
                knowledge_backed = $false
                severity = 'major'
                message = 'Issue'
                location = @{ file = 'src/a.al'; line = 1 }
                references = @()
            })
        } | ConvertTo-Json -Depth 8

        (Parse-BCQualityReport -Output $json).Findings[0].domain | Should -Be 'Agent'
    }

    It 'preserves the exact Agent label on a cross-cutting producer finding' {
        $json = @{
            outcome = 'completed'
            findings = @(@{
                id = 'agent:cross-cutting'
                domain = 'Agent'
                'from-sub-skill' = 'agent'
                severity = 'major'
                message = 'Issue'
                location = @{ file = 'src/a.al'; line = 1 }
                references = @()
            })
        } | ConvertTo-Json -Depth 8

        $finding = (Parse-BCQualityReport -Output $json).Findings[0]
        $finding.isAgentFinding | Should -BeTrue
        $finding.domain | Should -BeExactly 'Agent'
    }
}

Describe 'Domain metadata' {
    It 'round-trips a multi-word domain through collision-safe metadata' {
        $metadata = Get-AgentDomainMetadata -Domain 'Breaking Changes'
        $parsed = Get-CommentDomainMetadataKey -Body $metadata

        $parsed.Kind | Should -BeExactly 'Exact'
        $parsed.Key | Should -BeExactly (ConvertTo-DomainMetadataKey -Domain 'Breaking Changes')
    }

    It 'reads legacy single-token metadata' {
        $parsed = Get-CommentDomainMetadataKey -Body '<!-- agent_domain: security -->'

        $parsed.Kind | Should -BeExactly 'Legacy'
        $parsed.Key | Should -BeExactly 'security'
    }

    It 'encodes exact trimmed UTF-8 labels without lossy transformations' {
        $precomposed = [string][char]0x00E9
        $decomposed = "e$([char]0x0301)"
        $labels = @(
            'API', 'api', $precomposed, $decomposed, 'A B', 'A  B',
            'C#', 'C++', '!!!', '???', 'A-B', 'A_B', 'Æ', 'AE'
        )
        $keys = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )

        foreach ($label in $labels) {
            $keys.Add((ConvertTo-DomainMetadataKey -Domain $label)) | Should -BeTrue
        }
        $keys.Count | Should -Be $labels.Count
        ConvertTo-DomainMetadataKey -Domain '  API  ' |
            Should -BeExactly (ConvertTo-DomainMetadataKey -Domain 'API')
        ConvertTo-DomainMetadataKey -Domain 'A B' |
            Should -Not -BeExactly (ConvertTo-DomainMetadataKey -Domain 'A  B')
    }

    It 'deduplicates exact metadata by case, Unicode representation, whitespace, and punctuation' {
        $precomposed = [string][char]0x00E9
        $decomposed = "e$([char]0x0301)"
        $cases = @(
            @{ Label = 'API'; Path = 'src/1.al' }
            @{ Label = 'api'; Path = 'src/2.al' }
            @{ Label = $precomposed; Path = 'src/3.al' }
            @{ Label = $decomposed; Path = 'src/4.al' }
            @{ Label = 'A B'; Path = 'src/5.al' }
            @{ Label = 'A  B'; Path = 'src/6.al' }
            @{ Label = 'C#'; Path = 'src/7.al' }
            @{ Label = 'C++'; Path = 'src/8.al' }
            @{ Label = '!!!'; Path = 'src/9.al' }
            @{ Label = '???'; Path = 'src/10.al' }
        )
        $script:DomainComments = @($cases | ForEach-Object {
            [pscustomobject]@{
                body = Get-AgentDomainMetadata -Domain $_.Label
                path = $_.Path
                line = 10
                side = 'RIGHT'
            }
        })
        Mock Get-ReviewComments {
            $script:DomainComments
        }

        foreach ($case in $cases) {
            $existing = Get-ExistingCommentKeys -Domain $case.Label
            $existing.Keys.Count | Should -Be 1
            $existing.Keys.Contains("$($case.Path):10:RIGHT") | Should -BeTrue
        }
    }

    It 'keeps legacy lowercase matching separate from new exact matching' {
        $script:DomainComments = @(
            [pscustomobject]@{
                body = '<!-- agent_domain: security -->'
                path = 'src/legacy.al'; line = 1; side = 'RIGHT'
            },
            [pscustomobject]@{
                body = Get-AgentDomainMetadata -Domain 'security'
                path = 'src/exact.al'; line = 2; side = 'RIGHT'
            }
        )
        Mock Get-ReviewComments { $script:DomainComments }

        $capitalized = Get-ExistingCommentKeys -Domain 'Security'
        $capitalized.Keys.Count | Should -Be 1
        $capitalized.Keys.Contains('src/legacy.al:1:RIGHT') | Should -BeTrue
        $capitalized.Keys.Contains('src/exact.al:2:RIGHT') | Should -BeFalse

        (Get-ExistingCommentKeys -Domain 'security').Keys.Count | Should -Be 2
    }

    It 'does not match a new lowercase exact key to a capitalized target' {
        $script:DomainComments = @(
            [pscustomobject]@{
                body = Get-AgentDomainMetadata -Domain 'security'
                path = 'src/exact.al'; line = 2; side = 'RIGHT'
            }
        )
        Mock Get-ReviewComments { $script:DomainComments }

        (Get-ExistingCommentKeys -Domain 'security').Keys.Count | Should -Be 1
        (Get-ExistingCommentKeys -Domain 'Security').Keys.Count | Should -Be 0

        $script:DomainComments = @(
            [pscustomobject]@{
                body = Get-AgentDomainMetadata -Domain 'Security'
                path = 'src/exact-case.al'; line = 3; side = 'RIGHT'
            }
        )
        (Get-ExistingCommentKeys -Domain 'Security').Keys.Contains('src/exact-case.al:3:RIGHT') |
            Should -BeTrue
    }

    It 'reads both legacy single-token heading formats' {
        $script:DomainComments = @(
            [pscustomobject]@{
                body = '### High Security - issue'
                path = 'src/new-heading.al'; line = 1; side = 'RIGHT'
            },
            [pscustomobject]@{
                body = '### Security - High Severity'
                path = 'src/old-heading.al'; line = 2; side = 'RIGHT'
            }
        )
        Mock Get-ReviewComments { $script:DomainComments }

        (Get-ExistingCommentKeys -Domain 'Security').Keys.Count | Should -Be 2
    }
}

Describe 'Domain grouping and caps' {
    It 'caps exact domain labels independently' {
        $MaxFindings = 1
        try {
            $precomposed = [string][char]0x00E9
            $decomposed = "e$([char]0x0301)"
            $labels = @('API', 'api', $precomposed, $decomposed, 'A B', 'A  B', 'C#', 'C++')
            $rawFindings = [System.Collections.Generic.List[object]]::new()
            $line = 0
            foreach ($label in $labels) {
                $line++
                $rawFindings.Add(@{
                    id = "high-$line"; domain = $label; severity = 'major'; message = 'First'
                    location = @{ file = 'src/a.al'; line = $line }; references = @()
                }) | Out-Null
                $line++
                $rawFindings.Add(@{
                    id = "medium-$line"; domain = $label; severity = 'minor'; message = 'Second'
                    location = @{ file = 'src/a.al'; line = $line }; references = @()
                }) | Out-Null
            }
            $json = @{
                outcome = 'completed'
                findings = @($rawFindings)
            } | ConvertTo-Json -Depth 8

            $findings = (Parse-BCQualityReport -Output $json).Findings
            $findings.Count | Should -Be $labels.Count
            foreach ($label in $labels) {
                $domainFindings = @($findings | Where-Object {
                    [System.StringComparer]::Ordinal.Equals($_.domain, $label)
                })
                $domainFindings.Count | Should -Be 1
                $domainFindings[0].severity | Should -BeExactly 'High'
            }
        }
        finally {
            $MaxFindings = 25
        }
    }

    It 'keeps exact labels distinct through posting collections and summaries' {
        $precomposed = [string][char]0x00E9
        $decomposed = "e$([char]0x0301)"
        $labels = @('API', 'api', $precomposed, $decomposed, 'A B', 'A  B', 'C#', 'C++')
        $findings = @($labels | ForEach-Object {
            [pscustomobject]@{ domain = $_; isAgentFinding = $false }
        })
        Mock Post-Findings {
            [pscustomobject]@{ inline = $Findings.Count; fallback = 0 }
        }

        $summary = Publish-FindingsByDomain -Findings $findings -LineMaps @{} -ChangedFileSet @{}
        $summary.Count | Should -Be $labels.Count
        foreach ($label in $labels) {
            $summary.ContainsKey($label) | Should -BeTrue
            $summary[$label].findings | Should -Be 1
            Should -Invoke Post-Findings -Times 1 -ParameterFilter {
                [System.StringComparer]::Ordinal.Equals($Domain, $label)
            }
        }

        $body = Build-SummaryBody -Outcome completed -OutcomeReason '' -DomainSummary $summary `
            -Suppressed @() -SkippedSubSkills @() -FilterReport $null
        foreach ($label in $labels) {
            $safeLabel = ConvertTo-MarkdownTableCell -Value $label
            $body.Contains("| $safeLabel | 1 | 1 | 0 | 1 | 0 |") |
                Should -BeTrue -Because "the summary must contain the exact '$label' label"
        }
    }

    It 'keeps consumed-skill fallback domains distinct' {
        $report = [pscustomobject]@{
            SubResults = @()
            Findings = @(
                [pscustomobject]@{ domain = 'API'; references = @() },
                [pscustomobject]@{ domain = 'api'; references = @() }
            )
        }
        Mock Write-Host {}

        Write-ConsumedBCQualityLog -Report $report

        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq 'Sub-skills executed (2):' }
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq '  - API (findings=1)' }
        Should -Invoke Write-Host -Times 1 -ParameterFilter { $Object -eq '  - api (findings=1)' }
    }
}

Describe 'Domain rendering safety' {
    It 'preserves domain case in fallback text' {
        $finding = [pscustomobject]@{
            domain = 'API'
            severity = 'High'
            issue = ''
            recommendation = ''
            suggestedCode = ''
            references = @()
            isAgentFinding = $false
        }

        Build-CommentBody -Finding $finding | Should -Match 'High API finding'
    }

    It 'renders Markdown-active domain punctuation literally' {
        $finding = [pscustomobject]@{
            domain = '$@[API](//example): ~~C#~~!$'
            severity = 'High'
            issue = ''
            recommendation = ''
            suggestedCode = ''
            references = @()
            isAgentFinding = $false
        }

        Build-CommentBody -Finding $finding |
            Should -Match 'High &#36;&#64;\\\[API\\\]\\\(//example\\\)&#58; \\\~\\\~C\\#\\\~\\\~\\\!&#36; finding'
    }

    It 'shows agent provenance for an exact lowercase agent label' {
        $finding = [pscustomobject]@{
            domain = 'agent'
            severity = 'High'
            issue = 'Review judgement.'
            recommendation = ''
            suggestedCode = ''
            references = @()
            isAgentFinding = $true
        }

        Build-CommentBody -Finding $finding |
            Should -Match 'Agent judgement — not directly backed'
    }

    It 'preserves Unicode numeric entities while escaping Markdown' {
        ConvertTo-MarkdownTableCell -Value ([string][char]0x00E9) |
            Should -BeExactly '&#233;'
        ConvertTo-MarkdownTableCell -Value "e$([char]0x0301)" |
            Should -BeExactly "e$([char]0x0301)"
    }

    It 'escapes domain labels in LaTeX comment preheaders' {
        $finding = [pscustomobject]@{
            domain = 'API | 100%_safe & C#'
            severity = 'High'
            issue = 'Use the safe API.'
            recommendation = ''
            suggestedCode = ''
            references = @()
            isAgentFinding = $false
        }
        $body = Build-CommentBody -Finding $finding

        $body | Should -Match '100\\%\\_safe'
        $body | Should -Match '\\&'
        $body | Should -Match 'C\\#'
        $body | Should -Not -Match '<!-- agent_domain:'
    }

    It 'escapes markdown table separators, formatting, and HTML' {
        $summary = @{
            'API | 100%_safe & <test> $math$ @team :smile:' = @{
                findings = 1; knowledgeBacked = 1; agentFindings = 0; inline = 1; fallback = 0
            }
        }
        $body = Build-SummaryBody -Outcome completed -OutcomeReason '' -DomainSummary $summary `
            -Suppressed @() -SkippedSubSkills @() -FilterReport $null

        $body | Should -Match 'API \\\| 100%\\_safe &amp; &lt;test&gt; &#36;math&#36; &#64;team &#58;smile&#58;'
    }
}

Describe 'Build-BootstrapPrompt' {
    BeforeAll {
        $AnalysisWorkspace = '/home/runner/review-target'
        $ReviewSource = 'pr'
        $Repository = 'microsoft/BCApps'
        $PrNumber = 9479
        $DiffBaseRef = 'origin/main'
        $DiffRange = 'origin/main...HEAD'
        $ReportFileName = 'findings-report.json'
        $MinimumSeverity = 'Low'

        $script:BootstrapPrompt = Build-BootstrapPrompt -TaskContextPath '/home/runner/bcquality/_task-context.json'
    }

    It 'instructs the agent to diff against the merge-base (three-dot) so only PR changes are reviewed' {
        $script:BootstrapPrompt | Should -Match 'diff origin/main\.\.\.HEAD to see all changes'
        $script:BootstrapPrompt | Should -Match 'diff origin/main\.\.\.HEAD -- <file>'
        $script:BootstrapPrompt | Should -Match 'diff --name-only origin/main\.\.\.HEAD to list changed files'
    }

    It 'never instructs a two-dot diff, which would pull in files changed on the base since the branch point' {
        $script:BootstrapPrompt | Should -Not -Match 'diff origin/main to see all changes'
        $script:BootstrapPrompt | Should -Not -Match 'diff origin/main -- <file>'
        $script:BootstrapPrompt | Should -Not -Match 'diff --name-only origin/main to list changed files'
    }
}

Describe 'Local review authentication' {
    BeforeAll {
        $script:AuthWorkspace = Join-Path $TestDrive 'workspace'
        $script:AuthBCQuality = Join-Path $TestDrive 'bcquality'
        New-Item -ItemType Directory -Path $script:AuthWorkspace -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AuthBCQuality 'skills') -Force | Out-Null
        Set-Content -Path (Join-Path $script:AuthBCQuality 'skills/entry.md') -Value '# entry'
        & git -C $script:AuthWorkspace init -q
    }

    BeforeEach {
        $ReviewPhase = 'generate'
        $ReviewSource = 'local'
        $GithubToken = $null
        $CopilotToken = $null
        $BaseRef = 'HEAD'
        $AnalysisWorkspace = $script:AuthWorkspace
        $TrustedWorkspace = $script:AuthWorkspace
        $BCQualityRoot = $script:AuthBCQuality
        $BaseBranch = 'main'
        $PrNumber = 0
        $PrHeadSha = $null
        $MinimumSeverity = 'Low'
        $AgentMinimumSeverity = 'Low'
        $CopilotCliTimeoutMinutes = 30

        Mock Get-Command {
            [pscustomobject]@{ Source = 'copilot' }
        } -ParameterFilter { $Name -eq 'copilot' }
    }

    It 'allows local generation without GH_TOKEN' {
        { Assert-Config } | Should -Not -Throw
    }

    It 'still requires GH_TOKEN for PR generation' {
        $ReviewSource = 'pr'
        $PrNumber = 1
        $PrHeadSha = 'abc123'

        { Assert-Config } | Should -Throw '*GH_TOKEN is required*'
    }

    It 'launches the child Copilot process without a visible console window' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $source | Should -Match '\$startInfo\.CreateNoWindow\s*=\s*\$true'
        $source | Should -Match 'Get-Command copilot\.exe'
    }

    It 'does not forward an inherited GH_TOKEN to the local child process' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $source | Should -Match "if \(\`$ReviewSource -ne 'local' -and \`$CopilotToken\)"
    }
}

Describe 'Repair-ShellEscapedQuotes' {
    # Mirrors the real bug: a suggested-code field whose AL Label content is
    # emitted through a single-quoted shell argument leaves the POSIX
    # close/escape/reopen idiom '\'' in _review-report.json. That 4-char
    # sequence is invalid JSON and is rejected by strict parsers (Python's
    # json.loads in BC-Bench; .NET System.Text.Json here), even though
    # PowerShell's own ConvertFrom-Json happens to tolerate it.
    It 'collapses the POSIX shell single-quote escape so a strict parser accepts the report' {
        $corrupt = '{"suggested-code":"BearerTok: Label ' + "'\''" + '******' + "'\''" + ', Locked = true;"}'
        { [System.Text.Json.JsonDocument]::Parse($corrupt) } | Should -Throw

        $repaired = Repair-ShellEscapedQuotes -Text $corrupt
        $repaired.Contains("'\''") | Should -BeFalse
        $doc = [System.Text.Json.JsonDocument]::Parse($repaired)
        $doc.RootElement.GetProperty('suggested-code').GetString() |
            Should -Be "BearerTok: Label '******', Locked = true;"
    }

    It 'preserves valid JSON string escapes (backslash-quote and backslash-n)' {
        $json = '{"message":"He said \"hi\"\nnext line"}'
        Repair-ShellEscapedQuotes -Text $json | Should -Be $json
    }

    It 'leaves clean text unchanged and is idempotent' {
        $clean = '{"a":"no shell quotes here"}'
        $once = Repair-ShellEscapedQuotes -Text $clean
        $once | Should -Be $clean
        Repair-ShellEscapedQuotes -Text $once | Should -Be $clean
    }

    It 'passes empty and null input through unchanged' {
        Repair-ShellEscapedQuotes -Text '' | Should -Be ''
        Repair-ShellEscapedQuotes -Text $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-RegionalPathInfo' {
    It 'parses an src/Apps regional path' {
        $info = Get-RegionalPathInfo -FilePath 'src/Apps/US/Sales/Foo.Codeunit.al'
        $info.Tree | Should -Be 'apps'
        $info.Region | Should -Be 'us'
        $info.Relative | Should -Be 'Sales/Foo.Codeunit.al'
    }

    It 'parses an src/Layers regional path and normalizes backslashes/case' {
        $info = Get-RegionalPathInfo -FilePath '\src\Layers\W1\Bar.al'
        $info.Tree | Should -Be 'layers'
        $info.Region | Should -Be 'w1'
        $info.Path | Should -Be 'src/Layers/W1/Bar.al'
    }

    It 'returns null for a non-regional path' {
        Get-RegionalPathInfo -FilePath 'src/System Application/Foo.al' | Should -BeNullOrEmpty
    }
}

Describe 'Get-FindingOtherRegions' {
    It 'returns an empty array when the property is absent (StrictMode-safe)' {
        (Get-FindingOtherRegions -Finding ([pscustomobject]@{ filePath = 'x' })).Count | Should -Be 0
    }
}

Describe 'Group-RegionalFindings' {
    BeforeAll {
        function New-RegionalFinding {
            param([string] $Path, [int] $Line = 10, [string] $Issue = 'Avoid N+1 query', [string] $Rec = 'Use SetLoadFields')
            [pscustomobject]@{
                filePath = $Path; lineNumber = $Line; severity = 'Medium'
                domain = 'Performance'; issue = $Issue; recommendation = $Rec
            }
        }
    }

    It 'collapses an identical finding across regions and prefers W1 as primary' {
        $findings = @(
            New-RegionalFinding -Path 'src/Apps/US/Foo.al' -Line 42
            New-RegionalFinding -Path 'src/Apps/W1/Foo.al' -Line 42
            New-RegionalFinding -Path 'src/Apps/DE/Foo.al' -Line 42
        )
        $result = @(Group-RegionalFindings -Findings $findings)
        $result.Count | Should -Be 1
        $result[0].filePath | Should -Be 'src/Apps/W1/Foo.al'
        $others = Get-FindingOtherRegions -Finding $result[0]
        $others.Count | Should -Be 2
        ($others | ForEach-Object { $_.region }) | Should -Be @('DE', 'US')
        $others[0].line | Should -Be 42
    }

    It 'picks a deterministic primary when no W1 copy is present' {
        $findings = @(
            New-RegionalFinding -Path 'src/Apps/US/Foo.al' -Line 42
            New-RegionalFinding -Path 'src/Apps/DE/Foo.al' -Line 42
        )
        $result = @(Group-RegionalFindings -Findings $findings)
        $result.Count | Should -Be 1
        $result[0].filePath | Should -Be 'src/Apps/DE/Foo.al'
        (Get-FindingOtherRegions -Finding $result[0]).region | Should -Be 'US'
    }

    It 'collapses regional copies even when the model wording differs per file' {
        # The real-world driver for keying on location, not text: for byte-identical
        # regional copies the model still writes DIFFERENT issue/recommendation prose
        # per file (it may even cross-reference the other copy). Location must still
        # collapse them into one comment.
        $findings = @(
            New-RegionalFinding -Path 'src/Layers/W1/AlCosting/Foo.Codeunit.al' -Line 7 -Issue 'Missing SetLoadFields before Get' -Rec 'Add SetLoadFields'
            New-RegionalFinding -Path 'src/Layers/BE/AlCosting/Foo.Codeunit.al' -Line 7 -Issue 'Same issue as the W1 copy: no SetLoadFields' -Rec 'Add a SetLoadFields call'
        )
        $result = @(Group-RegionalFindings -Findings $findings)
        $result.Count | Should -Be 1
        $result[0].filePath | Should -Be 'src/Layers/W1/AlCosting/Foo.Codeunit.al'
        $others = Get-FindingOtherRegions -Finding $result[0]
        $others.Count | Should -Be 1
        $others[0].region | Should -Be 'BE'
    }

    It 'does not collapse findings at different lines of the same file across regions' {
        $findings = @(
            New-RegionalFinding -Path 'src/Apps/US/Foo.al' -Line 10
            New-RegionalFinding -Path 'src/Apps/W1/Foo.al' -Line 20
        )
        (Group-RegionalFindings -Findings $findings).Count | Should -Be 2
    }

    It 'does not collapse identical findings that stay within one region' {
        $findings = @(
            New-RegionalFinding -Path 'src/Apps/US/Foo.al' -Line 10
            New-RegionalFinding -Path 'src/Apps/US/Bar.al' -Line 99
        )
        $result = @(Group-RegionalFindings -Findings $findings)
        $result.Count | Should -Be 2
        (Get-FindingOtherRegions -Finding $result[0]).Count | Should -Be 0
    }

    It 'leaves a non-regional finding untouched even if it shares a signature' {
        $findings = @(
            New-RegionalFinding -Path 'src/Apps/US/Foo.al'
            New-RegionalFinding -Path 'src/Apps/W1/Foo.al'
            New-RegionalFinding -Path 'src/System Application/Foo.al'
        )
        $result = @(Group-RegionalFindings -Findings $findings)
        $result.Count | Should -Be 2
        ($result | Where-Object { $_.filePath -eq 'src/System Application/Foo.al' }).Count | Should -Be 1
    }
}

Describe 'Format-OtherRegionsNotice' {
    It 'renders a bullet list of the other regional copies' {
        $finding = [pscustomobject]@{ otherRegions = @(
            [pscustomobject]@{ path = 'src/Apps/US/Foo.al'; line = 42; region = 'US' }
        ) }
        $notice = Format-OtherRegionsNotice -Finding $finding
        $notice | Should -Match 'regional copies'
        $notice | Should -Match 'src/Apps/US/Foo.al:42`'
        $notice | Should -Match '\(US\)'
    }

    It 'returns an empty string when there are no other regions (under StrictMode)' {
        # Regression guard: Get-FindingOtherRegions returns @() when the property is
        # absent, but a function's empty-array return unrolls to $null on assignment,
        # so a naive $others.Count throws under Set-StrictMode -Version Latest (the mode
        # the orchestrator runs under). Pester does not enable StrictMode, so assert it
        # explicitly here on the common non-collapsed-finding path.
        & {
            Set-StrictMode -Version Latest
            Format-OtherRegionsNotice -Finding ([pscustomobject]@{ filePath = 'x' })
        } | Should -Be ''
    }
}
