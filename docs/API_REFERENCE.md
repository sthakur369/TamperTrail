# VeriLog — API Reference

**Base URL:** `http://your-host` (all traffic enters via Nginx on port 80)
**API prefix:** Every endpoint starts with `/v1`

---

## Table of Contents

1. [API Taxonomy — What To Use](#1-api-taxonomy)
2. [Authentication](#2-authentication)
3. [Data Dictionary — Ingest Payload](#3-data-dictionary)
4. [Integration APIs (Public)](#4-integration-apis)
5. [Dashboard & System APIs](#5-dashboard--system-apis)
6. [HTTP Status Code Reference](#6-http-status-code-reference)
7. [Rate Limits](#7-rate-limits)

---

## 1. API Taxonomy

Not all endpoints are meant for you. Read this first.

### 1.1 Integration APIs — Use These in Your Application Code

These are the endpoints your backend services call. They authenticate with an **API Key** in the `X-API-Key` header.

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST` | `/v1/log` | **The main event.** Send an audit log entry. |
| `GET`  | `/health` | Health probe for load balancers and uptime monitors. |

> **That's it.** As an integration developer, these two are the only endpoints your application code needs.

---

### 1.2 Dashboard & System APIs — Internal / Do Not Call From App Code

These exist to power the React dashboard and for system administration. **Standard developers should not call these from application code.** They require a JWT session cookie — not an API key.

| Category | Endpoints |
|----------|-----------|
| Authentication | `/v1/auth/login`, `/v1/auth/logout`, `/v1/auth/me`, `/v1/auth/password` |
| Setup Wizard | `/v1/setup`, `/v1/setup/status` |
| Log Search | `/v1/logs`, `/v1/environments` |
| Statistics | `/v1/stats` |
| Chain Verification | `/v1/verify`, `/v1/verify/deep`, `/v1/checkpoints` |
| Data Export | `/v1/export` |
| API Key Management | `/v1/keys` |
| User Management | `/v1/users` |
| Admin Settings | `/v1/admin/settings`, `/v1/admin/license`, `/v1/admin/retention` |
| Project Management | `/v1/tenants/me` |

Full docs for all of these are in [Section 5](#5-dashboard--system-apis).

---

## 2. Authentication

VeriLog uses **two separate authentication systems**. Never mix them up.

### 2.1 API Key — For Sending Logs

Create a key in the dashboard under **API Keys → Create Key**. The raw key is shown **only once**.

Pass it as an HTTP header on every request:

```
X-API-Key: vl_a1b2c3d4e5f6...
```

Keys are stored Argon2-hashed. A lost key cannot be recovered — revoke it and create a new one.

> **Never hardcode an API key.** Use an environment variable: `VERILOG_API_KEY=vl_...`

### 2.2 JWT Session — For the Dashboard

The browser dashboard handles this automatically via an `HTTPOnly` cookie (`verilog_token`) set at login. Tokens expire after 24 hours. One active session per user — logging in from a new location ends the previous session.

---

## 3. Data Dictionary

### 3.1 Ingest Payload Schema — `POST /v1/log`

| Field | Required | Type | Constraint | Description |
|-------|----------|------|-----------|-------------|
| `actor` | **YES** | string | max 255 chars | Who performed the action. Use a consistent format: `"user:alice@acme.com"`, `"service:billing-worker"`, `"cron:nightly-sync"` |
| `action` | **YES** | string | max 255 chars | What happened. Use `"resource.verb"` convention: `"invoice.created"`, `"user.login.failed"`, `"file.deleted"` |
| `level` | no | string | one of `DEBUG`, `INFO`, `WARN`, `ERROR`, `CRITICAL` | Explicit severity. Overrides auto-detection. Case-insensitive. |
| `message` | no | string | max 1,000 chars | Plain-English description a human will read first. |
| `target_type` | no | string | max 255 chars | Type of resource affected: `"Invoice"`, `"User"`, `"Document"`, `"ApiKey"` |
| `target_id` | no | string | max 255 chars | ID of the specific resource: `"inv_9f2a"`, `"usr_0012"` |
| `status` | no | string | max 50 chars | Outcome. Accepts HTTP codes (`"200"`, `"404"`) or strings (`"success"`, `"failed"`, `"timeout"`). Default: `"200"` |
| `environment` | no | string | max 100 chars | Deployment environment. Default: `"production"`. Common: `"staging"`, `"test"` |
| `source_ip` | no | string | valid IP | End-user or system IP. If omitted, VeriLog uses the API caller's IP automatically. |
| `request_id` | no | string | max 255 chars | Your own trace/correlation ID. **Idempotency key** — duplicate `request_id` within 10 minutes is silently dropped. |
| `tags` | no | object | any JSON object | **Searchable, plaintext** key-value pairs. GIN-indexed JSONB. Visible in the dashboard. |
| `metadata` | no | object | any JSON object | **Encrypted** key-value payload. Fernet AES-128. Never returned by the API. Never shown in the UI. |

#### `level` to Severity Mapping

| `level` you send | Severity in dashboard |
|------------------|-----------------------|
| `DEBUG` | info (blue) |
| `INFO` | info (blue) |
| `WARN` | warning (amber) |
| `ERROR` | critical (red) |
| `CRITICAL` | critical (red) |

#### Auto-Severity Fallback (when `level` is omitted)

VeriLog scans the `action` string for keywords:

| Dashboard Severity | Action contains any of... |
|--------------------|--------------------------|
| `critical` | `delete`, `destroy`, `revoke`, `drop`, `purge`, `wipe` |
| `warning` | `update`, `edit`, `modify`, `change`, `patch`, `rename` |
| `info` | anything else |

---

### 3.2 The `tags` vs. `metadata` Decision

This is the most important design decision you will make when integrating VeriLog.

| | `tags` | `metadata` |
|--|--------|-----------|
| Storage | Plaintext JSONB | Fernet AES-128 encrypted BYTEA |
| Searchable in dashboard | ✅ Yes (GIN index) | ❌ No |
| Visible in dashboard | ✅ Yes | ❌ Never |
| Returned by API | ✅ Yes | ❌ Never |
| Use for | Context you want to filter and display | Sensitive forensic data |

**Simple rule:**
- Comfortable showing on a team dashboard? → `tags`
- Contains PII, secrets, stack traces, or internal system details? → `metadata`

---

### 3.3 Auto-Captured Fields

You do **not** need to provide these. The server captures them automatically.

| Field | Source |
|-------|--------|
| `source_ip` | Request IP (reads `X-Forwarded-For` from Nginx). Overridable via body. |
| `user_agent` | `User-Agent` HTTP header of the API caller |
| `device_type` | Parsed from user-agent: `desktop`, `mobile`, `tablet`, `bot`, or `null` |
| `created_at` | Server UTC clock. Clock-skew protected — monotonically increasing per tenant. |
| `id` | UUID v4, server-generated |
| `hash` | SHA-256 of this entry, chained from `prev_hash` |

---

## 4. Integration APIs

---

### `POST /v1/log`

**Purpose:** Ingest a single audit log entry.
**Auth:** `X-API-Key` header
**Response:** `202 Accepted` — log is written to the WAL on disk and queued for batch DB insertion. The response does not wait for the DB write.

#### Minimal Request

```json
{
  "actor": "user:alice@acme.com",
  "action": "document.downloaded"
}
```

#### Full Request

```json
{
  "actor":       "user:alice@acme.com",
  "action":      "payment.processed",
  "level":       "INFO",
  "message":     "Payment of $149.00 processed via Stripe.",
  "target_type": "Invoice",
  "target_id":   "inv_9f2a3b4c",
  "status":      "200",
  "environment": "production",
  "request_id":  "req_trace_abc123",
  "tags": {
    "payment_provider": "stripe",
    "amount_usd":       149.00,
    "plan":             "pro"
  },
  "metadata": {
    "card_last4":    "4242",
    "stripe_charge": "ch_3abc123def",
    "billing_email": "alice@acme.com"
  }
}
```

#### Success Response

```json
{ "status": "accepted", "message": "Log queued for processing" }
```

#### Error Responses

| Code | Cause |
|------|-------|
| `401` | Missing or invalid `X-API-Key` |
| `403` | API key is revoked |
| `422` | `actor` or `action` missing, or any field exceeds its max length |
| `429` | Rate limit exceeded — 100 req/min per IP |
| `503` | WAL disk full. Free disk space and retry. |

---

### Code Examples — `POST /v1/log`

> For all examples: replace `$VERILOG_API_KEY` with your key and `localhost` with your host.

---

#### cURL

```bash
# A — Informational log
curl -X POST http://localhost/v1/log -H "X-API-Key: $VERILOG_API_KEY" -H "Content-Type: application/json" \
  -d '{"actor":"user:alice@acme.com","action":"user.login","level":"INFO","message":"User logged in.","tags":{"browser":"Chrome","region":"eu-west-1"}}'

# B — Error log (stack trace encrypted in metadata — never shown in dashboard)
curl -X POST http://localhost/v1/log -H "X-API-Key: $VERILOG_API_KEY" -H "Content-Type: application/json" \
  -d '{"actor":"service:payment-worker","action":"payment.charge.failed","level":"ERROR","status":"timeout","tags":{"provider":"stripe"},"metadata":{"exception":"ConnectionTimeout","stack_trace":"..."}}'
```

---

#### Python

```python
import httpx, traceback

# A — Informational log
httpx.post("http://localhost/v1/log", headers={"X-API-Key": API_KEY},
    json={"actor": "user:alice@acme.com", "action": "user.login", "level": "INFO", "tags": {"browser": "Chrome"}})

# B — Exception log (sensitive details encrypted in metadata)
try:
    stripe.charge(invoice_id, amount)
except Exception as exc:
    httpx.post("http://localhost/v1/log", headers={"X-API-Key": API_KEY},
        json={"actor": "service:worker", "action": "payment.charge.failed", "level": "ERROR",
              "metadata": {"exception": type(exc).__name__, "stack_trace": traceback.format_exc()}})
```

---

#### Node.js

```javascript
const post = (body) => fetch('http://localhost/v1/log',
  { method: 'POST', headers: { 'X-API-Key': API_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });

// A — Informational log
post({ actor: 'user:alice@acme.com', action: 'user.login', level: 'INFO', tags: { browser: 'Chrome' } });

// B — Exception log
try { stripe.charge(invoiceId, amount); }
catch (err) { post({ actor: 'service:worker', action: 'payment.charge.failed', level: 'ERROR',
                     metadata: { exception: err.constructor.name, stack_trace: err.stack } }); }
```

---

#### Java

```java
// Helper (inline or extract to method)
var client = HttpClient.newHttpClient();
Function<String, HttpRequest> req = body -> HttpRequest.newBuilder()
    .uri(URI.create("http://localhost/v1/log"))
    .header("X-API-Key", API_KEY).header("Content-Type", "application/json")
    .POST(BodyPublishers.ofString(body)).build();

// A — Informational log
client.send(req.apply("{\"actor\":\"user:alice\",\"action\":\"user.login\",\"level\":\"INFO\",\"tags\":{\"browser\":\"Chrome\"}}"), BodyHandlers.discarding());

// B — Exception log
try { stripe.charge(invoiceId, amount); }
catch (Exception e) {
    String body = String.format("{\"actor\":\"service:worker\",\"action\":\"payment.failed\",\"level\":\"ERROR\",\"metadata\":{\"error\":\"%s\"}}", e.getMessage());
    client.send(req.apply(body), BodyHandlers.discarding());
}
```

---

### `GET /health`

**Purpose:** Returns the live status of the server, database, and ingestion queue. No authentication required. Suitable for load balancer health probes.

**Auth:** None

**Response:** `200 OK`

```json
{
  "status": "ok",
  "db": "ok",
  "queue_depth": 0,
  "wal_entries": 0
}
```

If the database is unreachable, `"db"` will be `"error"` and the status code will be `503`.

---

## 5. Dashboard & System APIs

> These endpoints power the React dashboard. They require a **JWT session cookie** (`verilog_token`) obtained from `POST /v1/auth/login`. Do not call them from your application's integration code.

---

### 5.1 Authentication

---

#### `POST /v1/auth/login`

**Purpose:** Authenticate with username and password. Sets an `HTTPOnly` JWT session cookie valid for 24 hours. Invalidates any previous active session for that user.

**Auth:** None

**Request Body:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `username` | YES | string | Case-insensitive. Default admin username is `admin`. |
| `password` | YES | string | Min 8 chars (set during setup). |

**Success:** `200 OK` — sets `verilog_token` cookie and returns `{"token": "...", "expires_in": 86400}`.

**Errors:** `401` wrong credentials, `403` account deactivated.

> **Rate limit:** 5 requests/minute per IP.

---

#### `POST /v1/auth/logout`

**Purpose:** Clears the session cookie and marks the session as ended in the database.

**Auth:** JWT

**Request Body:** None

**Success:** `200 OK` → `{"status": "ok"}`

---

#### `GET /v1/auth/me`

**Purpose:** Returns the current user's identity, role, and list of tenants they can access.

**Auth:** JWT

**Success:** `200 OK`

```json
{
  "authenticated": true,
  "user_id": "uuid",
  "username": "admin",
  "role": "admin",
  "allowed_tenants": ["uuid-1", "uuid-2"]
}
```

---

#### `PUT /v1/auth/password`

**Purpose:** Change your own password. Ends all your active sessions — you must log in again.

**Auth:** JWT

**Request Body:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `current_password` | YES | string | Must match current password. |
| `new_password` | YES | string | Min 6 chars. |

**Success:** `200 OK` → `{"status": "ok", "message": "Password changed. Please log in again."}`

**Errors:** `401` current password wrong.

---

### 5.2 Setup Wizard

---

#### `GET /v1/setup/status`

**Purpose:** Check if the first-boot setup has been completed.

**Auth:** None

**Success:** `200 OK` → `{"needs_setup": true}` or `{"needs_setup": false}`

---

#### `POST /v1/setup`

**Purpose:** First-boot only. Creates the `admin` user, default tenant, and optionally activates a license. Fails with `409` if setup has already been completed.

**Auth:** None

**Request Body:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `password` | YES | string | Min 8 chars. Sets the admin password. |
| `license_key` | no | string | JWT license key. If invalid, returns `422`. |

**Success:** `200 OK` → `{"status": "ok", "username": "admin", "plan": "Free"}`

---

### 5.3 Log Search & Retrieval

---

#### `GET /v1/logs`

**Purpose:** Paginated, filterable search across all audit logs for the current tenant (real + demo logs merged).

**Auth:** JWT

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `actor` | string | Partial match (case-insensitive). |
| `action` | string | Partial match (case-insensitive). |
| `level` | string | Partial match: `DEBUG`, `INFO`, `WARN`, `ERROR`, `CRITICAL`. |
| `target_type` | string | Exact match. |
| `target_id` | string | Exact match. |
| `environment` | string | Exact match, or comma-separated list: `"production,staging"`. |
| `search` | string | Universal full-text ILIKE across all columns: actor, action, message, tags, hash, IP, etc. |
| `search_fields` | string | Comma-separated column names to scope `search` to, e.g. `"actor,hash"`. Omit to search all. |
| `meta_contains` | string | JSONB containment filter on `tags`. Pass as a JSON string: `{"plan":"pro"}`. Uses GIN index. |
| `start_date` | datetime | ISO 8601 lower bound on `created_at`. |
| `end_date` | datetime | ISO 8601 upper bound on `created_at`. |
| `page` | int | Default: `1`. Min: `1`. |
| `page_size` | int | Default: `50`. Min: `1`. Max: `200`. |

**Success:** `200 OK`

```json
{
  "data": [ { "id": "...", "actor": "...", "action": "...", "severity": "info", "tags": {}, "hash": "...", "created_at": "..." } ],
  "page": 1,
  "page_size": 50,
  "total_count": 1240,
  "total_pages": 25
}
```

---

#### `GET /v1/environments`

**Purpose:** Returns all distinct environment names seen in logs for the current tenant, merged with the tenant's configured allowed environments.

**Auth:** JWT

**Success:** `200 OK` → `{"environments": ["production", "staging", "test", "verilog_test"]}`

---

### 5.4 Statistics

---

#### `GET /v1/stats`

**Purpose:** Returns aggregated statistics for the dashboard overview charts.

**Auth:** JWT

**Query Parameters:** `start_date` (ISO 8601), `end_date` (ISO 8601) — both optional.

**Success:** `200 OK`

```json
{
  "total_logs": 4821,
  "daily_activity": [{ "date": "2025-01-15", "count": 312 }],
  "severity_counts": { "info": 4100, "warning": 600, "critical": 121 },
  "status_counts": { "success": 4200, "client_error": 500, "server_error": 121 },
  "top_actors": [{ "actor": "user:alice@acme.com", "count": 980 }]
}
```

---

### 5.5 Chain Verification

---

#### `GET /v1/verify`

**Purpose:** Verifies the SHA-256 hash chain across a range of logs. Detects any tampered, deleted, or reordered entries. Returns a list of broken links.

**Auth:** JWT

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `start_date` | datetime | Optional lower bound. |
| `end_date` | datetime | Optional upper bound. |
| `limit` | int | Max entries to check. Default: `10000`. Max: `100000`. |

**Success:** `200 OK`

```json
{
  "status": "ok",
  "checked": 4821,
  "broken": 0,
  "result": "Chain is intact."
}
```

If tampering is found, `"status"` will be `"tampered"` and `"broken"` will be non-zero.

---

#### `GET /v1/verify/deep`

**Purpose:** Deep verification — re-encrypts and re-hashes every entry from scratch to detect corruption at the storage layer. Slower but more thorough.

**Auth:** JWT (admin only)

**Query Parameters:** `limit` (int, default `100000`, max `500000`)

**Success:** Same shape as `/v1/verify`.

---

#### `POST /v1/checkpoints`

**Purpose:** Creates a monthly checkpoint hash — a cryptographic snapshot of the chain state at the end of a month. Used to bridge verification gaps caused by log retention pruning.

**Auth:** JWT (admin only)

**Request Body:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `year` | YES | int | e.g. `2025` |
| `month` | YES | int | `1`–`12` |

**Success:** `201 Created`

---

### 5.6 Data Export

---

#### `GET /v1/export`

**Purpose:** Export all logs for the current tenant within a date range. Streamed from the database to avoid memory issues on large datasets.

**Auth:** JWT

**Query Parameters:**

| Parameter | Required | Type | Notes |
|-----------|----------|------|-------|
| `format` | YES | string | `csv` or `jsonl` |
| `from_date` | YES | datetime | ISO 8601 start date |
| `to_date` | YES | datetime | ISO 8601 end date |

**Success:** `200 OK` — streaming file download. `Content-Disposition: attachment; filename="verilog_export.csv"` (or `.jsonl`).

---

### 5.7 API Key Management

---

#### `POST /v1/keys`

**Purpose:** Create a new API key. The raw key value is returned **only once** — it cannot be retrieved again.

**Auth:** JWT (admin only)

**Request Body:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `name` | YES | string | Human-readable label, e.g. `"Production Backend"` |
| `expires_in_days` | no | int | Days until expiry. Omit for non-expiring key. |

**Success:** `201 Created`

```json
{
  "id": "uuid",
  "name": "Production Backend",
  "key": "vl_a1b2c3d4...",
  "key_prefix": "vl_a1b2",
  "created_at": "2025-01-15T10:00:00Z"
}
```

> Save the `key` value now. It will never be shown again.

---

#### `GET /v1/keys`

**Purpose:** List all API keys for the current tenant. Raw key values are never included.

**Auth:** JWT

**Success:** `200 OK` → `{"data": [{"id": "...", "name": "...", "key_prefix": "...", "is_active": true, "created_at": "..."}]}`

---

#### `DELETE /v1/keys/{id}`

**Purpose:** Revoke an API key. Any request using this key will immediately return `403`.

**Auth:** JWT (admin only)

**Path Parameter:** `id` — UUID of the key to revoke.

**Success:** `200 OK` → `{"status": "ok"}`

**Errors:** `404` key not found.

---

#### `DELETE /v1/keys/revoked/all`

**Purpose:** Permanently delete all previously revoked keys from the database (housekeeping).

**Auth:** JWT (admin only)

**Success:** `200 OK` → `{"deleted": 3}`

---

### 5.8 User Management

---

#### `GET /v1/users`

**Purpose:** List all users for the tenant, including their role, permissions, and last login.

**Auth:** JWT (admin only)

**Success:** `200 OK` → `{"data": [...], "max_users": 5, "plan": "Free"}`

---

#### `POST /v1/users`

**Purpose:** Create a new viewer user. Only one admin is allowed — new users are always `viewer` role.

**Auth:** JWT (admin only)

**Request Body:**

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `username` | YES | string | 2–100 chars. Lowercased automatically. Must be unique. |
| `password` | YES | string | Min 6 chars. |
| `role` | no | string | Only `"viewer"` is accepted. Creating another admin is forbidden. |
| `permissions` | no | object | Map of permission flags: `view_logs`, `export_logs`, `manage_keys`, `verify_integrity`, `manage_users`. `view_logs` is always `true`. |
| `allowed_tenants` | no | array | List of tenant UUIDs this user can access. Defaults to the default tenant. |

**Success:** `201 Created` → full user object.

**Errors:** `409` username taken, `403` user limit reached for current license plan.

---

#### `PUT /v1/users/{id}`

**Purpose:** Update a user's active status or permissions.

**Auth:** JWT (admin only)

**Request Body:** All fields optional.

| Field | Type | Notes |
|-------|------|-------|
| `is_active` | bool | Set `false` to deactivate. Ends all their sessions immediately. |
| `permissions` | object | Partial update — only keys you include are changed. |
| `allowed_tenants` | array | Replaces the tenant access list. |

**Success:** `200 OK` → updated user object.

**Errors:** `400` cannot deactivate your own account, `404` user not found.

---

#### `DELETE /v1/users/{id}`

**Purpose:** Permanently delete a user. Requires admin password confirmation.

**Auth:** JWT (admin only)

**Request Body:**

| Field | Required | Notes |
|-------|----------|-------|
| `admin_password` | YES | Your own admin password, for confirmation. |

**Success:** `200 OK` → `{"status": "ok", "message": "User 'bob' has been permanently deleted."}`

**Errors:** `401` wrong admin password, `400` cannot delete yourself or another admin, `404` user not found.

---

#### `PUT /v1/users/{id}/password`

**Purpose:** Admin resets another user's password. Ends all their active sessions.

**Auth:** JWT (admin only)

**Request Body:**

| Field | Required | Notes |
|-------|----------|-------|
| `new_password` | YES | Min 6 chars. |

**Success:** `200 OK` → `{"status": "ok", "message": "Password reset for bob. All sessions ended."}`

---

#### `GET /v1/sessions`

**Purpose:** List the 100 most recent login sessions across all users. Includes IP, user agent, and session status.

**Auth:** JWT (admin only)

**Success:** `200 OK` → `{"data": [{"username": "admin", "ip_address": "...", "is_active": true, "login_at": "..."}]}`

---

### 5.9 Admin Settings & Licensing

---

#### `GET /v1/admin/settings`

**Purpose:** Retrieve current system settings including active license details and retention policy.

**Auth:** JWT (admin only)

**Success:** `200 OK`

```json
{
  "plan": "Free",
  "log_retention_days": 30,
  "max_users": 3,
  "max_tenants": 1,
  "license_expires_at": null
}
```

---

#### `PUT /v1/admin/license`

**Purpose:** Apply or update a VeriLog Pro license key.

**Auth:** JWT (admin only)

**Request Body:**

| Field | Required | Notes |
|-------|----------|-------|
| `license_key` | YES | RS256-signed JWT license key provided by VeriLog. |

**Success:** `200 OK` → `{"status": "ok", "plan": "Pro", "expires_at": "2026-01-01T00:00:00Z"}`

**Errors:** `422` invalid or expired license key.

---

#### `PUT /v1/admin/retention`

**Purpose:** Set how many days of logs to retain. Logs older than this are automatically pruned.

**Auth:** JWT (admin only)

**Request Body:**

| Field | Required | Allowed Values |
|-------|----------|---------------|
| `log_retention_days` | YES | `30`, `90`, `365`, `0` (0 = keep forever) |

**Success:** `200 OK` → `{"status": "ok", "log_retention_days": 90}`

**Errors:** `403` if the requested retention period exceeds what your license allows.

---

### 5.10 Project Management

---

#### `GET /v1/tenants/me`

**Purpose:** Returns the list of tenants the current user has access to, with display names and colors.

**Auth:** JWT

**Success:** `200 OK` → `{"data": [{"id": "uuid", "name": "Acme Corp", "color": "cyan", "is_default": true}]}`

---

## 6. HTTP Status Code Reference

| Code | Meaning | Common Cause |
|------|---------|-------------|
| `200 OK` | Success | Standard successful response |
| `201 Created` | Resource created | New user, key, or checkpoint |
| `202 Accepted` | Queued | Log entry accepted by WAL, not yet written to DB |
| `400 Bad Request` | Invalid request logic | Business rule violation (e.g. deleting yourself) |
| `401 Unauthorized` | Auth failed | Missing/invalid API key or wrong password |
| `403 Forbidden` | Access denied | Revoked key, deactivated account, or license limit |
| `404 Not Found` | Resource missing | User/key with given ID does not exist |
| `409 Conflict` | Duplicate | Setup already done, username already exists |
| `422 Unprocessable Entity` | Schema error | Missing required field, field too long, bad enum value |
| `429 Too Many Requests` | Rate limited | Exceeded per-IP request quota (see Section 7) |
| `503 Service Unavailable` | Server error | Database unreachable, or WAL disk full |

---

## 7. Rate Limits

Rate limiting is enforced by Nginx before requests reach the application server. Limits are **per IP address**.

| Endpoint(s) | Limit | Burst |
|-------------|-------|-------|
| `POST /v1/auth/login` | 5 req/min | 3 |
| `POST /v1/log` | 100 req/min | 20 |
| All other `/v1/*` | 200 req/min | 50 |

When a limit is exceeded, Nginx returns `429 Too Many Requests` with a `Retry-After` header.

> For high-volume ingestion above 100 req/min, batch your logs client-side into arrays and send them in fewer, larger requests — or contact us about a Pro ingestion upgrade.
