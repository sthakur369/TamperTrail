# VeriLog — CTO & Security Architecture Guide

**Audience:** Chief Technology Officers, Chief Security Officers, Principal Engineers, and Security Auditors.

**Purpose:** A transparent, technically rigorous description of VeriLog's internal architecture, security model, cryptographic guarantees, performance engineering, and the shared responsibility framework governing the boundary between what VeriLog protects and what the customer must protect.

---

## Table of Contents

1. [Executive Summary & Design Philosophy](#1-executive-summary--design-philosophy)
2. [High-Level System Architecture](#2-high-level-system-architecture)
3. [Performance & Scalability Mechanics](#3-performance--scalability-mechanics)
4. [Security & Cryptography Deep Dive](#4-security--cryptography-deep-dive)
5. [Data Lifecycle & Retention Governance](#5-data-lifecycle--retention-governance)
6. [Shared Responsibility Model](#6-shared-responsibility-model)
7. [Compliance Readiness Posture](#7-compliance-readiness-posture)
8. [Infrastructure Topology & Deployment Model](#8-infrastructure-topology--deployment-model)

---

## 1. Executive Summary & Design Philosophy

VeriLog is a **self-hosted, immutable audit vault** designed to give engineering and compliance teams cryptographically verifiable evidence that a sequence of events occurred, was not modified, and was not silently deleted — without surrendering that data to a third-party cloud provider.

### The Problem It Solves

Modern compliance frameworks (SOC 2, ISO 27001, HIPAA, GDPR) require organizations to maintain tamper-evident audit trails. The standard industry response is to ship logs to a SaaS platform. This approach has two fundamental problems:

1. **Data Sovereignty:** Sensitive operational and user-behavioral data leaves your infrastructure boundary permanently.
2. **Verifiability:** You cannot independently verify that a SaaS audit log has not been modified. You are trusting the vendor's word.

VeriLog eliminates both problems. Logs never leave your infrastructure, and mathematical proof of integrity is built into every write.

### Core Architectural Principles

| Principle | Implementation |
|-----------|---------------|
| **Zero external dependencies at runtime** | All components run as Docker containers. No cloud APIs, no third-party SDKs, no outbound network calls. |
| **Immutability by cryptographic construction** | Every log entry is SHA-256 hashed and chained to its predecessor. Tampering breaks the chain in a mathematically verifiable way. |
| **Encryption before persistence** | Sensitive `metadata` is Fernet-encrypted in application memory before it is passed to the database driver. The database never receives plaintext for this field. |
| **Zero-config security** | Cryptographic secrets (encryption key, JWT secret, database password) are generated automatically on first boot. No engineer is required to choose or manage them. |
| **Defense-in-depth** | Security is enforced at four independent layers: Nginx (network), FastAPI middleware (application), SQLAlchemy (query), and PostgreSQL RLS (database). A bypass at any single layer does not compromise the system. |

### Technology Selection Rationale

The stack — **React + FastAPI (Python) + PostgreSQL + Nginx** — was chosen deliberately:

- **FastAPI** over Node.js/Express: Native async/await, Pydantic for strict input validation at the schema layer, and Python's mature cryptography ecosystem (`cryptography` library with OpenSSL-backed AES).
- **PostgreSQL** over NoSQL: ACID guarantees, native JSONB with GIN indexing (combining document-store flexibility with relational integrity), and Row-Level Security for multi-tenant enforcement at the database engine level.
- **Nginx** over application-layer rate limiting: Network-layer enforcement is not bypassable by application bugs. Nginx's `limit_req_zone` operates before a single Python byte is executed.
- **Docker Compose** over Kubernetes (for self-hosted tier): Deployment simplicity is itself a security property — complex orchestration introduces additional attack surface for self-hosted deployments.
- **SQLAlchemy + Alembic**: Parameterized query construction (eliminating SQL injection by construction) and a full, auditable migration history for the database schema.

---

## 2. High-Level System Architecture

The system is composed of **four runtime layers**, each with a clearly defined responsibility boundary.

```
        ┌─────────────────────────────────────────────────────┐
        │                   CLIENT TRAFFIC                    │
        │          (Developers, Dashboards, Monitors)         │
        └──────────────────────┬──────────────────────────────┘
                               │ :80
        ┌──────────────────────▼──────────────────────────────┐
        │               LAYER 1 — NGINX GATEWAY               │
        │  Rate limiting · Request size caps · Security hdrs  │
        │  Reverse proxy to FastAPI · Serves React SPA files  │
        │              [ verilog-client container ]           │
        └──────────┬────────────────────────────┬─────────────┘
                   │ /v1/* (API calls)           │ /* (SPA assets)
        ┌──────────▼──────────────────┐   ┌──────▼────────────┐
        │   LAYER 2 — FASTAPI ENGINE  │   │  React SPA files  │
        │ Validation · Auth · Hashing │   │  (static, nginx)  │
        │ Encryption · WAL · Batching │   └───────────────────┘
        │   [ verilog-server :8000 ]  │
        └──────────┬──────────────────┘
                   │ asyncpg (async SQL, connection pool)
        ┌──────────▼──────────────────────────────────────────┐
        │           LAYER 3 — POSTGRESQL DATABASE             │
        │  audit_logs · JSONB GIN index · encrypted metadata  │
        │   Row-Level Security · Alembic-managed migrations   │
        │              [ verilog-db container ]               │
        └─────────────────────────────────────────────────────┘
```

---

### 2.1 Layer 1 — The API Gateway (Nginx)

**Container:** `verilog-client` | **Exposed:** Port 80 (only publicly accessible port)

The FastAPI backend is bound to `verilog-server:8000` **inside the Docker network** and is never directly reachable from outside. All external traffic — API calls and dashboard requests — enters exclusively through Nginx.

**Responsibilities:**

- **Reverse Proxy:** Forwards `/v1/*` to `verilog-server:8000`. Injects `X-Forwarded-For` and `X-Real-IP` for accurate IP attribution in logs.
- **Rate Limiting** (per IP, `limit_req_zone` with `nodelay`):
  - `POST /v1/auth/login`: 5 req/min — renders brute-force attacks infeasible
  - `POST /v1/log`: 100 req/min — prevents runaway services from flooding the WAL
  - All other `/v1/*`: 200 req/min
- **Request Size Limiting** (`client_max_body_size`): Oversized payloads are rejected at the network layer before any Python memory is allocated, preventing memory exhaustion attacks.
- **Security Headers** (enforced on every response): `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy`, `Strict-Transport-Security`, `Referrer-Policy: no-referrer`.
- **OpenAPI Suppression:** `/docs`, `/redoc`, and `/openapi.json` are explicitly blocked, preventing public API schema discovery.
- **Static Serving:** The pre-built React SPA is served directly as static files — no Node.js runtime in production.

---

### 2.2 Layer 2 — The Backend Engine (FastAPI / Python)

**Container:** `verilog-server` | **Internal port:** 8000

The application brain. Handles authentication, validation, encryption, hash computation, and asynchronous log ingestion.

#### Ingestion Pipeline (sub-10ms response path)

1. API key validated via Argon2id hash comparison.
2. `LogIngestRequest` Pydantic schema enforces field constraints — invalid payloads rejected with `422` before processing.
3. `LogItem` immediately appended to the **Write-Ahead Log** (`/app/data/queue.wal` on the `server_data` volume) — durable before `202 Accepted` is returned.
4. Item placed on `asyncio.Queue`. HTTP handler returns — it does not wait for the database.
5. Background `IngestionService` worker drains the queue in micro-batches: encrypts `metadata`, computes hash chain, executes a single bulk `INSERT` for the entire batch.
6. WAL position file (`queue.wal.pos`) updated only after DB transaction commits. On crash/restart, uncommitted entries replay automatically.

#### Schema & Migrations

**Alembic** manages all database schema migrations. `start.sh` runs `alembic upgrade head` on every container start, guaranteeing schema–code consistency with a full auditable migration history. **SQLAlchemy** (async mode via `asyncpg`) handles all queries using parameterized expressions — raw SQL string concatenation is not used anywhere in the codebase.

---

### 2.3 Layer 3 — The Storage Layer (PostgreSQL)

**Container:** `verilog-db` | **Persistence:** `postgres_data` Docker volume

**Dual-storage strategy** in the `audit_logs` table:

| Column | Type | Encrypted | GIN Indexed | Purpose |
|--------|------|-----------|------------|---------|
| `tags` | JSONB | ❌ Plaintext | ✅ Yes | Searchable context — fast dashboard filtering |
| `metadata` | BYTEA | ✅ Fernet AES-128 | ❌ N/A | Sensitive forensic payload — opaque binary blob |

This split is deliberate: encrypting `tags` would make them unsearchable (ciphertext is opaque to the query planner). VeriLog achieves both **search performance** on structured context and **cryptographic privacy** for sensitive payload data simultaneously.

**Row-Level Security (RLS):** PostgreSQL RLS policies enforce tenant isolation at the database engine layer — a defense-in-depth backstop independent of application-layer filtering.

---

### 2.4 Layer 4 — The Presentation Layer (React SPA)

**Served by:** Nginx (static files — no runtime server) | **Role:** Strictly read-only viewer

The React frontend **never receives the `metadata` field**. The `LogEntryOut` API response schema structurally excludes it — the `encrypted_metadata` BYTEA column is dropped before serialization. A complete compromise of the React application (XSS, supply chain attack) cannot expose the encrypted vault because that data is architecturally never transmitted to the browser.

---

## 3. Performance & Scalability Mechanics

### 3.1 Ingestion Speed — Async Micro-Batching

The most common bottleneck in audit logging is synchronous per-entry database writes. At 100 logs/second, this means 100 PostgreSQL round-trips per second with individual transaction overhead.

VeriLog's solution:
- The HTTP handler enqueues items on `asyncio.Queue` in sub-microsecond time.
- A background coroutine drains the queue in batches (up to 500 items per batch, 50ms flush interval).
- Each batch executes a **single parameterized `INSERT ... VALUES (...)`** with multiple rows — one DB round-trip for hundreds of entries.
- **asyncpg** maintains a persistent connection pool — no connection establishment on the hot path.

**Result:** `POST /v1/log` response latency is bounded by WAL disk write time (1–3ms on SSD), not database latency. The system sustains thousands of ingestion requests per second on standard hardware before the database becomes a bottleneck.

### 3.2 WAL Durability Guarantee

| Event | Behavior |
|-------|---------|
| `202 Accepted` returned | Entry is durable on disk in WAL file — guaranteed |
| Server crash mid-batch | On restart, worker replays all WAL entries not confirmed in `.wal.pos` — zero data loss |
| Sustained overload (queue growing faster than DB drain) | WAL enforces a maximum file size — new writes return `503` rather than silently failing or causing unbounded disk growth |

### 3.3 Search Speed — PostgreSQL GIN Indexing

The `tags` JSONB column carries a **Generalized Inverted Index (GIN)**. GIN indexes decompose JSONB into individual key-value pairs and index each independently, enabling:

- **JSONB containment** (`tags @> '{"plan":"pro"}'`): Used by the `meta_contains` API parameter — leverages the GIN index for near-constant query time regardless of table size.
- **Universal text search**: The `search` parameter performs `ILIKE '%term%'` across actor, action, message, environment, IP, tags-cast-to-text, and hash simultaneously in a single `OR` predicate.

Sub-10ms dashboard searches across millions of log entries are achievable on standard PostgreSQL hardware.

### 3.4 Resource Protection — Nginx Request Size Limiting

Python's JSON deserialization of an arbitrarily large payload consumes memory proportional to payload size. Nginx's `client_max_body_size` directive rejects oversized requests **before** they reach the Python process, returning `413 Request Entity Too Large` with zero Python memory allocation.

---

## 4. Security & Cryptography Deep Dive

### 4.1 The Immutable Ledger — SHA-256 Hash Chaining

Every `audit_logs` row carries two hash fields:

| Field | Content |
|-------|---------|
| `prev_hash` | The `hash` of the immediately preceding entry (same tenant, chronological order) |
| `hash` | SHA-256 digest of this entry's canonical representation |

**Hash input** (deterministic concatenation): `prev_hash + created_at + actor + action + target_type + target_id + hex(metadata_cipher)`

Including the **hex-encoded ciphertext** of `metadata` in the hash means that modifying the encrypted bytes — even without the decryption key — breaks the chain. The first entry of each tenant uses a fixed `GENESIS_HASH` (SHA-256 of `"GENESIS"`) as `prev_hash`.

**Tamper detection (`GET /v1/verify`):** For each entry in chronological order, the server recomputes the expected hash from stored fields and asserts `entry.prev_hash == previous_entry.hash`. Any deletion, modification, or insertion produces a broken link at that position — detectable without any external oracle.

**What this proves to an auditor:** If verification returns `"status": "ok"`, the log sequence has not been modified, reordered, or deleted since the last entry was written. This guarantee holds even against the operator of the instance: database-level modifications cannot be made undetectable without rehashing all subsequent entries.

**Retention-safe verification — Monthly Checkpoints:** When logs are pruned under a retention policy, `POST /v1/checkpoints` creates a cryptographic snapshot of the chain state at a month-end boundary. The verifier bridges the pruning gap by anchoring to the checkpoint hash, not GENESIS — preserving full chain verifiability across retention events.

---

### 4.2 Encryption at Rest — Fernet AES-128

**Algorithm:** Fernet (Python `cryptography` library, OpenSSL-backed)
- Cipher: **AES-128-CBC**
- Authentication: **HMAC-SHA256** (encrypt-then-MAC — ciphertext tampering is detectable)
- Key format: 32 bytes (256-bit), URL-safe base64 encoded — first 16 bytes for AES, second 16 for HMAC

**Key lifecycle:**
- Auto-generated on first boot via `Fernet.generate_key()` (draws from `/dev/urandom`).
- Stored in `/app/data/config.json` on the `server_data` Docker volume with restricted filesystem permissions.
- Never transmitted over the network. Never stored in the database.

**Key rotation (`MultiFernet`):** The `ENCRYPTION_KEY` accepts a comma-separated list. The **first key** encrypts new entries; all keys decrypt existing entries. Zero-downtime rotation: prepend a new key, deploy — new entries use the new key, existing entries remain readable.

**Envelope encryption (optional):** A `MASTER_KEY` configuration enables KEK/DEK separation — the data encryption key is itself encrypted by the master key before storage, enabling integration with AWS KMS, HashiCorp Vault, or GCP Cloud KMS. The plaintext DEK never persists to disk.

**What encryption protects:**
- A full PostgreSQL dump exposes only binary ciphertext for the `metadata` column.
- A compromised read replica, misconfigured snapshot, or stolen backup file does not expose `metadata` contents.

**What encryption does not protect:**
- An attacker with access to both the database **and** `config.json` (i.e., the `server_data` volume) can decrypt all `metadata`. Protecting the encryption key is the customer's responsibility — see [Section 6](#6-shared-responsibility-model).

---

### 4.3 Authentication Architecture — Strict Principal Separation

| Principal | Credential | Scope | Hashing |
|-----------|-----------|-------|---------|
| Machine (service/script) | API Key (`X-API-Key` header) | `POST /v1/log` only | Argon2id |
| Human (admin/viewer) | JWT session cookie (`verilog_token`) | Dashboard & management APIs | HS256, HTTPOnly cookie |

**Why strict separation?** Combining machine credentials with human session tokens creates a class of attack where a leaked API key grants dashboard access. Structurally different credential types enforced at the routing layer eliminate this class entirely.

**API key properties:**
- Generated once, returned once, never stored in plaintext.
- Stored as **Argon2id** hash — resistant to GPU/ASIC cracking.
- Revocation is immediate at the dependency injection layer.

**Session JWT properties:**
- **HS256** signed with auto-generated `JWT_SECRET`.
- `HTTPOnly` (inaccessible to JavaScript — mitigates XSS token theft).
- `SameSite=Lax` (mitigates CSRF).
- One active session per user — new login invalidates all prior sessions.
- Session records include IP and user-agent for forensic audit.

**Password hashing:**
- **Argon2id** (memory-hard, OWASP-recommended, resistant to GPU cracking).
- Automatic rehash-on-login: if cost parameters were upgraded since last login, the hash is transparently upgraded on next successful authentication.

---

### 4.4 License Integrity — RS256 JWT

Pro license keys are **RS256-signed JWTs** (asymmetric). The private key is held exclusively by the VeriLog issuing authority; the public key is embedded in the server for offline verification. A valid-appearing license key cannot be forged without the private key, even with full access to the source code.

---

## 5. Data Lifecycle & Retention Governance

| Stage | Detail |
|-------|--------|
| **Ingestion** | Validated → `metadata` encrypted in memory → hash computed → WAL write → `202 Accepted` returned → background batch DB insert |
| **Storage** | Append-only `audit_logs` table. Entries are never `UPDATE`d after creation. Alembic manages schema with full migration history. |
| **Search** | `GET /v1/logs` — paginated, filtered, tenant-scoped. `metadata` excluded from all responses structurally. |
| **Export** | `GET /v1/export` — cursor-streamed CSV or JSONL. `metadata` excluded from exports by design. |
| **Verification** | `GET /v1/verify` / `GET /v1/verify/deep` — full chain re-verification on demand. |
| **Pruning** | Hard delete of entries older than `log_retention_days`. Monthly checkpoints created first to preserve chain verifiability. |

---

## 6. Shared Responsibility Model

> This model follows industry-standard shared responsibility frameworks adapted for self-hosted enterprise software.

---

### 6.1 What VeriLog Guarantees

| Guarantee | Mechanism |
|-----------|-----------|
| Cryptographic chain integrity | SHA-256 hash chaining on every write. `GET /v1/verify` provides mathematical proof. |
| Metadata encryption before persistence | Fernet AES-128 in application memory. Plaintext never reaches the database driver. |
| Brute-force login protection | Nginx: 5 req/min per IP on login endpoint. |
| API abuse prevention | Nginx rate limiting and request size caps on all endpoints. |
| Credential storage security | All passwords and API keys stored as Argon2id hashes. No plaintext persistence. |
| Session security | HTTPOnly + SameSite=Lax JWT. Single active session per user. |
| Cross-tenant data isolation | Application-layer `tenant_id` scoping on every query + PostgreSQL RLS backstop. |
| Zero-config secret generation | All cryptographic secrets auto-generated from `/dev/urandom` on first boot. |
| Frontend metadata firewall | `metadata` structurally excluded from all API response schemas. React cannot receive it. |
| SQL injection prevention | All queries via SQLAlchemy parameterized expressions. No raw string interpolation. |

---

### 6.2 What the Customer Must Ensure

#### 6.2.1 Safeguarding the Encryption Key — **CRITICAL**

The `ENCRYPTION_KEY` in `/app/data/config.json` (Docker volume: `server_data`) is the sole key for the `metadata` vault. VeriLog holds no escrow copy.

| Scenario | Consequence |
|----------|------------|
| Key lost (volume deleted without backup) | All `metadata` ciphertext is **permanently and irrecoverably unreadable**. `tags` and all other fields remain intact. |
| Key leaked (config.json exposed) | All historical `metadata` can be decrypted offline with no detection mechanism. |

**Required actions:**
- Back up the `server_data` Docker volume (or extract `config.json`) to a secure, access-controlled location.
- Treat `config.json` with the same access controls as a TLS private key or database root credential.
- Rotate the encryption key on a schedule using VeriLog's `MultiFernet` rotation.
- For high-security deployments, use the `MASTER_KEY` option for envelope encryption with an external KMS.

---

#### 6.2.2 Infrastructure & Network Security

| Responsibility | Guidance |
|---------------|---------|
| **Host OS patching** | VeriLog containers run as non-root users, but a host kernel exploit bypasses container isolation. Keep the Docker host OS patched. |
| **Network firewall** | Port 80 should not be publicly exposed unless intentional. Restrict to your application servers or a VPN. |
| **TLS / HTTPS termination** | VeriLog does not terminate TLS. Without a TLS reverse proxy (Caddy, Traefik, cloud load balancer) in front, API keys and JWTs transit the network in plaintext. **Production deployments must use HTTPS.** |
| **Docker socket** | Do not expose the Docker socket to VeriLog containers. Container escape via Docker socket yields root on the host. |
| **Volume permissions** | `server_data` and `secrets` volumes must be accessible only to the Docker daemon and authorized system users. |

---

#### 6.2.3 Data Sanitization — The `tags` Field

**VeriLog encrypts what it is given. It cannot protect data it does not know is sensitive.**

The `tags` field is plaintext JSONB — visible in the dashboard, returned by the API, and included in exports. Any PII or sensitive data placed in `tags` is stored and transmitted in the clear.

| Do NOT put in `tags` | Correct field: `metadata` |
|---------------------|--------------------------|
| Email addresses, phone numbers | ✅ Put in `metadata` |
| User IP addresses (GDPR scope) | ✅ Put in `metadata` |
| Auth tokens, session IDs | ✅ Put in `metadata` |
| Internal credentials | ✅ Put in `metadata` |
| Stack traces with internal paths | ✅ Put in `metadata` |
| Any PII covered by your data classification policy | ✅ Put in `metadata` |

Enforce correct field routing in your integration code. Consider code review checklists or static analysis rules that audit all `POST /v1/log` call sites.

---

#### 6.2.4 Access Control & User Provisioning

- Provision admin accounts only to personnel who require administrative access.
- Revoke user access promptly when employees leave or change roles.
- Distribute API keys only to systems that legitimately require write access to the audit log.
- A compromised API key allows **log injection** (writing false entries) but not reading, modifying, or deleting existing entries.

---

## 7. Compliance Readiness Posture

VeriLog's design provides technical controls directly relevant to major compliance frameworks. This section describes the mapping — it does not constitute a compliance certification.

| Control | Framework Relevance | VeriLog Implementation |
|---------|--------------------|-----------------------|
| **Tamper-evident audit log** | SOC 2 CC7.2, ISO 27001 A.12.4 | SHA-256 hash chain. Mathematical tamper detection via `GET /v1/verify`. |
| **Encryption of sensitive data at rest** | HIPAA §164.312(a)(2)(iv), GDPR Art. 32 | Fernet AES-128 on `metadata` column. Key never persists to database. |
| **Access control to audit records** | SOC 2 CC6.1, ISO 27001 A.9 | JWT role-based access (admin/viewer). Session tracking with IP and user-agent. |
| **Audit log integrity verification** | SOC 2 CC7.3, PCI DSS 10.5 | `GET /v1/verify` and `GET /v1/verify/deep` provide on-demand chain integrity reports. |
| **Log retention policy enforcement** | HIPAA §164.316(b)(2), SOC 2 | Configurable retention periods. Retention is license-gated. |
| **Authentication hardening** | NIST SP 800-63B, SOC 2 CC6.1 | Argon2id password hashing. Brute-force protection via Nginx rate limiting. |
| **Multi-tenancy / data segregation** | SOC 2 CC6.3 | Application-layer `tenant_id` enforcement + PostgreSQL RLS. |
| **No data egress to third parties** | GDPR Art. 44–49 (data transfers) | Self-hosted. Zero outbound connections at runtime. All data remains in customer infrastructure. |

> **Note to auditors:** VeriLog is a tool that enables compliance. Achieving certification (SOC 2, ISO 27001, HIPAA) also requires customer-side policies, procedures, and controls that are outside the scope of any software product.

---

## 8. Infrastructure Topology & Deployment Model

### Container Map

| Container | Image | Role | Internal Port |
|-----------|-------|------|--------------|
| `verilog-init` | `init` (Alpine) | One-shot secret generation on first boot. Exits after creating `/secrets/db_password`. | — |
| `verilog-client` | `nginx` (custom) | API gateway, rate limiter, React SPA server. The only publicly exposed container. | 80 |
| `verilog-server` | `python:3.12-slim` (custom) | FastAPI application, background ingestion worker, WAL manager. | 8000 (internal only) |
| `verilog-db` | `postgres:16` | PostgreSQL database. | 5432 (internal only) |

### Docker Volumes

| Volume | Mounted In | Contents | Backup Priority |
|--------|-----------|----------|----------------|
| `postgres_data` | `verilog-db` | All PostgreSQL data files — the primary data store | **Critical** — back up regularly |
| `server_data` | `verilog-server` | `config.json` (contains `ENCRYPTION_KEY`, `JWT_SECRET`), WAL files | **Critical** — losing this loses all metadata |
| `secrets` | `verilog-init`, `verilog-db`, `verilog-server` | `db_password` file — shared secret between DB and server | **Critical** |

### Startup Sequence

```
1. verilog-init     → generates /secrets/db_password (runs once, exits)
2. verilog-db       → starts PostgreSQL, waits for init to complete
3. verilog-server   → runs `alembic upgrade head`, starts Uvicorn
4. verilog-client   → starts Nginx, begins accepting traffic
```

The `verilog-server` container uses Docker Compose `depends_on: condition: service_healthy` to wait for PostgreSQL to be fully ready before running migrations.

### Network Topology

All containers share a single Docker bridge network (`verilog_net`). `verilog-db` and `verilog-server` are not reachable from outside this network. Only `verilog-client` (Nginx) binds to a host port. This topology means that a full network compromise of the Docker host's external interface does not automatically yield database access — the attacker must first compromise the Nginx container or the Docker network itself.

### Recommended Production Hardening (Customer Responsibility)

```
Internet
    │
    ▼
[TLS Termination — Caddy / Traefik / Cloud LB]  ← Customer manages
    │ HTTPS
    ▼
[Nginx — verilog-client :80]  ← VeriLog manages
    │ Internal Docker network
    ▼
[FastAPI — verilog-server :8000]  ← VeriLog manages
    │
    ▼
[PostgreSQL — verilog-db :5432]  ← VeriLog manages
```

TLS termination sits in front of Nginx and is entirely customer-managed. VeriLog's responsibility begins at the Nginx listener.
