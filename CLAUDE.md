# CLAUDE.md — p2d

Standing orders for every CC task working on this project. Read top-to-bottom before doing anything on a p2d task. If anything here conflicts with the specific task you've been dispatched, the task wins — but pause and flag the conflict via escalation.

---

## What p2d is

p2d ("Prod-to-Dev Data Sync") is an open-source Ruby on Rails 8 developer tool. It copies Shopify catalog data **one-way** from a production Shopify store (source of truth) to one or more dev stores. It is self-hosted per developer — never a service, never multi-tenant.

Stack: Rails 8, Postgres (via docker-compose in dev), Solid Queue, Turbo Streams, Rails 8 built-in auth, Shopify Admin GraphQL API 2026-01 (pinned).

The architecture is decomposed into six bounded domains + one cross-cutting adapter:

- **D1** Stores & Credentials — the app's identity layer (Client ID/Secret + per-store tokens via client credentials grant)
- **D2** Shopify Adapter — cross-cutting, the only place that speaks HTTP to Shopify
- **D3** Mirror — the hub, local full-copy of every connected store
- **D4** Pull Engine — Shopify → Mirror (bulk queries)
- **D5** Push Engine — Mirror → destination Shopify (bulk mutations, phased pipeline)
- **D6** Jobs — long-running state and polling
- **D7** UI & Auth — Rails views, Turbo, auth

---

## The rules that can't drift

These do not change across tasks. If a task spec contradicts these, escalate.

### 1. One-way guarantee is structural

No code path issues a GraphQL **mutation** against a source-role store. Ever. Queries are fine (pulls are queries). Mutations are destination-only.

This is enforced by a system-wide test that audits every mutation call through D2 and asserts the target store's role is `:destination`. Do not add a flag, bypass, or exception for this. The architecture exists to make it impossible to violate accidentally.

### 2. `source_gid` stamp is the matching mechanism

Every destination record created by p2d carries a `$app:p2d.source_gid` metafield pointing back to the source GID. Destination records **without this stamp** are never touched by any phase. This is how the one-way guarantee extends into orphan reconciliation: we never delete or modify something we didn't stamp.

Do not add any other matching scheme (match-by-handle, match-by-SKU, etc.). The stamp is it.

### 3. Test contracts, not wiring

A contract test asserts a public promise. A wiring test asserts an implementation detail. We write contract tests.

If a reasonable refactor of the implementation would break a test, it is probably a wiring test. Rewrite it.

See `validation-plan.md` for the full philosophy. See §8 of that doc for what the Opus reviewer checks.

### 4. Fixtures are real, not imagined

Every Shopify-touching test uses fixtures captured from a real Shopify dev store. Hand-typed JSON approximating what you think Shopify returns is not acceptable.

If the fixture you need doesn't exist in the repo, either:
- Capture it via `bin/capture-fixtures` (or the current equivalent), commit it, use it
- Or escalate if capture infrastructure isn't ready

Do not invent fixtures inline in test files.

### 5. Delta-input idempotency is the push invariant

Every phase computes input as `scope_records MINUS Mirror::*.where(source_gid: present for dest store)`. Already-stamped records are always excluded. Do not cache input across boot cycles. Do not track "which rows were submitted" in a side table for retry — the source of truth is Mirror's stamps.

This is what makes retry, resume-from-crash, and re-run all "free" — they're the same path as a fresh run.

### 6. Translation tables rebuild from Mirror

Per-job translation tables (`source_gid → dest_gid` lookups for products, variants, collections, metaobjects, definitions) are rebuilt from Mirror's `dest_gid` columns at each phase start. Working memory is a cache, Mirror is the source of truth.

Do not persist translation tables in their own table. Do not carry them across process boundaries in memory.

### 7. Stack choices are locked

Do not introduce:
- Devise or any third-party auth gem (Rails 8 built-in auth is the answer)
- Sidekiq, Redis, or any other background runner (Solid Queue is the answer)
- ActionCable handlers for live updates (Turbo Streams is the answer)
- SQLite or any other DB (Postgres is the answer)
- A different Shopify API version (2026-01 is pinned)

If you think one of these should change, the answer is: file an item in the decisions log and keep coding against the current stack. Do not quietly introduce a new dependency.

---

## Vocabulary

- **p2d** — the project. Also the namespace slug used in metafields (`$app:p2d.source_gid`).
- **stamp** — the act of writing `$app:p2d.source_gid` on a dest record. Also refers to the metafield itself ("the stamp").
- **Mirror** — D3. The local DB tables that hold a full copy of each connected store's catalog.
- **source_gid** — the source Shopify GID (`gid://shopify/Product/...`). Stored as a column on dest-side Mirror rows and as the metafield value on dest-side Shopify records.
- **phase** — one step of a push job. The phase plan is in the pinned spec. Phases are numbered 0-7 and strictly ordered.
- **delta input** — `scope_records MINUS already-stamped records`. The idempotency mechanism.
- **translation table** — in-memory per-job map of `source_gid → dest_gid` for a given resource type (products, collections, etc.). Not to be confused with "translations" (the Shopify translations API).
- **OrphanPolicy** — the value object that decides what to do with dest records we didn't sync. `:ignore` (default), `:tag`, `:mirror` (destructive, explicit confirmation required).
- **Pull job** vs **Push job** — D4 vs D5. Both are Jobs (D6). Pull = Shopify → Mirror. Push = Mirror → Shopify.
- **PhaseRun** — D6 entity that tracks the state of one phase of one push job. States: `pending → input_built → submitted → polling → fetched → stamped → done`.
- **Bulk op** — a Shopify `bulkOperationRunQuery` or `bulkOperationRunMutation` invocation. We track these in a `bulk_operations` table tied to PhaseRuns.

