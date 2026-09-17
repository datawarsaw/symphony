# Validation

For normal validation (run from `elixir/`):

    mix symphony.validate

For full validation (adds `specs.check` + `credo --strict`):

    mix symphony.validate --full

Standard gates: `mix compile --warnings-as-errors`, `mix format
--check-formatted`, `git diff --check`, and `mix test`. Every gate runs; any
failing gate produces a non-zero exit. The script captures each gate's exit
status itself, so its own result cannot be lost — but the shell can still
mask it if you filter carelessly.

Windows notes:

- The repository `.gitattributes` is authoritative for line endings; do not
  rely on `core.autocrlf`. Fresh checkouts present all text files as LF, and
  `mix format --check-formatted` is reliable without workarounds.
- Existing worktrees created before the policy still have CRLF on disk. To
  convert one (and to clear the transient stat-only "modified" flood that an
  in-place conversion produces), run from the repository root:
  `git ls-files -z | xargs -0 rm -f && git checkout-index -f -a && git read-tree HEAD`.
  Fresh clones need nothing.
- Do not use `command | tail` as a pass/fail gate: the pipeline reports the
  filter's exit status, not the command's (`false | tail` succeeds). If you
  must filter, `set -o pipefail` first (Git Bash) or redirect to a file and
  check `$?`.

`make coverage` (aspirational 100% threshold) and `make dialyzer` remain
separate targets and are not part of this gate set.
