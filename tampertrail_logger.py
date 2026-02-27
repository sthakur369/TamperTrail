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
    actor: str,                           #✅ REQUIRED → who did it (e.g. "user:alice@acme.com")
    action: str,                          #✅ REQUIRED → what happened (e.g. "order.created")
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



"""

# =============================================================================
# 🧠 USAGE EXAMPLES
# =============================================================================

#################### 1️ Manual Business Event Log (Route-Level) ####################

# Use send_log() inside route handlers for important business events.

# 💡 Use metadata for sensitive data (PII, full payloads, card info).
# 🔒 Encrypted at rest. Never shown in dashboard.

# (YOUR route.py file)

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


#################### 2️ Automatic Logging (Middleware-Level) ####################

# Add once → every HTTP request is logged automatically.
# No changes required in routes.

# Captures 30+ request data points. You can trim it based on your requirements

# (YOUR middleware.py file)

import time
import uuid
import asyncio
import platform
import os
import inspect

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
            "method": request.method,
            "path": request.url.path,
            "full_url": str(request.url),
            "scheme": request.url.scheme,
            "http_version": request.scope.get("http_version", ""),
            "latency_ms": str(latency_ms),
            "client_ip": client_ip,
            "client_port": str(request.client.port) if request.client else "",
            "user_agent": request.headers.get("user-agent", ""),
            "host": request.headers.get("host", ""),
            "language": request.headers.get("accept-language", "").split(",")[0].strip(),
            "server_hostname": platform.node(),
            "server_os": platform.system(),
            "python_version": platform.python_version(),
            "server_pid": str(os.getpid()),
        }

        # Optional tags
        if request.url.query:
            tags["query_string"] = str(request.url.query)

        if request.headers.get("content-type"):
            tags["request_content_type"] = request.headers["content-type"]

        if request.headers.get("content-length"):
            tags["request_bytes"] = request.headers["content-length"]

        if response.headers.get("content-type"):
            tags["response_content_type"] = response.headers["content-type"]

        if response.headers.get("content-length"):
            tags["response_bytes"] = response.headers["content-length"]

        if request.headers.get("referer"):
            tags["referer"] = request.headers["referer"]

        if request.headers.get("origin"):
            tags["origin"] = request.headers["origin"]

        if request.headers.get("authorization"):
            tags["authenticated"] = "true"

        if handler_file:
            tags["handler_file"] = handler_file

        if handler_function:
            tags["handler_function"] = handler_function

        if handler_line:
            tags["handler_line"] = handler_line

        if getattr(route, "path", None):
            tags["route_pattern"] = route.path

        if error_detail:
            tags["error"] = error_detail[:200]

        # ---------------------------------------------------------------------
        # Fire Log (Non-Blocking)
        # ---------------------------------------------------------------------

        asyncio.create_task(
            send_log(
                actor=actor,
                action="http.request",
                level=level,
                message=f"{request.method} {request.url.path} → {status_code}",
                status=str(status_code),
                source_ip=client_ip,
                request_id=request_id,
                tags=tags,
            )
        )

        response.headers["X-Request-ID"] = request_id
        return response


# Register:
# app.add_middleware(LoggingMiddleware)

"""

