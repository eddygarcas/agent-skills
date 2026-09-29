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
- **roundhouse**: problem with source and emitted excerpts, `### Fix`, `### Tests` (name the test file,
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
- Prove the test: it must **fail without the fix** for the right reason (not a compile error in the test
  itself) and pass with it.
- Run the full suite on the branch and on unpatched main on the same machine; report both numbers. For
  several related PRs, also merge them all onto a scratch branch and run the suite once (conflicts +
  interactions).
- If a fix lives only in a file a sibling PR also touches, say so and link it ("whichever lands second
  rebases cleanly").
- Things with no clear fix become issues, with the repro and a one-line suggestion.

## Staying current and automation

A periodic job helps on long campaigns: fetch both repos, list new commits touching the areas you depend
on (roundhouse `src/emit/ruby`, `src/ingest`, `src/lower`, `runtime/ruby`; Spinel
`tools/spinel_rbs_extract.c`, `src/analyze*.c`, `src/codegen*.c`), track your open PRs/issues for comments,
and re-run the pipeline when something moved. If you let an agent file reports on its own, gate it hard:
isolated repro, not caused by your shims, not a duplicate, clean sensitive scan, at most one issue per repo
per run, issues only (no PRs, no comments on others' threads), everything else saved as a local draft for
a human.
