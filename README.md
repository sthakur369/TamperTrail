<div align="center">

# TamperTrail

### Where Logs Become Evidence

_The self-hosted, cryptographic vault for tamper-proof audit logs_

<br/>

> **Note:** TamperTrail is a **closed-source** product deployed via pre-built Docker containers.
> This repository contains the Docker Compose configuration, architecture documentation, and the public issue tracker.
[![GitHub Repo Size](https://img.shields.io/github/repo-size/sthakur369/TamperTrail?style=flat&color=blue)](https://github.com/sthakur369/TamperTrail)
[![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?logo=docker&logoColor=white)](https://www.docker.com/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.115-009688?logo=fastapi&logoColor=white)](https://fastapi.tiangolo.com/)
[![React](https://img.shields.io/badge/React-19-61DAFB?logo=react&logoColor=black)](https://react.dev/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)](https://www.postgresql.org/)
[![Python](https://img.shields.io/badge/Python-3.12-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![License: Proprietary](https://img.shields.io/badge/License-Proprietary--Software-blue)](LICENSE)
[![Feedback](https://img.shields.io/badge/💬_Feedback_%26_Bugs-tally.so-8b5cf6?style=flat)](https://tally.so/r/D4NvRl)

</div>

<br/>

<div align="center">
  <img
    src="docs/screenshots/dashboard.png"
    alt="TamperTrail Dashboard — tamper-proof audit trail"
    width="100%"
    style="border-radius: 12px; border: 1px solid #1e293b; box-shadow: 0 8px 32px rgba(0,0,0,0.5);"
  />
  <sub><i>TamperTrail dashboard — real-time tamper-evident audit logs with SHA-256 hash chain integrity verification.</i></sub>
</div>

<br/>

---

# Overview

You already log everything.
But can you prove none of it was touched?

TamperTrail is a self-hosted, tamper-evident audit logging system. It uses SHA-256 hash chaining to make log modification or deletion instantly detectable.

It runs alongside your app. Self-hosted — no SaaS lock-in, no data leaving your servers.

Built for teams that know: if you scale, compliance will follow — SOC 2, HIPAA, DPDP Act, ISO 27001.

> 💡 ***Free core edition available. Pro tier (extended limits and advanced capabilities) in development!***

> 💬 **Got feedback or found a bug?** We'd love to hear from you! Drop your feedback, feature requests, or bug reports here — every little note helps us improve the TamperTrail 💛 — [open the feedback form →](https://tally.so/r/D4NvRl)

---



## Quick Start

**Prerequisites:** Docker Desktop (or Docker Engine + Compose plugin)

```bash
# 1. Clone the repository
git clone https://github.com/sthakur369/TamperTrail.git
cd TamperTrail

# 2. Create your own local .env from the template
cp .env.example .env

# 3. Build and start (Ensure Port 80 is available)
docker compose up -d --build
```
 > ***💡 Note: By default, images are pulled from GitHub Container Registry (GHCR). If you encounter any issues, or prefer to use Docker Hub, edit the .env file in the project root: `IMAGE_REGISTRY=docker.io` and then run `docker compose up -d --build` command again.***

That's it. Seriously.

Navigate to **`http://localhost`** in your browser. You will see the setup wizard.


```
┌─────────────────────────────────────────┐
│          TamperTrail Setup Wizard       │
│                                         │
│  Create your master admin password      │
│  to unlock the dashboard.               │
│                                         │
│  Password: ████████████████             │
│                                         │
│            [ Complete Setup ]           │
└─────────────────────────────────────────┘
```

Enter a password (8+ characters), click **Complete Setup**, and you're in. All routes are locked by a middleware guard until this step is complete — the system cannot be accessed without it.

---


## Updating TamperTrail

> ⭐ **Stay up to date:** Watch this repository for new releases — click **Watch → Custom → Releases** in the top-right corner of this page to get notified when security patches and new features drop.

To pull the latest security patches and features without losing data:

```bash
# 1. Download the latest TamperTrail images from the repository
docker compose pull

# 2. Stop and remove the old containers and networks (Data is safe!)
docker compose down

# 3. Boot up the new containers using the fresh images
docker compose up -d

# 4. Delete the old, unused Docker images to free up disk space
docker image prune -f
```
---

## Sending Your First Log

### Step 1: Get an API Key

Dashboard → **API Keys** → **Create Key**. Copy the key (shown only once) and set in your application or environment variables.

```bash
export TAMPERTRAIL_API_KEY="vl_a1b2c3d4e5f6..."
export TAMPERTRAIL_URL="http://localhost"   # your TamperTrail instance
```

> 💡 For full API details, see [API_REFERENCE.md](https://github.com/sthakur369/TamperTrail/blob/main/docs/API_REFERENCE.md).

---

### Step 2: Send a Log (cURL)

One request that demonstrates **every field** TamperTrail accepts:

```bash
curl -X POST "$TAMPERTRAIL_URL/v1/log" \
  -H "X-API-Key: $TAMPERTRAIL_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "actor":       "user:alice@acme.com",
    "action":      "payment.success",
    "level":       "INFO",
    "message":     "Payment of $149.00 processed via Stripe for Pro plan upgrade.",
    "target_type": "invoice",
    "target_id":   "inv_9f2a3b4c",
    "status":      "success",
    "environment": "production",
    "source_ip":   "203.0.113.42",
    "request_id":  "req_abc123",
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
  }'
```

```json
// 202 Accepted
{ "status": "accepted", "message": "Log queued for processing" }
```


---

### Step 3: Send Logs from Python

Drop this file into your project — it's the only dependency you need.

Download (or copy) the file below, add it to your project directory, and import it wherever needed in your application.

👉 **[TamperTrail_logger.py](tampertrail_logger.py)**

```python
# =============================================================================
# tampertrail_logger.py
# Drop into your project and import everywhere
# =============================================================================

import os
import httpx
from typing import Optional, Any


# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

TAMPERTRAIL_URL = os.getenv("TAMPERTRAIL_URL", "http://localhost/v1/log")
TAMPERTRAIL_API_KEY = os.getenv("TAMPERTRAIL_API_KEY", "<your-api-key-here>")

# -----------------------------------------------------------------------------
# Global HTTP Client (Connection Pooling)
# -----------------------------------------------------------------------------
# ⚡ Keeps connections alive (no TCP handshake per request)
# ⚠️ On app shutdown, call: await http_client.aclose()
# FastAPI users: register inside lifespan shutdown handler
# -----------------------------------------------------------------------------

http_client = httpx.AsyncClient(
    timeout=2.0,  # Fail fast — logging must never block your app
    headers={
        "X-API-Key": TAMPERTRAIL_API_KEY,
        "Content-Type": "application/json",
    },
)


# =============================================================================
# Core Log Function
# =============================================================================

async def send_log(
    actor: str,                           # ✅ REQUIRED → who did it (e.g. "user:alice@acme.com")
    action: str,                          # ✅ REQUIRED → what happened (e.g. "order.created")
    level: Optional[str] = None,          # DEBUG | INFO | WARN | ERROR | CRITICAL
    message: Optional[str] = None,        # Human-readable description
    target_type: Optional[str] = None,    # Resource type (e.g. "order")
    target_id: Optional[str] = None,      # Resource ID   (e.g. "ORD-1001")
    status: Optional[str] = None,         # Outcome: "success", "failed", "200"
    environment: Optional[str] = None,    # "production" | "staging" | "test"
    source_ip: Optional[str] = None,      # Client IP (auto-captured if omitted)
    request_id: Optional[str] = None,     # Correlation ID
    tags: Optional[dict[str, Any]] = None,       # Visible & searchable
    metadata: Optional[dict[str, Any]] = None,   # 🔒 Encrypted at rest (never shown in UI)
) -> None:
    """
    Send a log entry to TamperTrail.

    • Fails silently — logging never crashes your application
    • Uses global connection-pooled client
    """

    # -------------------------------------------------------------------------
    # 1️⃣ Required fields
    # -------------------------------------------------------------------------

    payload = {
        "actor": actor,
        "action": action,
    }

    # -------------------------------------------------------------------------
    # 2️⃣ Optional fields (added only if not None)
    # -------------------------------------------------------------------------

    optional_fields = {
        "level": level,
        "message": message,
        "target_type": target_type,
        "target_id": target_id,
        "status": status,
        "environment": environment,
        "source_ip": source_ip,
        "request_id": request_id,
        "tags": tags,
        "metadata": metadata,
    }

    for key, value in optional_fields.items():
        if value is not None:
            payload[key] = value

    # -------------------------------------------------------------------------
    # 3️⃣ Fire & forget (never crash host app)
    # -------------------------------------------------------------------------

    try:
        # Use the global connection-pooled client!
        await http_client.post(TAMPERTRAIL_URL, json=payload)
    except Exception:
        pass


# =============================================================================
# Optional: Clean Shutdown (Recommended for Production)
# =============================================================================
#
# from contextlib import asynccontextmanager
#
# @asynccontextmanager
# async def lifespan(app: FastAPI):
#     yield
#     await http_client.aclose()
#


# =============================================================================
# 🔥 FastAPI Pro Tip
# =============================================================================
# Run send_log() inside a BackgroundTask so your API responds immediately:
#
# background_tasks.add_task(
#     send_log,
#     actor="user_123",
#     action="login"
# )
# =============================================================================

```

---

### Manual Log — Business Event

Use `send_log()` in route handlers for important business events.

> **💡 Use `metadata` for sensitive data** — credit card info, emails, full request bodies, PII.
> It's **encrypted at rest** and **never shown** in the dashboard. Only for forensic audits.

```python
# YOUR route.py file
#################### 1️ Manual Business Event Log (Route-Level) ####################


from tampertrail_logger import send_log
from fastapi import BackgroundTasks


@app.post("/place-order")
def place_order(order: OrderCreate, request: Request, background_tasks: BackgroundTasks):
    db_order = create_order(db, order)

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
        tags={                                  # ← visible & searchable in dashboard
            "price": str(order.price),
            "origin": order.user_location,
            "destination": order.destination,
        },
        metadata={                              # ← 🔒 encrypted, never shown in UI
            "user_id": order.user_id,
            "full_payload": order.model_dump(),
        },
    )

    return {"status": "created"}

```

---

### Automatic Log — Middleware

Add middleware once → **every HTTP request is logged automatically**, zero code changes in routes.

The middleware below captures **30+ data points** from each request. You can trim it based on your requirements:

```python
# (YOUR middleware.py file)

#################### 2️ Automatic Logging (Middleware-Level) ####################

import time, uuid, asyncio, platform, os, inspect
from starlette.middleware.base import BaseHTTPMiddleware
from fastapi.responses import JSONResponse
from tampertrail_logger import send_log


class LoggingMiddleware(BaseHTTPMiddleware):

    SKIP_PATHS = {"/health", "/favicon.ico"}

    async def dispatch(self, request, call_next):

        # ---------------------------------------------------------------------
        # Request Setup
        # ---------------------------------------------------------------------

        request_id = str(uuid.uuid4())
        request.state.request_id = request_id
        start_time = time.time()

        # Execute request (catch crashes → error tag)
        error_detail = None

        try:
            response = await call_next(request)
            status_code = response.status_code
        except Exception as e:
            status_code = 500
            error_detail = f"{type(e).__name__}: {str(e)}"
            response = JSONResponse(
                status_code=500,
                content={"detail": "Internal Server Error"},
            )

        if request.url.path in self.SKIP_PATHS:
            response.headers["X-Request-ID"] = request_id
            return response

        # ---------------------------------------------------------------------
        # Actor Resolution
        # ---------------------------------------------------------------------

        user_id = request.headers.get("X-User-ID")
        actor = f"user:{user_id}" if user_id else "service:my-api"

        # ---------------------------------------------------------------------
        # Client Info
        # ---------------------------------------------------------------------

        client_ip = (
            request.headers.get("X-Forwarded-For", "").split(",")[0].strip()
            or request.client.host
        )

        # ---------------------------------------------------------------------
        # Handler Introspection
        # ---------------------------------------------------------------------

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

        latency_ms = round((time.time() - start_time) * 1000, 2)

        level = (
            "ERROR" if status_code >= 500
            else "WARN" if status_code >= 400
            else "INFO"
        )

        # ---------------------------------------------------------------------
        # Tags (Visible & Searchable)
        # ---------------------------------------------------------------------
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

        # ---------------------------------------------------------------------
        # Fire Log (Non-Blocking)
        # ---------------------------------------------------------------------
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

# Register: app.add_middleware(LoggingMiddleware)
```

### What the Middleware Captures Automatically

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

### Manual vs Automatic — What's the Difference?

| | Manual (`send_log` in route) | Automatic (middleware) |
|---|---|---|
| **Captures** | Business events — *what matters to your product* | HTTP traffic — *every request hitting your API* |
| **Example action** | `order.created`, `payment.failed`, `user.deleted` | `http.request` |
| **Tags contain** | Business data: price, plan, order name | HTTP data: method, path, latency, user agent, etc. |
| **You write code?** | Yes — one `send_log()` call per event | No — add middleware once, covers all routes |
| **Both in dashboard?** | ✅ Yes — linked by the same `request_id` | ✅ Yes |

---

## Understanding the Log Fields

### Fields You Provide

| Field | Required | Type | Description |
|-------|----------|------|-------------|
| `actor` | ✅ | `string` | Who performed the action. Convention: `"user:alice@acme.com"`, `"service:payment-worker"`, `"api:mobile-app"` |
| `action` | ✅ | `string` | What happened. Convention: `"resource.verb"` e.g. `"payment.failed"`, `"user.deleted"` |
| `level` | | `string` | Explicit severity: `DEBUG`, `INFO`, `WARN`, `ERROR`, `CRITICAL`. Auto-derived from `action` keywords if omitted |
| `message` | | `string` | Human-readable description of the event. Max 1,000 chars |
| `target_type` | | `string` | The type of resource affected: `"Invoice"`, `"User"`, `"Document"` |
| `target_id` | | `string` | The ID of the resource: `"inv_9f2a3b4c"`, `"usr_alice_8821"` |
| `status` | | `string` | Outcome: HTTP code (`"200"`, `"404"`) or descriptive (`"success"`, `"failed"`, `"timeout"`) |
| `environment` | | `string` | Deployment environment. Default: `"production"`. Options: `"production"`, `"staging"` (configurable per project) |
| `request_id` | | `string` | Correlation/trace ID for linking to your APM or tracing system. Used for idempotency — duplicate `request_id` within 10 minutes is silently skipped |
| `tags` | | `object` | **Searchable** key-value metadata. GIN-indexed JSONB. Visible in the dashboard. Use for anything you want to filter or display |
| `metadata` | | `object` | **Encrypted** key-value payload. Fernet AES-128 encrypted at rest. **Never returned by the API or shown in the UI.** Use for sensitive forensic data |

### Automatically Captured Fields

These are captured by the server and **do not need to be provided**:

| Field | Source | Description |
|-------|--------|-------------|
| `source_ip` | HTTP request | Client IP address (respects `X-Forwarded-For` from Nginx) |
| `user_agent` | HTTP header | Raw `User-Agent` string of the caller |
| `device_type` | Parsed from user-agent | `"desktop"`, `"mobile"`, `"tablet"`, `"bot"` |
| `created_at` | Server clock (UTC) | Timestamp of ingestion. Clock-skew protected — always monotonically increasing per tenant |

---

## Severity Auto-Derivation

If you don't provide a `level`, TamperTrail derives severity from your `action` string:

| Severity | Triggered by action keywords |
|----------|------------------------------|
| `critical` | `delete`, `destroy`, `revoke`, `drop`, `purge`, `wipe` |
| `warning` | `update`, `edit`, `modify`, `change`, `patch`, `rename` |
| `info` | Everything else |

Or override explicitly with `"level": "ERROR"` — this always takes priority.

---

## 🔒 Production Deployment (HTTPS)

The default setup runs on **port 80 (HTTP)** — safe for local development and internal networks only.

> ⚠️ **Before exposing TamperTrail to the internet, place it behind a TLS-terminating reverse proxy.**
> Without HTTPS, API keys and session tokens travel in plaintext.
---
```
[ Internet ] → HTTPS → [ Your TLS Proxy ] → HTTP → [ TamperTrail :80 ]
```

Any TLS-terminating proxy works — Cloudflare, Caddy, Nginx, Traefik, AWS ALB, or any load balancer. Point it at `http://your-server:80`.

**Your responsibility:**
- **Port conflict** — If your proxy runs on the same machine, change TamperTrail's mapping from `"80:80"` → `"8080:80"` and point your proxy to port 8080.
- **Real IP forwarding** — Pass `X-Forwarded-For` so TamperTrail captures the actual client IP.
- **Certificates** — TamperTrail has no awareness of your certificates. Renewal and rotation are on you.

> 📄 Full network topology and compliance mapping (SOC 2, HIPAA, GDPR) → [Security & Compliance Whitepaper](docs/TamperTrail%20-%20Security%20%26%20Compliance%20Whitepaper.md).

---

## Key Features

### 🔗 Cryptographic Hash Chaining
Every log entry is SHA-256 hashed and chained to the previous one — forming an unbreakable ledger. Any deletion, modification, or insertion is mathematically detectable. Run `GET /v1/verify` at any time to validate the entire chain. Retention-safe: monthly checkpoints bridge gaps so archiving old logs doesn't break verification.

### 🔒 The Encrypted Metadata Vault
Your logs have two data layers:

| Field | Visibility | Indexed | Use for |
|-------|-----------|---------|---------|
| `tags` | ✅ Visible in dashboard | ✅ GIN-indexed, searchable | Event context, filtering, display |
| `metadata` | ❌ Never exposed in UI | ❌ Encrypted BYTEA blob | Sensitive forensic data |

`metadata` is encrypted server-side with **AES-128-CBC + HMAC-SHA256 (Authenticated Encryption)** the moment it arrives. The raw payload never touches the database. Even with read-only database access, an attacker sees only binary ciphertext. Supports key rotation and optional envelope encryption via a `MASTER_KEY` for integration with AWS KMS or HashiCorp Vault.

### ⚡ Fire-and-Forget Ingestion
`POST /v1/log` responds in **<10ms**. Logs are written to a crash-safe **Write-Ahead Log (WAL)** on disk before being micro-batched into PostgreSQL by a background worker. If the server restarts mid-batch, uncommitted entries are replayed automatically — zero data loss by design.

### 🛡️ The Bouncer (Nginx Rate Limiter)
All traffic passes through a hardened Nginx reverse proxy. The FastAPI server is **never exposed directly**. Strict per-IP rate limits protect every endpoint:
- **Login:** 5 requests/min (brute force protection)
- **Log ingestion:** 100 requests/min
- **General API:** 200 requests/min

Security headers included out of the box: `X-Frame-Options`, `X-Content-Type-Options`, `Content-Security-Policy`, `HSTS`, and more.

### 🚀 True Zero-Config Deployment
No `.env` files to edit. No secrets to generate manually. On first boot, TamperTrail automatically:
- Generates a cryptographically random **database password** (32 chars, `/dev/urandom`)
- Generates a **JWT secret** (128-char hex)
- Generates a **Fernet encryption key** for the metadata vault
- Stores everything with `chmod 600` permissions

One command. Fully production-ready.

### 🏢 Multi-Tenant & Multi-User
Isolate logs by project (tenant) with **two layers of enforcement**: application-level tenant filtering in every query, and PostgreSQL **Row-Level Security (RLS)** as a hard backstop. Add team members with `admin` or `viewer` roles. Track login sessions with IP and user-agent history. License limits enforced at the API layer.


---

## Architecture: What You Just Installed

```
┌─────────────────────────────────────────────────────────┐
│                    Your Browser                         │
└───────────────────────┬─────────────────────────────────┘
                        │ Port 80 (only exposed port)
┌───────────────────────▼─────────────────────────────────┐
│              TamperTrail-client (Nginx)                 │
│                                                         │
│  • Serves React dashboard (SPA)                         │
│  • Rate limiting per IP per endpoint                    │
│  • Security headers (CSP, HSTS, X-Frame-Options)        │
│  • Reverse proxies /v1/* → TamperTrail-server           │
│  • FastAPI /docs blocked from public access             │
└───────────────────────┬─────────────────────────────────┘
                        │ Internal Docker network (port 8000)
┌───────────────────────▼─────────────────────────────────┐
│              TamperTrail-server (FastAPI)               │
│                                                         │
│  • Log ingestion with WAL crash recovery                │
│  • SHA-256 hash chain computation                       │
│  • Fernet metadata encryption                           │
│  • JWT authentication + Argon2 password hashing         │
│  • Multi-tenant RLS enforcement                         │
│  • Micro-batch async DB writer                          │
│  • Monthly partition management                         │
│  • Chain verification engine                            │
└───────────────────────┬─────────────────────────────────┘
                        │ Internal Docker network (port 5432)
┌───────────────────────▼─────────────────────────────────┐
│              TamperTrail-db (PostgreSQL 16)             │
│                                                         │
│  • audit_logs: monthly range-partitioned table          │
│  • encrypted_metadata: BYTEA (Fernet ciphertext)        │
│  • tags: JSONB with GIN index (fast search)             │
│  • Row-Level Security on all sensitive tables           │
│  • Chain checkpoints for retention-safe verification    │
└─────────────────────────────────────────────────────────┘
```

### Docker Volumes

| Volume | Contents | Purpose |
|--------|----------|---------|
| `postgres_data` | PostgreSQL data directory | Persist the encrypted audit database |
| `server_data` | `config.json`, `queue.wal`, `queue.wal.pos` | Persist app config + WAL crash recovery |
| `secrets` | `db_password` file | Securely share DB credentials between containers |

---



## API Reference

All endpoints are prefixed with `/v1`. Authentication uses either a **JWT cookie** (dashboard) or `X-API-Key` header (programmatic access).

 > 💡 For full API details, see [API_REFERENCE.md](https://github.com/sthakur369/TamperTrail/blob/main/docs/API_REFERENCE.md)
---

## Chain Verification

TamperTrail's tamper detection works like a blockchain: each entry's hash includes the previous entry's hash. Modify or delete any entry, and the chain breaks.

```bash
# Quick verification — stops at first error
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost/v1/verify"

# Deep scan — finds ALL tampered entries across the entire vault
curl -H "Authorization: Bearer $TOKEN" \
  "http://localhost/v1/verify/deep"
```

```json
// All clear
{
  "valid": true,
  "checked": 10482,
  "message": "All 10,482 log entries verified successfully. Chain integrity intact."
}

// Tampering detected
{
  "valid": false,
  "checked": 4201,
  "first_error_at": "2026-01-15T14:22:03.491Z",
  "message": "Chain break detected: row prev_hash does not match previous row hash. Possible tampering before 2026-01-15T14:22:03Z."
}
```

---
## 🛠 Maintenance & Disaster Recovery

TamperTrail is designed with data sovereignty in mind. Since your data is
encrypted and self-hosted, you are responsible for managing your own
backups.


### 💾 Backing Up Data

Create a full database snapshot:

``` bash
docker exec -i tampertrail-db pg_dump -U tampertrail tampertrail > backup.sql
```

---
### 🔄 Disaster Recovery (Restore)

To restore your data to a fresh instance or roll back a corrupted database, use the following sequence.

⚠️ **Warning:** The first command (Drop Schema) will permanently delete
any existing data in the current database to ensure a clean restore.
Skip it if you are restoring to a completely empty instance.

---

#### Step 1: Clear the current schema

``` bash
docker exec -i tampertrail-db psql -U tampertrail -d tampertrail -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
```

---

#### Step 2: Import the backup

``` bash
cat backup.sql | docker exec -i tampertrail-db psql -U tampertrail -d tampertrail
```

---

## License Tiers

> 💡 ***Free core edition available. Pro tier (extended limits and advanced capabilities) in development!***

TamperTrail runs on a license key system. Without a license key, the Free tier applies.

| Limit | Free | Pro (Coming Soon) |
|-------|------|-----|
| Dashboard users | 1 | TBD |
| Projects (tenants) | 1 | TBD |
| Environments per project | 2 | TBD |
| Log retention | 30 days | Extended retention |
| Log ingestion | Unlimited | TBD |
| API keys | Unlimited | TBD |

> Licenses are RS256-signed JWTs. Apply via **Admin → Settings → License Key** in the dashboard. Expiry is graceful — existing data is never deleted, only creation of new resources above free-tier limits is blocked.


---

## Screenshots

<div align="center">

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/integrity-check.png" alt="Integrity Check — SHA-256 hash chain verification" width="100%" style="border-radius: 10px;" />
      <br />
      <sub><b>🔗 Integrity Check</b><br/>Real-time SHA-256 hash chain verification</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/api-keys.png" alt="API Keys — create and manage ingestion keys" width="100%" style="border-radius: 10px;" />
      <br />
      <sub><b>🔑 API Keys</b><br/>Create, manage, and revoke ingestion keys</sub>
    </td>
  </tr>

  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/projects.png" alt="Projects Page — create and manage projects" width="100%" style="border-radius: 10px;" />
      <br />
      <sub><b>📁 Projects</b><br/>Organize and manage your projects</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/teams.png" alt="Teams Page — create and manage teams" width="100%" style="border-radius: 10px;" />
      <br />
      <sub><b>👥 Teams</b><br/>Collaborate and manage team access</sub>
    </td>
  </tr>
</table>

</div>

---
## Security Model

TamperTrail is designed with defense-in-depth:

1. **Network boundary** — Only port 80 (Nginx) is exposed. PostgreSQL and FastAPI ports are internal-only
2. **Rate limiting** — Per-IP limits on every endpoint category via Nginx
3. **Authentication** — Argon2id password hashing, JWT session tokens (24h expiry), Argon2-hashed API keys
4. **Setup lock** — All API routes return `503` until the setup wizard is completed
5. **Encryption at rest** — Sensitive `metadata` Fernet-encrypted; even a full DB dump reveals only ciphertext
6. **Key security** — Config auto-generated with `chmod 600` on first boot; DB password in a shared volume readable only by containers
7. **Tenant isolation** — Every query is scoped to a `tenant_id` extracted from the JWT; PostgreSQL RLS provides a second enforcement layer
8. **Non-root containers** — Server runs as a dedicated `app` user (not root)
9. **Security headers** — Full suite: CSP, HSTS, X-Frame-Options, X-Content-Type-Options, Referrer-Policy, Permissions-Policy

For a full cryptographic breakdown, shared responsibility model, and infrastructure topology, see the **[Architecture Whitepaper](docs/TamperTrail%20-%20CTO%20Architecture%20Whitepaper.md)**.

---


## Future Roadmap

- **Forensic CLI Export Tool** — A command-line auditor tool for exporting, decrypting, and verifying the full audit chain offline, without requiring a running server
- **SSO Integration** — SAML 2.0 and OIDC support for enterprise identity providers (Okta, Azure AD, Google Workspace)
- **Internal System Audit Trails** — TamperTrail logs its own operations (API key creation, user changes, login events) as system-tagged audit entries for self-auditing
- **Compliance Export Reports** — Pre-formatted PDF/Excel reports for SOC 2, GDPR, and HIPAA auditors, with admin password re-confirmation and full audit logging of the export action
- **Webhook Alerts** — Real-time alerts to Slack, PagerDuty, or any webhook URL when critical-severity events are detected
- **Key Rotation UI** — Dashboard-driven Fernet key rotation with zero-downtime re-encryption of the metadata vault
- **Built-in HTTPS (Caddy Integration)** — Optional Caddy container with automatic Let's Encrypt certificates. Set `TAMPERTRAIL_DOMAIN=logs.acme.com` and get HTTPS with zero configuration. Localhost dev flow completely unaffected.

---



## Documentation

| Document | Description |
|----------|-------------|
| [Why TamperTrail](docs/TamperTrail%20-%20CEO%20Decision%20Brief.md) | ROI analysis, compliance acceleration, data sovereignty strategy, feature-to-benefit translation, and product roadmap |
| [Architecture Whitepaper](docs/TamperTrail%20-%20CTO%20Architecture%20Whitepaper.md) | Full technical architecture, cryptography deep dive, performance mechanics, and shared responsibility model |
| [Security & Compliance](docs/TamperTrail%20-%20Security%20%26%20Compliance%20Whitepaper.md) | Cryptographic architecture, compliance framework mapping (SOC 2, HIPAA, GDPR, ISO 27001, PCI DSS), and shared responsibility model |
| [Data Governance](docs/TamperTrail%20-%20Privacy%20%26%20Data%20Governance%20Whitepaper.md) | Privacy by Design architecture, data classification framework, GDPR/CCPA/HIPAA compliance mapping, and data subject rights |
| [API Reference](docs/API_REFERENCE.md) | Complete API documentation — integration guide, data dictionary, code examples, and middleware implementation |

---

## ⚖️ License

TamperTrail is **Self-Hosted Proprietary Software**.

* **Standard Features:** Free for individuals and small teams. Includes full access to the core vault, cryptographic chaining, and ingestion API.
* **Pro Features:** Requires a valid license key to unlock higher limits for tenants, users, and extended retention policies.

By downloading and using this software, you agree to the terms outlined in the [LICENSE](LICENSE) file. 

**Copyright © 2026 TamperTrail. All rights reserved.**

---

<div align="center">

 > **TamperTrail** — Where Logs Become Evidence

</div>
