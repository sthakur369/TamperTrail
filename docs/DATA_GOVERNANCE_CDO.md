# VeriLog — Data Governance Manual

**Classification:** Public  
**Audience:** Chief Data Officers (CDOs), Data Protection Officers (DPOs), Privacy Counsel, and Enterprise Compliance Teams  
**Version:** 1.0 — February 2026  
**Keywords:** audit log data governance, GDPR audit trail, CCPA compliance logging, privacy by design, encrypted audit log, immutable audit trail, data lifecycle management, HIPAA audit logging

---

## Table of Contents

1. [Executive Summary: Privacy by Design](#1-executive-summary-privacy-by-design)
2. [Data Classification Framework](#2-data-classification-framework)
3. [Data Lifecycle Management](#3-data-lifecycle-management)
4. [The Blind UI — Architectural Access Control](#4-the-blind-ui--architectural-access-control)
5. [Shared Responsibility Model — Data Governance](#5-shared-responsibility-model--data-governance)
6. [Regulatory Compliance Mapping](#6-regulatory-compliance-mapping)
7. [Data Subject Rights Operationalization](#7-data-subject-rights-operationalization)
8. [Honest Limitations](#8-honest-limitations)
9. [Data Privacy Roadmap](#9-data-privacy-roadmap)

---

## 1. Executive Summary: Privacy by Design

### The Foundational Principle

VeriLog is built on a single, non-negotiable principle: **sensitive data is a liability, not an asset, until it is explicitly needed.** Every architectural decision in VeriLog's data layer flows from this premise.

VeriLog treats sensitive forensic data as a toxic asset — something that must be contained in an encrypted vault, accessible only to explicitly authorized principals via deliberate forensic tooling, and never exposed to the broad internal surface area of a web application.

The result is an audit logging system that is fundamentally incompatible with accidental data exposure. The React dashboard — the surface through which the majority of your team will interact with audit data daily — is **architecturally incapable** of displaying the sensitive data stored in the `metadata` vault. This is not a permission setting or a feature flag. It is a structural property of the system: the API response schema does not include the field, and the frontend has no code path to request it.

### The Regulatory Compliance Problem This Solves

The dominant data privacy challenge facing compliance teams is not malicious exfiltration — it is **accidental exposure by well-intentioned internal employees** using systems that were not designed with containment in mind. A customer support agent who inadvertently sees a stored credential while resolving a ticket. A junior developer debugging production who reads a log entry containing a health record. A BI analyst exporting a CSV that includes columns that should never have been included.

VeriLog eliminates this class of problem architecturally, not operationally.

### Privacy by Design — Seven Principles (ISO/IEC 29101)

| Principle | VeriLog Implementation |
|-----------|----------------------|
| **Proactive, not reactive** | Encryption at ingestion — data never stored unprotected, even transiently |
| **Privacy as the default** | `metadata` is always encrypted; no opt-in required by the integrator |
| **Privacy embedded into design** | Encryption is part of the application architecture, not a bolt-on |
| **Full functionality** | Two-tier model provides full operational searchability without sacrificing privacy |
| **End-to-end security** | Ciphertext at rest, hash chain for integrity, required TLS for transit |
| **Visibility and transparency** | This document; `GET /v1/verify` for self-auditable chain integrity |
| **Respect for user privacy** | PII directed to encrypted vault; classification guidance enforced by policy |

---

## 2. Data Classification Framework

### 2.1 VeriLog's Native Two-Tier Model

VeriLog's data model is explicitly designed around a two-tier classification scheme:

```
┌─────────────────────────────────────────────────────────────────────┐
│                       AUDIT LOG ENTRY                               │
│                                                                     │
│   TIER 1 — OPERATIONAL DATA          TIER 2 — SENSITIVE VAULT       │
│   ┌───────────────────────────┐      ┌────────────────────────────┐ │
│   │         tags              │      │         metadata           │ │
│   │  Classification: Public   │      │  Classification: Private   │ │
│   │  Storage: JSONB plaintext │      │  Storage: BYTEA ciphertext │ │
│   │  GIN full-text indexed    │      │  Not indexed               │ │
│   │  Dashboard: VISIBLE       │      │  Dashboard: NEVER VISIBLE  │ │
│   │  API response: INCLUDED   │      │  API response: EXCLUDED    │ │
│   │  Data exports: INCLUDED   │      │  Data exports: EXCLUDED    │ │
│   └───────────────────────────┘      └────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 Tier 1 — Operational Data (`tags`)

Designed for non-sensitive operational metadata that provides business value through searchability and dashboard visibility.

**Appropriate data for `tags`:**
- Environment identifiers: `{"env": "production", "region": "eu-west-1"}`
- Service and component identifiers: `{"service": "payment-processor", "version": "3.1.2"}`
- Non-identifying request metadata: `{"method": "POST", "status_code": "200"}`
- Business domain context (non-personal): `{"plan": "enterprise", "billing_cycle": "annual"}`

> **Governance Rule:** Data in `tags` must be treated as observable by any authenticated dashboard user. Your privacy classification policy must explicitly prohibit personal data, credentials, financial data, or health data from this field. This is a **customer engineering responsibility** — VeriLog does not enforce it technically.

### 2.3 Tier 2 — Sensitive Data Vault (`metadata`)

Designed for sensitive forensic context that must be preserved for compliance but must never be accessible to the broad operational user base.

**Mandatory data types for `metadata`:**

| Data Category | Regulatory Driver |
|--------------|-----------------|
| End-user email addresses, names, phone numbers | GDPR, CCPA |
| Financial data: card type, bank identifiers, error codes | PCI DSS |
| Health-related identifiers or condition codes | HIPAA |
| Authentication event details: failure reasons, attempt counts | SOC 2 |
| Stack traces and exception messages with internal paths | Internal privacy policy |
| Any credentials, tokens, or secret values | Security policy — no exception |

> **Governance Rule:** Any data that could identify a natural person, constitute a protected health record, or carry financial instrument details **must** be placed in `metadata`. This routing decision lives in integration code and must be enforced by engineering policy and code review.

### 2.4 System-Captured Fields

VeriLog automatically captures these fields server-side — not from client-supplied payloads:

| Field | Classification | Note |
|-------|---------------|------|
| `source_ip` | Potentially PII (GDPR Recital 30) | If end-user-facing services, assess whether IP constitutes personal data in your jurisdiction |
| `user_agent` | Generally non-personal | Stored plaintext |
| `device_type` | Derived (`desktop`/`mobile`/`tablet`/`bot`) | Stored plaintext |
| `created_at` | Non-personal | UTC timestamp |
| `hash`, `prev_hash` | Cryptographic chain fields | SHA-256 digests |

> **DPO Note on `source_ip`:** Under GDPR, IP addresses are personal data when they can be linked to a natural person. If your audit events relate to end-user actions, your legal team must assess whether storing `source_ip` in plaintext is consistent with Article 5(1)(c) data minimization.

---

## 3. Data Lifecycle Management

### 3.1 Ingestion — Write-Time Encryption

The encryption decision occurs in FastAPI application memory before the database driver is invoked:

```
Client Request
     │
     ▼
[ Request parsed by Pydantic schema ]
     │
     ▼
[ SHA-256 hash chain updated — includes metadata ciphertext in hash input ]
     │
     ▼
[ metadata plaintext → Fernet.encrypt() → ciphertext ]   ← plaintext exists ONLY here
     │                                                      (microseconds, heap only)
     ▼
[ PostgreSQL INSERT: metadata stored as BYTEA ciphertext only ]
```

The plaintext value of `metadata` exists only in the Python process heap for the duration of the encryption operation. It is never serialized to disk, never written to a log file, and never transmitted over a network connection.

### 3.2 Storage — The Encrypted Database

PostgreSQL stores `metadata` as `BYTEA`. The database engine has no knowledge of the original structure or content. A full database dump reveals only binary ciphertext in this column — computationally indistinguishable from random noise without the encryption key.

Alongside the encrypted payload, each entry maintains:
- **`hash` and `prev_hash`** — SHA-256 chain fields providing tamper evidence for the entire record, including the encrypted payload
- **`tags`** — plaintext JSONB, GIN-indexed
- **All structured columns** (actor, action, level, environment, etc.) — plaintext

### 3.3 Retrieval — The Serialization Firewall

The `LogEntryOut` Pydantic schema structurally excludes the `metadata` column. The omission is not a permission check — the column is simply not part of the response model. This means:

- A database query returning all columns does not produce `metadata` in the API response
- An XSS attack on the React dashboard cannot exfiltrate `metadata` — the data is never present in the browser's memory or DOM
- A misconfigured logging middleware recording API responses does not capture `metadata`

The only path to `metadata` plaintext: **possession of the encryption key + direct database access + explicit decryption operation.**

### 3.4 The Immutable Ledger

Each entry's hash is computed over a deterministic concatenation that includes the raw bytes of the `metadata` ciphertext:

```
hash = SHA-256(prev_hash + created_at + actor + action + target_type + target_id + hex(metadata_ciphertext))
```

This means any modification to the ciphertext — even without the decryption key — breaks the chain at that entry. Deletion, insertion of synthetic entries, or reordering are all mathematically detectable via `GET /v1/verify`, which can be independently reimplemented by an auditor using only a database connection and these hash rules.

### 3.5 Retention — Time-Bound Data Governance

| Aspect | Behavior |
|--------|---------|
| Configuration | `RETENTION_DAYS` (server-side; default `0` = retain indefinitely) |
| Mechanism | Hourly background process; drops entire monthly PostgreSQL partitions |
| Deletion type | True, permanent deletion — no soft-delete, no tombstone |
| Chain integrity | `POST /v1/checkpoints` must precede any partition drop to preserve mathematical chain verifiability |

Partition-level deletion is relevant for GDPR Article 5(1)(e) storage limitation compliance: dropping a partition releases tablespace pages to the OS — not a logical deletion masking retained data.

---

## 4. The Blind UI — Architectural Access Control

### 4.1 Why the Dashboard is Intentionally Blind

The most significant internal data governance risk is **inadvertent exposure through overly permissive tools**. When an audit log viewer shows everything, preventing PII exposure becomes a permanent operational burden: policies accumulate exceptions, access reviews drift, and a single misconfiguration creates an exposure.

VeriLog eliminates this category through architectural design:

| Scenario | Traditional Log Viewer | VeriLog |
|----------|----------------------|---------|
| Customer support resolves a ticket | May see stored credentials, session tokens, PII in error details | Sees actor, action, timestamp, `tags`. Metadata: architecturally inaccessible |
| Junior developer debugs production | May see exception messages with PII, internal paths | Sees structured fields. Sensitive forensic detail: inaccessible |
| BI analyst exports logs for reporting | May inadvertently include PII columns in CSV | Export schema mirrors API response schema — metadata excluded by architecture |
| Disgruntled employee with dashboard access | Can read stored PII before access revocation | Cannot read `metadata` regardless of dashboard access level |

### 4.2 The Authorized Forensic Path

Access to plaintext `metadata` requires:

1. Physical or network-level access to the PostgreSQL database (not exposed outside Docker network)
2. The encryption key (stored separately in `server_data` Docker volume)
3. Explicit decryption tooling (Forensic Export CLI — see Roadmap, Section 9)

This creates a **chain of custody**: every `metadata` access requires a deliberate, auditable action by an authorized person. It cannot happen accidentally.

### 4.3 Internal Access Governance Recommendations

| Practice | Rationale |
|----------|-----------|
| Separate DB credentials from application API keys | API key compromise cannot yield database access |
| Store encryption key in a secrets manager separate from DB credentials | Dual-key requirement for forensic access |
| Require manager authorization before issuing forensic DB credentials | Creates an approval workflow for sensitive data access |
| Log forensic operations in VeriLog itself | Use the audit system to audit the auditors |
| Review dashboard user list quarterly | Promptly deactivate accounts for departed personnel |

---

## 5. Shared Responsibility Model — Data Governance

> This section defines the precise boundary between what VeriLog's software guarantees and what your organization's data governance program must provide. Ambiguity in this boundary is where compliance programs fail.

### 5.1 What VeriLog Automates

| Guarantee | Mechanism |
|-----------|-----------|
| Sensitive data encrypted at rest | Fernet AES-128-CBC applied in application memory before DB write |
| Sensitive data excluded from all API responses | `LogEntryOut` schema structural exclusion |
| Sensitive data excluded from all data exports | Export router uses the same response schema |
| Tamper-evident audit trail | SHA-256 hash chain — independently verifiable |
| No external data transmission | Zero outbound network calls at runtime |
| Cryptographically secure key generation | Auto-generated from `/dev/urandom` on first boot |
| True deletion on retention policy | Partition-level PostgreSQL drop, not logical deletion |

### 5.2 What Your Organization Must Provide

#### A. Data Tagging Discipline — Engineering Policy

> **This is the highest-risk gap in VeriLog deployments. VeriLog encrypts what it is given. If your engineers place PII into `tags`, that data is stored in plaintext.**

Your data governance program must establish and enforce a classification policy defining which data belongs in `metadata` (encrypted) vs. `tags` (plaintext). Enforce it through:
- Code review checklists at every `POST /v1/log` call site
- Static analysis linting rules auditing `tags` payloads
- Periodic review of live `tags` values for misclassified data

**Data classification decision matrix:**

| Question | If YES → | If NO → |
|----------|---------|---------|
| Could this value identify a living individual? | `metadata` | Evaluate further |
| Is this value subject to GDPR, CCPA, or HIPAA? | `metadata` | Evaluate further |
| Would exposure cause harm to a customer? | `metadata` | `tags` likely acceptable |
| Is this value a credential, token, or secret of any kind? | `metadata` — no exception | — |

#### B. Encryption Key Lifecycle Management — Critical

| Lifecycle Event | Required Action | Consequence of Inaction |
|----------------|----------------|------------------------|
| Initial deployment | Back up `config.json` to a secure, off-host secrets store | Disk failure = permanent, irrecoverable loss of all `metadata` |
| Regular operations | Verify backup integrity quarterly | Backup corruption discovered only during recovery |
| Suspected key exposure | Rotate key immediately via `MultiFernet`; investigate scope | All historical `metadata` can be decrypted offline |
| Infrastructure migration | Transfer key as part of migration plan | All historical metadata becomes permanently unreadable |
| Personnel change | Rotate if departed administrator had key access | Potential unauthorized offline decryption |

> **Crypto-shredding:** Intentionally deleting the encryption key renders all `metadata` encrypted with it permanently and irrecoverably unreadable — without modifying any database records (which would break the hash chain). This is the correct technique for GDPR Article 17 Right to Erasure when deleting individual audit records is impermissible due to evidentiary or legal preservation requirements.

#### C. Retention Policy Configuration

| Obligation | Action in VeriLog |
|-----------|-----------------|
| Define retention periods per data class | Configure `RETENTION_DAYS`; set per deployment environment |
| Checkpoint before retention drops | Run `POST /v1/checkpoints` before any partition is deleted |
| Document retention decisions | Maintain a data retention register mapping VeriLog environments to retention schedules |

#### D. TLS Termination

VeriLog does not terminate TLS. Without a TLS-terminating proxy upstream, API keys and session tokens transit the network in plaintext.

> **Requirement:** Provision a TLS-terminating reverse proxy (Caddy, Traefik, AWS ALB, or equivalent) in front of VeriLog for all production deployments.

---

## 6. Regulatory Compliance Mapping

> **Disclaimer:** This is an honest, good-faith technical assessment — not legal advice or a compliance certification. Your legal team must assess applicability to your specific circumstances and jurisdiction.

### 6.1 GDPR (Regulation (EU) 2016/679)

| Article | Requirement | VeriLog Control | Customer Obligation |
|---------|-------------|-----------------|-------------------|
| Art. 5(1)(c) | Data minimization | Two-tier model routes non-essential data to encrypted vault | Define and enforce `tags` classification policy |
| Art. 5(1)(e) | Storage limitation | Configurable retention; partition-level true deletion | Configure retention periods; checkpoint before drops |
| Art. 5(1)(f) | Integrity & confidentiality | AES-128 at rest; SHA-256 chain | Provision TLS; secure encryption key |
| Art. 17 | Right to erasure | Partition deletion for time-bounded erasure; crypto-shredding for targeted erasure | Assess whether audit records are exempt under Art. 17(3)(b) |
| Art. 25 | Privacy by design | Encryption unconditional; UI blindness is architectural | Enforce data classification in integration code |
| Art. 30 | Records of processing | — | Include VeriLog in your ROPA if personal data is present |
| Art. 32 | Technical measures | AES-128, Argon2id, rate limiting, RLS, hash chain | Provision TLS, host security, key management |
| Art. 33/34 | Breach notification | Hash chain detects unauthorized modification; no automated alerts | Establish monitoring process; VeriLog does not send breach alerts |
| Art. 44–49 | Third-country transfers | Zero outbound transmission — structurally impossible | Verify hosting jurisdiction aligns with transfer rules |

### 6.2 CCPA / CPRA (California Consumer Privacy Act)

| Obligation | VeriLog Relevance | Customer Action |
|-----------|------------------|----------------|
| Right to Know | VeriLog records may contain personal information (actor fields, IP) | Establish DSAR process covering VeriLog records; map `actor` conventions to identities |
| Right to Delete | Applies if VeriLog holds personal information not exempt as business records | Use partition deletion or crypto-shredding for targeted erasure |
| Right to Opt-Out of Sale | VeriLog holds no data outside customer infrastructure | Zero data egress — not applicable to VeriLog itself |
| Sensitive Personal Information (CPRA) | Financial data, health data, credentials | Route all SPI to `metadata`; never to `tags` |

### 6.3 HIPAA (Health Insurance Portability and Accountability Act)

| Safeguard | VeriLog Control | Gap / Customer Action |
|-----------|----------------|----------------------|
| §164.312(a)(2)(iv) — Encryption | Fernet AES-128 for `metadata` at rest | ePHI in `tags` = plaintext; data classification discipline required |
| §164.312(b) — Audit controls | Immutable hash-chained audit log | — |
| §164.312(c) — Integrity | SHA-256 chain — modifications detectable | — |
| §164.312(e) — Transmission security | **Customer responsibility** | Provision TLS proxy |

> **BAA Note:** VeriLog is self-hosted software operating within your infrastructure. The customer operates the software — VeriLog (the software project) does not itself constitute a Business Associate. Consult legal counsel to determine if a BAA is required for your specific deployment model.

### 6.4 ISO/IEC 27001:2022

| Control | VeriLog Implementation |
|---------|----------------------|
| A.8.15 — Logging | Immutable, tamper-evident audit log |
| A.8.16 — Monitoring | `GET /v1/verify` for chain integrity monitoring |
| A.8.24 — Use of cryptography | AES-128-CBC, SHA-256, Argon2id, HS256 JWT |
| A.5.18 — Access rights | Role-based access (admin/viewer), tenant isolation, RLS |

---

## 7. Data Subject Rights Operationalization

### 7.1 Data Subject Access Request (DSAR) — GDPR Art. 15 / CCPA Right to Know

**Step 1 — Identify relevant records:**
Query by actor value corresponding to the data subject:
```
GET /v1/logs?actor=user:alice@example.com&start_date=YYYY-MM-DD&end_date=YYYY-MM-DD
```

**Step 2 — Assess `metadata` content:**
The API response excludes `metadata`. If your DSAR obligations require disclosure of its contents, this requires a forensic database operation — a deliberate, logged action requiring the encryption key and direct database access.

**Step 3 — Export and deliver:**
```
GET /v1/export?actor=user:alice@example.com&format=jsonl
```
The export excludes `metadata` by architecture. Document this exclusion in your DSAR response procedure.

---

### 7.2 Right to Erasure — GDPR Art. 17 / CCPA Right to Delete

**First — Assess whether erasure is permissible:**

Audit records frequently fall under GDPR Article 17(3)(b) (compliance with a legal obligation) or 17(3)(e) (establishment or defense of legal claims). If your audit trail has evidentiary or regulatory preservation requirements, individual record deletion may be legally impermissible. **Consult your legal team before deleting audit records.**

**Option A — Retention-based deletion (preferred for time-bounded erasure):**
Configure `RETENTION_DAYS` so that records older than your retention period are automatically deleted. Operationally simple; defensible under Article 5(1)(e).

**Option B — Crypto-shredding (for targeted metadata erasure):**
Delete or rotate the encryption key for the records in scope. The `metadata` ciphertext becomes permanently and irrecoverably unreadable — achieving functional erasure of sensitive content without deleting the audit records or breaking the hash chain.

**What cannot be erased without breaking the chain:**
The `hash`, `prev_hash`, `actor`, `action`, `created_at`, and `tags` fields are part of the hash chain input. Modifying or deleting any of these fields in a historical record breaks the chain at that point. This is an inherent tension between data immutability (required for compliance with audit trail integrity requirements) and the right to erasure.

> **Recommended approach:** Engage legal counsel to determine whether your audit records are exempt from erasure under Article 17(3). For most audit trails, the evidentiary function provides a legitimate basis for retention. For the `metadata` vault specifically, crypto-shredding provides erasure of sensitive content without chain disruption.

---

### 7.3 Data Portability — GDPR Art. 20

VeriLog supports data export in two machine-readable formats:
- **JSONL** (`GET /v1/export?format=jsonl`) — suitable for programmatic processing
- **CSV** (`GET /v1/export?format=csv`) — suitable for spreadsheet review

Both formats exclude `metadata`. Date range, actor, environment, and other filter parameters are supported to scope the export to records relevant to the data subject.

---

## 8. Honest Limitations

VeriLog is committed to transparency about the boundaries of its current capabilities. The following limitations exist in the current release:

| Limitation | Detail | Honest Implication |
|-----------|--------|--------------------|
| **No built-in TLS termination** | Nginx listens on HTTP; TLS must be provisioned upstream | Without a TLS proxy, data transits in plaintext — unacceptable for production |
| **No automated PII detection** | VeriLog does not scan `tags` for inadvertently placed PII | Data misclassification by engineers is entirely undetected and unblocked |
| **No individual record deletion** | Deletion is partition-level (monthly), not record-level | Right to Erasure for specific records requires crypto-shredding or legal exemption |
| **No automated DSAR tooling** | DSAR response requires manual API queries and forensic database access for `metadata` | Response time for DSARs is operationally dependent on customer process |
| **No formal compliance certification** | VeriLog has not undergone a third-party SOC 2 audit | This document provides controls mapping; formal attestation requires independent auditor |
| **`source_ip` stored in plaintext** | IP addresses are not encrypted even when they may constitute personal data | Assess your jurisdiction's treatment of IP addresses; consider not sending them or requesting this be configurable in your deployment |
| **No automated breach alerting** | Chain verification requires manual trigger (`GET /v1/verify`) or scheduled automation | Tamper detection is available but not push-notified; customer must implement monitoring |
| **No SSO / SAML / OIDC** | Authentication is username/password only | No integration with enterprise identity providers or centralized access revocation |

---

## 9. Data Privacy Roadmap

The following capabilities represent our commitment to expanding VeriLog's data governance capabilities for enterprise and regulated industry deployments.

### Near-Term

**Granular Data Retention Rules**  
Per-tenant and per-environment retention configuration. Enables organizations to apply different retention schedules to different data classes — for example, HIPAA-governed audit events retained for 6 years while general operational events are dropped after 90 days.

**Forensic Export CLI**  
A standalone, read-only command-line tool for authorized investigators. Connects directly to PostgreSQL, decrypts `metadata` using a provided key, verifies the hash chain, and outputs a cryptographically signed, tamper-evident export file. Designed for evidence preservation in incident response, legal proceedings, and regulatory audits. Produces a documented chain of custody record for every execution.

**Audit Trail Self-Logging**  
VeriLog logs its own administrative operations (API key creation/revocation, user provisioning, login events, retention policy changes, key rotation) as tamper-evident system-tagged audit entries — a self-referential audit trail for the audit system itself.

### Medium-Term

**Automated PII Detection & Warning**  
A configurable scanning layer that inspects incoming `tags` payloads for patterns consistent with common PII types (email addresses, phone numbers, credit card patterns, national ID formats). Generates warnings or blocks ingestion based on policy configuration. Designed as a safety net to catch data misclassification errors in integration code.

**`source_ip` Encryption Toggle**  
An optional configuration to route `source_ip` into the encrypted `metadata` vault rather than storing it in plaintext, for jurisdictions where IP addresses constitute personal data and must be protected accordingly.

**Compliance Report Generation**  
Pre-formatted PDF and Excel reports for SOC 2, GDPR, and HIPAA auditors. Reports include: chain verification summary, access control summary, key rotation history, retention policy compliance, and data classification policy documentation. Report generation requires admin password re-confirmation and is itself logged as an audit event.

**RBAC — Granular Role-Based Access Control**  
Permissions scoped beyond the current admin/viewer model: read-only access scoped to specific tenants or date ranges, export permission gate, verification access control, and time-limited forensic access grants.

### Long-Term

**SSO Integration (SAML 2.0 + OIDC)**  
Native integration with enterprise identity providers — Okta, Microsoft Entra ID, Google Workspace, and any SAML 2.0-compatible IdP. Enables centralized identity lifecycle management: provisioning and immediate revocation via the IdP, single point of access control for all VeriLog instances.

**HSM / KMS Integration for Key Management**  
Native integration with Hardware Security Modules (Thales, Entrust, AWS CloudHSM) and cloud key management services (AWS KMS, GCP Cloud KMS, Azure Key Vault, HashiCorp Vault). The encryption key material never exists in software memory — generated, stored, and operated within the HSM boundary. Relevant for FIPS 140-2 Level 3 compliance requirements.

**Crypto-Shredding by Data Class**  
Configuration of multiple encryption keys scoped to specific data classes, tenants, or time periods. Enables targeted, granular cryptographic erasure: deleting the key for one data class renders only that class's `metadata` unreadable, while preserving all other data. Direct support for GDPR Article 17 Right to Erasure without requiring full partition deletion.

**SIEM & Webhook Integration**  
Real-time forwarding of critical-severity events and chain verification failures to SIEM platforms (Splunk, Microsoft Sentinel, IBM QRadar) and webhook endpoints. Enables VeriLog's tamper detection to trigger automated incident response workflows.

---

*VeriLog is open source software provided under the MIT License. This document describes the data governance architecture of VeriLog as of the version current at the document date. For the latest information, consult the project repository.*
