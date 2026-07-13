#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

# Unit tests for the pure, side-effect-free helpers in Invoke-CopilotPRReview.ps1.
# The script is an orchestrator with top-level executable code, so instead of
# dot-sourcing it (which would run the whole thing) we AST-extract just the
# functions under test and load those into the test scope.

BeforeAll {
    $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\agent\scripts\Invoke-CopilotPRReview.ps1')).Path
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$null)

    $wanted = @(
        'ConvertTo-LooseLine'
        'Test-OrderedSubsequence'
        'Resolve-SuggestionPlacement'
        'Test-GlobMatch'
        'Test-NearDuplicateLocation'
        'Get-FindingSignature'
    )
    $funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    foreach ($f in $funcs) {
        if ($wanted -contains $f.Name) { . ([scriptblock]::Create($f.Extent.Text)) }
    }

    function New-Finding {
        param([string] $Domain, [string] $Issue, [string] $Recommendation, [string] $FilePath = 'App/Foo.al', [int] $LineNumber = 1)
        [pscustomobject]@{ domain = $Domain; issue = $Issue; recommendation = $Recommendation; filePath = $FilePath; lineNumber = $LineNumber }
    }

    function New-Location {
        param([string] $Path, [int] $Line, [string] $Side = 'RIGHT')
        [pscustomobject]@{ path = $Path; line = $Line; side = $Side }
    }
}

Describe 'Get-FindingSignature' {
    It 'ignores whitespace differences' {
        $a = New-Finding -Domain 'Perf' -Issue 'Nested loop over records' -Recommendation 'Use SetLoadFields'
        $b = New-Finding -Domain 'Perf' -Issue "Nested   loop`tover  records" -Recommendation 'Use  SetLoadFields'
        (Get-FindingSignature $a) | Should -Be (Get-FindingSignature $b)
    }

    It 'ignores case' {
        $a = New-Finding -Domain 'Perf' -Issue 'Nested loop' -Recommendation 'Use SetLoadFields'
        $b = New-Finding -Domain 'PERF' -Issue 'NESTED LOOP' -Recommendation 'use setloadfields'
        (Get-FindingSignature $a) | Should -Be (Get-FindingSignature $b)
    }

    It 'is location-independent (same code in regional copies collapses)' {
        $w1 = New-Finding -Domain 'Perf' -Issue 'Nested loop' -Recommendation 'Use SetLoadFields' -FilePath 'App/W1/Foo.al' -LineNumber 10
        $us = New-Finding -Domain 'Perf' -Issue 'Nested loop' -Recommendation 'Use SetLoadFields' -FilePath 'App/US/Foo.al' -LineNumber 250
        (Get-FindingSignature $w1) | Should -Be (Get-FindingSignature $us)
    }

    It 'differs when the domain differs' {
        $a = New-Finding -Domain 'Perf' -Issue 'X' -Recommendation 'Y'
        $b = New-Finding -Domain 'Security' -Issue 'X' -Recommendation 'Y'
        (Get-FindingSignature $a) | Should -Not -Be (Get-FindingSignature $b)
    }

    It 'differs when the issue differs' {
        $a = New-Finding -Domain 'Perf' -Issue 'Nested loop' -Recommendation 'Y'
        $b = New-Finding -Domain 'Perf' -Issue 'Missing index' -Recommendation 'Y'
        (Get-FindingSignature $a) | Should -Not -Be (Get-FindingSignature $b)
    }

    It 'differs when the recommendation differs' {
        $a = New-Finding -Domain 'Perf' -Issue 'X' -Recommendation 'Use SetLoadFields'
        $b = New-Finding -Domain 'Perf' -Issue 'X' -Recommendation 'Add a key'
        (Get-FindingSignature $a) | Should -Not -Be (Get-FindingSignature $b)
    }
}

Describe 'ConvertTo-LooseLine' {
    It 'strips all whitespace' {
        ConvertTo-LooseLine "  exit (X) ;`t" | Should -Be 'exit(X);'
    }

    It 'returns empty string for null' {
        ConvertTo-LooseLine $null | Should -Be ''
    }
}

