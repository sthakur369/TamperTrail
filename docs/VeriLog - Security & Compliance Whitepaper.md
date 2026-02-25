# VeriLog — Security & Compliance Whitepaper

**Classification:** Public  
**Audience:** Chief Security Officers (CSOs), Data Protection Officers (DPOs), IT Compliance Auditors, and Enterprise Procurement Teams  
**Version:** 1.0 — February 2026

---

## Table of Contents

1. [Executive Summary & Our Unique Position](#1-executive-summary--our-unique-position)
2. [Cryptographic Architecture](#2-cryptographic-architecture)
3. [Access Control & Defensive Engineering](#3-access-control--defensive-engineering)
4. [Data Classification & Privacy Architecture](#4-data-classification--privacy-architecture)
5. [Shared Responsibility Model](#5-shared-responsibility-model)
6. [Compliance Framework Mapping](#6-compliance-framework-mapping)
7. [Honest Assessment of Current Limitations](#7-honest-assessment-of-current-limitations)
8. [Security Roadmap](#8-security-roadmap)
9. [Incident Response Considerations](#9-incident-response-considerations)

---

## 1. Executive Summary & Our Unique Position

### What VeriLog Is

VeriLog is a **self-hosted, cryptographically immutable audit vault**. It is not a log aggregator, an APM dashboard, or an observability platform. It is a purpose-built compliance instrument: a system whose primary guarantee is that once an event is recorded, that record cannot be silently modified, deleted, or reordered — and that this guarantee is **mathematically provable** by anyone with read access to the database, at any time, without trusting VeriLog's own reporting.

Every log entry is chained to its predecessor using SHA-256 cryptographic hashing. Every sensitive payload is encrypted with AES-128 before it touches the database. The system is deployed entirely within the customer's own infrastructure — no data ever transits to VeriLog's servers, because VeriLog has no servers.

### How VeriLog Differs from Traditional Observability Tools

The audit logging market is dominated by SaaS observability platforms designed for engineering teams: Datadog, Splunk, Sentry, New Relic, and similar products. These tools excel at performance monitoring, error tracking, and developer workflow. They are not compliance instruments.

| Criterion | SaaS Observability Platforms | VeriLog |
|-----------|------------------------------|---------|
| **Data sovereignty** | Data leaves your infrastructure permanently | Data never leaves your infrastructure |
| **Tamper evidence** | None — the vendor can modify records | SHA-256 hash chain — mathematically provable |
| **Sensitive payload protection** | Varies; typically plaintext | AES-128 encryption before database write |
| **Audit data verification** | Requires trusting vendor's attestation | Run `GET /v1/verify` — self-verifiable at any time |
| **Compliance scope** | Shared responsibility with a third party | Entirely within your own infrastructure boundary |
| **GDPR third-country transfer risk** | Potentially applicable (vendor data centers) | Not applicable — no data egress |
| **Cost at scale** | Per-seat or per-GB pricing | Self-hosted — infrastructure cost only |

### Honest Caveat

VeriLog is a software product, not a compliance certification. Deploying VeriLog provides the **technical controls** that underpin compliance. Achieving a formal certification (SOC 2 Type II, ISO 27001, HIPAA attestation) also requires organizational policies, procedures, personnel training, and operational practices that are beyond the scope of any software product. This document does not claim otherwise.

---

## 2. Cryptographic Architecture

### 2.1 Data at Rest — The Encrypted Metadata Vault

Every log entry accepted by VeriLog may carry two data payloads:

| Field | Storage Type | Encrypted | Searchable | Dashboard Visible |
|-------|-------------|-----------|-----------|------------------|
| `tags` | JSONB | ❌ Plaintext | ✅ GIN indexed | ✅ Yes |
| `metadata` | BYTEA | ✅ AES-128-CBC + HMAC-SHA256 | ❌ No | ❌ Never |

The `metadata` field uses the **Fernet** symmetric encryption scheme from the Python `cryptography` library (OpenSSL-backed):

- **Cipher:** AES-128-CBC
- **Authentication:** HMAC-SHA256 (encrypt-then-MAC — ciphertext tampering is detectable independently of decryption)
- **Key format:** 32-byte URL-safe base64 — 16 bytes for AES, 16 bytes for HMAC
- **Token structure:** Version byte + timestamp + IV + ciphertext + HMAC, all base64-encoded

**Encryption occurs in application memory before the database driver is called.** The PostgreSQL engine never receives the plaintext value of `metadata` under any code path. A complete dump of the `audit_logs` table reveals only binary ciphertext in the `metadata` column (stored as `BYTEA`). Without the encryption key, this ciphertext is computationally indistinguishable from random noise.

**Frontend architectural blindness:** The React dashboard is structurally prevented from receiving `metadata`. The `LogEntryOut` API response schema excludes the encrypted column — it is dropped in the Python serialization layer before the HTTP response is constructed. A complete compromise of the React application cannot expose the encrypted vault because that data is never transmitted to the browser under any code path.

**Key rotation (`MultiFernet`):** Multiple encryption keys can be configured simultaneously — new entries encrypt with the current primary key; all configured keys are tried for decryption. Zero-downtime rotation: prepend a new key, deploy, and historical entries remain readable indefinitely via the old key.

**Envelope encryption (Enterprise):** When a `MASTER_KEY` is configured, the data encryption key (DEK) is itself encrypted before storage — a standard KEK/DEK pattern. Enables integration with AWS KMS, HashiCorp Vault, GCP Cloud KMS, or any compatible external key management system. The plaintext DEK never persists to disk in this configuration.

---

### 2.2 The Immutable Ledger — SHA-256 Hash Chaining

Every row in `audit_logs` carries:

| Field | Content |
|-------|---------|
| `prev_hash` | SHA-256 hash of the immediately preceding entry (same tenant, chronological order) |
| `hash` | SHA-256 digest of this entry's canonical representation |

**Hash input** (deterministic concatenation):

```
hash = SHA-256(prev_hash + created_at + actor + action + target_type + target_id + hex(metadata_ciphertext))
```

Including the raw encrypted bytes of `metadata` in the hash means modifying the ciphertext — even without the decryption key — immediately breaks the chain. The first entry per tenant anchors to a fixed `GENESIS_HASH` (SHA-256 of the string `"GENESIS"`).

**Tamper detection (`GET /v1/verify`):** Reads every entry in chronological order, recomputes the expected hash, and asserts `entry.prev_hash == previous_entry.hash`. Any deletion, modification, insertion, or reordering produces a detectable chain break at that position — the system reports the exact location.

> **Auditor note:** The verification algorithm can be independently reimplemented using only a database connection and the hash rules above. It does not require trusting any VeriLog API response.

**Retention-safe verification — Monthly Checkpoints:** `POST /v1/checkpoints` creates a cryptographic snapshot of the chain state at a monthly boundary. Verification anchors to the most recent checkpoint rather than GENESIS, preserving full chain verifiability even after historical entries are pruned under a retention policy.

---

### 2.3 Data in Transit

**VeriLog does not terminate TLS.** This is a deliberate architectural boundary — TLS termination belongs in the customer's infrastructure layer, upstream of the application.

> **Customer Requirement:** All production deployments MUST place a TLS-terminating reverse proxy (Caddy, Traefik, AWS ALB, Cloudflare, or equivalent) in front of VeriLog. Without TLS, API keys and session tokens transit the network in plaintext.

Recommended production topology:

```
[ Internet ] → HTTPS → [ Customer TLS Proxy ] → HTTP → [ Nginx :80 ] → [ FastAPI :8000 ]
```

VeriLog's responsibility begins at the Nginx listener.

---

## 3. Access Control & Defensive Engineering

### 3.1 Authentication — Strict Principal Separation

| Principal | Credential | Transport | Scope | Storage |
|-----------|-----------|-----------|-------|---------|
| **Machine** (services, scripts) | API Key (`X-API-Key` header) | Stateless per-request | `POST /v1/log` ingestion only | Argon2id hash |
| **Human** (admin/viewer) | JWT session cookie (`verilog_token`) | HTTPOnly cookie | Dashboard & management APIs | Memory — 24h expiry |

A leaked API key cannot authenticate a dashboard request. A stolen session token cannot authenticate a log ingestion request. The credential types are structurally incompatible at the routing layer — not merely insufficient-scope-checked.

**API key properties:** Generated from cryptographically secure random source. Raw value returned once and never stored in plaintext. Stored as **Argon2id** hash (GPU/ASIC-resistant). Revocation is immediate.

**Session JWT properties:** **HS256** signed. `HTTPOnly` (XSS-resistant). `SameSite=Lax` (CSRF-resistant). Single active session per user — new login invalidates all prior sessions. Session records include IP and User-Agent for forensic review.

**Password hashing:** **Argon2id** (memory-hard, OWASP-recommended). Automatic parameter upgrade on next login if cost parameters have been increased.

---

### 3.2 The Network Boundary — Nginx as Enforcer

Only the Nginx container binds a host port. FastAPI and PostgreSQL are reachable exclusively within the internal Docker network.

**Per-IP rate limits (enforced before Python executes):**

| Endpoint | Limit | Burst | Protection Target |
|----------|-------|-------|-----------------|
| `POST /v1/auth/login` | 5 req/min | 3 | Brute-force credential attacks |
| `POST /v1/log` | 100 req/min | 20 | Log flooding, runaway services |
| All other `/v1/*` | 200 req/min | 50 | General API abuse |

**Request size limiting:** Oversized payloads are rejected by Nginx before any Python memory is allocated — prevents memory exhaustion attacks.

**OpenAPI suppression:** `/docs`, `/redoc`, and `/openapi.json` are blocked at the Nginx layer.

**Security response headers on every response:** `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Content-Security-Policy`, `Strict-Transport-Security`, `Referrer-Policy: no-referrer`, `Permissions-Policy`.

---

### 3.3 Multi-Tenant Data Isolation — Defense in Depth

**Layer 1 (Application):** Every query is constructed with an explicit `WHERE tenant_id = :tid` extracted from the authenticated JWT. Not from query parameters or request bodies.

**Layer 2 (Database):** PostgreSQL Row-Level Security (RLS) with `FORCE ROW LEVEL SECURITY` on `audit_logs` and `chain_checkpoints`. If the application-level tenant context is not set, **no rows are returned** — fails closed, not open.

Cross-tenant exposure requires simultaneously bypassing two independently implemented controls at different layers.

---

### 3.4 SQL Injection Prevention

All database queries use **SQLAlchemy parameterized expressions**. Raw SQL string interpolation is not used anywhere in the codebase. SQL injection is eliminated by construction.

---

### 3.5 Server-Side Attribution (Anti-Spoofing)

`source_ip`, `user_agent`, and `device_type` are captured server-side from the HTTP request context — not from client-supplied payload fields. Nginx injects `X-Real-IP` from the TCP connection level. Clients cannot suppress or falsify these fields.

---

## 4. Data Classification & Privacy Architecture

### 4.1 The Two-Tier Data Model

```
┌──────────────────────────────────────────────────────────────┐
│                      AUDIT LOG ENTRY                         │
│                                                              │
│  ┌─────────────────────────┐  ┌──────────────────────────┐  │
│  │      TIER 1: TAGS       │  │    TIER 2: METADATA      │  │
│  │  Plaintext JSONB        │  │  AES-128 Ciphertext      │  │
│  │  GIN-indexed            │  │  BYTEA binary blob       │  │
│  │  Dashboard visible      │  │  Never transmitted       │  │
│  │  Export included        │  │  Export excluded         │  │
│  │  Searchable             │  │  Unsearchable            │  │
│  │                         │  │                          │  │
│  │  Non-sensitive context  │  │  Sensitive forensic data │  │
│  └─────────────────────────┘  └──────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### 4.2 Data Residency

VeriLog makes **zero outbound network connections** at runtime. No telemetry, no analytics beacons, no license validation calls, no automatic update checks. All data resides exclusively in the Docker volumes on the customer's host machine.

> **GDPR Articles 44–49 (International Data Transfers):** VeriLog makes cross-border data transfers structurally impossible. Data cannot leave the jurisdiction in which the host machine resides because VeriLog contains no mechanism for outbound data transmission.

---

## 5. Shared Responsibility Model

> This section defines with precision what VeriLog guarantees and what the customer is responsible for. Security gaps most commonly arise from assumed — not stated — responsibilities.

---

### 5.1 VeriLog's Security Guarantees

| Guarantee | Mechanism |
|-----------|-----------|
| Cryptographic chain integrity | SHA-256 hash chain on every write — `GET /v1/verify` provides mathematical proof |
| Metadata never stored in plaintext | AES-128 in application memory before DB write |
| Brute-force login protection | Nginx: 5 req/min per IP |
| API key plaintext never stored | Argon2id hash only |
| Cross-tenant isolation | App-layer `tenant_id` filter + PostgreSQL RLS |
| Frontend metadata blindness | `metadata` excluded from all API response schemas |
| No outbound data transmission | Zero external network calls at runtime |
| SQL injection prevention | SQLAlchemy parameterized queries only |
| Session credential security | HTTPOnly + SameSite=Lax JWT cookies |
| Auto-generated cryptographic secrets | `/dev/urandom` source on first boot — no user-defined defaults |

---

### 5.2 Customer Responsibilities

> **The following describes where VeriLog's software controls end and customer operational responsibility begins. These are not gaps — they are the correct responsibility of the infrastructure operator.**

---

#### 5.2.1 Encryption Key Custody — CRITICAL

The encryption key stored in VeriLog's configuration file is the sole key for the metadata vault. VeriLog holds no escrow copy. There is no recovery mechanism.

| Scenario | Consequence |
|----------|------------|
| Key lost (volume deleted, disk failure) | All `metadata` ciphertext is **permanently and irrecoverably unreadable**. All other fields (`tags`, `actor`, `action`, timestamps) remain fully intact. |
| Key leaked (config file exposed) | All historical `metadata` can be decrypted offline with no detection mechanism. |

> **Treat the VeriLog configuration file with the same operational controls as a TLS private key: restricted file permissions, regular off-host backups, and storage in a secrets management system (HashiCorp Vault, AWS Secrets Manager, Azure Key Vault) for any production deployment of consequence.**

---

#### 5.2.2 TLS / HTTPS Termination

> **Without a TLS-terminating proxy in front of VeriLog, all API keys, session tokens, and log payloads transit the network in plaintext. This is not acceptable for any production deployment.**

Customer responsibilities: Provision and maintain valid TLS certificates. Configure a terminating proxy upstream of VeriLog. Enforce TLS 1.2 minimum (1.3 recommended). Manage certificate renewal.

---

#### 5.2.3 Host & Network Security

| Responsibility | Risk if Neglected |
|---------------|-----------------|
| Host OS patching | Container escape via kernel exploit yields host root |
| Docker socket access control | Docker socket access is equivalent to root on the host |
| Network firewall configuration | Port 80 exposed without TLS proxy allows plaintext credential interception |
| Volume access control | Direct volume access bypasses all application authentication |

---

#### 5.2.4 Data Sanitization — The `tags` Field

> **VeriLog encrypts what it is given. It cannot protect data it does not know is sensitive. Data misclassification is the customer's liability.**

The `tags` field is plaintext JSONB — fully visible in the dashboard, returned in API responses, and included in data exports.

| Data Category | Incorrect Field | Correct Field |
|--------------|----------------|--------------|
| User email addresses, phone numbers | `tags` ❌ | `metadata` ✅ |
| User IP addresses (GDPR scope) | `tags` ❌ | `metadata` ✅ |
| Authentication tokens, session IDs | `tags` ❌ | `metadata` ✅ |
| Stack traces with internal paths | `tags` ❌ | `metadata` ✅ |
| Any PII under your data classification policy | `tags` ❌ | `metadata` ✅ |

Enforce correct field routing in integration code via code review checklists or static analysis rules auditing all `POST /v1/log` call sites.

---

#### 5.2.5 Access Control Lifecycle

- Revoke API keys when services are decommissioned or credentials rotate.
- Deactivate or delete user accounts when personnel change roles or leave.
- Rotate API keys on a schedule consistent with your security policy.
- Review `GET /v1/sessions` regularly for anomalous login patterns.

---

## 6. Compliance Framework Mapping

> **Disclaimer:** This mapping represents an honest, good-faith assessment of controls VeriLog provides. It does not constitute a compliance certification or legal advice. Formal attestation requires an independent auditor's assessment of your complete environment, including organizational policies outside VeriLog's scope.

---

### 6.1 SOC 2 Type II (Trust Services Criteria)

| Criteria | Requirement | VeriLog Control | Gap / Customer Action |
|----------|-------------|----------------|----------------------|
| CC6.1 | Logical access controls | Role-based auth, API key isolation, session management | — |
| CC6.3 | Access based on authorization | Tenant-scoped access, per-user `allowed_tenants` | Customer must manage user provisioning lifecycle |
| CC6.7 | Restrict confidential data transmission | Encrypted `metadata`; `tags` requires customer data classification | Customer must provision TLS |
| CC7.2 | Monitor for unauthorized changes | SHA-256 hash chain — tampering mathematically detectable | — |
| CC7.3 | Evaluate security events | `GET /v1/verify` for on-demand chain integrity reports | — |
| CC9.2 | Third-party risk management | Self-hosted — no third-party vendors in data path | — |

---

### 6.2 HIPAA Security Rule (45 CFR Part 164)

| Safeguard | Specification | VeriLog Control | Gap / Customer Action |
|-----------|--------------|----------------|-----------------------|
| §164.312(a)(1) | Access control | Role-based auth, API key isolation | — |
| §164.312(a)(2)(iv) | Encryption and decryption | Fernet AES-128-CBC for `metadata` at rest | Customer must not store ePHI in `tags` |
| §164.312(b) | Audit controls | Immutable hash-chained audit log | — |
| §164.312(c)(1) | Integrity | SHA-256 chain — alteration is detectable | — |
| §164.312(e)(1) | Transmission security | **Customer responsibility** — TLS proxy required | Customer must provision TLS |
| §164.316(b)(2) | Retention | Configurable retention with checkpoint-safe pruning | — |

---

### 6.3 GDPR (Regulation (EU) 2016/679)

| Article | Requirement | VeriLog Relevance | Gap |
|---------|-------------|------------------|-----|
| Art. 5(1)(f) | Integrity and confidentiality | Fernet encryption + hash chain integrity | — |
| Art. 25 | Data protection by design | Two-tier model separates searchable and encrypted fields by architecture | Customer must classify data correctly |
| Art. 32 | Appropriate technical measures | AES-128, Argon2id, rate limiting, RLS | Customer must provision TLS |
| Art. 44–49 | Transfers to third countries | Not applicable — zero data egress | — |
| Art. 17 | Right to erasure | Retention policy enables time-bound deletion | Customer must configure retention appropriately |

**Honest note on GDPR scope:** If personal data appears in audit records (actor email addresses, user IDs in `tags`), VeriLog itself becomes a system processing personal data. The customer is the data controller and must assess proportionality and lawful basis independently.

---

### 6.4 ISO/IEC 27001:2022

| Control | VeriLog Implementation |
|---------|----------------------|
| A.8.15 — Logging | Immutable, tamper-evident audit log |
| A.8.16 — Monitoring | `GET /v1/verify` for continuous chain integrity monitoring |
| A.8.24 — Cryptography | AES-128, SHA-256, Argon2id, HS256 JWT |
| A.5.18 — Access rights | Role-based access, tenant isolation |
| A.8.9 — Configuration management | Auto-generated secrets, Alembic schema migrations |

---

### 6.5 PCI DSS v4.0

| Requirement | VeriLog Control | Gap |
|-------------|----------------|-----|
| Req. 10.2 — Implement audit logs | Core VeriLog function | — |
| Req. 10.3 — Protect logs from modification | SHA-256 hash chain — modifications detectable | — |
| Req. 10.5 — Retain logs 12+ months | Configurable; Pro tier supports 365 days / unlimited | Free tier: 30-day limit |
| Req. 8.3 — Strong authentication | Argon2id passwords, session management | — |
| Req. 4.2 — Encrypt data in transit | **Customer responsibility** | TLS proxy required |

---

## 7. Honest Assessment of Current Limitations

This section documents known limitations of the current VeriLog release. We believe transparency here is itself a security control — organizations should make deployment decisions with full knowledge of the current state.

| Limitation | Detail | Mitigation / Roadmap |
|-----------|--------|---------------------|
| **No built-in TLS termination** | Nginx listens on HTTP. TLS must be provisioned by the customer upstream. | Deploy a TLS-terminating proxy (Caddy, Traefik). This is standard architecture for self-hosted software. |
| **No Hardware Security Module (HSM) support** | Encryption keys are stored in `config.json` on the `server_data` volume — not in dedicated key hardware. | Envelope encryption with `MASTER_KEY` enables AWS KMS / HashiCorp Vault integration. Native HSM support is on the roadmap. |
| **No SSO / SAML / OIDC** | Authentication is username/password only. No integration with enterprise identity providers. | SSO (SAML 2.0 + OIDC) is on the near-term roadmap. |
| **No formal compliance certification** | VeriLog has not undergone a third-party SOC 2 audit. We are a software product that enables compliance; we are not ourselves certified. | This document provides the technical controls mapping to assist your auditors. |
| **`tags` field is plaintext** | The GIN-indexed search field is unencrypted by design (encryption would make it unsearchable). Organizations must enforce data classification in integration code. | Clear documentation and tooling guidance are provided. Encryption of specific tag keys is under consideration for a future release. |
| **Verification is eventually consistent** | `GET /v1/verify` reads the database at verification time. A sufficiently sophisticated attacker with database-level write access and hash-computation capability could, in theory, forge a consistent chain. This requires both database access and server code access simultaneously. | Defense-in-depth: the database is not directly accessible from outside the Docker network. PostgreSQL is not exposed on any host port. |
| **Log injection via compromised API key** | A leaked API key allows writing false log entries — it does not allow reading, modifying, or deleting existing entries. | Rotate API keys regularly. Monitor for anomalous ingestion patterns via `GET /v1/stats`. |

---

## 8. Security Roadmap

The following capabilities are planned for future VeriLog releases. They represent our commitment to continuous security improvement and enterprise-grade feature parity.

### Near-Term

- **SSO Integration (SAML 2.0 + OIDC):** Native integration with enterprise identity providers — Okta, Microsoft Entra ID (Azure AD), Google Workspace, and any SAML 2.0-compatible IdP. Enables centralized identity management and immediate access revocation via the IdP.

- **Granular Role-Based Access Control (RBAC):** Per-resource permission scoping beyond the current admin/viewer model. Planned permissions: read-only log access scoped to specific tenants or date ranges, export permission gate, verification access control.

- **Forensic Export CLI:** A standalone command-line tool for external auditors. Connects directly to the database with read-only credentials, decrypts `metadata` with a provided key, and outputs a fully verifiable, cryptographically signed export — independent of the running VeriLog server. Designed specifically for evidence preservation in incident response and legal proceedings.

### Medium-Term

- **Hardware Security Module (HSM) Support:** Native integration with dedicated HSM hardware (Thales, Entrust, AWS CloudHSM) for organizations requiring FIPS 140-2 Level 3 key storage. The DEK would be generated and stored within the HSM — the plaintext key material never exists in software memory.

- **Audit Trail Self-Logging:** VeriLog logs its own administrative operations (API key creation, user provisioning changes, login events, retention policy changes) as tamper-evident system-tagged audit entries — a self-referential audit trail for the audit system itself.

- **Compliance Report Generation:** Pre-formatted PDF/Excel reports for SOC 2, GDPR, and HIPAA auditors. Reports include chain verification summary, access control summary, key rotation history, and retention policy compliance — with admin password re-confirmation and full audit logging of the report generation action.

### Long-Term

- **Webhook & SIEM Integration:** Real-time alerts to SIEM platforms (Splunk, Microsoft Sentinel, IBM QRadar) and webhook endpoints (Slack, PagerDuty) when critical-severity events are detected or when chain verification fails.

- **Immutable Append-Only PostgreSQL Enforcement:** Database-level write-once enforcement via PostgreSQL triggers — preventing `UPDATE` and `DELETE` operations on `audit_logs` at the database layer, independent of application behavior.

- **Cross-Instance Chain Federation:** Cryptographic linking of audit chains across multiple VeriLog instances — enabling enterprise deployments to maintain a single verifiable ledger across distributed infrastructure regions.

---

## 9. Incident Response Considerations

### If You Suspect Log Tampering

1. **Run chain verification immediately:** `GET /v1/verify/deep` performs a full re-hash of every entry and reports all broken links with precise timestamps and positions.
2. **Preserve the database:** Take a PostgreSQL dump of the `audit_logs` table before any remediation. The ciphertext record is evidence.
3. **Review session history:** `GET /v1/sessions` shows all login events with IP addresses and User-Agents. Anomalous logins from unexpected IPs may indicate credential compromise.
4. **Check WAL files:** The Write-Ahead Log (`/app/data/queue.wal`) contains a sequential record of all ingested log items prior to database commit. It provides an independent record to compare against the database state.

### If You Suspect Encryption Key Exposure

1. **Do not delete or rotate immediately** — rotation without backup forfeits all historical `metadata` decryptability.
2. **Assess exposure scope:** Determine which systems had access to the `server_data` volume or the configuration file.
3. **Generate a new encryption key** using VeriLog's key rotation mechanism — this key becomes the primary key for all new entries.
4. **Keep the old key** in the rotation chain to preserve readability of existing records.
5. **Re-encrypt historical `metadata`** during a maintenance window if re-encryption is required by your security policy.
6. **Audit `GET /v1/sessions`** for any unexpected administrative access during the exposure window.

### If You Suspect a Compromised API Key

A compromised API key enables **log injection** (writing false entries). It does not grant:
- Read access to any log entries
- Access to the dashboard or management APIs
- Access to the `metadata` encryption key
- Ability to modify or delete existing entries

**Immediate response:** Revoke the key via `DELETE /v1/keys/{id}`. The key becomes invalid for any new requests within milliseconds. Review recent ingestion activity for false entries using the time range filter in `GET /v1/logs`.

---

*This whitepaper describes the security architecture of VeriLog as of the version current at the document date. For the latest security information, consult the project repository.*
