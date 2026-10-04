# Triage: what each failure means and what to do

Run `scripts/classify_errors.sh <spin-build.log> <abs-path-to-emitted-tree>` after every build. Decide per
failure whether it is (a) an app construct Spinel will never support → post-emit rewrite, (b) a roundhouse
emit or runtime bug → report upstream (and patch locally meanwhile), or (c) a Spinel bug → report upstream.

## Before spin build: emit problems (roundhouse)

| Symptom | Typical cause | Response |
|---|---|---|
| `ruby -c` fails on an emitted file | emitter printed invalid Ruby (reserved-word keyword flattened, `**rest` after a required keyword, `return if … else`, inlined multi-statement query as an argument, `Foo::::Bar` from a leading `/`) | minimal fixture, report; many were fixed in roundhouse PRs #152–#162 |
| `db/seed.sql` does not load | schema-qualified `create_table "public.x"`, SQL-keyword column names, index on a dropped column | report (fixed upstream); check your roundhouse is current |
| model has no column accessors, `check` silent | table name mismatch (e.g. schema prefix) | compare the emitted model's size to expectations |
| survey says `enum :x mapping must be an array or hash literal` | mapping via constant / `.freeze` | fixed upstream (#153) |

## Spinel analysis refusals

| Message | Meaning | Response |
|---|---|---|
| `cannot load such file -- X` | a require with no file or package | missing runtime shim (write one), missing `[dependencies]` in spin.toml, or scaffold leftovers (app with no views) |
| `spinel_rbs_extract: parse failed in X.rbs` | emitted RBS sidecar is not valid RBS | fix the sidecar in post-emit; report the emitter shape |
| `--rbs seed contradicted: … declared T but … passes U` | roundhouse's inferred signature is too narrow | loosen that sidecar entry to `untyped` in post-emit; report if systematic |
| `param 'x' has unsupported type nil` | sidecar seeds a parameter as `nil` (every call site passed nil) | widen to `untyped` (fixed upstream in roundhouse #180) |
| `const_get with a name known only at run time` | `Object.const_get(dynamic)` | rewrite to a raising stub or a literal-name case/Hash |
| `unsupported send with a runtime method name` | `send`/`public_send`/`__send__`/`method(x).call` with dynamic name | rewrite to a stub; literal-symbol sends are fine |
| `undefined method 'm' for a Class: no class in the program defines a class method 'm'` | dynamic finder (`find_by_email`), gem class method, dropped route helper | `find_by(email:)`; facade the gem; add the helper |
| `unsupported call: (CallNode \`m\`) recv=-/ty-1` | bare call with no resolvable receiver: helper from an `extend`ed-at-runtime module, a Devise/controller helper, a method defined only on a gem base class | define it on the class that owns the call (include connector modules statically, add controller shims); an Object-level method that *yields* was refused before Spinel `f9bf397e2` |
| `unsupported condition (non-bool)` | `if call_returning_non_bool` (e.g. `return if render(…)`, `secure_compare` on poly) | split into statement + `return`, or compare explicitly |
| `unsupported comparison` / `undefined method '>' for Time` | comparing values whose type is poly or a nullable Time | `.to_i` both sides or guard nil |
| `a Range of Time objects cannot be built` | `created_at: t.ago..` | rewrite to `where("created_at >= ?", t)` |
| `unsupported multiple assignment` | `a, b = call` | index into a temp |
| `unsupported operator assignment` inside an expression | `(x += y)` as a value | expand |
| `method_missing is defined but spinel does not dispatch …` (warning) | calls relying on method_missing will raise NoMethodError at run time | fine to compile; know which paths break |

## C compilation errors

Spinel accepted the program; the emitted C does not type-check. Group, then fix the largest cluster.

| C error | Usual Ruby shape | Response |
|---|---|---|
| `type mismatch in conditional expression` | `defined?(x) && x \|\| y`, `a && a.b \|\| c` producing a union the codegen can't unify | simplify the expression; neutralize helpers you don't need (Prism) |
| `passing argument N of 'sp_X_…' makes integer from pointer` | a pointer (String/Regexp/record) passed where an Integer is typed — e.g. a UUID id into a runtime slot typed Integer, or `poly[Regexp]` dispatching to every class's `[]` | fix the sidecar type (e.g. `Attached` `record_id: String`), or pin the receiver (`.to_s[regexp]`) |
| `incompatible type for argument 1 of 'sp_Object_m'` | an Object-level fallback method called on a typed receiver | drop the fallback; define the method where it belongs |
| `returning 'sp_A *' from a function with return type 'sp_B *'` | an RBS seed resolved a type name to the wrong class (same leaf name) | qualify the name in the sidecar; fixed in the extractor by Spinel #5981 |
| `‘_tNNN’ undeclared` | codegen temporaries inside nested blocks | reduce and report if reproducible in isolation |
| `invalid use of void expression` / `void value not ignored` | a stub whose body only raises used as a value | give stubs a typed tail value, or replace the call with `nil` |
| `‘return’ with a value, in function returning void` | Spinel + gcc ≥ 14 at top-level `ensure` | fixed upstream (#5777); `CC=clang` meanwhile |

## Run-time crashes

| Symptom | Usual cause | Response |
|---|---|---|
| the server segfaults on a request | a method called on `nil` held in a typed object slot (Spinel calls it with a NULL self instead of raising), or a GC barrier fault | `coredumpctl debug` for the frames; rerun with `SPINEL_GC_VERIFY=1 SPINEL_GC_STRESS=1`; fix the nil source app-side (often a stubbed identity), report the codegen side with a standalone repro |
| the server hangs after a background job raised | inline jobs run at the call site; a raising job can wedge the binary (an open item in roundhouse docs/pipeline/runtime.md) | make the job facade rescue, report if reproducible |

Errors inside `/tmp/spinel_split_*/sp_split.h` carry no Ruby line. Rebuild with `SPINEL_KEEP_SPLIT=1` and map
`#line` directives, or fix the Ruby-mapped instances of the same kind first — the split-header ones usually
share the cause.

## Is it upstream's bug?

Before reporting, reduce it: a standalone program (Ruby + optional `.rbs`, or a minimal Rails fixture for
roundhouse) that fails on current upstream and works on CRuby, **without** any of your post-emit shims.
Whole-program-only failures that vanish in isolation (they did for `runtime/user_agent.rb`'s undeclared
temporaries) are not reportable yet — they may be caused by your own shims.
