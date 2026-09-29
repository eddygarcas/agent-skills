# Toolchain: building and running roundhouse and Spinel

## roundhouse

- One binary: analyzer, LSP, MCP server and every transpile target.
- Release installer (`curl … roundhouse-installer.sh | sh`) puts a dated snapshot in `~/.local/bin`, but
  snapshots lag weeks behind `main`. Build from source for real work:
  ```sh
  mise use -g rust@latest            # or rustup; Rust >= 1.85
  sudo pacman -S clang               # Debian: apt install clang libclang-dev (both are needed)
  git clone https://github.com/rubys/roundhouse ~/.local/src/roundhouse
  cd ~/.local/src/roundhouse && cargo build --release --bin roundhouse
  cp target/release/roundhouse ~/.local/bin/roundhouse
  ```
  First build ≈ 4 min, incremental ≈ 1 min.
- Commands used:
  - `roundhouse check --continue <app>` — whole-program analysis; `--continue` records unrecognized
    constructs instead of aborting; prints a gem census (framework / modeled / unknown).
  - `roundhouse --target spinel --survey --allow-unsupported -o out/spinel <app>` — emit; `--survey`
    ledgers gaps, `--allow-unsupported` emits stubs at unsupported sites instead of refusing.
- Its test suite (`cargo test --release`) needs `fixtures/real-blog`, generated with `ruby bin/rh fixture`
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
  `--cc=clang`.

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
