# review / publish MCP servers

Skeleton for **AB#645219** - refactor the PR-review engine into two MCP servers so
there is a single source of truth for PROD, BC-Bench (offline eval), and customers.

> Status: **additive - not wired into the live path**. The tool contracts are the
> target schema; the two handlers are per-phase **pass-throughs** that set
> `REVIEW_PHASE` and delegate to `scripts/Invoke-CopilotPRReview.ps1`, which still
> owns all logic. `.github/workflows/review.yml` is intentionally **left unchanged**
> and keeps calling `scripts/Invoke-CopilotPRReview.ps1` directly - the many
> pipelines that consume the old path must keep working untouched. These tools are a
> standalone, opt-in capability (call them directly / over MCP, e.g. via
> `../scripts/Invoke-PRReviewShell.ps1`); consumers migrate to them **one at a time**.
> Wiring PROD's `review.yml` to the tools, moving the logic into them, and BC-Bench
> consuming `review` follow in subsequent PRs, each additive.

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
| `review/Invoke-ReviewTool.ps1` | `review` handler (interim per-phase pass-through) |
| `publish/publish.tool.json` | `publish` tool contract |
| `publish/Invoke-PublishTool.ps1` | `publish` handler (interim per-phase pass-through) |
| `../scripts/Invoke-PRReviewShell.ps1` | single-process (BC-Bench/local) call site: `review(...)` then `publish(...)` |

## Target shape

```
$r = review(target, base/diff, bcquality_ref, model, min_severity)
publish($r.findings, pr, iteration_ctx)   # PROD only; BC-Bench stops after review
```

This mirrors what `review.yml` already does at the **job** level (a read-only
`review`/generate job and a write `publish`/post job calling the same script) -
this refactor will lift that boundary down to the tool level so the wiring exists
once. Until a pipeline opts in, `review.yml` keeps calling the script directly.

## Servers are PowerShell

The handlers wrap the existing PowerShell functions in
`scripts/Invoke-CopilotPRReview.ps1` (e.g. `Get-FindingSignature`,
`Resolve-SuggestionPlacement`, `Build-CommentBody`, `Post-Findings`). PROD's thin
shell and BC-Bench both call them over MCP stdio; the single wiring stays in
PowerShell - the smallest, most faithful change.
