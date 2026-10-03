# Reporting to rubys/roundhouse and matz/spinel

Both projects fix well-evidenced reports fast (the same day, often within hours) and merge outside PRs.
Most of the campaign's progress came from here. The bar is evidence: a minimal repro that fails on current
`main`/`master`, and — for PRs — a regression test that fails without the fix.

## Data safety first (private apps)

A private app must never leak into a public report.
1. Write **fresh generic fixtures** (Widget, Report, Search, Order). Don't copy app code, and don't reuse
   app class or method names even when they look generic — a reused base-class name slipped into one
   merged fixture before the scanner existed.
2. Build a denylist from the app and scan everything before posting:
   ```sh
   ruby scripts/build_denylist.rb /path/to/app companyname productname vendor1 > denylist.txt
   ruby scripts/sensitive_scan.rb --denylist denylist.txt <draft-dir> <pr-body.md> <test files>
   ```
   Tune the generic allowlist inside `build_denylist.rb` for your domain; test that the scan *catches* a
   real app file.
3. Neutral footer only: "Found while compiling a Rails API app with `--target spinel`." No stack details,
   file counts, gem lists or company names. Remember the author's GitHub profile may already name the
   company, so the content is the only thing you control.
4. Commit with a personal identity (`git config user.email` in the clone), not a company address.

## From failure to repro

1. Reproduce on **fresh upstream** (rebuild both tools); check the commit log and `gh search issues` for an
   existing report or fix.
2. Reduce: Spinel bugs → a standalone `.rb` (+ `.rbs` when seeds matter) that works on CRuby; roundhouse
   bugs → a minimal Rails fixture (`app/`, `config/routes.rb`, `db/schema.rb`) whose emit fails to parse,
   build, or answer correctly.
3. Run each variant in its own empty directory (`--rbs DIR` reads every `.rbs`).
4. Confirm the repro does not depend on any post-emit shim. If it only fails inside the full app, it is not
   ready to report.
5. For performance bugs, measure a scalable generator (e.g. N = 16/20/24) on master vs. patched, and check
   the output against CRuby.

## House style

- **Title**: a behavior sentence — what happens, not "bug in X" ("A leading `/` in a route target or a
  partial path means the top level").
- **Check the project's docs first.** roundhouse `docs/rails-coverage.md`, `docs/runtime.md` (its
  "Deliberate divergences from Rails" ledger) and `docs/guide/` say what is intended. Don't file intended
  behaviour as a bug; when the docs claim support that the code doesn't deliver, quote the doc line — it is the
  strongest evidence you can give. Classify a divergence before filing (masked value, deliberate divergence,
  or translation bug — roundhouse `docs/verifying.md`).
- **roundhouse**: open with `roundhouse --version` (its docs ask for it first); problem with source and emitted excerpts, `### Fix`, `### Tests` (name the test file,
  say it fails without the change, give suite numbers vs `main`), then the footer.
- **Spinel**: open with `Probed at master <sha>, <OS>, <compiler>`; CRuby-vs-Spinel table for behavioral
  bugs; `## Cause` / `## Change` / `## Tests` for fixes; exact error text in code blocks.
- Don't present speculation as fact — say "I read that rather than measured it" where true.

## PRs

- One PR per fix, one commit, a short branch name, rebased on the current main/master. Split a combined
  patch into per-issue hunks (a small hunk-extractor script helps), apply each on a fresh branch, and
  commit **before** switching branches.
- Add a regression test in the project's own harness:
  - roundhouse: `tests/<name>.rs` — ingest an in-memory app (`ingest_app_from_tree`), `analyze_and_lower`,
    `project::target_files(.., BuildTarget::Spinel)`, assert on the emitted text; parse emitted Ruby with
    `ruby_prism::parse(...).errors()`. No `#[allow(dead_code)]` on helpers that are used.
  - Spinel: `test/<name>.rb` + `.rb.expected` (stdout) for the corpus; `test/rbs/<name>.rbs` +
    `.seed.expected` golden for the RBS extractor.
  - Prefer tests that **run** the emitted code over text assertions where it is cheap: CRuby emit-and-run
    tests, Spinel-compiled tests, or `#[ignore]`d gate tests selected by a name prefix in a CI lane (passing
    tests named `<lane>_gate_…`, known failures named after their issue so the filter skips them).
  - roundhouse runtime changes: land the runtime method and its emitter change in the same commit; keep
    every runtime method fully typed (its `.rbs` sidecar, checked by `every_runtime_method_body_is_fully_typed`)
    with a test under `runtime/ruby/test/`; record any chosen divergence from Rails in `docs/runtime.md`'s
    ledger in the same PR; list a new `ROUNDHOUSE_*` variable in `docs/env-gates.md`.
- Prove the test: it must **fail without the fix** for the right reason (not a compile error in the test
  itself) and pass with it.
- Run the full suite on the branch and on unpatched main on the same machine; report both numbers. For
  several related PRs, also merge them all onto a scratch branch and run the suite once (conflicts +
  interactions).
