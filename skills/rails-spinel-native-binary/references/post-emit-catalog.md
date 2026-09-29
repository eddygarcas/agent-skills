# Post-emit catalogue

Rewrites that a real Rails 8 API (Devise, Doorkeeper, Sidekiq, pg_search, acts_as_tenant, several vendor API
client gems) needed before `spin build` could get through. Each exists because Spinel resolves
everything at compile time and roundhouse deliberately does not model some gems. Apply them from one
script, in order, to a fresh emit; comment each section with why it exists and delete it once upstream
covers the case. Much of any real script ends up app-specific; treat this catalogue as a pattern source.

Stubs share one idea: **compile, and raise loudly if reached.** Define them in a runtime file required from
`main.rb` (e.g. `runtime/dynamic_send.rb`), give them a typed tail so Spinel can infer a return type, and
seed them `untyped` in a sidecar.

## 1. Dynamic dispatch (always needed)

| App construct | Rewrite | Why |
|---|---|---|
| `Object.const_get(dynamic)` / `"Foo::#{x}".constantize` | a literal constant when there is one obvious target (e.g. `Net::HTTP::Get`), otherwise `Object` or a raising `rz_dyn_const(name)` | constant names must be static |
| `send`/`__send__`/`public_send` with a non-literal name, `method(x).call(...)` | `rz_dyn_send(name, *args)` raising stub; drop the receiver when the receiver is typed | method names must be static; an Object-level stub on a typed receiver miscompiles in C |
| `eval(formula)` for arithmetic (pricing rules) | a tiny arithmetic evaluator (`rz_eval`) | `eval` is unsupported; these formulas are numbers and `+-*/()` |
| `Class.new.include(M).new(...)`, `define_method` loops, `instance_eval` hooks, `ObjectSpace`, `binding`, `instance_variable_get/set`, runtime `extend` | stub or delete | no runtime class construction |
| `respond_to?(dynamic)` | answer `false`; `respond_to?(:lit) && lit` → `lit` | runtime reflection; the second form makes a bool/value union |
| `Thread.new do … end` | run the block inline (`[nil].each do`) | background work; the server already has green threads |

## 2. Unmodeled gems (derive the list with `scripts/undefined_constants.rb`)

- **Structural uses** — superclass, `include`, `rescue X`, constants: define empty shells
  (`class Devise::SessionsController < ActionController::Base; end`, `module PgSearch::Model; end`,
  `class OpenURI::HTTPError < StandardError; end`, `Rack::Utils::HTTP_STATUS_CODES = {…}`).
- **Expression uses** (`Gem::Thing.new(...)`, `Gem.call`) — rewrite `Gem::Thing.` to
  `rz_dyn_const('Gem::Thing').`, and only in method-call positions (a lookahead of `\.[a-z_]`). Use
  single quotes: a double-quoted rewrite inside a string literal broke the surrounding string once.
- **Things the local API test actually needs get real implementations**:
  - `I18n` — generate the table from `config/locales` (`scripts/locale_table.rb`) and implement
    `t`/`translate` (interpolation, `default:`, `count:` plurals, fallback to `en`), `locale`/`locale=`,
    `with_locale`, `default_locale`, `available_locales`. Views also call bare `t "key"` without
    parentheses — rewrite both `t(` and `t "` in `app/views`.
  - App config read from YAML (`config_for(:app)`) — emit a class with one method per top-level key.
  - Pusher/notifications — no-op, or neutralize the calls entirely (below).
  - Sidekiq — `Sidekiq.logger` taking `(msg, **fields)`; `Worker`/`Job` modules; class-side
    `perform_async/perform_sync/perform_in/perform_at`. Running jobs inline (`new.perform(*args)`)
    miscompiles when `perform` is typed; making them no-ops compiles but disables the jobs.
- **Polymorphic `belongs_to`** — roundhouse emits `Assoc.find_by(id: @assoc_id)` with the association
  name as a class. Rewrite to the concrete classes (`@x_type == "Company" ? Company.find_by(...) : ...`)
  or `nil`.

## 3. Rails/Devise surface the runtime lacks

