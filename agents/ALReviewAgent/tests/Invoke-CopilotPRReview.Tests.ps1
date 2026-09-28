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
    $EngineRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptPath)))
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

Describe 'Resolve-FindingLocation' {
    BeforeAll {
        $patch = @'
@@ -10,7 +10,7 @@
 context
 context
 context
-old line
+new line
 context
 context
 context
@@ -30,7 +30,7 @@
 context
 context
 context
-another old line
+another new line
 context
 context
 context
'@
        $lineMap = Build-LineMap -Patch $patch
    }

    It 'preserves an exact changed-line anchor' {
        $location = Resolve-FindingLocation -LineMap $lineMap -LineNumber 13

        $location.line | Should -Be 13
        $location.side | Should -Be 'RIGHT'
    }

    It 'marks an exact anchor as not inferred and stays StrictMode-safe' {
        # Regression: the exact-match branch used to return the raw Build-LineMap
        # entry, which has no 'inferred' key. Post-Findings reads
        # [bool]($location.inferred ?? $false) with member syntax, and under
        # Set-StrictMode -Version Latest a missing property throws before ?? runs
        # (unlike hashtable indexing). Pester does not enable StrictMode, so assert
        # the exact behaviour of the posting call site explicitly.
        Set-StrictMode -Version Latest
        try {
            $location = Resolve-FindingLocation -LineMap $lineMap -LineNumber 13

            $location.inferred | Should -BeFalse
            { [bool]($location.inferred ?? $false) } | Should -Not -Throw
        }
        finally {
            Set-StrictMode -Off
        }
    }

    It 'uses the nearest changed line in the same hunk' {
        $location = Resolve-FindingLocation -LineMap $lineMap -LineNumber 12

        $location.line | Should -Be 13
        $location.side | Should -Be 'RIGHT'
        $location.inferred | Should -BeTrue
    }

    It 'uses the earlier changed line when distances are equal' {
        $tiePatch = @'
@@ -10,7 +10,7 @@
 context
-old before
+new before
 context
-old after
+new after
 context
 context
 context
'@
        $tieMap = Build-LineMap -Patch $tiePatch

        (Resolve-FindingLocation -LineMap $tieMap -LineNumber 12).line | Should -Be 11
    }

    It 'does not cross into an unrelated hunk' {
        Resolve-FindingLocation -LineMap $lineMap -LineNumber 22 | Should -BeNullOrEmpty
    }

    It 'infers the nearest LEFT anchor in a deletion-only hunk' {
        $deletionPatch = @'
@@ -10,7 +10,6 @@
 context
 context
 context
-deleted line
 context
 context
 context
'@
        $deletionMap = Build-LineMap -Patch $deletionPatch

        $location = Resolve-FindingLocation -LineMap $deletionMap -LineNumber 12

        $location.line | Should -Be 13
        $location.side | Should -Be 'LEFT'
        $location.inferred | Should -BeTrue
        (Resolve-FindingLocation -LineMap $deletionMap -LineNumber 13).side | Should -Be 'LEFT'
    }

    It 'maps nearby PR-head lines to the closest deletion in a deletion-only hunk' {
        $deletionPatch = @'
@@ -91,18 +91,14 @@
 context
 context
 context
-deleted first
 context
 context
 context
-deleted second
 context
 context
 context
 context
 context
-deleted third
-deleted fourth
 context
 context
 context
'@
        $deletionMap = Build-LineMap -Patch $deletionPatch

        (Resolve-FindingLocation -LineMap $deletionMap -LineNumber 97).line | Should -Be 98
        (Resolve-FindingLocation -LineMap $deletionMap -LineNumber 103).line | Should -Be 104
    }

    It 'does not infer a LEFT anchor across hunk boundaries' {
        $deletionPatch = @'
@@ -10,4 +10,3 @@
 context
-deleted line
 context
 context
@@ -30,4 +29,3 @@
 context
-another deleted line
 context
 context
'@
        $deletionMap = Build-LineMap -Patch $deletionPatch

        Resolve-FindingLocation -LineMap $deletionMap -LineNumber 20 | Should -BeNullOrEmpty
    }
}

