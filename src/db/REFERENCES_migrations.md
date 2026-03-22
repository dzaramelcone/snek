# Database Migration & Schema Management Tools: Exhaustive Reference

Research compiled 2026-03-21. Covers state-of-the-art tools, patterns, post-mortems, and design trade-offs.

---

## Table of Contents

1. [Declarative vs Imperative Migrations](#declarative-vs-imperative-migrations)
2. [Zero-Downtime Patterns](#zero-downtime-patterns)
3. [Tool Catalog](#tool-catalog)
   - [pgroll (Xata)](#pgroll)
   - [pg-schema-diff (Stripe)](#pg-schema-diff-stripe)
   - [Reshape](#reshape)
   - [Atlas (Ariga)](#atlas)
   - [migra (DEPRECATED)](#migra)
   - [Alembic](#alembic)
   - [goose](#goose)
   - [dbmate](#dbmate)
   - [sqitch](#sqitch)
   - [Flyway](#flyway)
   - [Liquibase](#liquibase)
   - [Skeema](#skeema)
   - [SchemaHero](#schemahero)
   - [Prisma Migrate](#prisma-migrate)
   - [Bytebase](#bytebase)
   - [gh-ost (GitHub)](#gh-ost)
   - [pt-online-schema-change (Percona)](#pt-online-schema-change)
4. [Rollback Strategies](#rollback-strategies)
5. [Schema Drift Detection](#schema-drift-detection)
6. [Migration Testing Strategies](#migration-testing-strategies)
7. [Post-Mortems & Lessons Learned](#post-mortems--lessons-learned)
8. [Summary Matrix](#summary-matrix)

---

## Declarative vs Imperative Migrations

### Declarative (State-based)

You describe WHAT the schema should look like. The tool diffs current state against desired state and generates the migration plan.

**Advantages:**
- Single source of truth -- one file (or set of files) describes the entire schema. No need to replay N migration files to understand current state.
- Rollback is identical to upgrade: check out old schema, apply. The tool figures out the diff.
- Database introspection: works regardless of what state the live DB is in. Manual changes don't break the tool.
- No unbounded accumulation of migration files.

**Disadvantages:**
- Cannot express renames natively (column rename looks like drop + create, causing data loss).
- Requires database connectivity at plan time (not suitable for air-gapped/on-prem deployments).
- Less control -- you trust the tool's diff algorithm to generate safe SQL.
- Complex data migrations (backfills, transforms) don't fit the declarative model.

**Tools:** Atlas, Skeema, SchemaHero, pg-schema-diff (Stripe), Prisma (hybrid).

### Imperative (Versioned/Change-based)

You describe HOW to get from state A to state B. Ordered, versioned migration files.

**Advantages:**
- Full control over every SQL statement executed.
- Works offline -- migration files are pre-computed, no DB connectivity needed at authoring time.
- Natural audit trail in version control.
- Can express renames, data migrations, and complex multi-step operations.

**Disadvantages:**
- Migration files accumulate without bound. New environment setup slows over time.
- To understand current schema, you must replay all migrations mentally (or run them).
- Developer burden: must manually write safe SQL, handle locks, etc.
- Concurrent development creates merge conflicts and ordering issues.

**Tools:** Alembic, goose, dbmate, sqitch, Flyway, Liquibase.

### Hybrid Approach

Atlas pioneered "versioned migration authoring": declare desired state, tool generates versioned migration files for review. You get declarative ergonomics with imperative control and auditability. Prisma also uses this pattern (schema-as-code generates SQL migration files).

**Best practice:** Use declarative locally during development, switch to versioned for CI/CD and production. This is the Atlas recommendation and increasingly the industry consensus.

Sources:
- https://atlasgo.io/concepts/declarative-vs-versioned
- https://andrewjdawson2016.medium.com/declarative-vs-imperative-schema-management-tools-f8a8c63791a8
- https://www.skeema.io/blog/2019/01/18/declarative/

---

## Zero-Downtime Patterns

### Expand/Contract (Parallel Change)

The gold standard for breaking schema changes without downtime. Three phases:

1. **Expand:** Add new structures (columns, tables) alongside old ones. Old application code is unaware and continues functioning. All changes are additive and backward-compatible.
2. **Migrate:** Deploy new application code that writes to both old and new. Backfill existing data. Switch reads to new. Stop writing to old.
3. **Contract:** Remove old structures once all application code uses the new schema exclusively.

**Rules:**
- Never add a NOT NULL column without a default.
- CREATE INDEX CONCURRENTLY in PostgreSQL (avoids table locks).
- Use small, incremental migrations.
- Test against production-scale data (migration that takes ms on 100 rows may take hours on millions).

**Tools that automate expand/contract:** pgroll, Reshape.

### Online Schema Change (Ghost Tables / Shadow Tables)

Used primarily in MySQL. Creates a shadow copy of the table, applies schema changes to the copy, copies data row by row, then atomically swaps. Two major implementations:

- **gh-ost (GitHub):** Triggerless. Uses binlog to track changes. Lower production impact, greater control (pause/resume/throttle). Does NOT support foreign keys. Requires row-based binlog.
- **pt-online-schema-change (Percona):** Trigger-based. Better FK support. Faster on idle loads but 12% overhead on active tables. Simpler setup.

### Concurrent Index Building

PostgreSQL-specific. `CREATE INDEX CONCURRENTLY` avoids `ACCESS EXCLUSIVE` locks but takes longer and cannot run inside a transaction. pg-schema-diff and pgroll both leverage this automatically.

### Online Constraint Addition

Add constraints as `NOT VALID`, then `VALIDATE CONSTRAINT` separately. The validation only requires a `SHARE UPDATE EXCLUSIVE` lock (allows concurrent reads/writes) rather than `ACCESS EXCLUSIVE`. pg-schema-diff automates this.

### Lock Timeout Strategy

Set `lock_timeout` on migration statements so they fail fast rather than blocking the entire table. GoCardless recommends this as essential for production migrations.

Sources:
- https://xata.io/blog/pgroll-expand-contract
- https://gocardless.com/blog/zero-downtime-postgres-migrations-the-hard-parts/
- https://github.blog/news-insights/company-news/gh-ost-github-s-online-migration-tool-for-mysql/

---

## Tool Catalog

---

### pgroll

| | |
|---|---|
| **URL** | https://github.com/xataio/pgroll |
| **Language** | Go |
| **Database** | PostgreSQL 14+ |
| **Approach** | Automated expand/contract |
| **License** | Apache 2.0 |

**How it works:**
- Creates virtual schemas using **views** on top of physical tables.
- During migration, both old and new schema versions are available simultaneously via different `search_path` settings.
- For breaking column changes: creates new column, backfills from old, sets up **triggers** to keep both columns in sync during transition.
- Completing migration removes old schema, triggers, and renames columns.
- Rollback is instant: abort removes the new schema version, old one remains untouched.

**Key design decisions:**
- JSON-based migration definitions (not SQL).
- Schema versioning via Postgres views -- zero application changes needed beyond search_path.
- Triggers for bidirectional sync during active migration.

**Trade-offs:**
- Write amplification from triggers during active migrations.
- View-based access adds a layer of indirection.
- Limited to PostgreSQL.
- JSON migration format is less familiar than raw SQL.

**Production exposure:**
- Powers Xata's schema change APIs in production.
- 5k+ GitHub stars.
- Benchmarked against PostgreSQL 14.8 through 18.0 with datasets from 10k to 300k rows.

**Lessons:**
- Automates the hardest part of expand/contract (trigger management, view creation) that teams otherwise get wrong manually.
- The instant rollback capability changes the risk calculus of migrations fundamentally.

---

### pg-schema-diff (Stripe)

| | |
|---|---|
| **URL** | https://github.com/stripe/pg-schema-diff |
| **Language** | Go |
| **Database** | PostgreSQL 14-17 |
| **Approach** | Declarative diffing |
| **License** | MIT |

**How it works:**
- Takes plain DDL files as desired state.
- Computes diff between current DB and desired schema.
- Generates SQL migration plan using native Postgres operations for minimal locking.
- **Validates plans against a temporary database** before execution.
- **Hazards system:** warns about potentially dangerous operations (data loss, long locks) that require explicit approval.

**Key design decisions:**
- No shadow tables / stateful techniques -- purely native Postgres operations.
- Online index replacement: builds new index concurrently before dropping old.
- Online NOT NULL via temporary check constraints (avoids table lock).
- Prioritizes index builds over deletions to maintain query performance during migration.
- Statement-level and lock-level timeouts configurable per operation.

**Trade-offs:**
- Cannot track renames (treated as drop + create).
- Only enum types supported (not arbitrary custom types).
- No data migration support.
- Stateful migration techniques (shadow tables) not supported.

**Production exposure:**
- Built and used internally at Stripe -- one of the highest-stakes production environments in tech.
- Battle-tested against Stripe's payment infrastructure.

**Lessons:**
- The hazards system is a key innovation: instead of silently generating dangerous SQL, it forces human acknowledgment.
- Validating against a temporary DB before touching production catches plan-generation bugs.

---

### Reshape

| | |
|---|---|
| **URL** | https://github.com/fabianlindfors/reshape |
| **Language** | Rust |
| **Database** | PostgreSQL 12+ |
| **Approach** | Automated expand/contract |
| **License** | MIT |

**How it works:**
- Similar to pgroll: creates views that encapsulate underlying tables.
- During migration, triggers translate inserts/updates between old and new schemas.
- Application selects schema version via a query at connection time (helper library for Rust).
- `reshape migration abort` rolls back without data loss.
- All changes applied without excessive locking.

**Key design decisions:**
- TOML-based migration definitions.
- Rust helper library embeds schema selection macro directly in application code.
- Designed for Postgres-specific semantics, not cross-database.

**Trade-offs:**
- Smaller community than pgroll.
- Rust helper library means tightest integration is Rust-only (other languages must manage search_path manually).
- Project appears less actively maintained than pgroll (last release check needed).

**Production exposure:**
- Smaller-scale adoption. Created by an individual developer (Fabian Lindfors).

**Lessons:**
- Demonstrated that the expand/contract pattern can be fully automated at the tool level.
- Predecessor/inspiration for pgroll's approach.

---

### Atlas

| | |
|---|---|
| **URL** | https://atlasgo.io / https://github.com/ariga/atlas |
| **Language** | Go |
| **Database** | PostgreSQL, MySQL, SQLite, SQL Server, ClickHouse, Redshift, and more |
| **Approach** | Declarative + versioned hybrid |
| **License** | Apache 2.0 (open core) |

**How it works:**
- Define schema in HCL, SQL, or via ORM providers (GORM, Django, SQLAlchemy, Drizzle).
- `atlas schema apply` -- declarative: diff and apply.
- `atlas migrate diff` -- generate versioned migration file from declarative diff.
- `atlas migrate lint` -- static analysis of migration files for issues.
- `atlas migrate apply` -- run versioned migrations.

**Key design decisions:**
- Hybrid approach: combine declarative ergonomics with versioned auditability.
- Schema-as-code with multiple input formats.
- Built-in linting catches destructive operations, naming violations, etc.
- Drift detection: compare live DB against expected state, alert on divergence.
- Migration directory integrity file prevents concurrent conflicting changes.

**2025-2026 features:**
- Custom schema rules (user-defined linting policies).
- pgvector support for AI/ML workloads.
- Drift detection simplified setup.
- Multi-project ER diagrams.

**Trade-offs:**
- Open core model: some features are paid-only.
- HCL schema format is non-standard (though SQL and ORM inputs are also supported).
- Declarative mode requires DB connectivity.

**Production exposure:**
- Widely adopted. Active development by Ariga (funded company).
- Used across multiple database engines in production.

**Lessons:**
- The hybrid "versioned migration authoring" approach is arguably the best of both worlds.
- ORM provider integration (import schema from your GORM/SQLAlchemy models) dramatically lowers adoption friction.

---

### migra

| | |
|---|---|
| **URL** | https://github.com/djrobstep/migra |
| **Language** | Python |
| **Database** | PostgreSQL |
| **Approach** | Declarative diffing |
| **License** | The Unlicense |
| **Status** | **DEPRECATED** |

**How it worked:**
- "Like diff but for PostgreSQL schemas."
- Connected to two Postgres instances (or schemas) and generated SQL to bring one to parity with the other.
- No migration state tracking -- pure diffing.

**Why it matters:**
- Demonstrated the power of schema diffing as a concept.
- Spiritual predecessor to pg-schema-diff and Atlas's declarative mode.

**Why it died:**
- Solo maintainer project.
- Python ecosystem moved toward Alembic.
- No built-in safety rails (no hazard warnings, no lock management).

---

### Alembic

| | |
|---|---|
| **URL** | https://github.com/sqlalchemy/alembic |
| **Language** | Python |
| **Database** | All SQLAlchemy-supported databases |
| **Approach** | Imperative (with autogenerate) |
| **License** | MIT |

**How it works:**
- Tightly coupled to SQLAlchemy ORM.
- `alembic revision --autogenerate` diffs SQLAlchemy models against live DB and generates migration script.
- Migrations are Python files with `upgrade()` and `downgrade()` functions containing SQLAlchemy operations or raw SQL.
- Branching/merging of migration history supported.

**Key design decisions:**
- Autogenerate is a suggestion, not a guarantee -- manual review is mandatory.
- Migration scripts can contain arbitrary Python code (data migrations, conditionals).
- Batch operations for SQLite (which doesn't support ALTER TABLE well).
- Naming conventions configurable for constraints/indexes.

**Limitations:**
- Autogenerate cannot detect: table/column renames, changes to constraints in some cases, changes to server defaults, changes to `Enum` values on some backends.
- No built-in zero-downtime support.
- No linting or hazard warnings.
- CI/CD integration is DIY.

**Production exposure:**
- The standard migration tool for the Python/SQLAlchemy ecosystem.
- Extremely widely deployed. Current version 1.18.4.

**Lessons:**
- Autogenerate is a massive DX win but creates a false sense of safety. Teams that skip manual review get burned.
- The tight SQLAlchemy coupling is both its greatest strength (model-aware diffs) and its limitation (can't use without SQLAlchemy).

Sources:
- https://alembic.sqlalchemy.org/en/latest/autogenerate.html
- https://atlasgo.io/blog/2025/02/10/the-hidden-bias-alembic-django-migrations

---

### goose

| | |
|---|---|
| **URL** | https://github.com/pressly/goose |
| **Language** | Go |
| **Database** | Postgres, MySQL, SQLite, ClickHouse, YDB, Spanner, MSSQL, Vertica |
| **Approach** | Imperative (SQL or Go functions) |
| **License** | MIT |

**How it works:**
- Migrations are SQL files with `-- +goose Up` and `-- +goose Down` annotations.
- Alternatively, migrations can be Go functions for complex logic.
- Sequential or timestamp-based versioning.
- Embedded migrations supported (embed migration files in Go binary).

**Key design decisions:**
- `-- +goose NO TRANSACTION` annotation for statements that can't run in transactions (e.g., `CREATE DATABASE`, `CREATE INDEX CONCURRENTLY`).
- Environment variable substitution in SQL migrations.
- Out-of-order migration support (opt-in).
- Both CLI and library usage.

**Trade-offs:**
- No autogenerate / schema diffing.
- No built-in linting or safety checks.
- Simple by design -- lacks advanced features of Atlas.

**Production exposure:**
- Very widely used in Go ecosystem.
- Active maintenance, frequent releases.

**Lessons:**
- The `NO TRANSACTION` annotation is critical for Postgres -- without it, concurrent index creation fails silently.
- Go function migrations enable complex data transformations that SQL-only tools can't handle.

---

### dbmate

| | |
|---|---|
| **URL** | https://github.com/amacneil/dbmate |
| **Language** | Go (standalone binary) |
| **Database** | PostgreSQL, MySQL, SQLite, ClickHouse |
| **Approach** | Imperative (SQL files) |
| **License** | MIT |

**How it works:**
- Plain SQL migration files with `-- migrate:up` and `-- migrate:down` sections.
- Timestamp-versioned to avoid conflicts.
- Atomic transactions per migration.
- `dbmate dump` saves `schema.sql` for easy git diffing.
- Database URL via environment variable (`DATABASE_URL`).

**Key design decisions:**
- Language-agnostic: single binary, no runtime dependency.
- Schema dump file enables reviewing schema changes in PRs.
- Simple command set: new, up, down, create, drop, dump, wait.

**Trade-offs:**
- No Go function migrations (SQL only).
- No autogenerate.
- No advanced features (linting, drift detection, zero-downtime).

**Production exposure:**
- Popular for polyglot teams. Simple and reliable.

**Lessons:**
- The `schema.sql` dump is underrated -- it gives you a declarative view of your schema even when using imperative migrations.
- `dbmate wait` is useful in Docker/CI environments (waits for DB to be ready).

---

### sqitch

| | |
|---|---|
| **URL** | https://sqitch.org / https://github.com/sqitchers/sqitch |
| **Language** | Perl |
| **Database** | PostgreSQL, MySQL, SQLite, Oracle, Firebird, Vertica, Exasol, Snowflake |
| **Approach** | Imperative (dependency-graph based) |
| **License** | MIT |

**How it works:**
- Changes are native SQL scripts for your specific database engine.
- Plan file tracks change ordering with Merkle tree integrity (like git).
- Changes can declare dependencies on other changes, even across projects.
- Iterative development: scripts can be modified freely until tagged/released.

**Key design decisions:**
- **No ORM, no framework, no abstraction.** Pure SQL, native to your DB engine.
- **Dependency-driven execution** rather than sequential numbering.
- **Merkle tree integrity** prevents accidental wrong-order application.
- **Cross-project dependencies** for microservice architectures.

**Trade-offs:**
- Perl dependency (though Docker images available).
- Steeper learning curve than simple numbered migrations.
- No autogenerate or schema diffing.
- Smaller community than alternatives.

**Production exposure:**
- Used by organizations that need cross-database, framework-independent migrations.
- Mature project (started ~2012).

**Lessons:**
- Dependency-based ordering is more correct than sequential numbering for large teams.
- The Merkle tree integrity check catches a class of bugs that other tools miss entirely.

---

### Flyway

| | |
|---|---|
| **URL** | https://flywaydb.org |
| **Language** | Java |
| **Database** | 22+ databases |
| **Approach** | Imperative (SQL files) |
| **License** | Apache 2.0 (Community) / Commercial (Enterprise) |

**How it works:**
- Versioned SQL scripts named with convention (e.g., `V1__description.sql`).
- Scans migration directory, applies in order, tracks in `flyway_schema_history` table.
- Repeatable migrations (R__ prefix) for views/procedures that should be re-applied.

**Key design decisions:**
- Convention over configuration. Minimal setup.
- Java callbacks for hooks (before/after migrate, etc.).
- Baseline support for brownfield databases.

**2025 licensing changes:**
- Only Community (free) and Enterprise (paid) tiers remain. Teams tier discontinued.
- **Rollback is Enterprise-only.** Community cannot roll back.

**Trade-offs:**
- Java dependency (JVM required).
- No declarative mode.
- Rollback is paid-only and requires manually written undo scripts.
- Limited linting.

**Production exposure:**
- One of the most widely deployed migration tools. Massive enterprise adoption.
- Acquired by Redgate.

**Lessons:**
- The "convention over configuration" approach is Flyway's superpower and its limitation.
- Enterprise-only rollback is a controversial decision that pushes some users to alternatives.

---

### Liquibase

| | |
|---|---|
| **URL** | https://www.liquibase.com |
| **Language** | Java |
| **Database** | 50+ databases |
| **Approach** | Imperative (XML/YAML/JSON/SQL changelogs) |
| **License** | Apache 2.0 (OSS) / Commercial (Pro) |

**How it works:**
- Changesets defined in XML, YAML, JSON, or SQL changelogs.
- Each changeset has a unique ID, author, and set of changes.
- Preconditions gate changeset execution (e.g., "only run if table exists").
- Rollback support built-in (auto-generated for simple changes, manual for complex).

**Key design decisions:**
- Database-agnostic change types (e.g., `addColumn`, `createTable`) that generate DB-specific SQL.
- Preconditions enable conditional execution.
- Contexts and labels for environment-specific migrations.

**Liquibase 5.0 (September 2025):**
- Java 17 minimum.
- AI Changelog Generator.
- Enhanced rollback reporting.
- Liquibase Secure 5.0.

**Trade-offs:**
- XML changelogs are verbose and disliked by many developers.
- Java dependency.
- Complex feature set has steep learning curve.
- Best features are paid.

**Production exposure:**
- Extremely widely deployed in enterprise. 50+ database support is unmatched.
- Long track record (started 2006).

**Lessons:**
- The changelog abstraction layer enables database portability but adds complexity.
- Preconditions are powerful for multi-environment deployments but rarely used well.

---

### Skeema

| | |
|---|---|
| **URL** | https://www.skeema.io / https://github.com/skeema/skeema |
| **Language** | Go |
| **Database** | MySQL, MariaDB |
| **Approach** | Declarative (pure SQL) |
| **License** | Apache 2.0 (Community) / Commercial (Premium) |

**How it works:**
- Each table/routine stored as its own CREATE statement file.
- `skeema diff` shows what would change.
- `skeema push` applies changes to bring DB to declared state.
- `skeema pull` updates local files from live DB.
- Can delegate large table changes to pt-online-schema-change or gh-ost.

**Key design decisions:**
- Pure SQL -- no DSL, no YAML, no abstraction. CREATE TABLE IS the schema definition.
- One file per object for clean git history.
- Multiple named environments (dev, staging, prod) in configuration.
- Integration with online schema change tools for large tables.

**Trade-offs:**
- MySQL/MariaDB only.
- Views, triggers, events are Premium-only.
- No built-in data migration support.

**Production exposure:**
- 1.5M+ downloads since 2016. 60,000+ installs/month.
- Used by large public tech companies.

**Lessons:**
- Pure SQL as schema definition is the most readable and portable format.
- Delegating large-table changes to specialized tools (gh-ost, pt-osc) is pragmatic.

---

### SchemaHero

| | |
|---|---|
| **URL** | https://schemahero.io / https://github.com/schemahero/schemahero |
| **Language** | Go |
| **Database** | PostgreSQL, MySQL, SQLite, CockroachDB |
| **Approach** | Declarative (Kubernetes CRDs) |
| **License** | Apache 2.0 |

**How it works:**
- Database table schemas expressed as Kubernetes Custom Resources (YAML).
- SchemaHero Operator watches for changes, diffs desired vs actual, generates ALTER TABLE.
- Integrates with GitOps tools (ArgoCD, Flux).

**Key design decisions:**
- Kubernetes-native: schema changes are just another `kubectl apply`.
- No migration history needed -- operator always diffs current vs desired.
- Can manage both in-cluster and external databases (RDS, CloudSQL).

**Trade-offs:**
- Requires Kubernetes. Not usable outside K8s.
- YAML schema definition is less expressive than SQL.
- Limited database feature coverage vs native SQL.

**Production exposure:**
- Niche adoption within Kubernetes-heavy organizations.
- CNCF sandbox project (was).

---

### Prisma Migrate

| | |
|---|---|
| **URL** | https://www.prisma.io/docs/orm/prisma-migrate |
| **Language** | TypeScript/JavaScript |
| **Database** | PostgreSQL, MySQL, SQLite, SQL Server, CockroachDB |
| **Approach** | Hybrid (declarative schema, generated SQL migrations) |
| **License** | Apache 2.0 |

**How it works:**
- Schema defined in Prisma Schema Language (`.prisma` files).
- `prisma migrate dev` diffs schema against DB, generates SQL migration file.
- Generated SQL is fully customizable before applying.
- `prisma migrate deploy` runs pending migrations in production.

**Limitations:**
- No data migration orchestration. Schema and data migrations are separate concerns.
- Provider-specific SQL: can't share migrations between Postgres and SQLite.
- Development mode may prompt for destructive DB reset on drift detection.
- No MongoDB support for migrations.
- No built-in zero-downtime support.

**Production exposure:**
- Widely used in Node.js/TypeScript ecosystem.

---

### Bytebase

| | |
|---|---|
| **URL** | https://www.bytebase.com / https://github.com/bytebase/bytebase |
| **Language** | Go + TypeScript |
| **Database** | 20+ databases |
| **Approach** | Platform (wraps migration workflow) |
| **License** | Open source + Commercial |

**Not a migration tool per se, but a migration workflow platform:**
- Visual CI/CD pipelines for database changes.
- Schema review with 100+ SQL lint rules.
- Approval workflows with role-based access.
- Drift detection (background process compares live DB vs recorded schema).
- GitOps integration.
- One-click rollback capability.

**Production exposure:**
- Growing enterprise adoption. Positions itself as "GitHub/GitLab for database DevSecOps."

---

### gh-ost

| | |
|---|---|
| **URL** | https://github.com/github/gh-ost |
| **Language** | Go |
| **Database** | MySQL |
| **Approach** | Online schema change (shadow table, binlog-based) |
| **License** | MIT |

**How it works:**
- Creates ghost (shadow) table with desired schema.
- Copies rows from original table to ghost table.
- Uses **binlog** (not triggers) to capture ongoing changes during copy.
- Atomically swaps tables when copy is complete.

**Key design decisions:**
- **Triggerless:** Unlike pt-osc, does not create triggers on the original table. This avoids trigger overhead and contention.
- **Pausable and throttleable:** When throttled, truly ceases all writes to master.
- **Dynamic reconfiguration:** Can change parameters while migration is running.
- **Testable in production:** GitHub runs continuous migration tests on designated production replicas that don't serve traffic, checksumming entire table data.
- **Postponable cutover:** Can be instructed to wait for human approval before final table swap.

**Trade-offs:**
- **No foreign key support.**
- Requires row-based binlog format.
- Single-threaded binlog processing -- can't keep up under very heavy write loads.
- Slower than pt-osc on idle tables (but lower production impact).

**Production exposure:**
- Created at GitHub because pt-osc was causing MySQL outages under their scale.
- Every single GitHub production table has passed multiple successful gh-ost migrations on replica.
- Battle-tested at massive scale.

**Lessons:**
- GitHub's testing strategy (continuous migration tests on production replicas) is the gold standard.
- The move from trigger-based to binlog-based was driven by real production pain.

---

### pt-online-schema-change

| | |
|---|---|
| **URL** | https://docs.percona.com/percona-toolkit/pt-online-schema-change.html |
| **Language** | Perl |
| **Database** | MySQL, MariaDB |
| **Approach** | Online schema change (shadow table, trigger-based) |
| **License** | GPL v2 |

**How it works:**
- Creates shadow table, copies data, uses **triggers** on original table to capture ongoing DML.
- Atomically renames tables when complete.

**vs gh-ost:**
- ~2x faster on idle loads.
- Supports foreign keys (gh-ost does not).
- 12% performance overhead from triggers during migration.
- Less control (no pause/resume/dynamic reconfiguration).

**Production exposure:**
- Industry standard for MySQL online DDL for years before gh-ost.
- Used at scale across thousands of organizations.

---

## Rollback Strategies

### The Four Levels (per pgroll team)

**Level 0 -- No strategy:** Ad-hoc manual fixes in production. Common in early startups. Dangerous.

**Level 1 -- Down scripts:** Paired up/down SQL for each migration. Better than nothing but:
- Down scripts are almost never tested.
- Partial failures leave DB in inconsistent state.
- Human error in writing rollback SQL.
- Cannot recover data from destructive changes (dropped columns).

**Level 2 -- Manual expand/contract:** Three-phase approach with backward-compatible changes. Original schema remains intact until contract phase, so "rollback" is just "don't contract." Dramatically safer but high manual effort.

**Level 3 -- Automated expand/contract:** Tools like pgroll and Reshape handle the mechanics automatically. Fewer human errors, faster, more reliable rollback execution.

### Why Rollback Is Fundamentally Hard

- **Databases are stateful.** Unlike application code, you can't just redeploy the old version.
- **New data arrives during migration.** Rolling back means deciding what happens to data written to the new schema.
- **Destructive changes are irreversible.** If you dropped a column and rolled back the migration, the data is gone.
- **Rollback scripts can fail too.** An untested rollback that fails leaves you worse off than before.
- **Partial rollbacks break integrity.** Rolling back one migration but not others can violate foreign keys, constraints.

### Roll Forward vs Roll Back

Growing industry consensus: **roll forward** (fix the new state) rather than rolling back. Rationale:
- Eliminates the entire class of rollback-related failures.
- Forces investment in monitoring and fast-fix capabilities.
- Better aligned with continuous deployment.
- Expand/contract makes this natural: if the new version has a bug, fix it and re-deploy; old schema is still serving.

Sources:
- https://pgroll.com/blog/levels-of-a-database-rollback-strategy
- https://atlasgo.io/blog/2024/11/14/the-hard-truth-about-gitops-and-db-rollbacks
- https://www.liquibase.com/blog/database-rollbacks-the-devops-approach-to-rolling-back-and-fixing-forward

---

## Schema Drift Detection

**What is drift?** The live database schema differs from the source of truth (migration history, declarative schema files, or ORM models). One of the most frequent root causes of database-related outages.

**Causes:**
- Manual changes by engineers ("just this once" in production).
- Failed migrations that partially applied.
- Multiple deployment pipelines applying changes independently.
- ORM model changes without corresponding migrations.

**Detection approaches:**
- **Atlas:** Automatically compares live DB against declared schema. Alerts on divergence. Can be set up as periodic monitoring.
- **Bytebase:** Background process periodically compares recorded schema vs live DB.
- **Migration-based:** Query migration tracking table + system catalogs. Compare history vs live schema.
- **Skeema:** `skeema diff` shows divergence between local files and live DB.

**Prevention:**
- Incorporate schema validation in CI/CD pipelines.
- Version control all schema changes (no manual DDL in production).
- Use tools with drift detection (Atlas, Bytebase).
- Regular audits comparing expected vs actual schema.

Sources:
- https://atlasgo.io/monitoring/drift-detection
- https://www.bytebase.com/blog/what-is-database-schema-drift/

---

## Migration Testing Strategies

### Pre-Production Validation

1. **Run migrations against a clone of production.** Not a toy database with 100 rows -- actual production-scale data. A migration taking ms on test data may take hours on millions of rows.

2. **Validate migration plans against a temporary database** (pg-schema-diff approach). Execute the exact plan against a disposable DB to catch SQL errors before touching production.

3. **Backward compatibility testing.** Run old application code against new schema (and vice versa) to catch incompatibilities. Val Town learned this the hard way.

4. **Schema linting in CI.** Atlas `migrate lint`, Bytebase's 100+ SQL rules, custom policies. Catches anti-patterns before review.

### CI/CD Integration

- Run migrations in CI against a fresh database to verify they apply cleanly.
- Check migration file integrity (Atlas's integrity file, sqitch's Merkle tree).
- Lint for dangerous operations (DROP TABLE without confirmation, missing indexes, etc.).
- Verify both upgrade AND downgrade paths.
- Test data migrations with realistic data volumes.

### Production Safeguards

- **Lock timeouts.** Set `lock_timeout` and `statement_timeout` to fail fast rather than blocking.
- **Staged rollout.** Apply to canary/staging environment first, soak, then production.
- **Pre-deployment snapshots.** Always have a restore point.
- **Monitoring.** Watch for lock contention, query latency, error rates during migration.
- **GitHub's strategy (gh-ost):** Continuous migration tests on production replicas not serving traffic. Checksum entire table data. Every production table verified.

---

## Post-Mortems & Lessons Learned

### GitLab Database Outage (January 2017)

**What happened:** Accidental data removal from primary database. Cascading failures across replication, backups.

**Root cause:** Automated spam detection system + manual database operations + backup systems that were not actually working.

**Key lessons:**
- Test your backups. GitLab discovered their backup systems weren't functioning correctly during the incident.
- Automated systems triggering manual interventions on databases is a dangerous pattern.
- Transparent post-mortems (GitLab live-streamed the recovery) build trust.

### Linear Database Incident (January 2024)

**What happened:** Database migration accidentally deleted production data. Service entered maintenance mode. Recovery from backup took two days.

**Changes implemented:**
- Database admin review separate from code review.
- Linting for dangerous operations (DROP, DELETE).
- Automated testing of migrations in staging before production.

### Val Town Backward-Incompatible Migration (2024)

**What happened:** 12-minute outage. Database migrations deployed successfully, but application code deployment hung. Old application code crashed against new schema because migrations were not backward-compatible.

**Timeline:**
- 10:11 -- code merged
- 10:16 -- outage reported
- 10:19 -- rollback attempt failed due to migration constraints
- 10:22 -- fix deployed
- 10:28 -- service restored

**Root cause:** Deployment timing mismatch. Migrations ran before new app code was live. Old code + new schema = crash.

**Fix:** Added automated test ensuring all database migrations maintain backward compatibility with previous application version.

**Key lesson:** **Migrations MUST be backward-compatible with the currently running application code.** This is the expand/contract pattern in its simplest form: expand first, deploy new code, then contract.

### GoCardless: Zero-Downtime Postgres Hard Parts

**Key findings from production:**
- Adding foreign keys requires `AccessExclusive` locks on BOTH referencing and referenced tables.
- Lock queue blocking: even fast schema changes cause downtime if they queue behind existing locks. Locks conflict with queued locks and cascade.
- Solutions: set `lock_timeout`, eliminate long-running queries via analytics replicas, add constraints as `NOT VALID` then validate separately, split changes into smaller transactions.

Sources:
- https://about.gitlab.com/blog/postmortem-of-database-outage-of-january-31/
- https://linear.app/now/linear-incident-on-jan-24th-2024
- https://blog.val.town/post-mortem-db-migration
- https://gocardless.com/blog/zero-downtime-postgres-migrations-the-hard-parts/

---

## Summary Matrix

| Tool | Language | DBs | Approach | Zero-DT | Rollback | Drift Detection | Battle-Tested |
|------|----------|-----|----------|---------|----------|-----------------|---------------|
| **pgroll** | Go | PG | Expand/contract | Yes (automated) | Instant | No | Xata prod |
| **pg-schema-diff** | Go | PG | Declarative diff | Yes (native ops) | N/A (declarative) | Via diffing | Stripe prod |
| **Reshape** | Rust | PG | Expand/contract | Yes (automated) | Yes | No | Small-scale |
| **Atlas** | Go | Multi | Hybrid decl+ver | Partial | Via declarative | Yes | Wide adoption |
| **migra** | Python | PG | Declarative diff | No | N/A | Via diffing | DEPRECATED |
| **Alembic** | Python | Multi (via SA) | Imperative+autogen | No | Manual down() | No | Extremely wide |
| **goose** | Go | Multi | Imperative | No | Manual down | No | Very wide |
| **dbmate** | Go | Multi | Imperative | No | Manual down | No | Wide |
| **sqitch** | Perl | Multi | Imperative (deps) | No | Manual revert | No | Moderate |
| **Flyway** | Java | 22+ | Imperative | No | Enterprise-only | No | Massive enterprise |
| **Liquibase** | Java | 50+ | Imperative | No | Built-in (limited) | Yes (Pro) | Massive enterprise |
| **Skeema** | Go | MySQL | Declarative SQL | Via ext tools | Via declarative | Via diff | 1.5M+ downloads |
| **SchemaHero** | Go | Multi | Declarative K8s | No | Via declarative | Via operator | Niche (K8s) |
| **Prisma** | TS/JS | Multi | Hybrid | No | Manual | Dev mode only | Wide (Node.js) |
| **Bytebase** | Go+TS | 20+ | Platform | No | One-click (UI) | Yes | Growing enterprise |
| **gh-ost** | Go | MySQL | Online schema change | Yes | Abort migration | No | GitHub prod |
| **pt-osc** | Perl | MySQL | Online schema change | Yes | Abort migration | No | Industry standard |

---

## Key Takeaways

1. **For Postgres zero-downtime migrations:** pgroll (automated expand/contract) or pg-schema-diff (declarative with native ops) are the state of the art. pgroll if you want automated multi-version serving; pg-schema-diff if you want declarative diffing with hazard warnings.

2. **For schema-as-code with safety:** Atlas is the most complete offering -- hybrid declarative+versioned, multi-DB, linting, drift detection.

3. **Expand/contract is the winning pattern.** It makes rollback trivial (just don't contract), maintains backward compatibility, and enables true zero-downtime. pgroll and Reshape automate it; everyone else requires manual implementation.

4. **Rollback is overrated; roll-forward is underrated.** Industry is moving toward "fix forward" rather than maintaining untested rollback scripts. Expand/contract makes this natural.

5. **Test migrations against production-scale data.** The #1 lesson from post-mortems. GitHub's approach (continuous migration tests on production replicas) is the gold standard.

6. **Migrations must be backward-compatible with currently-running code.** The Val Town outage is the canonical example of what happens when they're not.

7. **Set lock_timeout.** The GoCardless lesson: even fast schema changes can cause cascading lock contention. Fail fast, retry later.


---

## Agent Session Transcript

Full conversation transcript (all tool calls, searches, and reasoning):
`/Users/dzaramelcone/.claude/projects/-Users-dzaramelcone-lab-snek/9e16eb4e-374d-4279-9404-5ebd626d6d45/subagents/agent-abf0aaacb00410f2b.jsonl`
