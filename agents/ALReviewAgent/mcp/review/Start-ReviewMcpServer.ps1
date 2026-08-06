<#
.SYNOPSIS
    `review` stdio MCP server - exposes the GENERATE phase over the Model
    Context Protocol so any MCP client (BC-Bench, a future PROD wiring, a
    customer harness) can call one shared review tool. AB#645219.

.DESCRIPTION
    A thin JSON-RPC 2.0 transport over stdio (newline-delimited messages, one
    JSON object per line - the MCP stdio framing). It does NOT re-implement the
    review; it advertises the `review` tool using review.tool.json as the single
    source of truth for name/description/inputSchema, and delegates execution to
    Invoke-ReviewTool.ps1 (the existing behavior-preserving generate pass-through).

    Protocol stdout is sacred: only JSON-RPC lines may be written to stdout, so
    the delegated engine run happens in a CHILD pwsh whose every stream is
    redirected to a per-call log file. Diagnostics from this server go to stderr.

    tools/call argument -> engine mapping (mirrors how PROD's runner and the
    local harness already set the environment - inputs via env, output via
    REVIEW_OUTPUT_DIR):
      local_path    -> REVIEW_SOURCE=local + REVIEW_TARGET_WORKSPACE
      base_ref      -> BASE_REF
      bcquality_ref -> -BcqualityRef   (handler param)
      model         -> -Model          (handler param)
      min_severity  -> -MinSeverity    (handler param)
      output_dir    -> -OutputDir      (handler param; default = a temp dir)
    Source/PR context for the `repo_ref` (PROD/CampAir) path stays env-driven, and
    BCQUALITY_ROOT must be provided by the caller (the runner's Fetch BCQuality
    step / the BC-Bench wiring) - exactly as the pass-through already requires.

    This is ADDITIVE and opt-in: review.yml still calls Invoke-CopilotPRReview.ps1
    directly, so the pipelines on the old path are untouched.

.OUTPUTS
    Interim: the `review` tool returns the raw agent-output.txt (the harvested
    findings the publish phase consumes) as text content. Target: the structured
    findings[] + resolved{} defined in review.tool.json, once the generate logic
    physically moves into the tool.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here             = $PSScriptRoot
$toolContractPath = Join-Path $here 'review.tool.json'
$handlerPath      = Join-Path $here 'Invoke-ReviewTool.ps1'

$contract        = Get-Content -Raw -LiteralPath $toolContractPath | ConvertFrom-Json
$protocolVersion = '2024-11-05'
$serverInfo      = [ordered]@{ name = 'bc-review'; version = '0.1.0' }

# Resolve the current PowerShell executable so the child run uses the same host.
$pwshExe = (Get-Process -Id $PID).Path

function Get-Prop {
    param($Object, [string] $Name)
    # Set-StrictMode Latest throws on missing members, so probe defensively.
    if ($null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)) { return $Object.$Name }
    return $null
}

