# Toolchain: building and running roundhouse and Spinel

## roundhouse

- One binary: analyzer, LSP, MCP server and every transpile target.
- Release installer (`curl … roundhouse-installer.sh | sh`) puts a dated snapshot in `~/.local/bin`, but
  snapshots lag weeks behind `main`. Build from source for real work:
  ```sh
  mise use -g rust@latest            # or rustup; Rust >= 1.89 (roundhouse docs/guide/install.md)
  sudo pacman -S clang               # Debian: apt install clang libclang-dev (both are needed)
  git clone https://github.com/rubys/roundhouse ~/.local/src/roundhouse
  cd ~/.local/src/roundhouse && cargo build --release   # all bins: roundhouse, roundhouse-ast, dump_ir
  cp target/release/roundhouse ~/.local/bin/roundhouse
  ```
  First build ≈ 4 min, incremental ≈ 1 min.
- Commands used:
  - `roundhouse check --continue <app>` — whole-program analysis; `--continue` records unrecognized
    constructs instead of aborting; prints a gem census (framework / modeled / unknown).
  - `roundhouse --target spinel --survey --allow-unsupported -o out/spinel <app>` — emit; `--survey`
    ledgers gaps, `--allow-unsupported` emits stubs at unsupported sites instead of refusing. Emit into an
    empty directory (`rm -rf` it first): files a previous run left behind are not removed.
  - `roundhouse --version` — the first line of any bug report.
- Its test suite (`cargo test --locked`; `--all-targets` at milestones; `bin/rh verify --plan --base main --test
  <suite>` for a focused loop — docs/development/testing.md) needs `fixtures/real-blog`, generated with `ruby bin/rh fixture`
  (requires the `rails` gem). Two tests stay environment-dependent (`fixtures/store` absent; the system Ruby
  needs the sqlite3 gem). Compare branch vs `main` on the same machine rather than expecting zero failures.

## Spinel

- Source only (no gem). Build and install to a user prefix:
  ```sh
  git clone https://github.com/matz/spinel ~/.local/src/spinel && cd ~/.local/src/spinel
  make deps                      # fetches vendored prism/rbs sources
  make -j"$(nproc)"
  make install PREFIX=$HOME/.local     # spinel + spin on PATH via ~/.local/bin
  spinel --version                     # e.g. "2026.09.12+2237 (6626c0f05) [gcc 16.2.1 (cc)]"
  ```
  Build ≈ 5 min. roundhouse's `RELEASES.md` names the Spinel release it was tested against; roundhouse
  `main` usually needs Spinel `master` (its runtime requires bundled packages newer than the last tag).
- System packages: a C compiler, sqlite3 headers, **jemalloc headers** (`spin.toml` requests the jemalloc
  allocator and the build refuses without it), libvips only when the app declares image variants.
- `spin build` in the emitted tree resolves dependencies (git packages such as spinel-bcrypt,
  spinel-rqrcode), runs the whole-program compile, and writes `build/bin/<name>` (the app is named `blog`).
- Corpus tests: `make test-corpus` (≈ 20 min, 4.6k tests); extractor goldens `make rbs-test`;
  seed tests `make rbs-seed-test`. Run a single test with `make build/test-results/<name>.ok`.
- Useful switches: `--rbs DIR` (seed types from sidecars — note it reads every `.rbs` in DIR), `-c` (emit C
  only), `SPINEL_KEEP_SPLIT=1` (keep the split C sources so errors in `sp_split.h` can be mapped back),
  `--cc=clang` / `CC=clang spin build` — use clang by default: about twice as fast as gcc on Spinel's output
  (roundhouse docs/guide/spinel.md).
- The built server: `./build/bin/<app> --help` lists its flags. Leave `--workers` at 1 (prefork is not ready).

## Diagnostics worth knowing

- `roundhouse mcp .` exposes analysis tools to an MCP client: `traceroute` lists every before/around/after
  filter a route runs, with a footer naming what could not be resolved (check that auth/tenant filters
  survived); `wont_lower` returns the deduplicated unsupported constructs for a target — a cheap diff between
  roundhouse versions without a `spin build`.
- `roundhouse-ast --stage prism|ingest|emit-ruby` (or `--stages`, `--round-trip`) and `dump_ir` speed up
  reducing an emit bug. `emit_preview` skips the post-analyze lowerings — don't reduce lowering bugs with it.
- `ROUNDHOUSE_TIMINGS=1 roundhouse check …` prints per-phase time and peak RSS. Every `ROUNDHOUSE_*`
  variable is read somewhere in the source: find them with `rg -n 'ROUNDHOUSE_' src/ scripts/` and check the
  actual read before assuming one is live (roundhouse docs/development/debugging.md).
- A compiled server that crashes: rerun with `SPINEL_GC_VERIFY=1 SPINEL_GC_STRESS=1` (and
  `SPINEL_GC_VERIFY_GEN=1`) to tell a GC barrier fault from a codegen fault (e.g. a method called on nil
  through a typed slot) before reporting; `coredumpctl debug` gives named C frames that map to Ruby methods.

## Diagnosing a hang

`spin build` at 100 % CPU with flat memory for many minutes is an analyzer loop, not slowness.

- `gdb -p <pid>` fails with `ptrace: Operation not permitted` under `kernel.yama.ptrace_scope=1`: only a
  parent may trace. Run the compiler under gdb and interrupt the child:
  ```sh
  FLAGS=$(cd out/spinel && spin flags)
  ( sleep 300; kill -INT "$(pgrep -P "$(pgrep -x gdb)")" ) &
  gdb -batch -ex run -ex 'bt 30' -ex kill --args ~/.local/lib/spinel/spinel bin/blog.rb $FLAGS -o /tmp/x
  ```
  Beware `pkill -f <pattern>`: it also matches your own shell's command line.
- A backtrace that is one function recursing into itself (e.g. `cmethod_reaches_override`) points at a
  depth-capped recursive walk without a visited set. Reproduce with a generated program whose size you can
  scale (e.g. a chain of N class methods each calling the next twice) and time N = 16, 20, 24.
- `perf` may not be installed; gdb sampling is enough.

## Compiler versions

GCC 14 made some diagnostics errors by default. If C compilation fails with `-Wreturn-mismatch` or similar
only under gcc, confirm with `--cc=clang` or `CC="gcc -Wno-error=return-mismatch"` before treating it as an
app problem — then report it (this exact case was fixed upstream).