Describe 'Test-OrderedSubsequence' {
    It 'is true when the suggestion is the span with an inserted line' {
        $span = @('begin', 'x := 1;', 'end;')
        $sug  = @('begin', 'x := 1;', 'y := 2;', 'end;')
        Test-OrderedSubsequence -FileSpan $span -Suggestion $sug | Should -BeTrue
    }

    It 'is whitespace-insensitive' {
        $span = @('exit (X)')
        $sug  = @('exit(X)')
        Test-OrderedSubsequence -FileSpan $span -Suggestion $sug | Should -BeTrue
    }

    It 'is false when a span line is missing from the suggestion' {
        $span = @('begin', 'x := 1;', 'end;')
        $sug  = @('begin', 'end;')
        Test-OrderedSubsequence -FileSpan $span -Suggestion $sug | Should -BeFalse
    }
}

Describe 'Resolve-SuggestionPlacement' {
    It 'snaps a single-line suggestion onto the matching anchor' {
        $file = @('aaa', 'bbb', 'ccc')
        $r = Resolve-SuggestionPlacement -FileLines $file -AnchorLine 2 -SuggestedLines @('bbb')
        $r.startLine | Should -Be 2
        $r.endLine   | Should -Be 2
    }

    It 'trusts the anchor for a single-line suggestion with no content match' {
        $file = @('aaa', 'bbb', 'ccc')
        $r = Resolve-SuggestionPlacement -FileLines $file -AnchorLine 2 -SuggestedLines @('zzz')
        $r.startLine | Should -Be 2
        $r.endLine   | Should -Be 2
    }

    It 'places a multi-line additive suggestion over the full original span' {
        $file = @('procedure Foo()', 'begin', '    x := 1;', 'end;')
        $sug  = @('procedure Foo()', 'begin', '    x := 1;', '    y := 2;', 'end;')
        $r = Resolve-SuggestionPlacement -FileLines $file -AnchorLine 1 -SuggestedLines $sug
        $r.startLine | Should -Be 1
        $r.endLine   | Should -Be 4
    }

    It 'returns null for an unrelated rewrite that cannot be anchored' {
        $file = @('procedure Foo()', 'begin', '    x := 1;', 'end;')
        $sug  = @('procedure Bar()', '    return;')
        Resolve-SuggestionPlacement -FileLines $file -AnchorLine 1 -SuggestedLines $sug | Should -BeNullOrEmpty
    }
}

Describe 'Test-GlobMatch' {
    It 'matches a trailing ** against files in the folder' {
        Test-GlobMatch -Filename 'src/foo.al' -Pattern 'src/**' | Should -BeTrue
    }

    It 'matches **/*.al against nested files' {
        Test-GlobMatch -Filename 'src/app/Foo.al' -Pattern '**/*.al' | Should -BeTrue
    }

    It 'does not match outside the pattern' {
        Test-GlobMatch -Filename 'test/foo.al' -Pattern 'src/**' | Should -BeFalse
    }
}

Describe 'Test-NearDuplicateLocation' {
    It 'is true within the tolerance on the same path and side' {
        $locs = [System.Collections.Generic.List[object]]::new()
        $locs.Add((New-Location -Path 'App/Foo.al' -Line 100)) | Out-Null
        Test-NearDuplicateLocation -ExistingLocations $locs -Path 'App/Foo.al' -Line 101 -Side 'RIGHT' | Should -BeTrue
    }

    It 'is false beyond the tolerance' {
        $locs = [System.Collections.Generic.List[object]]::new()
        $locs.Add((New-Location -Path 'App/Foo.al' -Line 100)) | Out-Null
        Test-NearDuplicateLocation -ExistingLocations $locs -Path 'App/Foo.al' -Line 110 -Side 'RIGHT' | Should -BeFalse
    }

    It 'is false for a different path' {
        $locs = [System.Collections.Generic.List[object]]::new()
        $locs.Add((New-Location -Path 'App/Foo.al' -Line 100)) | Out-Null
        Test-NearDuplicateLocation -ExistingLocations $locs -Path 'App/Bar.al' -Line 100 -Side 'RIGHT' | Should -BeFalse
    }

    It 'is false for an empty location list' {
        $locs = [System.Collections.Generic.List[object]]::new()
        Test-NearDuplicateLocation -ExistingLocations $locs -Path 'App/Foo.al' -Line 100 -Side 'RIGHT' | Should -BeFalse
    }
}
