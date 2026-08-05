# review / publish MCP servers

Skeleton for **AB#645219** - refactor the PR-review engine into two MCP servers so
there is a single source of truth for PROD, BC-Bench (offline eval), and customers.

> Status: **draft skeleton**. Folders, tool contracts, and stub handlers only. The
> stubs throw `NotImplementedException`; nothing here is wired into
> `.github/workflows/review.yml` or `ci.yml`. The monolithic
> `scripts/Invoke-CopilotPRReview.ps1` remains the live path and behavior is
> unchanged. Full implementation follows in subsequent PRs.

## Why split

- **`review`** (shared) - the generate half: filter BCQuality @ ref, run the model
  with the one shared prompt/skills wiring, parse findings, content-level dedup +
  cap. Returns `findings[]` + `resolved{}` provenance. Consumed identically by PROD
  and BC-Bench, so the eval scores exactly what PROD runs.
- **`publish`** (PROD only) - the post half: suggestion placement, location dedup,
  iteration numbering, comment rendering, POST.

Splitting into two servers makes "eval never posts" a **physical** guarantee -
BC-Bench simply does not load `publish` - instead of a mode flag that can be set
wrong. `bcquality_ref` is the #1 runtime input (branch / SHA / worktree / customer
layer); PROD never overrides it, keeping the `agent_version: X.Y.Z` marker honest
for Online Eval. Dedup + cap live in `review` because they change finding counts,
so offline eval must see them; placement / iteration / POST live in `publish`.

## Layout

| Path | Role |
| --- | --- |
| `review/review.tool.json` | `review` tool contract (input + output schema) |
| `review/Invoke-ReviewTool.ps1` | `review` handler (stub) |
| `publish/publish.tool.json` | `publish` tool contract |
| `publish/Invoke-PublishTool.ps1` | `publish` handler (stub) |
| `../scripts/Invoke-PRReviewShell.ps1` | target thin-shell call site: `review(...)` then `publish(...)` |

## Target shape

```
$r = review(target, base/diff, bcquality_ref, model, min_severity)
publish($r.findings, pr, iteration_ctx)   # PROD only; BC-Bench stops after review
```

This mirrors what `review.yml` already does at the **job** level (a read-only
`review`/generate job and a write `publish`/post job calling the same script) -
this refactor lifts that boundary down to the tool level so the wiring exists once.

## Servers are PowerShell

The handlers wrap the existing PowerShell functions in
`scripts/Invoke-CopilotPRReview.ps1` (e.g. `Get-FindingSignature`,
`Resolve-SuggestionPlacement`, `Build-CommentBody`, `Post-Findings`). PROD's thin
shell and BC-Bench both call them over MCP stdio; the single wiring stays in
PowerShell - the smallest, most faithful change.