---

## Where to find things

**Canonical design docs:**

- **Pinned spec** — the `raw-spec-notes` conversation. The *currently pinned message* is always the source of truth for product scope, matching rule, phase plan, error policy, translation handling. Previous versions remain as history, unpinned. Always read the current pinned message, never rely on a specific version number.
- **Architecture doc** — `docs/domain-breakdown.md` in this repo. Source of truth for bounded contexts, domain interfaces, cross-cutting concerns, system boundaries.
- **Validation plan** — `docs/validation-plan.md` in this repo. Testing philosophy, invariants, per-artifact gates, dispatch gates.
- **Decisions log** — `docs/decisions.md` in this repo. Append-only ADR-lite record of why non-obvious choices were made.

**Canonical per-artifact references (as they come into existence):**

- **Schema** — `docs/schema.md` + the migrations in `db/migrate/`
- **Contracts** — `docs/contracts/D1.md` through `docs/contracts/D7.md`
- **State machines** — `docs/state-machines.md`
- **Shopify payloads** — `docs/shopify-payloads.md`
- **Sequences** — `docs/sequences.md`
- **Data flow** — `docs/data-flow.md`
- **Context** — `docs/context.md`

If a file in this list doesn't exist yet, the artifact hasn't been authored. Don't invent its content — escalate if the current task depends on it.

---

## How task specs are shaped

Every CC task arrives as a spec with the following sections:

1. **Situation** — why the task exists, what's missing
2. **What to do** — specific, bounded scope
3. **Reference** — relevant design docs, pinned conversations, prior task IDs
4. **Invariants this code must satisfy** — 3-5 plain-English promises the code must keep, regardless of how it's written. These are *mandatory* — every task spec has them, and every invariant must be verified by at least one test.
5. **Checklist** — acceptance criteria, gate signals

The **Invariants** section is the load-bearing one for testing. Each invariant is a contract test's subject. When you write a test, you're testing *that this invariant holds*, not *that this line of code was executed*.

See `docs/validation-plan.md` §7 for the full template and guidance on writing invariants.

---

## The review gate

After you complete a task, an Opus reviewer checks:

1. Every invariant in the task spec has a corresponding test
2. Every test's assertion survives a reasonable refactor (contract, not wiring)
3. Every Shopify-touching test uses a real fixture
4. No test mocks the thing under test
5. No bypass of the one-way guarantee

Tests that don't meet these bars are flagged and returned. See `validation-plan.md` §8.

---

## Escalation: when to stop and ask

**Use the escalation mechanism** when you hit any of:

- A contradiction between the spec, the architecture doc, and the task
- Missing information the task requires that isn't in the referenced docs
- A design call the task doesn't have authority to make (the spec is silent, the task isn't about that topic)
- A decision that would break one of the rules in §"The rules that can't drift"

**Do not** escalate for:

- "I could do it two ways and I picked one" — pick one, note the pick in the decisions log
- "The spec says X but I think Y is better" — implement X, add a note suggesting Y for review
- "This is harder than I thought" — press through or decompose

Silent guessing is the failure mode. Escalation is a feature.

---

## Naming conventions

- Ruby modules match domain names: `P2d::Stores`, `P2d::Mirror`, `P2d::Push`, etc. (not `D1`, `D3`, `D5`)
- `D1`-`D7` are reference labels in docs, not in code
- Migrations and table names: snake_case, plural (`stores`, `phase_runs`, `bulk_operations`, `mirror_products`)
- Mirror tables are prefixed `mirror_` to distinguish from operational tables (`mirror_products`, `mirror_variants`, etc.)
- Job classes: `P2d::Jobs::PullJob`, `P2d::Jobs::PushJob`
- PhaseRun states are symbols: `:pending`, `:input_built`, `:submitted`, `:polling`, `:fetched`, `:stamped`, `:done`, `:failed`
- Test files colocate with code (`app/mirror/product.rb` → `test/mirror/product_test.rb`)

---

## What "done" looks like

A task is done when:

1. All checklist items from the task spec are satisfied
2. All invariants have tests that verify them (contract tests, not wiring)
3. `bin/rails test` passes
4. The Opus reviewer has reviewed and not flagged any issues
5. If `auto_pr=true` was set: a PR is open against `main`

If you believe you're done but one of the above isn't met, don't declare done — either fix the gap or escalate.

---

## Note on this document

This file is stable across tasks. If a rule changes, this file changes, and the change is reflected in the decisions log. Assume this file's current contents are authoritative unless a specific task spec overrides a point (which the spec must do explicitly).