- `ActionController::API` is not defined: retarget `< ActionController::API` to `< ActionController::Base`,
  otherwise every request answers 500 (`undefined method 'params='`). (roundhouse issue #163.)
- Devise controller/model surface used in the app: `devise_controller?` (false),
  `configure_permitted_parameters`, `authenticate_or_request_with_http_basic` (→ `[["", ""]].each do |u, t|`
  — a yielding Object method was refused before Spinel `f9bf397e2`), `bypass_sign_in`, `access_locked?`,
  `lock_access!`, `unlock_access!`, `invitation_accepted?`, `generate_otp_secret`, an OTP URI helper.
- `ActiveSupport::SecurityUtils.secure_compare`, `ActiveRecord::Base.sanitize_sql_like/…_array`,
  `touch_all`, `transaction`/`with_lock` (yield), `suppress(Exception) { … }` (inline a begin/rescue — a
  class-object argument and a yielding Object method both failed), `ActsAsTenant.with_mutable_tenant`.
- Dynamic finders `find_by_attr(x)` → `find_by(attr: x)`.
- Dropped route helpers (Devise/Doorkeeper mounts, storage paths) → placeholder methods on `RouteHelpers`.
- Credentials: the runtime's store is empty; read secrets from `Rails.application.secret_key_base` / ENV.

## 4. acts_as_tenant

roundhouse does not carry it. A minimal runtime shim: `ActsAsTenant.current_tenant(=)`,
`with_tenant { }`, `without_tenant { }`, and `ActionController::Base#set_current_tenant`. It does **not**
apply the default `where(tenant_id: …)` scope — explicit tenant-scoped queries still work, implicit
scoping does not. Require it from `main.rb` before the app.

## 5. Provider modules extended at run time

Modules that Rails `extend`s onto an object at run time (`extend(Object.const_get("Integrations::Providers::#{p}"))`)
have bodies with no receiver type for Spinel. `include` each provider module statically into the class that
extends it (and `require_relative` them) so bare calls inside them resolve; stub the runtime `extend`.

## 6. Time and dates

Spinel's built-in `Time` **cannot be reopened** (added methods are refused, and the reopen broke Time
comparisons elsewhere). Route through the runtime's module functions instead:
`x.beginning_of_day` → `ActiveSupport.beginning_of_day(x)`, `.to_date`/`.to_datetime` on strings →
`ActiveSupport.parse_time(s.to_s)` (drop them on values that are already Time), `midday` comparisons →
compare `beginning_of_day(...).to_i`, nullable Time comparisons → `(t || now) > …` or `.to_i`.

## 7. RBS sidecars

Spinel trusts seeds, so a wrong seed is fatal. Sweep the emitted `.rbs`:
- `nil`-typed parameters (positional `nil x`, keyword `x: nil`) → `untyped` (fixed upstream, roundhouse #180).
- `-> bot` returns → `untyped`.
- Every `--rbs seed contradicted` site → loosen that one entry (e.g. params helpers returning `Array` vs
  `Hash`, connector parameters typed from a single call site).
- Runtime sidecars with Integer ids when the app uses UUIDs (`ActiveStorage::Attached#initialize`
  `record_id`) → `String`, scoped to that class only (a class-unscoped `sed` changed a second class and
  broke it).

## 8. Neutralize what the local test does not need

When a helper family is irrelevant locally but produces many errors (dashboard push notifications,
sign-in audit logging), replace every call and the helpers' bodies with `nil` using Prism
(`scripts/neutralize_calls.rb <tree> name1,name2`). One such pass removed ~300 C errors. Never do this to
code on the path the user wants to test.

## 9. One-off shapes

Keep a catch-all section for single-site fixes found by the C-error loop (e.g. `head(:x) and nil` →
`head(:x)`, `(x += y)` as a value, `a, b = call`, `permitted.to_h.merge(...)` on a poly hash,
`SecureRandom.base36` → `hex`). Implement it as a Ruby script with `scan`-then-`gsub!(re, replacement)`
so backreferences expand and counts are reported — a block-form `gsub!` with `\1` wrote a literal `\1`
and destroyed the original text once.