Describe 'Inferred location deduplication' {
    It 'deduplicates by source line without reserving the shared anchor' {
        $domain = 'Style'
        $domainKey = ConvertTo-DomainMetadataKey -Domain $domain
        Mock Get-ReviewComments {
            @([pscustomobject]@{
                path = 'src/example.al'
                line = 13
                side = 'RIGHT'
                body = "<!-- agent_domain_key: $domainKey -->`n<!-- agent_source_line: 12 -->"
            })
        }

        $existing = Get-ExistingCommentKeys -Domain $domain

        $existing.SourceKeys.Contains('src/example.al:12') | Should -BeTrue
        $existing.Keys.Count | Should -Be 0
        $existing.Locations.Count | Should -Be 0
    }
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

Describe 'Resolve-SuggestionPlacement' {
    It 'suppresses an edited single-line suggestion from a comment anchor' {
        $lines = @(
            'begin',
            '    // Calculate the quantity to release.',
            '    ReleaseQtyBase := Abs(QtyBase) - CalcQtyToPickOnLotBase(ItemLedgerEntry);',
            'end;'
        )
        $suggestion = @(
            '    ReleaseQtyBase := Abs(QtyBase) - this.CalcQtyToPickOnLotBase(ItemLedgerEntry);'
        )

        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 2 -SuggestedLines $suggestion

        $placement | Should -BeNullOrEmpty
    }

    It 'does not match code suggestions to similar comment text' {
        $lines = @(
            '    // ReleaseQtyBase := Abs(QtyBase) - this.CalcQtyToPickOnLotBase(ItemLedgerEntry);',
            '    ReleaseQtyBase := Abs(QtyBase) - CalcQtyToPickOnLotBase(ItemLedgerEntry);'
        )
        $suggestion = @(
            '    ReleaseQtyBase := Abs(QtyBase) - this.CalcQtyToPickOnLotBase(ItemLedgerEntry);'
        )

        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 1 -SuggestedLines $suggestion

        $placement | Should -BeNullOrEmpty
    }

    It 'suppresses an unrelated single-line rewrite instead of trusting the anchor' {
        $placement = Resolve-SuggestionPlacement `
            -FileLines @('begin', '    DoWork();', 'end;') `
            -AnchorLine 2 `
            -SuggestedLines @('    CompletelyDifferentOperation(Value);')

        $placement | Should -BeNullOrEmpty
    }

    It 'suppresses an ambiguous single-line target' {
        $lines = @(
            '    Customer.SetRange(Blocked, Customer.Blocked::All);',
            '    Vendor.SetRange(Blocked, Vendor.Blocked::All);'
        )

        $placement = Resolve-SuggestionPlacement `
            -FileLines $lines `
            -AnchorLine 1 `
            -SuggestedLines @('    Record.SetRange(Blocked, Record.Blocked::All);')

        $placement | Should -BeNullOrEmpty
    }

    It 'does not move from one code line to a more similar unrelated code line' {
        $lines = @(
            'OldResult := OldProvider.Calculate(Source);',
            'OtherResult := NewProvider.Calculate(Target);'
        )

        $placement = Resolve-SuggestionPlacement `
            -FileLines $lines `
            -AnchorLine 1 `
            -SuggestedLines @('Result := NewProvider.Calculate(Target);')

        $placement | Should -BeNullOrEmpty
    }

    It 'does not guess between plausible lines from a comment anchor' {
        $lines = @(
            '// Update the result.',
            'Result := Calculate(Source);',
            'begin',
            'end;',
            'Result := this.Provider.Calculate(Target);'
        )

        $placement = Resolve-SuggestionPlacement `
            -FileLines $lines `
            -AnchorLine 1 `
            -SuggestedLines @('Result := this.Provider.Calculate(Source);')

        $placement | Should -BeNullOrEmpty
    }

    It 'keeps an exact single-line suggestion on its anchor' {
        $placement = Resolve-SuggestionPlacement `
            -FileLines @('begin', '    DoWork();', 'end;') `
            -AnchorLine 2 `
            -SuggestedLines @(' DoWork(); ')

        $placement.startLine | Should -Be 2
        $placement.endLine | Should -Be 2
    }

    It 'suppresses a changed target when an out-of-range anchor clamps to code' {
        $placement = Resolve-SuggestionPlacement `
            -FileLines @('DoWork();', 'exit(Result);') `
            -AnchorLine 99 `
            -SuggestedLines @('exit(this.Result);')

        $placement | Should -BeNullOrEmpty
    }

    It 'suppresses empty input and blank single-line suggestions' {
        Resolve-SuggestionPlacement -FileLines @() -AnchorLine 1 -SuggestedLines @('x') |
            Should -BeNullOrEmpty
        Resolve-SuggestionPlacement -FileLines @('x') -AnchorLine 1 -SuggestedLines @('   ') |
            Should -BeNullOrEmpty
    }

    It 'preserves additive multi-line placement' {
        $lines = @('begin', '    DoFirst();', '    DoLast();', 'end;')
        $suggestion = @('    DoFirst();', '    DoMiddle();', '    DoLast();')

        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 2 -SuggestedLines $suggestion

        $placement.startLine | Should -Be 2
        $placement.endLine | Should -Be 3
    }

    It 'places pure reorderings over the complete source span' {
        $lines = @('using Microsoft.Sales;', 'using Microsoft.Foundation;', 'using System;')
        $suggestion = @('using System;', 'using Microsoft.Foundation;', 'using Microsoft.Sales;')

        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 2 -SuggestedLines $suggestion

        $placement.startLine | Should -Be 1
        $placement.endLine | Should -Be 3
    }

    It 'does not let an additive subsequence truncate a reordered source span' {
        $lines = @('using Microsoft.Sales;', 'using Microsoft.Foundation;', 'using System;')
        $suggestion = @('using Microsoft.Foundation;', 'using Microsoft.Sales;', 'using System;')

        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 1 -SuggestedLines $suggestion

        $placement.startLine | Should -Be 1
        $placement.endLine | Should -Be 3
    }

    It 'suppresses a suggestion that both reorders and inserts' {
        $lines = @('using Microsoft.Sales;', 'using Microsoft.Foundation;', 'using System;')
        $suggestion = @(
            'using Microsoft.Foundation;',
            'using Microsoft.Sales;',
            'using Microsoft.Inventory;',
            'using System;'
        )
        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 1 -SuggestedLines $suggestion
        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 1 -SuggestedLines $suggestion

        $placement | Should -BeNullOrEmpty
    }

    It 'does not let reorder-plus-insert masquerade as a truncated additive span' {
        $lines = @('using Microsoft.Sales;', 'using Microsoft.Foundation;', 'using System;')
        $suggestion = @(
            'using Microsoft.Foundation;',
            'using Microsoft.Sales;',
            'using Microsoft.Inventory;',
            'using System;'
        )

        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 2 -SuggestedLines $suggestion

        $placement | Should -BeNullOrEmpty
    }

    It 'prefers the repeated additive block that contains the anchor' {
        $lines = @('Reset();', 'Run();', 'Reset();', 'Run();')
        $suggestion = @('Reset();', 'Configure();', 'Run();')

        $placement = Resolve-SuggestionPlacement -FileLines $lines -AnchorLine 3 -SuggestedLines $suggestion

        $placement.startLine | Should -Be 3
        $placement.endLine | Should -Be 4
    }

    It 'suppresses equally ranked repeated reorder spans' {
        $placement = Resolve-SuggestionPlacement `
            -FileLines @('DoWork();', 'DoWork();', 'DoWork();') `
            -AnchorLine 2 `
            -SuggestedLines @('DoWork();', 'DoWork();')

        $placement | Should -BeNullOrEmpty
    }

    It 'does not treat a changed line set as a pure reordering' {
        $placement = Resolve-SuggestionPlacement `
            -FileLines @('using Microsoft.Sales;', 'using Microsoft.Foundation;') `
            -AnchorLine 1 `
            -SuggestedLines @('using Microsoft.Foundation;', 'using System;')

        $placement | Should -BeNullOrEmpty
    }

    It 'does not move a multi-line replacement away from a code anchor' {
        $placement = Resolve-SuggestionPlacement `
            -FileLines @('A();', 'B();', 'C();') `
            -AnchorLine 1 `
            -SuggestedLines @('B();', 'X();', 'C();')

        $placement | Should -BeNullOrEmpty
    }

    It 'counts duplicate lines when validating a multiset equality' {
        Test-LooseMultisetEqual `
            -A @('DoWork();', 'DoWork();', 'Finish();') `
            -B @('Finish();', 'DoWork();', 'DoWork();') |
            Should -BeTrue
        Test-LooseMultisetEqual `
            -A @('DoWork();', 'DoWork();', 'Finish();') `
            -B @('Finish();', 'Finish();', 'DoWork();') |
            Should -BeFalse
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

    It 'renders failed sub-skills separately from intentionally skipped sub-skills' {
        $body = Build-SummaryBody -Outcome partial -OutcomeReason 'One review domain failed.' `
            -DomainSummary @{} -Suppressed @() `
            -SkippedSubSkills @([pscustomobject]@{ id = 'al-testing-review'; reason = 'configuration' }) `
            -FailedSubSkills @([pscustomobject]@{
                id = 'al-error-handling-review'
                reason = 'Leaf report failed schema validation.'
            }) `
            -FilterReport $null

        $body | Should -Match '### Sub-skills skipped'
        $body | Should -Match 'al-testing-review — configuration'
        $body | Should -Match '### Sub-skills failed — review coverage is incomplete'
        $body | Should -Match '\| al-error-handling-review \| Leaf report failed schema validation\. \|'
    }

    It 'uses a bounded fallback when a failed sub-skill has no report explanation' {
        $body = Build-SummaryBody -Outcome partial -OutcomeReason '' -DomainSummary @{} `
            -Suppressed @() -SkippedSubSkills @() `
            -FailedSubSkills @([pscustomobject]@{ id = 'al-query-review'; reason = '' }) `
            -FilterReport $null

        $body | Should -Match 'al-query-review'
        $body | Should -Match 'Failed without a report-provided explanation; see the run manifest'
    }

    It 'omits the failed sub-skills section when no sub-result failed' {
        $body = Build-SummaryBody -Outcome completed -OutcomeReason '' -DomainSummary @{} `
            -Suppressed @([pscustomobject]@{ path = 'microsoft/knowledge/a.md'; reason = 'configuration' }) `
            -SkippedSubSkills @([pscustomobject]@{ id = 'al-testing-review'; reason = 'not-applicable' }) `
            -FailedSubSkills @() -FilterReport $null

        $body | Should -Match 'Knowledge files suppressed'
        $body | Should -Match '### Sub-skills skipped'
        $body | Should -Not -Match 'Sub-skills failed'
    }
}

Describe 'Deterministic leaf orchestration contract' {
    BeforeEach {
        $BCQualityRoot = Join-Path $TestDrive 'deterministic-bcquality'
        $ReviewOutputDir = Join-Path $TestDrive 'review-output'
        $ReviewStartedAt = [DateTime]::UtcNow.AddSeconds(-5)
        $CopilotCliVersion = '1.0.83'
        $CopilotModel = 'claude-sonnet-5'
        $LeafModel = 'gpt-5.4'
        $LeafExecution = 'serial'
        $MaxLeafConcurrency = 4
        $CopilotCliTimeoutMinutes = 30
        $MinimumSeverity = 'Low'
        $AgentMinimumSeverity = 'Low'
        $ReviewSource = 'local'
        $BCQualitySha = 'b74967bc5b7a454eae19d6a1250199afd869f064'
        $AgentVersion = '1.0.0'
        $ReportFileName = '_review-report.json'
        $AgentWorkDir = $BCQualityRoot
        $AnalysisWorkspace = 'C:\review-target'
        $DiffRange = 'origin/main...HEAD'
        $script:AgentTranscript = ''
        $script:CopilotOtelRecords = @()
        $script:CopilotOtelMalformedRecords = 0
        $script:FailedLeafReviews = @()
        $script:ReviewProcessTelemetry = [System.Collections.Generic.List[object]]::new()
        $script:ReviewRunCompletedAt = $null
        $script:ObservedCopilotCliVersion = '1.0.83'
        $script:CopilotCliCompatibility = [pscustomobject]@{
            version = '1.0.83'
            otel_cli_version = 'required'
        }
        New-Item -ItemType Directory -Path (Join-Path $BCQualityRoot 'microsoft/skills/review') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $BCQualityRoot 'skills') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $BCQualityRoot 'schemas') -Force | Out-Null
        @'
{
  "type": "object",
  "required": ["skill", "findings", "suppressed"],
  "properties": {
    "skill": {
      "type": "object",
      "required": ["id"],
      "properties": { "id": { "type": "string" } }
    },
    "findings": { "type": "array" },
    "suppressed": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["reference"],
        "properties": { "reference": { "type": "object" } }
      }
    }
  }
}
'@ | Set-Content -LiteralPath (Join-Path $BCQualityRoot 'schemas/findings-report.schema.json')
        Set-Content -LiteralPath (Join-Path $BCQualityRoot 'microsoft/skills/review/al-security-review.md') -Value '# security'
        Set-Content -LiteralPath (Join-Path $BCQualityRoot 'microsoft/skills/review/al-style-review.md') -Value '# style'

        @{
            version = 1
            skills = @(
                @{
                    id = 'al-code-review'
                    path = 'microsoft/skills/review/al-code-review.md'
                    version = 1
                    outputs = @('findings-report')
                    subSkills = @(
                        'microsoft/skills/review/al-security-review.md',
                        'microsoft/skills/review/al-style-review.md'
                    )
                },
                @{
                    id = 'al-security-review'
                    path = 'microsoft/skills/review/al-security-review.md'
                    version = 1
                    outputs = @('findings-report')
                    subSkills = @()
                },
                @{
                    id = 'al-style-review'
                    path = 'microsoft/skills/review/al-style-review.md'
                    version = 1
                    outputs = @('findings-report')
                    subSkills = @()
                }
            )
        } | ConvertTo-Json -Depth 10 |
            Set-Content -LiteralPath (Join-Path $BCQualityRoot '_skill-index.json')

        $script:BCQualityConfigCache = @{
            'enabled-layers' = @('microsoft')
            'disabled-skills' = @()
        }
        $script:TestLeafReports = @{}
        $script:TestLeafMetrics = [pscustomobject]@{
            models = @('gpt-5.4')
            usage_complete = $true
            malformed_records = 0
            cli_version = '1.0.83'
            total_tokens = 12
        }

        Mock Save-CopilotRunMetrics { $script:TestLeafMetrics }
        Mock Start-LeafCopilotProcess {
            param($Leaf, $WorkDir, $Prompt)

            New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
            $script:TestLeafReports[$Leaf.id] |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath (Join-Path $WorkDir $ReportFileName)
            $process = [pscustomobject]@{
                HasExited = $true
                ExitCode = 0
            }
            $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
            return [pscustomobject]@{
                Leaf = $Leaf
                WorkDir = $WorkDir
                OtelPath = Join-Path $WorkDir 'missing-otel.jsonl'
                Process = $process
                StdoutTask = [System.Threading.Tasks.Task]::FromResult([string]'')
                StderrTask = [System.Threading.Tasks.Task]::FromResult([string]'')
                StartedAt = [DateTime]::UtcNow.AddSeconds(-1)
            }
        }
    }

    It 'resolves leaves in the exact order declared by BCQuality' {
        $plan = @(Get-ReviewLeafPlan)

        $plan.id | Should -Be @('al-security-review', 'al-style-review')
        $plan.ordinal | Should -Be @(1, 2)
    }

    It 'removes configured disabled leaves without reordering the remainder' {
        $script:BCQualityConfigCache['disabled-skills'] = @(
            'microsoft/skills/review/al-security-review.md'
        )

        $plan = @(Get-ReviewLeafPlan)

        $plan.id | Should -Be @('al-style-review')
        $plan.ordinal | Should -Be 2
    }

    It 'pins a leaf process to one skill and forbids child-agent delegation' {
        $AnalysisWorkspace = 'C:\review-target'
        $DiffRange = 'origin/main...HEAD'
        $ReviewPathSpec = ''
        $LeafModel = 'gpt-5.6-luna'
        $ReportFileName = '_review-report.json'
        $leaf = (Get-ReviewLeafPlan)[0]

        $prompt = New-LeafReviewPrompt -Leaf $leaf -WorkDir $TestDrive

        $prompt | Should -Match "Review only the domain defined by BCQuality leaf skill 'al-security-review'"
        $prompt | Should -Match "pinned mechanically to model 'gpt-5\.6-luna'"
        $prompt | Should -Match 'Do not invoke child agents or other review skills'
    }

    It 'repairs an omitted suppressed array without inventing suppressed items' {
        $report = [pscustomobject]@{
            skill = [pscustomobject]@{ id = 'al-security-review' }
            findings = @()
        }

        Repair-MissingSuppressedProperty -ReportObject $report | Should -BeTrue
        $report.PSObject.Properties.Match('suppressed').Count | Should -Be 1
        @($report.suppressed).Count | Should -Be 0

        $malformedSuppressed = [pscustomobject]@{
            skill = [pscustomobject]@{ id = 'al-security-review' }
            suppressed = @([pscustomobject]@{})
        }
        Repair-MissingSuppressedProperty -ReportObject $malformedSuppressed | Should -BeFalse
        $malformedSuppressed.suppressed[0].PSObject.Properties.Match('reference').Count | Should -Be 0
    }

    It 'rejects super-skill-only fields in an otherwise schema-valid leaf report' {
        $report = [pscustomobject]@{
            skill = [pscustomobject]@{ id = 'al-security-review' }
            findings = @()
            suppressed = @()
            'sub-results' = @()
            'skipped-sub-skills' = @()
        }

        { Assert-LeafReportRole -ReportObject $report } |
            Should -Throw '*super-skill-only field(s): sub-results, skipped-sub-skills*'
    }

    It 'marks a schema-valid leaf with super-skill fields failed during orchestration' {
        $plan = @(Get-ReviewLeafPlan)
        $script:TestLeafReports['al-security-review'] = @{
            skill = @{ id = 'al-security-review' }
            findings = @()
            suppressed = @()
            'sub-results' = @()
            'skipped-sub-skills' = @()
        }

        $results = @(Invoke-DeterministicLeafReviews -Plan @($plan[0]))

        $results.Count | Should -Be 0
        $script:FailedLeafReviews[0].Leaf.id | Should -Be 'al-security-review'
        $script:FailedLeafReviews[0].Reason |
            Should -Match 'super-skill-only field'
    }

    It 'accepts a normal leaf report without super-skill fields' {
        $report = [pscustomobject]@{
            skill = [pscustomobject]@{ id = 'al-security-review' }
            findings = @()
            suppressed = @()
        }

        { Assert-LeafReportRole -ReportObject $report } | Should -Not -Throw
    }

    It 'reconciles final status from leaf coverage and the validated root report' {
        $plan = @(Get-ReviewLeafPlan)
        $complete = [pscustomobject]@{
            outcome = 'completed'
            'sub-results' = @(
                [pscustomobject]@{ outcome = 'completed' },
                [pscustomobject]@{ outcome = 'not-applicable' }
            )
        }
        $partialRoot = [pscustomobject]@{
            outcome = 'completed'
            'sub-results' = @(
                [pscustomobject]@{ outcome = 'completed' },
                [pscustomobject]@{ outcome = 'failed' }
            )
        }
        $failedRoot = [pscustomobject]@{
            outcome = 'failed'
            'sub-results' = @(
                [pscustomobject]@{ outcome = 'failed' },
                [pscustomobject]@{ outcome = 'failed' }
            )
        }
        $allLeaves = @([pscustomobject]@{ Leaf = $plan[0] }, [pscustomobject]@{ Leaf = $plan[1] })
        $oneLeaf = @([pscustomobject]@{ Leaf = $plan[0] })

        Get-ConsolidatedReviewStatus -Plan $plan -LeafResults $allLeaves -Report $complete |
            Should -Be 'completed'
        Get-ConsolidatedReviewStatus -Plan $plan -LeafResults $oneLeaf -Report $complete |
            Should -Be 'partial'
        Get-ConsolidatedReviewStatus -Plan $plan -LeafResults $allLeaves -Report $partialRoot |
            Should -Be 'partial'
        Get-ConsolidatedReviewStatus -Plan $plan -LeafResults $allLeaves -Report $failedRoot |
            Should -Be 'failed'
    }

    It 'harvests OTel before recovering a nonzero leaf exit' {
        $workDir = Join-Path $TestDrive 'nonzero-leaf'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $otel = @(
            '{"type":"span","attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.agent.version":"1.0.83"}}',
            '{"type":"span","status":{"code":2},"attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5.4","gen_ai.usage.input_tokens":90,"gen_ai.usage.output_tokens":10}}'
        )
        Set-Content -LiteralPath (Join-Path $workDir 'otel.jsonl') -Value $otel
        $process = [pscustomobject]@{ HasExited = $true; ExitCode = 7 }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        Mock Save-CopilotRunMetrics {
            param($Records, $OutputDir, $WallTimeSeconds, $MalformedRecords)
            Get-CopilotRunMetrics -Records $Records -WallTimeSeconds $WallTimeSeconds -MalformedRecords $MalformedRecords
        }
        $leaf = @(Get-ReviewLeafPlan)[0]
        $state = [pscustomobject]@{
            Leaf = $leaf
            WorkDir = $workDir
            OtelPath = Join-Path $workDir 'otel.jsonl'
            Process = $process
            StdoutTask = [System.Threading.Tasks.Task]::FromResult([string]'')
            StderrTask = [System.Threading.Tasks.Task]::FromResult([string]'')
            StartedAt = [DateTime]::UtcNow.AddSeconds(-1)
        }

        $result = Receive-LeafCopilotProcess -State $state

        $result | Should -BeNullOrEmpty
        $script:CopilotOtelRecords.Count | Should -Be 2
        $failed = @($script:ReviewProcessTelemetry | Where-Object status -eq 'failed')
        $failed[0].metrics.total_tokens | Should -Be 100
        $failed[0].failure_reason | Should -Match 'exited with code 7'
    }

    It 'harvests OTel before recovering a timed-out leaf' {
        $workDir = Join-Path $TestDrive 'timeout-leaf'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        @(
            '{"type":"span","attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.agent.version":"1.0.83"}}',
            '{"type":"span","status":{"code":2},"attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gpt-5.4","gen_ai.usage.input_tokens":40,"gen_ai.usage.output_tokens":6}}'
        ) | Set-Content -LiteralPath (Join-Path $workDir 'otel.jsonl')
        $process = [pscustomobject]@{ HasExited = $true; ExitCode = 0 }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        Mock Save-CopilotRunMetrics {
            param($Records, $OutputDir, $WallTimeSeconds, $MalformedRecords)
            Get-CopilotRunMetrics -Records $Records -WallTimeSeconds $WallTimeSeconds -MalformedRecords $MalformedRecords
        }
        $leaf = @(Get-ReviewLeafPlan)[0]
        $oldTimeout = $CopilotCliTimeoutMinutes
        $CopilotCliTimeoutMinutes = 1
        try {
            $state = [pscustomobject]@{
                Leaf = $leaf
                WorkDir = $workDir
                OtelPath = Join-Path $workDir 'otel.jsonl'
                Process = $process
                StdoutTask = [System.Threading.Tasks.Task]::FromResult([string]'')
                StderrTask = [System.Threading.Tasks.Task]::FromResult([string]'')
                StartedAt = [DateTime]::UtcNow.AddMinutes(-2)
            }

            $result = Receive-LeafCopilotProcess -State $state

            $result | Should -BeNullOrEmpty
            $script:CopilotOtelRecords.Count | Should -Be 2
            $failed = @($script:ReviewProcessTelemetry | Where-Object status -eq 'failed')
            $failed[0].metrics.total_tokens | Should -Be 46
            $failed[0].failure_reason | Should -Match 'timed out'
        }
        finally {
            $CopilotCliTimeoutMinutes = $oldTimeout
        }
    }

    It 'records an uncontrolled timed-out leaf before refusing to drain output' {
        $workDir = Join-Path $TestDrive 'uncontrolled-timeout-leaf'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        $process = [pscustomobject]@{ HasExited = $false; ExitCode = $null }
        $process | Add-Member -MemberType ScriptMethod -Name Kill -Value { param($EntireProcessTree) }
        $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($Milliseconds) return $false }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        $script:OutputDrainAttempted = $false
        $stdoutTask = [pscustomobject]@{}
        $stdoutTask | Add-Member -MemberType ScriptMethod -Name GetAwaiter -Value {
            $script:OutputDrainAttempted = $true
            throw 'stdout drain must not be attempted'
        }
        $stderrTask = [pscustomobject]@{}
        $stderrTask | Add-Member -MemberType ScriptMethod -Name GetAwaiter -Value {
            $script:OutputDrainAttempted = $true
            throw 'stderr drain must not be attempted'
        }
        Mock Add-ReviewProcessTelemetry {}
        Mock Save-ReviewRunManifest {}
        $leaf = @(Get-ReviewLeafPlan)[0]
        $oldTimeout = $CopilotCliTimeoutMinutes
        $CopilotCliTimeoutMinutes = 1
        try {
            $state = [pscustomobject]@{
                Leaf = $leaf
                WorkDir = $workDir
                OtelPath = Join-Path $workDir 'otel.jsonl'
                Process = $process
                StdoutTask = $stdoutTask
                StderrTask = $stderrTask
                StartedAt = [DateTime]::UtcNow.AddMinutes(-2)
            }

            { Receive-LeafCopilotProcess -State $state } |
                Should -Throw "*remained running after timeout kill*"
            $script:OutputDrainAttempted | Should -BeFalse
            Should -Invoke Add-ReviewProcessTelemetry -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'failed' -and
                $FailureReason -match 'remained running after timeout kill'
            }
            Should -Invoke Save-ReviewRunManifest -Times 1 -Exactly -ParameterFilter {
                $Status -eq 'failed' -and
                $FailureReason -match 'remained running after timeout kill'
            }
        }
        finally {
            $CopilotCliTimeoutMinutes = $oldTimeout
        }
    }

    It 'hard-fails a nonzero leaf when harvested OTel has the wrong model' {
        $workDir = Join-Path $TestDrive 'nonzero-wrong-model'
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
        @(
            '{"type":"span","attributes":{"gen_ai.operation.name":"invoke_agent","gen_ai.agent.version":"1.0.83"}}',
            '{"type":"span","status":{"code":2},"attributes":{"gen_ai.operation.name":"chat","gen_ai.request.model":"gemini-3.6-flash","gen_ai.usage.input_tokens":90,"gen_ai.usage.output_tokens":10}}'
        ) | Set-Content -LiteralPath (Join-Path $workDir 'otel.jsonl')
        $process = [pscustomobject]@{ HasExited = $true; ExitCode = 7 }
        $process | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
        Mock Save-CopilotRunMetrics {
            param($Records, $OutputDir, $WallTimeSeconds, $MalformedRecords)
            Get-CopilotRunMetrics -Records $Records -WallTimeSeconds $WallTimeSeconds -MalformedRecords $MalformedRecords
        }
        $leaf = @(Get-ReviewLeafPlan)[0]
        $state = [pscustomobject]@{
            Leaf = $leaf
            WorkDir = $workDir
            OtelPath = Join-Path $workDir 'otel.jsonl'
            Process = $process
            StdoutTask = [System.Threading.Tasks.Task]::FromResult([string]'')
            StderrTask = [System.Threading.Tasks.Task]::FromResult([string]'')
            StartedAt = [DateTime]::UtcNow.AddSeconds(-1)
        }

        { Receive-LeafCopilotProcess -State $state } |
            Should -Throw "*required model 'gpt-5.4'*"
        $script:CopilotOtelRecords.Count | Should -Be 2
    }

    It 'consolidates only after ordered leaf reports exist and forbids leaf retries' {
        $AnalysisWorkspace = 'C:\review-target'
        $DiffRange = 'origin/main...HEAD'
        $ReportFileName = '_review-report.json'
        $AgentWorkDir = $TestDrive
        $leafResults = @(
            [pscustomobject]@{ ReportPath = 'C:\out\01-security\_review-report.json' },
            [pscustomobject]@{ ReportPath = 'C:\out\02-style\_review-report.json' }
        )

        $prompt = Build-ConsolidationPrompt -LeafResults $leafResults

        $prompt.IndexOf('01-security') | Should -BeLessThan $prompt.IndexOf('02-style')
        $prompt | Should -Match 'Do not invoke child agents, Task tools, or leaf skills'
        $prompt | Should -Match 'Do not omit, retry, or replace any leaf report'
    }

    It 'surfaces failed leaves to root consolidation as failed rather than skipped' {
        $AnalysisWorkspace = 'C:\review-target'
        $DiffRange = 'origin/main...HEAD'
        $ReportFileName = '_review-report.json'
        $AgentWorkDir = $TestDrive
        $leafResults = @(
            [pscustomobject]@{ ReportPath = 'C:\out\01-security\_review-report.json' }
        )
        $failedLeaves = @(
            [pscustomobject]@{
                Leaf = [pscustomobject]@{ id = 'al-style-review' }
                Reason = 'report does not conform to the findings-report schema'
            }
        )

        $prompt = Build-ConsolidationPrompt -LeafResults $leafResults -FailedLeaves $failedLeaves

        $prompt | Should -Match 'al-style-review: failed before a usable findings-report was available'
        $prompt | Should -Match "outcome 'failed'"
        $prompt | Should -Match 'Failed leaves are distinct from\s+skipped'
    }

    It 'parses failed sub-results and their schema-defined outcome reasons' {
        $report = @{
            skill = @{ id = 'al-code-review'; version = 1 }
            outcome = 'partial'
            'outcome-reason' = 'One leaf failed.'
            summary = @{
                counts = @{ blocker = 0; major = 0; minor = 0; info = 0 }
                coverage = @{ 'worklist-size' = 2; 'items-evaluated' = 1 }
            }
            findings = @()
            suppressed = @()
            'sub-results' = @(
                @{
                    skill = @{ id = 'al-security-review'; version = 1 }
                    outcome = 'completed'
                    summary = @{
                        counts = @{ blocker = 0; major = 0; minor = 0; info = 0 }
                        coverage = @{ 'worklist-size' = 1; 'items-evaluated' = 1 }
                    }
                    findings = @()
                    suppressed = @()
                },
                @{
                    skill = @{ id = 'al-style-review'; version = 1 }
                    outcome = 'failed'
                    'outcome-reason' = 'Schema-invalid leaf report.'
                    summary = @{
                        counts = @{ blocker = 0; major = 0; minor = 0; info = 0 }
                        coverage = @{ 'worklist-size' = 1; 'items-evaluated' = 0 }
                    }
                    findings = @()
                    suppressed = @()
                }
            )
            'skipped-sub-skills' = @()
        } | ConvertTo-Json -Depth 20

        $parsed = Parse-BCQualityReport -Output $report

        $parsed.FailedSubSkills.Count | Should -Be 1
        $parsed.FailedSubSkills[0].id | Should -Be 'al-style-review'
        $parsed.FailedSubSkills[0].reason | Should -Be 'Schema-invalid leaf report.'
        $parsed.SkippedSubSkills.Count | Should -Be 0
    }

    It 'continues after a schema-invalid leaf and records partial coverage' {
        $plan = @(Get-ReviewLeafPlan)
        $script:TestLeafReports['al-security-review'] = @{
            skill = @{ id = 'al-security-review' }
            findings = @()
        }
        $script:TestLeafReports['al-style-review'] = @{
            skill = @{ id = 'al-style-review' }
            findings = @()
            suppressed = @(@{ reason = 'missing reference' })
        }

        $results = @(Invoke-DeterministicLeafReviews -Plan $plan)
        $status = Assert-UsableLeafReviewCoverage -Plan $plan -LeafResults $results
        $prompt = Build-ConsolidationPrompt -LeafResults $results -FailedLeaves $script:FailedLeafReviews
        Save-ReviewRunManifest -Status $status

        $results.Count | Should -Be 1
        $results[0].Leaf.id | Should -Be 'al-security-review'
        $status | Should -Be 'partial'
        $prompt | Should -Match 'al-style-review: failed before a usable findings-report was available'
        $repaired = Get-Content -LiteralPath $results[0].ReportPath -Raw | ConvertFrom-Json
        $repaired.PSObject.Properties.Match('suppressed').Count | Should -Be 1
        @($repaired.suppressed).Count | Should -Be 0
        $script:TestLeafReports['al-style-review'].suppressed[0].ContainsKey('reference') | Should -BeFalse

        $manifest = Get-Content -LiteralPath (Join-Path $ReviewOutputDir '_run-manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.status | Should -Be 'partial'
        @($manifest.processes | Where-Object status -eq 'completed').Count | Should -Be 1
        @($manifest.processes | Where-Object status -eq 'failed').Count | Should -Be 1
        ($manifest.processes | Where-Object status -eq 'failed').skill_id | Should -Be 'al-style-review'
        ($manifest.processes | Where-Object status -eq 'failed').failure_reason |
            Should -Match 'Required properties.*reference'
    }

    It 'fails before root consolidation when every leaf report is unusable' {
        $plan = @(Get-ReviewLeafPlan)
        foreach ($leaf in $plan) {
            $script:TestLeafReports[$leaf.id] = @{
                skill = @{ id = $leaf.id }
                findings = @()
                suppressed = @(@{ reason = 'missing reference' })
            }
        }

        $results = @(Invoke-DeterministicLeafReviews -Plan $plan)

        $results.Count | Should -Be 0
        { Assert-UsableLeafReviewCoverage -Plan $plan -LeafResults $results } |
            Should -Throw '*All 2 deterministic review leaves failed*root consolidation was not run*'
        $manifest = Get-Content -LiteralPath (Join-Path $ReviewOutputDir '_run-manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.status | Should -Be 'failed'
        @($manifest.processes | Where-Object status -eq 'completed').Count | Should -Be 0
        @($manifest.processes | Where-Object status -eq 'failed').Count | Should -Be 2
        @($manifest.processes | Where-Object status -eq 'failed').skill_id |
            Should -Be @('al-security-review', 'al-style-review')
    }

    It 'stops the orchestration immediately on <Name> integrity failure' -ForEach @(
        @{
            Name = 'wrong-model'
            Metrics = [pscustomobject]@{
                models = @('gemini-3.6-flash')
                usage_complete = $true
                malformed_records = 0
                cli_version = '1.0.83'
                total_tokens = 12
            }
            ErrorPattern = "*required model 'gpt-5.4'*"
        },
        @{
            Name = 'incomplete-usage'
            Metrics = [pscustomobject]@{
                models = @('gpt-5.4')
                usage_complete = $false
                malformed_records = 0
                cli_version = '1.0.83'
                total_tokens = 12
            }
            ErrorPattern = '*incomplete Copilot usage telemetry*'
        },
        @{
            Name = 'malformed-telemetry'
            Metrics = [pscustomobject]@{
                models = @('gpt-5.4')
                usage_complete = $true
                malformed_records = 1
                cli_version = '1.0.83'
                total_tokens = 12
            }
            ErrorPattern = '*malformed Copilot telemetry record*'
        },
        @{
            Name = 'wrong-CLI'
            Metrics = [pscustomobject]@{
                models = @('gpt-5.4')
                usage_complete = $true
                malformed_records = 0
                cli_version = '1.0.82'
                total_tokens = 12
            }
            ErrorPattern = "*expected startup-probed Copilot CLI '1.0.83'*"
        }
    ) {
        $plan = @(Get-ReviewLeafPlan)
        foreach ($leaf in $plan) {
            $script:TestLeafReports[$leaf.id] = @{
                skill = @{ id = $leaf.id }
                findings = @()
                suppressed = @()
            }
        }
        $script:TestLeafMetrics = $Metrics

        { Invoke-DeterministicLeafReviews -Plan $plan } |
            Should -Throw $ErrorPattern
        Should -Invoke Start-LeafCopilotProcess -Times 1 -Exactly
        $manifest = Get-Content -LiteralPath (Join-Path $ReviewOutputDir '_run-manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.status | Should -Be 'failed'
        @($manifest.processes | Where-Object status -eq 'failed').Count | Should -Be 1
        @($manifest.processes).Count | Should -Be 1
    }

    It 'rejects a consolidated report that changes the declared leaf order' {
        $plan = @(Get-ReviewLeafPlan)
        $report = @{
            skill = @{ id = 'al-code-review'; version = 1 }
            outcome = 'completed'
            summary = @{ knowledge = 0; agent = 0; suppressed = 0; total = 0 }
            findings = @()
            references = @()
            suppressed = @()
            'sub-results' = @(
                @{ skill = @{ id = 'al-style-review'; version = 1 }; outcome = 'completed'; summary = @{}; findings = @(); suppressed = @() },
                @{ skill = @{ id = 'al-security-review'; version = 1 }; outcome = 'completed'; summary = @{}; findings = @(); suppressed = @() }
            )
            'skipped-sub-skills' = @()
        } | ConvertTo-Json -Depth 10

        { Assert-ConsolidatedReport -ReportText $report -Plan $plan } |
            Should -Throw "*was 'al-style-review'; expected 'al-security-review'*"
    }

    It 'fails closed on model, usage, malformed-record, and CLI-version telemetry mismatches' {
        $valid = [pscustomobject]@{
            models = @('gpt-5.4')
            usage_complete = $true
            malformed_records = 0
            cli_version = '1.0.83'
        }
        { Assert-CopilotInvocationMetrics -Metrics $valid -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Not -Throw

        $wrongModel = $valid.PSObject.Copy()
        $wrongModel.models = @('gemini-3.6-flash')
        { Assert-CopilotInvocationMetrics -Metrics $wrongModel -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Throw "*required model 'gpt-5.4'*"

        $incomplete = $valid.PSObject.Copy()
        $incomplete.usage_complete = $false
        { Assert-CopilotInvocationMetrics -Metrics $incomplete -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Throw '*incomplete Copilot usage telemetry*'

        $malformed = $valid.PSObject.Copy()
        $malformed.malformed_records = 1
        { Assert-CopilotInvocationMetrics -Metrics $malformed -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Throw '*1 malformed Copilot telemetry record*'

        $wrongCli = $valid.PSObject.Copy()
        $wrongCli.cli_version = '1.0.82'
        { Assert-CopilotInvocationMetrics -Metrics $wrongCli -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Throw "*expected startup-probed Copilot CLI '1.0.83'*"
    }

    It 'requires OTel CLI version for the 1.0.83 compatibility policy' {
        $metrics = [pscustomobject]@{
            models = @('gpt-5.4')
            usage_complete = $true
            malformed_records = 0
            cli_version = $null
        }

        { Assert-CopilotInvocationMetrics -Metrics $metrics -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Throw "*expected startup-probed Copilot CLI '1.0.83'; telemetry reported '(none)'*"
    }

    It 'accepts absent OTel CLI version only for the 1.0.88 compatibility policy' {
        $script:ObservedCopilotCliVersion = '1.0.88'
        $script:CopilotCliCompatibility = [pscustomobject]@{
            version = '1.0.88'
            otel_cli_version = 'optional'
        }
        $metrics = [pscustomobject]@{
            models = @('gpt-5.4')
            usage_complete = $true
            malformed_records = 0
            cli_version = $null
        }

        { Assert-CopilotInvocationMetrics -Metrics $metrics -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Not -Throw
    }

    It 'accepts a matching OTel CLI version for the 1.0.88 compatibility policy' {
        $script:ObservedCopilotCliVersion = '1.0.88'
        $script:CopilotCliCompatibility = [pscustomobject]@{
            version = '1.0.88'
            otel_cli_version = 'optional'
        }
        $metrics = [pscustomobject]@{
            models = @('gpt-5.4')
            usage_complete = $true
            malformed_records = 0
            cli_version = '1.0.88'
        }

        { Assert-CopilotInvocationMetrics -Metrics $metrics -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Not -Throw
    }

    It 'rejects a mismatched OTel CLI version for the 1.0.88 compatibility policy' {
        $script:ObservedCopilotCliVersion = '1.0.88'
        $script:CopilotCliCompatibility = [pscustomobject]@{
            version = '1.0.88'
            otel_cli_version = 'optional'
        }
        $metrics = [pscustomobject]@{
            models = @('gpt-5.4')
            usage_complete = $true
            malformed_records = 0
            cli_version = '1.0.83'
        }

        { Assert-CopilotInvocationMetrics -Metrics $metrics -RequestedModel 'gpt-5.4' -InvocationLabel 'leaf' } |
            Should -Throw "*expected startup-probed Copilot CLI '1.0.88'; telemetry reported '1.0.83'*"
    }

    It 'writes a resolved run manifest with ordered per-process telemetry' {
        $script:ReviewPlanIds = @('al-security-review')
        $script:ReviewPlanSourceSnapshot = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $metrics = [pscustomobject]@{
            models = @('gpt-5.4')
            usage_complete = $true
            malformed_records = 0
            cli_version = '1.0.83'
            total_tokens = 12
        }
        $started = [DateTime]::UtcNow.AddSeconds(-2)
        Add-ReviewProcessTelemetry -Role leaf -Ordinal 1 -SkillId 'al-security-review' `
            -RequestedModel 'gpt-5.4' -Status completed -StartedAt $started `
            -CompletedAt ([DateTime]::UtcNow) -Metrics $metrics -ExitCode 0 `
            -ReportPath (Join-Path $ReviewOutputDir 'leaf-results/01-security/_review-report.json')

        Save-ReviewRunManifest -Status completed

        $manifest = Get-Content -LiteralPath (Join-Path $ReviewOutputDir '_run-manifest.json') -Raw |
            ConvertFrom-Json
        $manifest.schema_version | Should -Be 1
        $manifest.status | Should -Be 'completed'
        $manifest.configuration.copilot_cli_version | Should -Be '1.0.83'
        $manifest.configuration.PSObject.Properties.Name | Should -Be @(
            'copilot_cli_version',
            'root_model',
            'leaf_model',
            'leaf_execution',
            'max_leaf_concurrency',
            'cli_timeout_minutes',
            'minimum_severity',
            'agent_minimum_severity',
            'review_source'
        )
        $manifest.configuration.PSObject.Properties.Match('requested_copilot_cli_version').Count |
            Should -Be 0
        $manifest.configuration.root_model | Should -Be 'claude-sonnet-5'
        $manifest.configuration.leaf_execution | Should -Be 'serial'
        $manifest.bcquality.commit | Should -Be $BCQualitySha
        $manifest.plan.leaf_ids | Should -Be @('al-security-review')
        $manifest.processes[0].requested_model | Should -Be 'gpt-5.4'
        $manifest.processes[0].report_path | Should -Be 'leaf-results/01-security/_review-report.json'
    }
}

Describe 'BCQuality revision ownership' {
    It 'derives the commit from the checkout and only treats an input SHA as an assertion' {
        $root = Join-Path $TestDrive 'bcquality-revision'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        & git -C $root init -q
        & git -C $root config user.email 'test@example.com'
        & git -C $root config user.name 'Test'
        Set-Content -LiteralPath (Join-Path $root 'entry.md') -Value '# test'
        & git -C $root add entry.md
        & git -C $root commit -q -m 'test'
        $expected = (& git -C $root rev-parse HEAD).Trim()

        Resolve-BCQualityCommit -Root $root | Should -Be $expected
        Resolve-BCQualityCommit -Root $root -ExpectedCommit $expected | Should -Be $expected
        { Resolve-BCQualityCommit -Root $root -ExpectedCommit ('f' * 40) } |
            Should -Throw "*does not match expected commit*"
    }

    It 'uses the workflow-provided provenance in post without resolving a checkout' {
        $postSha = 'a' * 40

        $resolved = Resolve-BCQualityCommitForPhase `
            -Phase 'post' `
            -Root (Join-Path $TestDrive 'no-bcquality-checkout') `
            -ExpectedCommit $postSha

        $resolved | Should -Be $postSha
    }

    It 'requires a generation SHA in post' {
        {
            Resolve-BCQualityCommitForPhase -Phase 'post' -Root '' -ExpectedCommit ''
        } | Should -Throw '*BCQUALITY_SHA must contain the resolved 40-character lowercase commit SHA from the generate phase*'
    }

    It 'requires a lowercase resolved generation SHA in post' {
        {
            Resolve-BCQualityCommitForPhase -Phase 'post' -Root '' -ExpectedCommit ('A' * 40)
        } | Should -Throw '*BCQUALITY_SHA must contain the resolved 40-character lowercase commit SHA from the generate phase*'
    }

}

Describe 'Local review authentication' {
    BeforeAll {
        $script:AuthWorkspace = Join-Path $TestDrive 'workspace'
        $script:AuthBCQuality = Join-Path $TestDrive 'bcquality'
        New-Item -ItemType Directory -Path $script:AuthWorkspace -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AuthBCQuality 'skills') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:AuthBCQuality 'schemas') -Force | Out-Null
        Set-Content -Path (Join-Path $script:AuthBCQuality 'skills/entry.md') -Value '# entry'
        Set-Content -Path (Join-Path $script:AuthBCQuality 'schemas/findings-report.schema.json') -Value '{}'
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
        $CopilotModel = 'claude-sonnet-5'
        $CopilotCliVersion = '1.0.83'
        $LeafModel = 'gpt-5.4'
        $script:CopilotExecutable = $null
        $script:ObservedCopilotCliVersion = $null
        $script:CopilotCliCompatibility = $null

        Mock Get-Command {
            [pscustomobject]@{ Name = 'Test-Json' }
        } -ParameterFilter { $Name -eq 'Test-Json' }
        Mock Resolve-CopilotExecutable { 'C:\tools\copilot.exe' }
        Mock Invoke-CopilotVersionProbe {
            @(
                'GitHub Copilot CLI 1.0.83.',
                "Run 'copilot update' to check for updates."
            )
        }
    }

    It 'allows local generation without GH_TOKEN' {
        { Assert-Config } | Should -Not -Throw
    }

    It 'probes the exact child executable and applies the requested pin at startup' {
        { Assert-Config } | Should -Not -Throw

        $script:CopilotExecutable | Should -Be 'C:\tools\copilot.exe'
        $script:ObservedCopilotCliVersion | Should -Be '1.0.83'
        $script:CopilotCliCompatibility.otel_cli_version | Should -Be 'required'
        Should -Invoke Resolve-CopilotExecutable -Times 1 -Exactly
        Should -Invoke Invoke-CopilotVersionProbe -Times 1 -Exactly -ParameterFilter {
            $Executable -eq 'C:\tools\copilot.exe'
        }
    }

    It 'accepts a numeric CLI prerelease from the verified multi-line banner' {
        Mock Invoke-CopilotVersionProbe {
            @(
                'GitHub Copilot CLI 1.0.89-1.',
                "Run 'copilot update' to check for updates."
            )
        }

        Get-CopilotExecutableVersion -Executable 'C:\tools\copilot.exe' | Should -Be '1.0.89-1'
    }

    It 'fails during preflight before an agent process for an unsupported CLI version' {
        $CopilotCliVersion = '1.0.89'
        Mock Invoke-CopilotVersionProbe {
            @(
                'GitHub Copilot CLI 1.0.89.',
                "Run 'copilot update' to check for updates."
            )
        }
        Mock Start-LeafCopilotProcess {}

        { Assert-Config } | Should -Throw "*has not been compatibility-validated*"
        Should -Invoke Start-LeafCopilotProcess -Times 0 -Exactly
    }

    It 'fails early when the requested CLI pin differs from the startup probe' {
        Mock Invoke-CopilotVersionProbe {
            @(
                'GitHub Copilot CLI 1.0.88.',
                "Run 'copilot update' to check for updates."
            )
        }

        { Assert-Config } |
            Should -Throw "*COPILOT_REVIEW_CLI_VERSION '1.0.83' does not match startup-probed Copilot CLI version '1.0.88'*"
    }

    It 'fails early when the executable version output is unparseable' {
        Mock Invoke-CopilotVersionProbe {
            @(
                'GitHub Copilot CLI 1.0.83',
                "Run 'copilot update' to check for updates."
            )
        }

        { Assert-Config } |
            Should -Throw "*must return exactly one 'GitHub Copilot CLI <semantic-version>.' banner*"
    }

    It 'fails early when the executable version output has competing CLI banners' {
        Mock Invoke-CopilotVersionProbe {
            @(
                'GitHub Copilot CLI 1.0.83.',
                'GitHub Copilot CLI 1.0.88.'
            )
        }

        { Get-CopilotExecutableVersion -Executable 'C:\tools\copilot.exe' } |
            Should -Throw "*must return exactly one 'GitHub Copilot CLI <semantic-version>.' banner*"
    }

    It 'still requires GH_TOKEN for PR generation' {
        $ReviewSource = 'pr'
        $PrNumber = 1
        $PrHeadSha = 'abc123'

        { Assert-Config } | Should -Throw '*GH_TOKEN is required*'
    }

    It 'allows post validation with generated provenance and no BCQuality checkout' {
        $ReviewPhase = 'post'
        $ReviewSource = 'pr'
        $GithubToken = 'post-token'
        $PrNumber = 1
        $PrHeadSha = 'abc123'
        $BCQualityRoot = $null
        $BCQualitySha = Resolve-BCQualityCommitForPhase `
            -Phase $ReviewPhase `
            -Root $BCQualityRoot `
            -ExpectedCommit ('b' * 40)

        { Assert-Config } | Should -Not -Throw
        $BCQualitySha | Should -Be ('b' * 40)
    }

    It 'publishes generated findings after post validation without a BCQuality checkout' {
        $ReviewPhase = 'post'
        $ReviewSource = 'pr'
        $GithubToken = 'post-token'
        $PrNumber = 1
        $PrHeadSha = 'abc123'
        $BCQualityRoot = $null
        $BCQualitySha = Resolve-BCQualityCommitForPhase `
            -Phase $ReviewPhase `
            -Root $BCQualityRoot `
            -ExpectedCommit ('c' * 40)
        Mock Post-Findings {
            [pscustomobject]@{ inline = $Findings.Count; fallback = 0 }
        }

        { Assert-Config } | Should -Not -Throw
        $summary = Publish-FindingsByDomain `
            -Findings @([pscustomobject]@{ domain = 'Style'; isAgentFinding = $false }) `
            -LineMaps @{} `
            -ChangedFileSet @{}

        $summary['Style'].inline | Should -Be 1
        Should -Invoke Post-Findings -Times 1 -Exactly
    }

    It 'continues requiring BCQUALITY_ROOT for all and generate' -ForEach @('all', 'generate') {
        $ReviewPhase = $_
        $BCQualityRoot = $null

        { Assert-Config } | Should -Throw '*BCQUALITY_ROOT is required*'

        $BCQualityRoot = Join-Path $TestDrive 'missing-bcquality'
        { Assert-Config } | Should -Throw '*BCQUALITY_ROOT does not exist*'
    }

    It 'launches the child Copilot process without a visible console window' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $source | Should -Match '\$startInfo\.CreateNoWindow\s*=\s*\$true'
        $source | Should -Match 'Get-Command copilot\.exe'
        $source | Should -Match '\$startInfo\.FileName\s*=\s*\$script:CopilotExecutable'
    }

    It 'does not forward inherited tokens to a local non-CI child process' {
        $environment = New-CopilotChildEnvironment `
            -ReviewSource 'local' `
            -CopilotToken 'inherited-gh-token' `
            -CopilotGithubToken 'inherited-copilot-token' `
            -CiValue $null

        $environment.ContainsKey('GH_TOKEN') | Should -BeFalse
        $environment.ContainsKey('COPILOT_GITHUB_TOKEN') | Should -BeFalse
        $environment.ContainsKey('GITHUB_TOKEN') | Should -BeFalse
    }

    It 'forwards only COPILOT_GITHUB_TOKEN to a local CI child process' {
        $environment = New-CopilotChildEnvironment `
            -ReviewSource 'local' `
            -CopilotToken 'inherited-gh-token' `
            -CopilotGithubToken 'ci-copilot-token' `
            -CiValue 'true'

        $environment['COPILOT_GITHUB_TOKEN'] | Should -Be 'ci-copilot-token'
        $environment.ContainsKey('GH_TOKEN') | Should -BeFalse
    }

    It 'keeps forwarding GH_TOKEN to a PR child process' {
        $environment = New-CopilotChildEnvironment `
            -ReviewSource 'pr' `
            -CopilotToken 'pr-copilot-token' `
            -CopilotGithubToken 'inherited-copilot-token' `
            -CiValue 'true'

        $environment['GH_TOKEN'] | Should -Be 'pr-copilot-token'
        $environment.ContainsKey('COPILOT_GITHUB_TOKEN') | Should -BeFalse
    }

    It 'does not set COPILOT_GH_HOST for github.com' {
        $environment = New-CopilotChildEnvironment `
            -ReviewSource 'pr' `
            -CopilotToken 'pr-copilot-token' `
            -CopilotGithubToken $null `
            -CiValue 'true' `
            -GitHubServerUrl 'https://github.com'

        $environment.ContainsKey('COPILOT_GH_HOST') | Should -BeFalse
    }

    It 'sets COPILOT_GH_HOST for a GitHub Enterprise host' {
        $environment = New-CopilotChildEnvironment `
            -ReviewSource 'pr' `
            -CopilotToken 'pr-copilot-token' `
            -CopilotGithubToken $null `
            -CiValue 'true' `
            -GitHubServerUrl 'https://contoso.ghe.com'

        $environment['COPILOT_GH_HOST'] | Should -Be 'https://contoso.ghe.com'
        $environment['GH_TOKEN'] | Should -Be 'pr-copilot-token'
    }
}

