---
name: rails-spinel-native-binary
description: >
  Compile a Ruby on Rails app (especially a Rails API) into a single native binary with roundhouse
  (`roundhouse --target spinel`) and the Spinel AOT compiler, then seed and run it locally. Covers building
  both toolchains from source, transpiling, a re-runnable post-emit patch script, the `spin build`
  refusal/C-error loop, running the binary, and turning the bugs you hit into clean upstream issues and PRs
  for rubys/roundhouse and matz/spinel. Use this whenever the user mentions roundhouse, Spinel, `spin build`,
  compiling/transpiling Rails or Ruby to a native binary or C, running a Rails app "as a binary", AOT Ruby,
  or asks why a roundhouse/spinel build fails — even if they only paste a spinel error or a roundhouse survey.
---

# Rails → roundhouse → Spinel → native binary

roundhouse reads a Rails app without booting it and emits a metaprogramming-free "Ruby shape" of it;
with `--target spinel` that tree is a `spin` project that Spinel compiles ahead of time to C and then to one
executable. Both projects move fast (dozens of commits a day) and are proven on real apps (Campfire,
Lobsters), but a large, gem-heavy production app will hit gaps. Treat the work as an **iterative campaign**:
each round fixes a class of failures, some fixes belong in your app-side patch script, and the rest are
upstream bugs worth reporting — which is often what moves you forward most.

Set expectations with the user early, because they change what "done" means:

