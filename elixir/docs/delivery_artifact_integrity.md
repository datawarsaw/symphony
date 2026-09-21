# Delivery Artifact Integrity

A small deterministic helper that turns the manual delivery proof used in
recent deliveries into evidence you can generate on demand. It is a freeze
manifest plus a preflight gate — not a delivery framework, not a merge
automator, and not a new state layer.

## What it answers

    What exact artifact was accepted?          (freeze manifest)
    Has fresh main drifted?                    (preflight + drift)
    Can the accepted artifact be replayed?     (scratch cherry-pick replay)
    Is the replay artifact-equivalent?         (patch-id / paths / blobs / tree)
    Did remote main after merge contain it?    (remote-truth)

## Hard boundary

    proof tool != semantic reviewer
    proof tool != Human Acceptance
    proof tool != merge authority

The tool is an evidence generator and a deterministic stop gate only. It
never classifies semantic drift as safe: whether overlapped main changes are
`IRRELEVANT` or `SEMANTIC` is a review decision, and Human Acceptance is a
separate gate. A `PROCEED` verdict means *mechanical artifact equivalence was
proven*, nothing more.

## The freeze manifest

A plain JSON file derived entirely from git objects at freeze time. The
helper keeps no other state — no database, no hidden baseline. Every check
recomputes everything from the repository plus the manifest file you hand it.

Schema version 1:

```json
{
  "schema_version": 1,
  "generated_at": "2026-09-21T12:00:00Z",
  "repository": "<advisory: origin url or path at freeze time>",
  "artifact_kind": "single | cumulative",
  "commits": [
    {
      "candidate_sha": "<full sha>",
      "parent_sha": "<full sha or null for a root commit>",
      "commit_subject": "...",
      "tree_sha": "<full sha>",
      "changed_paths": ["lib/foo.ex"],
      "stable_patch_id": "<git patch-id --stable>",
      "path_blobs": {"lib/foo.ex": "<blob sha>", "deleted/path": null}
    }
  ],
  "cumulative": {
    "feature_sha": "...",
    "remediation_sha": "...",
    "original_parent_sha": "...",
    "ordered_patch_ids": ["...", "..."]
  }
}
```

* Single-commit artifacts carry one `commits` entry and no `cumulative` block.
* Cumulative artifacts (for example a feature commit accepted together with a
  remediation commit, as in the PARKED Recovery delivery) carry the ordered
  chain. The artifact is always proven as a whole — there is no supported way
  to prove "just the remediation" of a cumulative delivery, and freezing only
  the remediation fails its preflight because its accepted parent (the
  feature) is missing from the main it is proven against.
* Merge commits cannot be frozen.

Patch ids are computed with pinned diff settings (myers algorithm, context 3,
renames off, no colors) so the id depends only on the patch content — never
on local git config, platform, or clone.

## Commands

Run from `elixir/`. Point `--repo` at the git repository the artifact lives
in (defaults to the current directory).

```bash
# 1. Freeze what was accepted (ordered shas: feature first, remediation last)
mix symphony.delivery_preflight freeze <sha> [<sha> ...] --repo <repo> --out manifest.json

# 2. Preflight against an externally supplied fresh main
mix symphony.delivery_preflight preflight --manifest manifest.json --repo <repo> \
  --fresh-main <sha> [--replay] [--json]

# 3. Report main movement between two observations
mix symphony.delivery_preflight drift --from <old-main> --to <new-main> --repo <repo>

# 4. Prove post-merge remote truth without touching the remote
mix symphony.delivery_preflight remote-truth --manifest manifest.json \
  --final-main <sha> --repo <repo> [--scan-base <sha>] [--scan-limit N] [--json]
```

Exit codes: `0` = mechanical PROCEED, `1` = STOP or usage error. STOP is
always the safe direction.

### preflight

1. Self-check: recomputes every manifest fact from git (existence, lineage,
   subject, tree, changed paths, patch ids, blobs, cumulative chain). Any
   divergence stops — the frozen artifact can no longer be proven to be what
   was accepted.
2. Classifies the supplied `--fresh-main`:
   * `EXACT_PARENT` — main is exactly the accepted parent; replay will sit on
     the identical parent (tree proof applies).
   * `NO_OVERLAP` — main advanced, none of the artifact's paths moved.
     Mechanically replayable; semantic relevance is still a review decision.
   * `CHANGED_PATH_OVERLAP` — main moved into the artifact's surface. STOP.
   * `ALREADY_MERGED` — the accepted shas are already ancestors of main.
   * `SUPERSEDED` — equivalent patches (same stable patch ids) are already in
     main. STOP: review, do not replay.
   * `PARTIALLY_SUPERSEDED` — only some artifact patch ids are in main. STOP.
   * `MAIN_NOT_DESCENDANT` — main is behind the accepted parent or its
     history was rewritten. STOP.
3. With `--replay`, cherry-picks the accepted commits onto `--fresh-main`
   inside a scratch worktree (the only mutation the helper performs, and
   only on this explicit flag), then compares the replay against the
   manifest: stable patch ids, changed-path sets, per-path blob identity,
   and tree equality when the parent is identical. Conflicts stop with the
   conflicting paths listed. Under `CHANGED_PATH_OVERLAP` a replay runs as
   evidence only and never overturns the stop: "merged cleanly" is not
   "semantically safe".

### drift

Takes both observations explicitly every time (`--from`, `--to`) — the tool
never remembers or updates a baseline. Reports `unchanged`, `advanced (+N)`,
`rewound` (STOP), or `diverged` (STOP). Run it before replay, before push,
and after merge; each run prints the movement, and the manifest file is
never modified.

### remote-truth

Given `--final-main`:

* containment per commit — exact (sha is an ancestor) or transformed
  (accepted sha ≠ merged sha; found by stable patch id in a bounded newest-
  first scan window);
* artifact equivalence of each container (patch-id, paths, blobs);
* for cumulative artifacts, ordered lineage: the feature container must be
  an ancestor of the remediation container;
* current blob state of every artifact path on final main — informational
  ("evolved after delivery" is legitimate and not a stop).

Scan bounds: `--scan-limit` (default 2000 commits) and `--scan-base` bound
the patch-id scan window; containment by sha ancestry is exact regardless.
Scans skip merge commits, and the scan looks for patches by content
identity, so a transformed delivery must land within the scanned window.

## Transformed delivery shas

The normal case — accepted SHA ≠ delivery SHA after a cherry-pick — is
supported throughout: ancestry of the accepted sha is never required for a
transformed proof. Equivalence is proven by stable patch-id equality plus
blob/path identity at the container commit; tree equality is claimed only
when the parent is identical.

## Modules

* `SymphonyElixir.Delivery.Git` — read-only git shell-out primitives
* `SymphonyElixir.Delivery.ArtifactManifest` — manifest struct + JSON codec
* `SymphonyElixir.Delivery.Proof` — classification, comparison, drift, remote truth
* `SymphonyElixir.Delivery.Replay` — the explicit opt-in scratch cherry-pick
* `Mix.Tasks.Symphony.DeliveryPreflight` — the CLI surface
