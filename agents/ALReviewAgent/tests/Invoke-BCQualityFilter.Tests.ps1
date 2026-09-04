param()

BeforeAll {
    $script:filterScript = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') 'Invoke-BCQualityFilter.ps1'

    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($script:filterScript, [ref]$null, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors | ForEach-Object Message | Out-String)
    }

    # The filter deletes files, so it is exercised against a throwaway clone
    # shaped like BCQuality rather than by extracting functions.
    function New-BCQualityFixture {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ("bcqfilter-" + [guid]::NewGuid().ToString('N'))
        foreach ($layer in @('microsoft', 'community')) {
            $domain = Join-Path $root (Join-Path $layer (Join-Path 'knowledge' 'ui'))
            New-Item -ItemType Directory -Path $domain -Force | Out-Null
            foreach ($ext in @('md', 'good.al', 'bad.al')) {
                Set-Content -LiteralPath (Join-Path $domain "$layer-article.$ext") -Value 'x' -NoNewline
            }
        }
        return $root
    }

    $script:onlyMicrosoft = @{
        'enabled-layers'  = @('microsoft')
        'disabled-skills' = @()
        'knowledge'       = @{ allow = @('microsoft/knowledge/**'); deny = @() }
    }
}

Describe 'Invoke-BCQualityFilter knowledge samples' {
    BeforeEach {
        $script:root = New-BCQualityFixture
        & $script:filterScript -BCQualityRoot $script:root -Config $script:onlyMicrosoft | Out-Null
    }

    AfterEach {
        Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'removes the .al samples belonging to a removed article' {
        $orphans = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'community') -Recurse -File -Filter '*.al')
        $orphans | Should -HaveCount 0
    }

    It 'keeps the .al samples of an article it kept' {
        $kept = @(Get-ChildItem -LiteralPath (Join-Path $script:root 'microsoft') -Recurse -File -Filter '*.al')
        $kept | Should -HaveCount 2
    }

    It 'reports every sample it removed' {
        $report = Get-Content -LiteralPath (Join-Path $script:root '_filter-report.json') -Raw | ConvertFrom-Json
        $samples = @($report.removed | Where-Object { $_.kind -eq 'knowledge-sample' })

        $samples | Should -HaveCount 2
        $samples | ForEach-Object { $_.reason | Should -Be 'layer-disabled' }
    }
}