- If a fix lives only in a file a sibling PR also touches, say so and link it ("whichever lands second
  rebases cleanly").
- Things with no clear fix become issues, with the repro and a one-line suggestion.
- **After opening:** bots review too (roundhouse runs CodeRabbit). Verify each finding against the code and
  real Ruby before acting — most are right, some aren't. Fix the valid ones in the same commit and reply on the
  thread with the test name; for a finding that is a separate improvement, reply that it is left for a follow-up
  rather than growing the PR. Maintainers sometimes rebase your branch themselves: fetch before pushing and use
  `--force-with-lease`, so you never overwrite a newer head. Don't merge your own PR in someone else's project
  just because you have the rights — the maintainer who asked for changes usually merges.
- **roundhouse CI is selective.** A PR runs the jobs its paths select (`scripts/ci-plan.py`); Spinel lanes are
  advisory and don't run by default for analyzer or lowerer changes, and draft PRs run fixture + unit tests
  only. Fork contributors can't apply labels: open the PR ready for review, say in the body which Spinel
  checks you ran locally, and ask a maintainer for `ci:full` when a Spinel lane matters. Run the unit batch
  locally with `scripts/ci-unit-tests.py` and read the whole log (a later batch can fail to compile after
  earlier batches passed).
- **CI failures that aren't yours:** if every job fails the same way, read one log. A broken `main` at the time
  CI ran shows up as one compile error in a file you didn't touch; check `main`'s own CI at that commit, then
  rebase onto the fixed `main`.

## Issue or PR?

Open a **PR** only when all of these hold: the fix is small and in one place with a single right answer; a
regression test proves it (fails on main for the right reason, passes with the fix); the full suite shows
nothing else moved; and it needs no design decision only the maintainers should make (if one comes up, decide
it by matching Ruby's behaviour and explain why in the thread). Open an **issue** instead when the fix touches
design or a wide area (a new gem's runtime support, a whole dialect), when the cause is deep in the other
project's internals (most of Spinel's codegen — Matz fixes clean repros within hours, and Spinel PRs now need
`make gate` output), when the behaviour may be intended (ask, don't patch), when a maintainer has said they
prefer to make that kind of change themselves, or when you can reproduce it but haven't found the cause. For
a structural addition (a new fixture app, a new CI lane), propose it in an issue and offer the PR.

## Long-term contributions

Once the app builds, the post-emit script is a list of upstream gaps. Work it down:
1. **Turn workarounds into fixes.** For each post-emit section, decide issue or PR by the rules above; when the
   fix lands, delete the section (its comment should already say which issue it waits for).
2. **File what you only noted.** Shapes you worked around during triage need their own generic fixture before
   filing; check them against current `main` first — some are fixed already.
3. **Help with the big gaps** (e.g. a Postgres lane) by researching the pieces and offering one in the
   maintainers' thread — generic, no stack details — before writing code.
4. **Leave regression coverage behind.** Check which of the fixed shapes the project's tests already cover and
   propose a small generic fixture app (API-only, UUID keys, concerns, keyword helpers, pagination, token auth)
   for its CI, so the fixes stay fixed after you stop watching.

## Staying current and automation

A periodic job helps on long campaigns: fetch both repos, list new commits touching the areas you depend
on (roundhouse `src/emit/ruby`, `src/ingest`, `src/lower`, `runtime/ruby`; Spinel
`tools/spinel_rbs_extract.c`, `src/analyze*.c`, `src/codegen*.c`), track your open PRs/issues for comments,
and re-run the pipeline when something moved. If you let an agent file reports on its own, gate it hard:
isolated repro, not caused by your shims, not a duplicate, clean sensitive scan, at most one issue per repo
per run, issues only (no PRs, no comments on others' threads), everything else saved as a local draft for
a human.

Lessons from running such a job for days:
- **Every 2 hours is enough.** A pipeline run takes 25–35 minutes (longer when it reduces a failure); hourly
  runs overlap and the second one just hits the lock.
- **Compare by error key, not by count**, and against the last *real* build: a run that stopped at a refusal
  reports 0 C errors, which is not an improvement. Strip tree paths and counts from the keys before diffing.
- **New items are invisible to a baseline-diff script on their first run.** Check recently filed items directly
  (`gh search issues --author <you> --sort updated`).
- **Upstream can add a hard stop** (a new refusal class, a feature gate that rejects the app). Decide per case:
  pin the tool to the commit before it (cheapest, records why and how to unpin), add a pre-emit rewrite, or wait
  for upstream. When a tool's new refusal is intended behaviour — e.g. refusing at compile time what used to
  raise at run time — keep the old run-time behaviour with stubs that compile and raise, rather than inventing
  implementations.
- **Bail out early on hangs.** If the build is still in type inference after ~10 minutes, sample the fixpoint
  round counter under gdb; a climb to the cap means a non-converging inference, not a slow build — kill it so
  the run records a failure, then attribute it (old tree + new compiler).
- **Clean up after every run:** the kept C file (`/tmp/spinel_out_*.c`, 80–100 MB), started servers and wait
  loops. `pgrep -f <pattern>` matches your own shell's command line; match the process name (`pgrep -x`).
- **The job is session-scoped.** Write down how to recreate it (schedule, prompt, pin) where the next session
  will look.
