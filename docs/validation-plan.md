# Validation Plan — p2d

How we know a thing works. How we gate CC dispatches. How we review.

This doc is read alongside `CLAUDE.md` and the pinned `raw-spec-notes` spec. It exists because agentic builds fail in a specific way — the code looks right, the tests pass, and the behavior is wrong — and the defense against that is explicit rules about what "done" and "tested" mean.

---

## 0. Test pyramid

Not every test lives at the same layer. Default suite mix:

| Layer | Purpose | Speed | Uses Shopify fixtures? | ~% of suite |
|---|---|---|---|---|
| **Unit** | Pure-logic helpers (delta computation, error-code lookup, `OrphanPolicy.decide`, JSONL stitcher, translation-table builder). | Microseconds | No — inline minimal inputs are fine and preferred. | ~60% |
| **Contract** | Each domain's public method surface; verifies the promise. | Milliseconds | Real fixtures for Shopify-shape round-trips; factories otherwise. | ~25% |
| **Integration** | Cross-domain flows with recorded Shopify responses (VCR-style). | Seconds | Real fixtures, played back. | ~10% |
| **Invariant / system** | The 7 system invariants (§3), end-to-end against the test dev store. | Minutes | Live dev store. | ~5% |

The pyramid shape is not cosmetic. A suite weighted toward integration/live-store tests is slow, flaky, and expensive to run — meaning it gets run less, which defeats the point. Keep the fast layers thick; reserve the slow ones for things only they can verify.

---

## 1. Philosophy: prefer contracts, allow meaningful interaction tests

A **contract test** asserts a public promise: *given this input, the output has this property.*

A **wiring test** asserts an implementation detail: *this method called that method with these arguments.*

**Default to contract tests.** They survive refactoring and test what callers actually depend on. But some things are *inherently* about interaction and belong as explicit tests:

- **State machine transitions.** "From `submitted`, on `poll_complete`, transition to `fetched`" is a wiring-shaped test and it's the right test for a state machine.
- **Retry counts and back-off.** "After 3 `RETRY_SAME_INPUT` failures, promote to `NO_RETRY`" is an interaction assertion; it's also exactly what the retry policy promises.
- **Regression nails.** When a specific bug is fixed, a test that locks in "this specific thing won't happen again" is legitimate even if it looks like wiring.

**The heuristic:** if a **minor** refactor (renaming a private method, restructuring a loop, changing a query shape) would break the test, it's probably wiring and should be rewritten. If a **major** refactor (swapping ActiveRecord, rewriting an entire phase) would break it — that's fine; major refactors warrant test churn.

Mock the **collaborators** of the thing under test; never mock the thing under test itself. A unit test of `OrphanPolicy.decide` that stubs a logger is fine. A test of `OrphanPolicy.decide` that stubs `OrphanPolicy.decide` is fraud.

### Concrete examples for p2d

**Good (contract):** Given a real Shopify JSONL fixture, after ingestion into Mirror, a re-pull against the same source store produces byte-identical JSONL (modulo ordering). *Verifies the mirror is lossless without caring how ingestion is implemented.*

**Good (legit interaction):** A PhaseRun transitions `submitted → polling → fetched → stamped → done` in that order when each corresponding event fires, and refuses transitions that skip states. *State machines need transition-level tests; this is not wiring.*

**Bad (wiring masquerading as a test):** `Pull::Ingester#call` invokes `Mirror::Product.upsert!` N times for N input rows. *Tests that we wrote a loop. Passes even if the loop does nothing meaningful.*

**Bad (wiring):** `Phase3#run` calls `Mirror::Product.where(store: source).stamped_in(dest).not_exists` to compute input. *Tests today's query shape, not the delta-input invariant.* The correct test: "after Phase 3 runs, the set of stamped dest records equals scope minus previously-stamped."

---

## 2. Fixture discipline

Contract tests need **real reference data**, not hand-typed approximations of what we think Shopify returns. The moment fixtures are hand-typed, assumptions get baked in, and CC inherits those assumptions.

### Rules

