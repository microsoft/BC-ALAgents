# Running the review engine locally (`Invoke-LocalReview.ps1`)

`Invoke-LocalReview.ps1` is the single entry point for running the **production
BC AL review agent** against a local git worktree and getting its findings back
as JSON. It is the seam any harness (e.g. BC-Bench's engine arm) should call:
give it a worktree + a BCQuality checkout, it runs the exact production reviewer
(`Invoke-CopilotPRReview.ps1`) in local mode and writes a findings report.

Script: `agents/ALReviewAgent/scripts/Invoke-LocalReview.ps1`

## Prerequisites

- PowerShell 7+ (`pwsh`).
- Node 24 + the Copilot CLI on `PATH`: `npm i -g @github/copilot`.
- `gh auth login` **or** `GH_TOKEN` in the environment (used to authenticate the
  Copilot CLI). Note `GH_TOKEN` is terminal-scoped — a fresh `pwsh -NoProfile`
  child process does not inherit it, so set it explicitly in the process you
  launch the script from.
- A **BCQuality checkout** (`https://github.com/microsoft/BCQuality`). The script
  does **not** clone BCQuality for you — see the note under `-BCQualityRoot`.
- `Install-Module powershell-yaml`.

## Input contract (parameters)

| Parameter | Required | Meaning |
| --- | --- | --- |
| `-RepoPath` | **yes** | Path to the git worktree to review. Its **HEAD** is what gets reviewed. |
| `-BCQualityRoot` | **yes** | Path to a BCQuality checkout. The script **filters this checkout in place** (destructive) and reads skills/knowledge from it — it never clones BCQuality. Point it at a throwaway copy, or pass `-SkipBCQualityFilter` if it is already filtered / you want the full skill set. |
| `-Mode` | no | `Branch` (default) reviews committed + staged changes vs `-BaseRef`. `Existing` reviews the whole tree at HEAD (diff vs the empty tree). |
| `-BaseRef` | no | `Branch` mode only. The base commit/ref to diff against. Defaults to the upstream merge-base of HEAD, falling back to `main`. Pass an explicit SHA from a harness. |
| `-ConfigPath` | no | Path to a `bcquality.config.yaml`. Defaults to `agents/ALReviewAgent/bcquality.config.yaml` in this engine repo (pins the BCQuality content version). |
| `-OutputDir` | no | Where the report + transcript + metrics land. Defaults to `<RepoPath>/.bc-review`. |
| `-MinimumSeverity` | no | `Critical` \| `High` \| `Medium` \| `Low`. Default `Medium`. Floor applied to knowledge-backed findings. |
| `-Model` | no | Copilot model override (`COPILOT_MODEL`). |
| `-LeafModel` | no | Cheaper/faster model for the leaf sub-skill child agents. |
| `-Path` | no | Scope the reviewed diff + findings to a folder or glob, relative to `-RepoPath`. |
| `-Fix` | no | After review, run a second Copilot pass that applies the findings to `-RepoPath` (working-tree edits only, no commit). |
| `-SkipBCQualityFilter` | no | Skip the destructive pre-filter of `-BCQualityRoot`. |
| `-NoPruneDomains` | no | Run every review domain instead of skipping feature-gated domains with zero signal. |
| `-NoParallelLeaves` | no | Run leaf sub-skills serially instead of as parallel child agents. |

### Example — invoke from a harness, just get the JSON

```powershell
$env:GH_TOKEN = (gh auth token)

$out = 'C:\temp\review-run-42'
pwsh -NoProfile -File .\agents\ALReviewAgent\scripts\Invoke-LocalReview.ps1 `
    -RepoPath      C:\repo\MyBCApp `
    -BaseRef       a417c1610375486a8350158e9078ec0320378343 `
    -BCQualityRoot C:\repo\BCQuality `
    -OutputDir     $out `
    -MinimumSeverity Low

$report = Get-Content "$out\_review-report.json" -Raw | ConvertFrom-Json
$report.findings | Format-Table @{n='file';e={$_.location.file}}, @{n='line';e={$_.location.line}}, severity, @{n='skill';e={$_.'from-sub-skill'}}
```

## Output contract

The reviewer writes **`<OutputDir>/_review-report.json`** — the raw agent JSON,
per the BCQuality `skills/do.md` DO output contract. A run-metrics summary is
written alongside it at `<OutputDir>/_run-metrics.json` (wall time, token usage,
estimated credits).

`_review-report.json` is an envelope, not a bare array — consumers read the
top-level **`findings`** array (see
[`sample-review-report.json`](./sample-review-report.json) for a full example):

```jsonc
{
  "skill":   { "id": "al-code-review", "version": 1 },
  "outcome": "completed",             // completed | not-applicable | no-knowledge | partial | failed
  "summary": {
    "counts":   { "blocker": 0, "major": 1, "minor": 1, "info": 0 },
    "coverage": { "worklist-size": 2, "items-evaluated": 2 }
  },
  "findings": [
    {
      "id":       "microsoft/knowledge/performance/avoid-findset-inside-loop.md",
      "severity": "major",            // blocker | major | minor | info
      "message":  "...Recommendation: ...",
      "location": {
        "file": "src/Sales/SalesLine.Table.al",   // repo-relative, forward slashes
        "line": 142,
        "range": { "start-line": 140, "end-line": 145 }   // optional
      },
      "references": [                 // knowledge-backed: BCQuality article(s)
        { "path": "microsoft/knowledge/performance/avoid-findset-inside-loop.md" }
      ],
      "confidence":     "high",       // high | medium | low
      "from-sub-skill": "al-performance-review"
    }
  ],
  "suppressed": [],                   // findings the agent raised then suppressed
  "sub-results": [],                  // per-leaf raw reports
  "skipped-sub-skills": []
}
```

Field notes for consumers:

- **Read `findings` off the top-level envelope.** The file also carries
  `skill`, `outcome`, `summary`, `suppressed`, `sub-results`, and
  `skipped-sub-skills`; a consumer that only scores findings just takes
  `.findings`. An `outcome` of `completed` with an empty `findings` array means
  "ran, found nothing" — not an error.
- **Location** is nested: `location.file` (repo-relative, forward slashes) and
  `location.line` (plus optional `location.range`). There is no flat
  `filePath` / `lineNumber`.
- **`severity`** uses the DO vocabulary `blocker | major | minor | info`. Map to
  your own scale if needed (e.g. `blocker->critical, major->high, minor->low,
  info->low`).
- **`id`** — for a knowledge-backed finding the `id` **equals**
  `references[0].path` (the primary article). For an agent finding it is a slug
  prefixed with `agent:`.
- **`message`** is a single string. Skills conventionally split guidance with a
  `Recommendation:` or `Fix:` marker, but that is best-effort, not guaranteed.
- **`references`** is non-empty for knowledge-backed findings (each entry is a
  BCQuality article `{ "path": ... }`; a `sha` may also appear but the engine
  currently emits `path` only). An **agent finding** — the reviewer's own
  judgement, not backed by an article — has `references: []` and an `id` that
  starts with `agent:`. `from-sub-skill` is present on *every* finding (the
  producing leaf skill's id, e.g. `al-performance-review`) and is the literal
  string `"agent"` only for an agent finding the super-skill produced itself, so
  use empty `references` + the `agent:` id prefix as the reliable agent-finding
  markers.
- There is **no `domain`** field. Derive a domain from `from-sub-skill` if you
  need one.
- Additional optional fields you may see: `suggested-code`,
  `suggested-code-omission-reason`.

If the agent produced no report file, the run fails loudly rather than emitting
an empty report — treat a missing `_review-report.json` as an error, not "zero
findings".