- **SQLite only.** Every target serves `storage/development.sqlite3`. Postgres types are mapped to SQLite
  storage; `tsvector`/`vector` columns are dropped; hand-written SQL (`ILIKE`, `->>`, `@>`, `<=>`) survives
  verbatim and fails at run time. A Postgres app becomes a local, throwaway-data binary — useful for API
  testing and benchmarking, not a drop-in replacement (roundhouse issue #91 tracks a Postgres lane).
- **Not everything compiles.** `eval`, `method_missing` dispatch, `send`/`const_get` with runtime names,
  `define_method` loops, `ObjectSpace`, `binding`, runtime `extend` are unsupported by design. Unmodeled
  gems (Devise, Doorkeeper, Sidekiq, pg_search…) need facades. Those paths get stubbed, so the endpoints that
  use them will not work in the binary.
- **No `Date` on the Spinel target.** roundhouse rejects any Date (a `t.date` column, a `Date` constant, a
  Date-typed value or signature) at the project boundary for `spinel`, even with `--allow-unsupported`. Its
  docs call this an intended support boundary, not a bug: plan for it (wait for Date support, or rewrite Date
  in a pre-emit copy of the app) rather than waiting for an issue to be fixed.
- **It is slow to iterate.** A full-app `spin build` of a mid-size API takes 8–16 minutes. Batch fixes.

## 0. Before starting

Ask (or infer) three things, since they decide how far to push:
1. Which endpoints must work in the binary? (Stubbing lets you compile past code the user doesn't need —
   but never stub the code paths they want to test, e.g. tenant resolution or auth.)
2. May we report bugs upstream? If yes, **nothing from a private app may be published** — see
   `references/upstream-reporting.md` (fresh generic fixtures, a denylist scan, personal commit identity).
3. Where should work live? Use a dedicated branch (e.g. `experiment/native-binary`) and keep the emitted
   tree in a gitignored `out/`.

## 1. Toolchain

Build both from source; the release binaries lag behind fixes you will need. Details, versions and
gotchas: `references/toolchain.md`. Short form:

```sh
# roundhouse (Rust ≥ 1.89, clang + libclang)
git clone https://github.com/rubys/roundhouse ~/.local/src/roundhouse && cd $_
cargo build --release && cp target/release/roundhouse ~/.local/bin/   # all bins: roundhouse-ast, dump_ir too
# Spinel + spin (C toolchain, sqlite3 + jemalloc dev headers; libvips only for image variants)
git clone https://github.com/matz/spinel ~/.local/src/spinel && cd $_
make deps && make -j"$(nproc)" && make install PREFIX=$HOME/.local
```

Re-pull and rebuild both at the start of every session: upstream fixes are the cheapest progress you get.

**Read roundhouse's own `docs/` before treating a gap as a bug.** `docs/guide/rails-coverage.md` lists what is and
isn't modelled (Devise/Doorkeeper route DSLs and engine mounts are dropped by design), `docs/pipeline/runtime.md` keeps a
ledger of deliberate divergences from Rails (e.g. a plain `has_many` reader answers an Array; a new record's
id is `0`/`""`, not `nil`), and `docs/guide/` documents the support boundaries. Something documented as
intended is a post-emit item, not a report; something the docs say is supported but misbehaves is a strong
report — quote the doc line.

## 2. Transpile and gate the emit

```sh
roundhouse check --continue .                     # optional: analysis report, gem census, survey of gaps
rm -rf out/spinel                                 # a re-emit does not remove files a previous run left
roundhouse --target spinel --survey --allow-unsupported -o out/spinel .
scripts/check_parse.sh out/spinel                  # every emitted file must parse
sqlite3 /tmp/t.db < out/spinel/db/seed.sql         # the seed must load
grep -n '^\[dependencies\]' out/spinel/spin.toml   # present if any package (bcrypt/rqrcode/vips) is used
```

Read the survey (`── Survey: N ingest gap(s)`) — it lists every construct roundhouse skipped. Unparseable
files, a seed that won't load, or a missing manifest header are **roundhouse emit bugs**: note the shape,
make a minimal fixture, and report it (they are usually quick to fix upstream). Check also: an app with no
view templates, or no `root` route, has failed to build in the past.

## 3. The post-emit script (app side)

Everything you change in the emitted tree goes into **one re-runnable script** applied to a *fresh* emit:
`post-emit.sh out/spinel`. Never hand-edit the tree without recording the edit in the script — you will
re-emit dozens of times (new upstream versions, new app code), and an unrecorded edit is lost work.
Keep sections numbered and commented with *why* each exists, so you can delete them when upstream catches
up. Rewrites that span expressions should use Prism (`scripts/neutralize_calls.rb` shows the pattern), not
regexes.

The catalogue of rewrites that were needed for a real Rails API — dynamic dispatch stubs, gem facades,
generated I18n table, Devise/Rails surface, API-only base controller, connector modules, Time helpers,
RBS sidecar loosening, ActsAsTenant, ActiveStorage UUID ids — with the reason for each:
`references/post-emit-catalog.md`. Start from it, but derive your app's list from evidence:

- `ruby scripts/undefined_constants.rb out/spinel` — gem constants nothing in the tree defines.
- `ruby scripts/locale_table.rb .` — flattens `config/locales` into a table for an I18n facade.

## 4. The build loop

```sh
cd out/spinel && CC=clang spin build > ../spin-build.log 2>&1; cd -   # spin honours CC; clang ≈ 2× gcc here
scripts/classify_errors.sh out/spin-build.log "$PWD/out/spinel"
```

Spinel fails in stages, and each stage wants a different response (full table in
`references/error-triage.md`):

1. **Early refusals, one at a time** — `cannot load such file`, RBS sidecar parse errors, `--rbs seed
   contradicted`, `param has unsupported type nil`, `const_get with a name known only at run time`,
   `unsupported send with a runtime method name`. Fix and rebuild; each costs a few minutes.
2. **Whole-program refusals, in a batch** — `undefined method … for a Class`, `unsupported call`,
   `unsupported condition (non-bool)`, `a Range of Time objects cannot be built`. Group by kind; most are a
   handful of shapes repeated across many files.
3. **C compile errors** (`spinel: C compilation failed`) — Spinel accepted the program but emitted C that
   does not type-check. By Spinel's own contract that is a Spinel bug, but it is usually triggered by a union
   type the analyzer could not settle (`a && a.b || c`, an Object-level method on a typed receiver, a poly
   value into a `const char *` slot). Classify by kind and by Ruby line; fix the biggest cluster first.

Iterate with discipline: after each build, record refusal and C-error counts, compare with the previous
run, and stop to reassess when progress stalls or when the remaining failures sit in code the user needs.

If a build **hangs** (CPU at 100 %, memory flat), don't wait it out: interrupt it under gdb *as the parent
process* (Linux `ptrace_scope=1` forbids attaching to a sibling) and read the backtrace — that is how an
exponential analyzer walk was found and fixed upstream. See `references/error-triage.md`.

## 5. Run the binary

```sh
cd out/spinel
sqlite3 storage/development.sqlite3 < db/seed.sql     # plus your own seed data
SECRET_KEY_BASE=local-secret PORT=3000 ./build/bin/blog
curl -i localhost:3000/<endpoint>
```

The runtime's encrypted credentials are empty by design; anything read from `Rails.application.credentials`
must come from the environment or be patched to `Rails.application.secret_key_base`. Seed any API keys or
fixtures with the same secret the binary runs with. Compare responses with the Rails app for the endpoints
that matter.

## 6. Report what upstream should fix

Most of the forward progress in practice came from upstream fixes — both projects merge well-evidenced
issues and PRs within hours. The method (isolate → minimal repro → verify it fails on current main/master
and passes on CRuby → dedupe → data-safety scan → file in house style, one PR per fix with a regression
test that fails without the fix): `references/upstream-reporting.md`. It also covers when to open an issue
rather than a PR, how to handle bot and maintainer review, and what to do once the app builds — turning each
post-emit workaround into an upstream fix and leaving regression fixtures behind.

## 7. After the binary builds

A build is not a working app. Smoke-test the endpoints the user cares about (seed first, then start the binary
and `curl` them) and expect a second round: views that lower to `{}`, unmodeled gems (pagination,
auth helpers), id types the runtime assumes are Integer. Fix those the same way — post-emit for now, upstream
for good. Be explicit with the user about what the binary is: SQLite only, stubbed paths raise, and anything
the stubs bypass (authentication included) is not enforced — never expose it. If the real goal is a single
deployable file or more speed rather than the experiment itself, point out the alternatives: a packager that
bundles the interpreter and the unchanged app into one executable, or Ruby's own JITs (YJIT/ZJIT).

## Pitfalls that cost real time

- `spinel --rbs DIR` reads **every** `.rbs` in DIR. Run each repro variant in its own empty directory — a
  leftover sidecar once produced a false "qualified names fail too" diagnosis.
- In Ruby `String#sub/gsub` with a replacement *string*, `\0`/`\1` are backreferences: a C `'\0'` literal
  in a replacement silently pastes the match. Use the block form (`sub(old) { new }`) for literal text; with
  the block form, `\1` is *not* expanded — pick one deliberately.
- Rust raw strings: Ruby source containing `"#{…}"` ends an `r#"…"#` early — use `r##"…"##`.
- roundhouse's own loop is `cargo test --locked` (default suite before committing, `--all-targets` at milestones,
  `bin/rh verify --plan --base main --test <suite>` for focused runs). If you use `cargo test --release`, it rebuilds
  `target/release/<bin>`: after testing a stash of `main`, rebuild before
  trusting the binary again.
