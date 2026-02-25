# VeriLog — API Reference

**Base URL:** `http://your-host` (all traffic enters via Nginx on port 80)
**API prefix:** Every endpoint starts with `/v1`

---

## Table of Contents

1. [Authentication](#1-authentication)
2. [Log API — `POST /v1/log`](#2-log-api--post-v1log)
   - [2.1 Payload Schema](#21-payload-schema)
   - [2.2 Tags vs Metadata](#22-the-tags-vs-metadata-decision)
   - [2.3 Severity Auto-Derivation](#23-severity-auto-derivation)
   - [2.4 Auto-Captured Fields](#24-auto-captured-fields)
   - [2.5 Requests & Responses](#25-requests--responses)
   - [2.6 Code Examples](#26-code-examples)
   - [2.7 Automatic Logging — Middleware](#27-automatic-logging--middleware-integration)
3. [Health Check — `GET /health`](#3-health-check--get-health)
4. [HTTP Status Code Reference](#4-http-status-code-reference)
5. [Rate Limits](#5-rate-limits)
6. [Dashboard & System APIs](#6-dashboard--system-apis) *(admin-only, not needed for log integration)*

---

## 1. Authentication

VeriLog uses **two separate authentication systems**. Never mix them up.

### API Key — For Sending Logs (this is what you need)

Create a key in the dashboard under **API Keys → Create Key**. The raw key is shown **only once**.

Pass it as an HTTP header on every request:

```
X-API-Key: vl_a1b2c3d4e5f6...
```

Keys are stored Argon2-hashed. A lost key cannot be recovered — revoke it and create a new one.

> **Never hardcode an API key.** Use an environment variable: `VERILOG_API_KEY=vl_...`

### JWT Session — For the Dashboard

The browser dashboard handles this automatically via an `HTTPOnly` cookie (`verilog_token`) set at login. Tokens expire after 24 hours. One active session per user — logging in from a new location ends the previous session. You don't need to worry about this for log integration.

---

## 2. Log API — `POST /v1/log`

**Purpose:** Ingest a single audit log entry.
**Auth:** `X-API-Key` header
**Response:** `202 Accepted` — log is written to the WAL on disk and queued for batch DB insertion. The response does not wait for the DB write.

### 2.1 Payload Schema

Every log entry sent to VeriLog can contain up to 12 fields. Only 2 are required.

| Field | Required | Type | Constraint | Description |
|-------|----------|------|-----------|-------------|
| `actor` | **YES** | `string` | max 255 chars | Who performed the action. Use a consistent prefix format: `"user:alice@acme.com"`, `"service:billing-worker"`, `"cron:nightly-sync"` |
| `action` | **YES** | `string` | max 255 chars | What happened. Use `"resource.verb"` convention: `"invoice.created"`, `"user.login.failed"`, `"file.deleted"` |
| `level` | no | `string` | one of: `DEBUG`, `INFO`, `WARN`, `ERROR`, `CRITICAL` | Explicit severity. Case-insensitive. Overrides auto-detection. If omitted, VeriLog derives it from keywords in `action` (see [Severity Auto-Derivation](#23-severity-auto-derivation)). |
| `message` | no | `string` | max 1,000 chars | Human-readable description of the event. This is the first thing someone reads when investigating a log. |
| `target_type` | no | `string` | max 255 chars | Type of resource affected. Appears in the "Target" column: `"order"`, `"invoice"`, `"user"`, `"document"` |
| `target_id` | no | `string` | max 255 chars | Unique ID of that resource: `"ORD-1001"`, `"inv_9f2a3b4c"`, `"usr_alice_8821"` |
| `status` | no | `string` | max 50 chars | Outcome. Accepts HTTP codes (`"200"`, `"404"`) or descriptive strings (`"success"`, `"failed"`, `"timeout"`). Default: `"200"` |
| `environment` | no | `string` | max 100 chars | Deployment environment. Default: `"production"`. Options: `"production"`, `"staging"`, `"test"`, `"development"` |
| `source_ip` | no | `string` | valid IPv4/IPv6 | End-user's IP address. If omitted, VeriLog uses the API caller's IP automatically (respects `X-Forwarded-For` from Nginx). |
| `request_id` | no | `string` | max 255 chars | Your trace/correlation ID. Also used as an **idempotency key** — duplicate `request_id` within 10 minutes is silently dropped. |
| `tags` | no | `object` | any JSON object | **Searchable, plaintext** key-value pairs. GIN-indexed JSONB. Visible in the dashboard. Use for data you want to filter and display. |
| `metadata` | no | `object` | any JSON object | **Encrypted** key-value payload. Fernet AES-128 encrypted on arrival. **Never** returned by the API. **Never** shown in the UI. Use for PII, credentials, stack traces. |

---

#### Field-by-Field Examples

**`actor` — who did it:**
```
"user:alice@acme.com"       — a logged-in user
"service:billing-worker"    — a backend service/microservice
"cron:nightly-sync"         — a scheduled job
"api:mobile-app"            — an API consumer
"admin:superadmin"          — an admin performing a privileged action
```

**`action` — what happened:**
```
"order.created"             — resource.verb format
"payment.refunded"          — financial event
"user.login.failed"         — nested context
"file.deleted"              — destructive action (auto-detected as critical)
"api_key.revoked"           — security event
```

**`message` — write for humans:**
```
✅ "Order ORD-1001 created — AirPods Pro worth ₹24,900 shipping from Mumbai to Delhi"
✅ "Payment of $149.00 processed via Stripe for Pro plan upgrade"
❌ "order created"         — too vague, not useful for investigation
❌ "{json blob here}"      — put structured data in tags/metadata, not message
```

**`target_type` + `target_id` — identify the resource:**
```
target_type: "order"        target_id: "ORD-1001"
target_type: "invoice"      target_id: "inv_9f2a3b4c"
target_type: "user"         target_id: "usr_alice_8821"
target_type: "document"     target_id: "doc_annual_report_2025"
target_type: "api_key"      target_id: "vl_a1b2"
```

**`status` — what happened:**
```
"success"     — action completed
"failed"      — action did not complete
"timeout"     — action timed out
"200"         — HTTP 200 OK
"404"         — resource not found
"500"         — server error
```

**`environment` — deployment context:**
```
"production"  — live system
"staging"     — pre-production testing
"test"        — automated test environment
"development" — local development
```

---

### 2.2 The `tags` vs. `metadata` Decision

This is the most important design decision when integrating VeriLog.

| | `tags` | `metadata` |
|--|--------|-----------|
| Storage | Plaintext JSONB | Fernet AES-128 encrypted BYTEA |
| Searchable | ✅ Yes — GIN-indexed, fast | ❌ No — encrypted blob |
| Visible in dashboard | ✅ Yes — shown in Tags column | ❌ Never — not in any UI |
| Returned by API | ✅ Yes — in GET /v1/logs | ❌ Never — no API returns it |
| **Use for** | Context you want to **filter and display** | Sensitive **forensic** data |

**Decision rule — ask yourself:**
- Would you be comfortable showing this on a team dashboard? → **`tags`**
- Does it contain PII, secrets, credentials, stack traces, or internal details? → **`metadata`**

**`tags` examples** (searchable, visible):
```json
{
  "payment_provider": "stripe",
  "amount_usd": "149.00",
  "plan": "pro",
  "region": "eu-west-1",
  "browser": "Chrome"
}
```

**`metadata` examples** (encrypted, never shown):
```json
{
  "card_last4": "4242",
  "stripe_charge": "ch_3abc123def",
  "billing_email": "alice@acme.com",
  "full_request_body": { "..." },
  "stack_trace": "Traceback (most recent call last)..."
}
```

---

### 2.3 Severity Auto-Derivation

If you don't provide a `level` field, VeriLog automatically derives severity by scanning your `action` string for keywords.

#### How `level` maps to dashboard severity:

| `level` you send | Dashboard badge | Color |
|------------------|-----------------|-------|
| `DEBUG` | info | blue |
| `INFO` | info | blue |
| `WARN` | warning | amber |
| `ERROR` | critical | red |
| `CRITICAL` | critical | red |

#### When `level` is omitted — auto-detection kicks in:

VeriLog scans the `action` string for these keywords:

| Auto-derived severity | Triggered when `action` contains any of... |
|----------------------|---------------------------------------------|
| `critical` (red) | `delete`, `destroy`, `revoke`, `drop`, `purge`, `wipe` |
| `warning` (amber) | `update`, `edit`, `modify`, `change`, `patch`, `rename` |
| `info` (blue) | everything else |

**Examples:**
```
action: "user.deleted"      → auto-derived: critical (contains "delete")
action: "profile.updated"   → auto-derived: warning  (contains "update")
action: "order.created"     → auto-derived: info     (no trigger words)
action: "api_key.revoked"   → auto-derived: critical (contains "revoke")
```

> **Explicit `level` always wins.** If you send `"level": "INFO"` with `"action": "user.deleted"`, the log will be `info`, not `critical`.

---

### 2.4 Auto-Captured Fields

These fields are captured by the server automatically. You do **not** need to provide them.

| Field | Source | Description |
|-------|--------|-------------|
| `source_ip` | HTTP connection | Client IP address. Reads `X-Forwarded-For` from Nginx. You can override it by passing `source_ip` in the body. |
| `user_agent` | `User-Agent` header | Raw user-agent string of the API caller (e.g. `"python-httpx/0.27"`, `"Mozilla/5.0 Chrome/..."`) |
| `device_type` | Parsed from user-agent | Automatically classified: `"desktop"`, `"mobile"`, `"tablet"`, `"bot"`, or `null` |
| `created_at` | Server clock (UTC) | Timestamp of ingestion. Clock-skew protected — always monotonically increasing per tenant. |
| `id` | Server-generated | UUID v4, unique identifier for this log entry |
| `hash` | Server-computed | SHA-256 hash of this entry, chained from the previous entry's hash |

---

### 2.5 Requests & Responses

#### Minimal Request — Only the 2 required fields

```json
{
  "actor": "user:alice@acme.com",
  "action": "document.downloaded"
}
```

#### Full Request — Every field VeriLog accepts

```json
{
  "actor":       "user:alice@acme.com",
  "action":      "payment.processed",
  "level":       "INFO",
  "message":     "Payment of $149.00 processed via Stripe for Pro plan upgrade.",
  "target_type": "invoice",
  "target_id":   "inv_9f2a3b4c",
  "status":      "success",
  "environment": "production",
  "source_ip":   "203.0.113.42",
  "request_id":  "req_trace_abc123",
  "tags": {
    "payment_provider": "stripe",
    "amount_usd":       "149.00",
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

### 2.6 Code Examples

> For all examples: replace `$VERILOG_API_KEY` with your key and `localhost` with your host.

---

#### cURL

```bash
# A — Simple informational log
curl -X POST http://localhost/v1/log \
  -H "X-API-Key: $VERILOG_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "actor":   "user:alice@acme.com",
    "action":  "user.login",
    "level":   "INFO",
    "message": "User logged in from Chrome.",
    "tags":    {"browser": "Chrome", "region": "eu-west-1"}
  }'

# B — Error log (stack trace encrypted in metadata — never shown in dashboard)
curl -X POST http://localhost/v1/log \
  -H "X-API-Key: $VERILOG_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "actor":       "service:payment-worker",
    "action":      "payment.charge.failed",
    "level":       "ERROR",
    "message":     "Stripe charge timed out after 30s for invoice inv_9f2a3b4c.",
    "target_type": "invoice",
    "target_id":   "inv_9f2a3b4c",
    "status":      "timeout",
    "environment": "production",
    "tags":        {"provider": "stripe", "amount_usd": "149.00"},
    "metadata":    {"exception": "ConnectionTimeout", "stack_trace": "Traceback..."}
  }'
```

---

#### Python

```python
import httpx
import traceback

HEADERS = {"X-API-Key": VERILOG_API_KEY, "Content-Type": "application/json"}
URL = "http://localhost/v1/log"

# A — Simple informational log
httpx.post(URL, headers=HEADERS, json={
    "actor":   "user:alice@acme.com",
    "action":  "user.login",
    "level":   "INFO",
    "message": "User logged in from Chrome.",
    "tags":    {"browser": "Chrome", "region": "eu-west-1"},
})

# B — Error log with encrypted metadata
try:
    stripe.charge(invoice_id, amount)
except Exception as exc:
    httpx.post(URL, headers=HEADERS, json={
        "actor":       "service:payment-worker",
        "action":      "payment.charge.failed",
        "level":       "ERROR",
        "message":     f"Stripe charge failed for {invoice_id}: {exc}",
        "target_type": "invoice",
        "target_id":   invoice_id,
        "status":      "failed",
        "metadata":    {                              # 🔒 encrypted, never shown
            "exception":   type(exc).__name__,
            "stack_trace": traceback.format_exc(),
        },
    })
```

---

### 2.7 Automatic Logging — Middleware Integration

The examples above show **manual logging** — you call `POST /v1/log` in your code for specific business events like payments, order creation, or user actions.

But most production applications also need **automatic HTTP request logging** — capturing every API call hitting your server with details like method, path, latency, client IP, user agent, and more. This is where **middleware** comes in.

#### What is middleware?

Middleware is a layer that sits between your web server and your route handlers. Every request passes through it before reaching your endpoint, and every response passes through it on the way out. This makes it the perfect place to log HTTP traffic **automatically** — without changing any of your route handler code.

#### When can you use automatic logging?

Automatic logging works with **any framework that supports middleware**:

| Framework | Middleware support | How to add |
|-----------|-------------------|------------|
| **FastAPI** (Python) | ✅ `BaseHTTPMiddleware` | `app.add_middleware(LoggingMiddleware)` |
| **Django** (Python) | ✅ `MIDDLEWARE` setting | Add class to `settings.py` |
| **Express** (Node.js) | ✅ `app.use()` | `app.use(loggingMiddleware)` |
| **Spring Boot** (Java) | ✅ `HandlerInterceptor` | Register interceptor |
| **ASP.NET** (C#) | ✅ `IMiddleware` | `app.UseMiddleware<LoggingMiddleware>()` |
| **Mobile backends** | ✅ Same as above | If your mobile app talks to a backend API, add middleware there |

> **Building a mobile app?** Your mobile app itself doesn't need middleware — but your **backend API** that the app talks to likely uses one of the frameworks above. Add the middleware there, and every API call your mobile app makes will be logged automatically.

#### Why use both manual + automatic logging?

| | Manual (`send_log` in route) | Automatic (middleware) |
|---|---|---|
| **Captures** | Business events — *what matters* | HTTP traffic — *every request* |
| **Example actions** | `order.created`, `payment.failed` | `http.request` |
| **Tags contain** | Business data: price, plan, order | HTTP data: method, path, latency |
| **Code changes?** | Yes — one call per event | No — add once, covers all routes |
| **Linked in dashboard?** | ✅ Yes, by `request_id` | ✅ Yes, by `request_id` |

Using both gives you a complete picture: the middleware captures the HTTP layer (who called what, how fast it responded), and manual logs capture the business context (what actually happened in your domain logic).

---

#### Step 1 — The Logger Utility

Drop this file into your project. Both manual logs and the middleware use it.

```python
# verilog_logger.py — drop into your project, import everywhere
import os
import httpx
from typing import Optional

VERILOG_URL = os.getenv("VERILOG_URL", "http://localhost/v1/log")
VERILOG_API_KEY = os.getenv("VERILOG_API_KEY", "your-api-key-here")

HEADERS = {
    "X-API-Key": VERILOG_API_KEY,
    "Content-Type": "application/json",
}

async def send_log(
    actor: str,                          # ✅ REQUIRED — who did it       (e.g. "user:alice@acme.com")
    action: str,                         # ✅ REQUIRED — what happened    (e.g. "order.created")
    level: Optional[str] = None,         # severity: DEBUG, INFO, WARN, ERROR, CRITICAL
    message: Optional[str] = None,       # human-readable event description
    target_type: Optional[str] = None,   # resource type  (e.g. "order", "invoice")
    target_id: Optional[str] = None,     # resource ID    (e.g. "ORD-1001")
    status: Optional[str] = None,        # outcome: "success", "failed", "200", etc.
    environment: Optional[str] = None,   # "production", "staging", "test"
    source_ip: Optional[str] = None,     # client IP address (auto-captured if omitted)
    request_id: Optional[str] = None,    # correlation ID — links related logs together
    tags: Optional[dict] = None,         # searchable key-value pairs (visible in dashboard)
    metadata: Optional[dict] = None,     # 🔒 ENCRYPTED at rest, NEVER shown in UI
) -> None:
    """Send a log entry to VeriLog. Fails silently — logging never crashes your app."""

    # Build payload — only include fields that have values
    payload = {"actor": actor, "action": action}

    optional = {
        "level": level, "message": message, "target_type": target_type,
        "target_id": target_id, "status": status, "environment": environment,
        "source_ip": source_ip, "request_id": request_id,
        "tags": tags, "metadata": metadata,
    }
    for key, value in optional.items():
        if value is not None:
            payload[key] = value

    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            await client.post(VERILOG_URL, json=payload, headers=HEADERS)
    except Exception:
        pass  # logging should never crash your app
```

---

#### Step 2 — Manual Logging (Business Events)

Use `send_log()` in your route handlers for important business events like order creation, payments, or user actions.

> **💡 Use `metadata` for sensitive data** — credit card info, emails, full request bodies, PII.
> It's **encrypted at rest** and **never shown** in the dashboard. Only for forensic audits.

```python
# YOUR route.py file
from verilog_logger import send_log

@app.post("/place-order")
def place_order(order: OrderCreate, request: Request, background_tasks: BackgroundTasks):
    db_order = create_order(db, order)

    # background_tasks runs AFTER response is sent → zero latency impact on your API
    background_tasks.add_task(
        send_log,
        actor=f"user:{order.user_id}",
        action="order.created",
        level="INFO",
        message=f"Order {order.order_id} — {order.order_name} worth ₹{order.price:,.0f}",
        target_type="order",
        target_id=order.order_id,
        status="success",
        environment="production",
        source_ip=request.client.host,
        request_id=request.state.request_id,
        tags={                                      # ← visible & searchable in dashboard
            "price": str(order.price),
            "origin": order.user_location,
            "destination": order.destination,
        },
        metadata={                                   # ← 🔒 encrypted, never shown in UI
            "user_id": order.user_id,
            "full_payload": order.model_dump(),
        },
    )
    return {"status": "created"}
```

---

#### Step 3 — Automatic Logging (Middleware)

Add middleware once → **every HTTP request is logged automatically**, zero code changes in routes.

The middleware below captures **30+ data points** from each request. You can trim it based on your requirements:

```python
# YOUR middleware.py file
import time, uuid, asyncio, platform, os, inspect
from starlette.middleware.base import BaseHTTPMiddleware
from fastapi.responses import JSONResponse
from verilog_logger import send_log

class LoggingMiddleware(BaseHTTPMiddleware):
    SKIP_PATHS = {"/health", "/favicon.ico"}

    async def dispatch(self, request, call_next):
        request_id = str(uuid.uuid4())                     # → request_id
        request.state.request_id = request_id
        start = time.time()

        # Execute request (catch crashes → error tag)
        error_detail = None
        try:
            response = await call_next(request)
            status_code = response.status_code               # → status
        except Exception as e:
            status_code = 500
            error_detail = f"{type(e).__name__}: {str(e)}"   # → error
            response = JSONResponse(status_code=500, content={"detail": "Internal Server Error"})

        if request.url.path in self.SKIP_PATHS:
            response.headers["X-Request-ID"] = request_id
            return response

        # → actor (from X-User-ID header or fallback)
        user_id = request.headers.get("X-User-ID")
        actor = f"user:{user_id}" if user_id else "service:my-api"

        # → client_ip, client_port (from proxy headers or direct connection)
        client_ip = (request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
                     or request.client.host)

        # → handler_file, handler_function, handler_line (introspection)
        handler_file = handler_function = handler_line = None
        try:
            endpoint = request.scope.get("endpoint")
            if endpoint:
                handler_file = os.path.basename(inspect.getfile(endpoint))
                handler_function = endpoint.__name__
                handler_line = str(inspect.getsourcelines(endpoint)[1])
        except Exception:
            pass

        route = request.scope.get("route")
        latency_ms = round((time.time() - start) * 1000, 2)  # → latency_ms
        level = "ERROR" if status_code >= 500 else ("WARN" if status_code >= 400 else "INFO")

        # ── Build tags (all visible & searchable in dashboard) ─────
        tags = {
            "method":       request.method,                                         # → HTTP method
            "path":         request.url.path,                                       # → endpoint path
            "full_url":     str(request.url),                                       # → complete URL
            "scheme":       request.url.scheme,                                     # → http or https
            "http_version": request.scope.get("http_version", ""),                  # → protocol version
            "latency_ms":   str(latency_ms),                                        # → response time
            "client_ip":    client_ip,                                              # → real client IP
            "client_port":  str(request.client.port) if request.client else "",     # → client port
            "user_agent":   request.headers.get("user-agent", ""),                  # → browser/SDK
            "host":         request.headers.get("host", ""),                        # → host header
            "language":     request.headers.get("accept-language", "").split(",")[0].strip(),  # → locale
            "server_hostname": platform.node(),                                     # → server name
            "server_os":       platform.system(),                                   # → OS
            "python_version":  platform.python_version(),                           # → runtime
            "server_pid":      str(os.getpid()),                                    # → process ID
        }

        # Optional fields (added only when data exists; spacing is only for readability)
        if request.url.query:                    tags["query_string"]        = str(request.url.query)
        if request.headers.get("content-type"):  tags["request_content_type"]= request.headers["content-type"]
        if request.headers.get("content-length"):tags["request_bytes"]       = request.headers["content-length"]
        if response.headers.get("content-type"): tags["response_content_type"]= response.headers["content-type"]
        if response.headers.get("content-length"):tags["response_bytes"]     = response.headers["content-length"]
        if request.headers.get("referer"):       tags["referer"]             = request.headers["referer"]
        if request.headers.get("origin"):        tags["origin"]              = request.headers["origin"]
        if request.headers.get("authorization"): tags["authenticated"]       = "true"  # presence only, never the token!
        if handler_file:                         tags["handler_file"]        = handler_file
        if handler_function:                     tags["handler_function"]    = handler_function
        if handler_line:                         tags["handler_line"]        = handler_line
        if getattr(route, "path", None):         tags["route_pattern"]       = route.path
        if error_detail:                         tags["error"]               = error_detail[:200]

        # ── Fire log to VeriLog ──────────────────────────
        asyncio.create_task(send_log(
            actor=actor,
            action="http.request",
            level=level,
            message=f"{request.method} {request.url.path} → {status_code}",
            status=str(status_code),
            source_ip=client_ip,
            request_id=request_id,
            tags=tags,
        ))

        response.headers["X-Request-ID"] = request_id
        return response

# Register in your main.py: app.add_middleware(LoggingMiddleware)
```

---

#### What the Middleware Captures Automatically

Every field below is extracted **without any code in your route handlers**:

| Tag | Example | What it tells you |
|-----|---------|-------------------|
| `method` | `POST` | HTTP method |
| `path` | `/place-order` | Endpoint path |
| `full_url` | `http://api.acme.com/place-order?v=2` | Complete URL with query |
| `scheme` | `https` | HTTP or HTTPS |
| `http_version` | `1.1` | Protocol version |
| `latency_ms` | `23.41` | How long the request took |
| `client_ip` | `203.0.113.42` | Real client IP (respects `X-Forwarded-For`) |
| `client_port` | `54821` | Client's ephemeral port |
| `user_agent` | `Mozilla/5.0 Chrome/...` | Browser or SDK identifier |
| `host` | `api.acme.com` | Host header |
| `language` | `en-US` | Client's preferred language |
| `query_string` | `page=1&limit=10` | URL query parameters |
| `request_content_type` | `application/json` | What the client sent |
| `request_bytes` | `157` | Request body size |
| `response_content_type` | `application/json` | What your API returned |
| `response_bytes` | `284` | Response body size |
| `referer` | `https://app.acme.com/checkout` | Where the user came from |
| `origin` | `https://app.acme.com` | CORS origin |
| `authenticated` | `true` | Was an auth header present? (never logs the token) |
| `handler_file` | `main.py` | Which file handled the request |
| `handler_function` | `place_order` | Which function handled it |
| `handler_line` | `54` | Exact line number of the route |
| `route_pattern` | `/orders/{user_id}` | Route template with params |
| `server_hostname` | `prod-api-01` | Which server processed it |
| `server_os` | `Linux` | Server operating system |
| `python_version` | `3.12.4` | Python runtime version |
| `server_pid` | `12700` | Process ID |
| `error` | `ValueError: invalid ID` | Error details (on 5xx failures only) |

---

## 3. Health Check — `GET /health`

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

## 6. Dashboard & System APIs

> These endpoints power the React dashboard. They require a **JWT session cookie** (`verilog_token`) obtained from `POST /v1/auth/login`. Do not call them from your application's integration code.

---

### 6.1 Authentication

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

### 6.2 Setup Wizard

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

### 6.3 Log Search & Retrieval

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

### 6.4 Statistics

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

### 6.5 Chain Verification

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

### 6.6 Data Export

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

### 6.7 API Key Management

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

### 6.8 User Management

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

### 6.9 Admin Settings & Licensing

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

### 6.10 Project Management

---

#### `GET /v1/tenants/me`

**Purpose:** Returns the list of tenants the current user has access to, with display names and colors.

**Auth:** JWT

**Success:** `200 OK` → `{"data": [{"id": "uuid", "name": "Acme Corp", "color": "cyan", "is_default": true}]}`

---

## 4. HTTP Status Code Reference

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
| `429 Too Many Requests` | Rate limited | Exceeded per-IP request quota (see [Rate Limits](#5-rate-limits)) |
| `503 Service Unavailable` | Server error | Database unreachable, or WAL disk full |

---

## 5. Rate Limits

Rate limiting is enforced by Nginx before requests reach the application server. Limits are **per IP address**.

| Endpoint(s) | Limit | Burst |
|-------------|-------|-------|
| `POST /v1/auth/login` | 5 req/min | 3 |
| `POST /v1/log` | 100 req/min | 20 |
| All other `/v1/*` | 200 req/min | 50 |

When a limit is exceeded, Nginx returns `429 Too Many Requests` with a `Retry-After` header.

> For high-volume ingestion above 100 req/min, batch your logs client-side into arrays and send them in fewer, larger requests — or contact us about a Pro ingestion upgrade.
