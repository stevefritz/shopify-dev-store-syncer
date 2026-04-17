# p2d — Prod-to-Dev Data Sync

p2d is a self-hosted Rails 8 tool that copies Shopify catalog data one-way from a production store to one or more dev stores. It is a developer utility — never a hosted service, never multi-tenant. You run it locally, point it at your stores, and it keeps your dev store's catalog in sync with production so you can work against realistic data without touching prod.

## Quickstart

```bash
# 1. Clone and enter the repo
git clone <repo-url> && cd <repo-dir>

# 2. Start Postgres (for development)
docker-compose up -d db

# 3. Install dependencies
bundle install

# 4. Set up the database (runs migrations + seed)
cp .env.test.example .env  # fill in ADMIN_EMAIL and ADMIN_PASSWORD
bin/rails db:setup

# 5. Start the server
bin/rails server
# → http://localhost:3000
```

**Running tests** (no external services needed — uses SQLite):

```bash
bin/rails test
```

## Design docs

- [Architecture](docs/domain-breakdown.md)
- [Validation plan](docs/validation-plan.md)
- [Decisions log](docs/decisions.md)