function Write-Message {
    param($Payload)
    # Write straight to the real stdout so PowerShell stream redirection cannot
    # interleave anything with the protocol framing.
    $json = $Payload | ConvertTo-Json -Depth 40 -Compress
    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Write-Result {
    param($Id, $Result)
    Write-Message ([ordered]@{ jsonrpc = '2.0'; id = $Id; result = $Result })
}

function Write-RpcError {
    param($Id, [int] $Code, [string] $ErrorMessage)
    Write-Message ([ordered]@{ jsonrpc = '2.0'; id = $Id; error = [ordered]@{ code = $Code; message = $ErrorMessage } })
}

function Write-Diag {
    param([string] $Text)
    [Console]::Error.WriteLine("[bc-review] $Text")
}

$toolEntry = [ordered]@{
    name        = $contract.name
    description = $contract.description
    inputSchema = $contract.inputSchema
}

function Invoke-ReviewGenerate {
    param($Arguments)

    $arg = @{}
    if ($null -ne $Arguments) {
        foreach ($p in $Arguments.PSObject.Properties) { $arg[$p.Name] = $p.Value }
    }

    $outDir = if ($arg.ContainsKey('output_dir') -and $arg['output_dir']) {
        [string]$arg['output_dir']
    } else {
        Join-Path ([IO.Path]::GetTempPath()) ('bc-review-' + [Guid]::NewGuid().ToString('N'))
    }
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    # Source / PR context: set the same env vars PROD's runner and the local
    # harness set. Only touch what the caller supplied.
    if ($arg.ContainsKey('local_path') -and $arg['local_path']) {
        $env:REVIEW_SOURCE           = 'local'
        $env:REVIEW_TARGET_WORKSPACE = [string]$arg['local_path']
    }
    if ($arg.ContainsKey('base_ref') -and $arg['base_ref']) {
        $env:BASE_REF = [string]$arg['base_ref']
    }

    # Typed pass-through handler params.
    $childArgs = @('-NoProfile', '-NonInteractive', '-File', $handlerPath, '-OutputDir', $outDir)
    if ($arg.ContainsKey('bcquality_ref') -and $arg['bcquality_ref']) { $childArgs += @('-BcqualityRef', [string]$arg['bcquality_ref']) }
    if ($arg.ContainsKey('model') -and $arg['model'])                 { $childArgs += @('-Model', [string]$arg['model']) }
    if ($arg.ContainsKey('min_severity') -and $arg['min_severity'])   { $childArgs += @('-MinSeverity', [string]$arg['min_severity']) }

    $logFile = Join-Path $outDir 'mcp-generate.log'
    Write-Diag "generate -> $outDir"

    # Run in a child pwsh with ALL streams redirected to a file: the engine's
    # console output must never reach this server's protocol stdout.
    & $pwshExe @childArgs *> $logFile
    $exit = $LASTEXITCODE

    $outputFile = Join-Path $outDir 'agent-output.txt'
    if ($exit -ne 0 -or -not (Test-Path -LiteralPath $outputFile)) {
        $tail = if (Test-Path -LiteralPath $logFile) { (Get-Content -Tail 40 -LiteralPath $logFile) -join "`n" } else { '(no log captured)' }
        return [ordered]@{
            content = @([ordered]@{ type = 'text'; text = "review generate failed (exit $exit).`nLog tail:`n$tail" })
            isError = $true
        }
    }

    $findings = Get-Content -Raw -LiteralPath $outputFile
    return [ordered]@{
        content = @([ordered]@{ type = 'text'; text = $findings })
        isError = $false
    }
}

Write-Diag "review MCP server ready (protocol $protocolVersion)"

$stdin = [Console]::In
while ($null -ne ($line = $stdin.ReadLine())) {
    $line = $line.Trim()
    if (-not $line) { continue }

    try {
        $req = $line | ConvertFrom-Json
    } catch {
        Write-Diag "dropping unparseable line: $_"
        continue
    }

    $method = Get-Prop $req 'method'
    $id     = Get-Prop $req 'id'

    switch ($method) {
        'initialize' {
            Write-Result $id ([ordered]@{
                protocolVersion = $protocolVersion
                capabilities    = [ordered]@{ tools = [ordered]@{} }
                serverInfo      = $serverInfo
            })
        }
        'notifications/initialized' { }   # notification: no response
        'ping'        { Write-Result $id ([ordered]@{}) }
        'tools/list'  { Write-Result $id ([ordered]@{ tools = @($toolEntry) }) }
        'tools/call'  {
            $params = Get-Prop $req 'params'
            $name   = Get-Prop $params 'name'
            if ($name -ne $contract.name) {
                Write-RpcError $id -32602 "Unknown tool: $name"
                break
            }
            try {
                $callResult = Invoke-ReviewGenerate (Get-Prop $params 'arguments')
                Write-Result $id $callResult
            } catch {
                Write-Result $id ([ordered]@{
                    content = @([ordered]@{ type = 'text'; text = "review tool failed: $($_.Exception.Message)" })
                    isError = $true
                })
            }
        }
        'shutdown'    { Write-Result $id ([ordered]@{}) }
        'exit'        { break }
        default {
            # Requests (with an id) get a proper error; notifications are ignored.
            if ($null -ne $id) { Write-RpcError $id -32601 "Method not found: $method" }
        }
    }
}