Describe 'Test-GitHubEnterpriseHost' {
    It 'treats github.com as the default host' {
        Test-GitHubEnterpriseHost -ServerUrl 'https://github.com' | Should -BeFalse
        Test-GitHubEnterpriseHost -ServerUrl 'https://github.com/' | Should -BeFalse
        Test-GitHubEnterpriseHost -ServerUrl '' | Should -BeFalse
        Test-GitHubEnterpriseHost -ServerUrl $null | Should -BeFalse
    }

    It 'recognises GitHub Enterprise Cloud and Server hosts' {
        Test-GitHubEnterpriseHost -ServerUrl 'https://contoso.ghe.com' | Should -BeTrue
        Test-GitHubEnterpriseHost -ServerUrl 'https://github.contoso.local/' | Should -BeTrue
    }

    It 'derives the API base and git credential host from the Actions server variables' {
        $source = Get-Content -LiteralPath $scriptPath -Raw
        $source | Should -Not -Match 'https://api\.github\.com/repos'
        $source | Should -Not -Match "http\.https://github\.com/\.extraheader"
        $source | Should -Match '\$BaseUrl\s*=\s*"\$GitHubApiUrl/repos/\$Repository"'
        $source | Should -Match '\$env:GIT_CONFIG_KEY_0 = "http\.\$GitHubServerUrl/\.extraheader"'
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

Describe 'Save-ReviewArtifacts' {
    It 'persists sub-results used for knowledge and sub-skill diagnostics' {
        $ReviewOutputDir = Join-Path $TestDrive 'review-output'
        $Repository = 'microsoft/BCApps'
        $PrNumber = 1
        $BaseBranch = 'main'
        $PrHeadSha = 'abc123'
        $report = [pscustomobject]@{
            Outcome = 'completed'
            OutcomeReason = ''
            Findings = @()
            Suppressed = @()
            SubResults = @(
                [pscustomobject]@{
                    id = 'al-performance-review'
                    outcome = 'completed'
                    references = @([pscustomobject]@{ path = 'microsoft/knowledge/performance/article.md' })
                }
            )
            SkippedSubSkills = @()
        }

        Save-ReviewArtifacts -RawOutput '{}' -Report $report -ParseErrors @() -TaskContext @{} -Transcript ''

        $saved = Get-Content -LiteralPath (Join-Path $ReviewOutputDir 'al-code-review-findings.json') -Raw | ConvertFrom-Json
        $saved.subResults.Count | Should -Be 1
        $saved.subResults[0].id | Should -Be 'al-performance-review'
        $saved.subResults[0].references[0].path | Should -Be 'microsoft/knowledge/performance/article.md'
    }
}
