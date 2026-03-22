"""Custom middleware for the todo app.

Middleware and handlers share the same DI graph — no separate Depends() needed.
Injectables declared with @app.injectable work everywhere.
"""

import time

import snek


def auth_middleware(app: snek.App):
    """JWT auth — sets req.user from the Authorization header."""

    @app.before_request
    async def check_auth(req: snek.Request):
        if req.path.startswith("/auth/") or req.path in ("/health", "/signup", "/login"):
            return

        token = req.headers.get("Authorization", "").removeprefix("Bearer ")
        if not token:
            raise snek.Unauthorized("missing token")

        payload = await app.jwt.decode(token)
        req.user = payload


def timing_middleware(app: snek.App):
    """Inject X-Request-Time header on every response."""

    @app.middleware
    async def timing(req: snek.Request, call_next):
        start = time.monotonic()
        response = await call_next(req)
        elapsed = time.monotonic() - start
        response.headers["X-Request-Time"] = f"{elapsed:.4f}"
        return response


def logging_middleware(app: snek.App):
    """Log every request with method, path, status, and timing."""

    @app.middleware
    async def log_request(req: snek.Request, call_next):
        start = time.monotonic()
        response = await call_next(req)
        elapsed = time.monotonic() - start

        app.log.info(
            "request",
            method=req.method,
            path=req.path,
            status=response.status,
            time=f"{elapsed:.4f}s",
            request_id=req.headers.get("X-Request-ID", ""),
        )
        return response


def session_middleware(app: snek.App):
    """Redis-backed sessions with HMAC-signed cookie IDs."""

    cookie_name = app.config.session.cookie_name
    ttl = app.config.session.ttl
    secret = app.config.session.secret_key

    @app.before_request
    async def load_session(req: snek.Request):
        session_id = req.cookies.get(cookie_name)
        if session_id and snek.verify_signature(session_id, secret):
            raw_id = snek.unsigned_value(session_id, secret)
            data = await app.redis.get(f"session:{raw_id}")
            req.session = snek.json_decode(data) if data else {}
            req.session_id = raw_id
        else:
            req.session = {}
            req.session_id = snek.generate_id()

    @app.after_request
    async def save_session(req: snek.Request, resp: snek.Response):
        if req.session:
            await app.redis.setex(
                f"session:{req.session_id}",
                ttl,
                snek.json_encode(req.session),
            )
            signed = snek.sign(req.session_id, secret)
            resp.set_cookie(
                cookie_name,
                signed,
                httponly=app.config.session.cookie_httponly,
                secure=app.config.session.cookie_secure,
                samesite=app.config.session.cookie_samesite,
                max_age=ttl,
            )


def oauth_middleware(app: snek.App):
    """OAuth2 authorization code flow for multiple providers.

    Provider config is read from snek.toml [oauth.*] sections via app.config.oauth.
    """

    @app.route("GET", "/auth/{provider}/login")
    async def oauth_login(provider: str):
        config = app.config.oauth[provider]
        params = snek.urlencode({
            "client_id": config.client_id,
            "redirect_uri": config.redirect_uri,
            "scope": config.scope,
            "response_type": "code",
        })
        return snek.redirect(f"{config.authorize_url}?{params}")

    @app.route("GET", "/auth/{provider}/callback")
    async def oauth_callback(
        req: snek.Request,
        provider: str,
        code: snek.Query[str],
    ):
        config = app.config.oauth[provider]

        token_resp = await app.http.post(
            config.token_url,
            form={
                "grant_type": "authorization_code",
                "code": code,
                "client_id": config.client_id,
                "client_secret": config.client_secret,
                "redirect_uri": config.redirect_uri,
            },
            headers={"Accept": "application/json"},
        )
        token_data = await token_resp.json()
        access_token = token_data["access_token"]

        user_resp = await app.http.get(
            config.userinfo_url,
            headers={"Authorization": f"Bearer {access_token}"},
        )
        user_info = await user_resp.json()

        await req.session.set("user", {
            "provider": provider,
            "id": str(user_info.get("id", user_info.get("sub", ""))),
            "email": user_info.get("email", ""),
            "name": user_info.get("name", user_info.get("login", "")),
        })

        return snek.redirect("/")