- **Shopify-shape round-trip and ingest tests use fixtures captured from a real Shopify dev store.** Not hand-written JSON. Not docstring examples. Real JSONL from real GraphQL calls. This rule is scoped to tests that assert something about *Shopify's data shape* — ingest correctness, round-trip fidelity, stitching, error-response parsing. Pure-logic helpers that happen to work on Shopify-shaped types (delta computation, error-code classification, JSONL-line-building) are allowed inline minimal inputs, which are often clearer than a full fixture.
- **Fixtures carry provenance metadata** as a sibling `.meta.yml` file: which store, which API version, which query or mutation, capture timestamp, capture script version.
- **Fixtures are regenerated by script, never edited by hand.** A `bin/capture-fixtures` (or equivalent) script runs against the project's test dev store and refreshes the fixture set. The script is the source of truth for fixture content.
- **Fixtures are committed to the repo.** Yes, they're large. Yes, they belong in git. Testing depends on their stability.
- **When Shopify's API version bumps** (e.g., 2026-01 → 2026-04), fixtures are recaptured in a single dedicated commit. That commit's diff surfaces exactly what Shopify changed.

### Required fixtures (minimum, for v1)

Captured from the project's test dev store (see §6):

- One product with variants, media, product-level metafields
- One product with variant-level metafields
- One product with 20+ images (for `productSet` media reconciliation testing)
- One manual collection with 10+ products
- One smart collection with metafield-referencing rules
- One metaobject definition + 10 metaobject instances
- One metafield definition
- Translation data for one product (2+ locales, multiple fields)
- Result JSONL from a successful bulk push (products, metaobjects, collections, translations)
- Result JSONL from a bulk push with per-line errors (deliberately malformed input, to capture real error shapes)
- Result JSONL from a bulk-op-level failure (TIMEOUT or INTERNAL_SERVER_ERROR — may need to engineer)
- `shopLocales` response from source and destination stores
- `translatableResources` response

Expect ~50-200MB of fixtures. That's fine. They're the test oracle.

---

## 2.5 Database during tests

The test suite runs against **in-memory SQLite** (`config/database.yml` test block uses `adapter: sqlite3, database: ":memory:"`). Dev and production run against Postgres via docker-compose. This is a deliberate, hard constraint — CC dispatches multiple agents in parallel worktrees, and a shared Postgres creates port and schema contention that ruins that model.

### The hard portability rule

**No Postgres-specific SQL in application code. Ever.**