- `git checkout -f` between branches discards staged work — commit per branch as you go.
- Build with `CC=clang` by default: roundhouse's Spinel docs measure it about twice as fast as gcc on the
  generated C. GCC 14+ also turns some Spinel warnings into errors (`-Wreturn-mismatch`); if a build fails only
  under gcc, that confirms it before you blame the app.
- The compile has no timeout in Spinel's own corpus runner; an exponential regression shows up as "slow",
  not "failed" — measure. A build that never leaves type inference is usually the fixpoint not converging;
  `SP_FIXPOINT_LOG=1` (or the round counter under gdb) tells you within minutes.
- A fix in one tool can expose a bug in the other: a newly emitted type declaration can turn a long-silent
  mis-binding into a refusal. Check the commit that changed the emit before assuming a regression.
- Rewrites in the post-emit script should assert their exact match counts and stop when they differ — a silent
  zero-match after an upstream change looks like success.
- Keep a written recovery note (where things are, what is pinned and why, how to recreate the periodic job,
  what was in progress) so a new session can resume instead of rediscovering.

## Keeping it current

Upstream changes daily. For long campaigns, schedule a periodic job that fetches both repos, reports new
commits touching the areas you depend on, tracks your open issues/PRs, and re-runs the pipeline when
something moved — with strict gates before anything is filed automatically (see the end of
`references/upstream-reporting.md`, including how often to run it, how to compare runs, and what to do when
an upstream change starts rejecting the app).