Banned in default-path code:
- JSON operators: `->`, `->>`, `@>`, `?`, `jsonb_*()` functions
- Array columns (we don't need them)
- `tsvector` / full-text search built on Postgres extensions
- Any `execute("postgres-specific SQL")` block

There is **no escape hatch**. No `@postgres_only` tag, no excluded-from-default-suite pattern. If a feature requires Postgres semantics, the feature is wrong for this codebase — rewrite it as Ruby-level logic or a portable query.

### Column type for JSON-shaped values

Use `t.text` with `serialize :field, coder: JSON` at the model layer. Example:

```ruby
# migration
create_table :mirror_metafields do |t|
  t.text :value   # JSON-encoded string, opaque to SQL
  ...
end

# model
class Mirror::Metafield < ApplicationRecord
  serialize :value, coder: JSON
end
```

Do **not** use `t.jsonb` or `t.json`. Both introduce adapter-specific behavior. `t.text` + `serialize` gives identical read/write semantics on SQLite and Postgres.

Architectural rationale: Mirror is a mirror. We store values; we don't filter, aggregate, or search inside them. If a future feature wants JSON-inside queries, that's the signal to extract the searched field as its own column, not to reach for JSONB.

### FK enforcement in SQLite

SQLite disables foreign key enforcement by default. Enable it via a connection initializer:

```ruby
# config/initializers/sqlite_foreign_keys.rb
ActiveSupport.on_load(:active_record) do
  if connection.adapter_name.downcase.include?("sqlite")
    connection.execute("PRAGMA foreign_keys = ON")
  end
end
```

Without this, SQLite silently orphans children on parent delete; Postgres raises. With it, they behave identically. Do not remove this initializer.

### Portability gotchas to watch for

Most divergence is eliminated by "no JSON operators, no arrays, FK on." What remains:

- **NULL ordering in `ORDER BY`**: explicit `NULLS LAST` (or `NULLS FIRST`) whenever ordering on nullable columns. Implicit behavior differs between SQLite and Postgres.
- **`LIKE` case sensitivity**: SQLite is case-insensitive by default; Postgres is case-sensitive. We don't do fuzzy string search, but if you ever do, use `LOWER()` on both sides.
- **`upsert_all` behavior**: Rails abstracts `ON CONFLICT` across adapters. Safe as long as you use the Rails API, not raw SQL.

### The CI compatibility canary

Local dev + test workflow: SQLite for tests (fast, zero services).
CI main job: SQLite for tests (fast feedback).
CI parity job: runs the full test suite against real Postgres on each push. This is the drift detector — if it fails, the cause is always a portability violation. Fix the code; never exclude the test.

Implication for fixtures: unchanged. Shopify fixtures are captured from a real dev store and live on disk. The DB adapter has nothing to do with fixture capture — it's about what tests do with the fixtures once loaded.

---

## 3. System invariants

Invariants are system-wide promises that must hold regardless of which domain you're in. Each has a dedicated system-level test. These tests are the canaries: when one fails, the system broke a promise, regardless of which code path caused it.

### Invariant 1 — One-way guarantee

**No code path issues a GraphQL mutation against a source-role store.** Queries against source stores are always allowed (pulls are queries). Mutations are destination-only.

Enforced by a system-level test that audits every mutation call through D2 and asserts the target store's role is `:destination`. Runs on every test suite execution. Fails if anyone — directly or transitively — dispatches a mutation to a `:source` store.

### Invariant 2 — Stamp-before-commit

**Every Mirror row with `source_gid` present was stamped during a specific, traceable job+phase.** No orphan stamps (stamps with no originating JobEvent). No stamps written outside of Phase 3, Phase 2, or Phase 5 contexts (per the phase plan).

Enforced by a system-level test that queries all stamped rows across all Mirror tables and asserts each has a corresponding `phase_completed` JobEvent referencing the source_gid.

### Invariant 3 — Delta-input correctness

**Phase input is always computed fresh from Mirror at phase start, never cached across boot cycles.** The formula `scope_records MINUS Mirror::*.where(source_gid: present for dest store)` is recomputed every time a phase's `input_built` state is entered.

Enforced by a system-level test: run a phase twice in sequence; the second run must produce empty input. Kill the process mid-phase; on reboot, input must be recomputed, not loaded from working memory or a cache.

### Invariant 4 — Translation-table rebuildability

**Translation tables can be reconstructed from Mirror's `dest_gid` columns alone, with no other state required.**

Enforced by a system-level test: populate Mirror with dest_gid data, clear all in-memory state, invoke the translation-table builder, assert the tables are fully populated. No JobEvent replay, no cached state, no side inputs.

### Invariant 5 — Bulk op state consistency

**For every `bulk_operations` row not in a terminal state, either Shopify's op is still alive, or the reconciler will detect staleness within one boot cycle.**

Enforced by a system-level test: simulate a Rails crash mid-push by terminating the process; restart; assert every non-terminal BulkOperation row either advances to a terminal state within one reconciler tick or surfaces as "too stale" to the user.

### Invariant 6 — Retry idempotency

**Any phase can be safely re-entered at any PhaseRun state.** No state produces a "can't resume from here" error. Re-entry from `stamped` moves to next phase; re-entry from `input_built` discards partial work and rebuilds; re-entry from `submitted` continues polling; etc.

Enforced by a system-level test that explicitly re-enters phases from each possible starting state and asserts progress.

### Invariant 7 — Orphan policy safety

**The `:mirror` (destructive) orphan policy cannot execute without an explicit user confirmation captured as a JobEvent with the `OrphanPolicy.destructive_confirmation_token` field populated.**

Enforced by a system-level test that attempts to run Phase 6 with `:mirror` policy but no confirmation token and asserts the phase refuses, logs, and surfaces an error.

### Invariant 8 — DB-adapter portability

**Every application SQL query runs unchanged on both SQLite (in-memory, test-time) and Postgres (dev/prod).** No `@postgres_only` tags, no excluded-from-default-suite tests, no adapter-specific code paths.

Enforced by: (a) the default test suite running against SQLite, which fails loudly if adapter-specific SQL is used inadvertently; (b) a CI compatibility-canary job that runs the full default suite against real Postgres. Any divergence fails the canary, and the fix is always in application code — never a test exclusion.

---

## 3.5 What NOT to test (anti-bloat rules)

Tests cost maintenance. Tests that don't earn their keep drag on velocity every time the code moves. CC left unchecked will happily generate 50 tests where 5 would do. These rules cap the ceremony.

### Hard no's

- **No tests for trivial delegations.** `def active? = status == :active` does not need a test. `def source_store_id = store_id if store.source?` does not need a test.
- **No tests that enumerate every ActiveRecord validation.** `validates :name, presence: true` is Rails; trust Rails. One test per model proving the constraint object exists is overkill.
- **No tests of private methods directly.** Exercise privates through the public surface. If a private method needs its own test, it probably wants to be extracted as its own public thing.
- **No tests that assert specific log lines or specific event payloads unless the log/event IS the contract.** Audit log content is the contract for observability; random info-level logs are not.
- **No tests of every combination of inputs for a pure function.** One test per equivalence class (happy path, edge case, error case) is usually enough. Don't enumerate 15 metafield types when 3 representative ones cover the dispatch logic.
- **No duplicate coverage across layers.** If an integration test proves Phase 3 stamps records correctly, a separate unit test asserting the same thing at the component level is redundant. Pick the cheapest layer that proves it.

### The one-sentence test

Before adding a test, state in one sentence: *what failure does this catch that no existing test catches?* If you can't answer, the test is redundant; delete it.

### Count discipline per unit

As a rule of thumb (not hard limit), a well-scoped public method gets 1–3 tests: happy path, one edge case if there's a non-trivial one, one error case if it has a documented failure mode. A unit of code with 8+ tests is a smell — either the unit is too big, or the tests are redundant, or both.

### The one sentence per test assertion

Each test's primary assertion should state *what behavior is promised*, not *what code executed*. "After Phase 3, Mirror has exactly N stamped records" is a promise. "`upsert!` was called N times" is execution.

---

## 4. Per-artifact validation

Each design artifact has a contract statement, required fixtures, and a gate criterion. CC does not dispatch against an artifact until its gate is met.

### Schema (`schema.md`, produces `db/migrate/*`)

- **Contract:** Real Shopify JSONL ingested into this schema round-trips — select it back, emit JSONL, byte-compare against original (modulo ordering and Shopify-side-only fields).
- **Fixtures:** All required fixtures from §2.
- **Gate:**
  - [ ] Migrations run cleanly on fresh Postgres
  - [ ] Every Mirror table has a round-trip test using at least one real fixture
  - [ ] JSONB value columns have at least one test per value type (string, integer, date, JSON, reference, reference-list)
  - [ ] No schema-level wiring tests

### Domain interface contracts (`contracts/D1.md` through `D7.md`)

- **Contract:** Each public method has a YARD signature, a contract-test stub that asserts one invariant of that method's promise, and documented failure modes (exceptions raised).
- **Fixtures:** N/A at this stage (contracts are signatures, not behavior).
- **Gate:**
  - [ ] Every public method signed
  - [ ] Every public method has at least one contract test (even if it's a stub pending implementation)
  - [ ] Every exception type documented at the contract layer is defined as a real Ruby class
  - [ ] No method-chain assertions in the tests

### State machines (`state-machines.md`)

- **Contract:** Every documented transition has a test. Every *undocumented* transition (i.e., illegal) has a test that asserts the transition is rejected. Crash-recovery has a test using simulated process termination.
- **Fixtures:** N/A beyond standard factories.
- **Gate:**
  - [ ] Mermaid state diagrams for Job lifecycle + PhaseRun lifecycle
  - [ ] Test per legal transition
  - [ ] Test per illegal transition (asserts rejection)
  - [ ] Crash-simulation test for PhaseRun recovery

### Shopify payloads catalog (`shopify-payloads.md`)

- **Contract:** Each authored bulk query runs against a real dev store and returns the expected JSONL shape. Each authored push mutation dispatches as a bulk op and either succeeds or returns an error code from our classification table (§5 of the spec).
- **Fixtures:** Outputs of every query + mutation, captured.
- **Gate:**
  - [ ] All 4 pull bulk queries authored and verified against dev store
  - [ ] All push mutations (one per phase that uses bulk) authored and verified
  - [ ] Fixture captured for every successful query/mutation
  - [ ] Error-code mapping table complete, with fixture for at least one error response per classification state (`NO_RETRY`, `RETRY_SAME_INPUT`, `RETRY_AFTER_CHANGE`)

### Sequences (`sequences.md`)

- **Contract:** Each documented sequence has an end-to-end integration test that exercises the full flow. Shopify-touching sequences run against a real dev store.
- **Fixtures:** Dev store state captures before and after each sequence.
- **Gate:**
  - [ ] Push happy path sequence + end-to-end test
  - [ ] Crash + boot reconciler recovery sequence + test (with simulated process termination)
  - [ ] Locale pre-flight pause/resume sequence + test

### Data flow (`data-flow.md`)

- **Contract:** (None directly; validated through the sequence tests)
- **Gate:** Diagrams exist, reviewed for accuracy.

### Context & boundaries (`context.md`)

- **Contract:** (None directly; this is a review artifact)
- **Gate:** Every external arrow annotated with protocol, auth mechanism, and trust level.

### Decisions log (`decisions.md`)

- **Contract:** Every non-obvious pick in the spec has an entry.
- **Gate:** Seeded with current decisions (Postgres, Solid Queue, Turbo Streams, JSONB, `p2d` namespace, `OrphanPolicy` value object, delta-input idempotency, fixed 30s retry back-off, `:ignore` as default orphan policy).

---

## 5. Per-phase dispatch gates

Before any CC task dispatches in a given phase, the following must be true. If a gate is not met, the dispatch is paused and the gap is closed first.

### Phase 0 gate (before any code)

- [ ] Pinned spec in `raw-spec-notes` reflects current decisions
- [ ] Architecture doc committed to repo at `docs/domain-breakdown.md`
- [ ] `validation-plan.md` committed (this doc)
- [ ] `CLAUDE.md` committed
- [ ] JSONB value-schema lock decided and documented

### Phase 1 gate (foundation scaffold)

- [ ] Phase 0 gate met
- [ ] Stack choices reflected in the task spec (Rails 8, Postgres dev/prod + in-memory SQLite test, Solid Queue, Turbo Streams, Rails 8 auth)
- [ ] `config/database.yml` uses Postgres for dev/prod, `adapter: sqlite3, database: ":memory:"` for test
- [ ] `config/initializers/sqlite_foreign_keys.rb` enables `PRAGMA foreign_keys = ON`
- [ ] `Gemfile` has `gem "pg"` (dev/prod) and `gem "sqlite3", group: :test`
- [ ] CI runs `bin/rails test` with zero external services (main job) + a Postgres-parity canary job

### Phase 2 gate (D1 + D2)

- [ ] Phase 1 merged
- [ ] **Test dev store exists and is credentialed in `.env.test.example`**
- [ ] **First fixture capture run completed** — at least one product with variants, metafields, media; one collection; one metaobject; one translation set. Captured fixtures committed.
- [ ] Domain contracts for D1 and D2 drafted

### Phase 3 gate (D3 Mirror)

- [ ] Phase 2 merged
- [ ] Schema migrations written
- [ ] All required fixtures (§2) captured
- [ ] Round-trip test written for at least one Mirror table

### Phase 4+ gates

Defined as artifacts stabilize. Each phase gate includes:
- Prior phase merged
- Domain contracts for the target domain drafted
- Any Shopify payloads needed for the phase authored and verified

---

## 6. The test dev store

A dedicated Shopify dev store exists for this project and is the source of every fixture. Requirements:

- Populated with realistic-ish catalog data (not empty, not massive — ~100 products, ~10 collections, ~10 metaobject instances, 2+ locales)
- Credentials in `.env.test` (never committed); `.env.test.example` has placeholder structure
- Dev Dashboard app created, installed on this store
- `bin/capture-fixtures` script targets this store via `.env.test`

The store is a project dependency, same as Ruby version or Postgres version. Nothing works without it.

---

## 7. Task-spec template addendum: "Invariants this code must satisfy"

Every CC task spec gets a mandatory **Invariants** section, written in plain English, 3-5 bullets. CC must demonstrate the invariants hold via tests. The Opus reviewer explicitly checks that the tests would fail if the invariant were violated — not just that the tests pass.

### Template

```
# [Task title]

## Situation
[Why this task exists, what's missing, what pain it addresses]

## What to do
[Specific, bounded scope. File paths when possible. Don't write implementation
details — describe intent and constraints.]

## Reference
- [Relevant design docs, pinned conversations, prior task IDs]

## Invariants this code must satisfy
- [Invariant 1 — a promise the code must keep, regardless of how it's written]
- [Invariant 2]
- [Invariant 3]
[3-5 total]

## Checklist
- [Concrete acceptance criteria — the gate signals]
```

### How to write good invariants

- **State the promise, not the method.** "Given an invalid credential, `Store.add` returns a validation error and does not persist" — not "`Store.add` calls `Credential.validate`."
- **Make it falsifiable.** An invariant that can't be tested is vibes. Every invariant corresponds to at least one test.
- **Prefer end-state invariants over process invariants.** "After run, Mirror contains X" is testable. "The method processes each row in order" is often wiring-in-disguise.
- **Link to a system invariant where one applies.** If the task touches one of the 7 system invariants, cite it.

---

## 8. Review gate: what the Opus reviewer checks

In addition to correctness + style, the Opus review must verify:

1. **Every invariant in the task spec has a corresponding test.** Not "a test exists" — *this specific invariant* is verifiable by *this specific test*.
2. **Every test's primary assertion survives a MINOR refactor** (rename private method, restructure loop, change query shape). Tests that fail only on *major* refactor (swap ORM, rewrite phase) are fine. The bar is "would a reader doing cleanup hate this test?", not "is this test perfectly abstract?"
3. **Shopify-shape round-trip tests use real fixtures.** Pure-logic tests on Shopify-shaped inputs may use inline minimal data. The distinction matters; both should exist.
4. **No test that mocks the thing under test.** Testing `Phase3` by mocking `Phase3::InputBuilder` and asserting the mock was called is the canonical failure pattern. Reject.
5. **No bypass of the one-way guarantee.** Any code that writes to a store whose role hasn't been verified as `:destination` is an auto-reject.
6. **Anti-bloat audit.** The reviewer runs through §3.5 and flags:
   - Tests of trivial delegations / Rails validations / private methods.
   - Redundant tests across layers (if X is proven at integration level, don't also test X at unit level).
   - Tests whose one-sentence description ("what failure does this catch?") is unanswerable.
   - Any public method with 8+ tests — investigate whether the unit is too big or the tests are redundant.
   - Hand-typed JSON masquerading as Shopify data in a test that claims to verify Shopify-shape behavior.
7. **Legitimate interaction tests are not flagged.** State machine transitions, retry counts, event emissions that are part of the contract — these look like wiring but are the correct shape. The reviewer distinguishes "wiring that tests trivia" from "interaction that IS the contract."

The reviewer's output includes a **test-by-test classification**: for each test added, one of `contract / legit-interaction / wiring / redundant / fixture-shape-mismatch` with one-line reasoning. Anything `wiring` or `redundant` is rejected. `fixture-shape-mismatch` means a test claims to test Shopify-shape behavior with hand-typed JSON — rejected, must use a real fixture or be reframed as a pure-logic test.

---

## 9. The escalation rule

**When CC hits genuine ambiguity, contradiction, or a gap, it escalates rather than guesses.** Pull the emergency brake. The task pauses, a human reviews, the task resumes with clarification.

Genuine ambiguity includes:
- Contradictions between the spec, the architecture doc, and the task
- Missing information the task requires that isn't in the referenced docs
- Design calls the task doesn't have authority to make (e.g., "what should the default retry limit be" when the spec is silent and the task isn't about retry policy)

Does not include:
- "I could do it two ways and I picked one" — fine, document the pick in the decisions log
- "The spec says X but I think Y is better" — implement X, leave a note suggesting Y for review
- "This is harder than I thought" — press through or decompose the task

The escalation is a feature, not a failure. Silent guessing is the failure.

---

## 10. Changes to this plan

This document is append-mostly. Invariants may get refined. New artifacts may be added. Gate criteria may tighten. But the core rule — **contracts not wiring** — does not change.

When this document changes, the change is reflected in the decisions log. When an invariant changes, a dated entry in the log says what changed and why.
