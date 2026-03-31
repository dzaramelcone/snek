from __future__ import annotations

import json
import os
import shutil
import subprocess
import time
from pathlib import Path

import pytest


pytestmark = pytest.mark.skipif(
    os.environ.get("SNEK_RUN_DOCKER_INTEGRATION") != "1",
    reason="set SNEK_RUN_DOCKER_INTEGRATION=1 to run Docker ownership integration",
)


ROOT = Path(__file__).resolve().parents[2]
BENCH_CONTAINER = "compose-bench-1"
POSTGRES_CONTAINER = "compose-postgres-1"
PORT = 18090


def _run(cmd: list[str], *, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        cwd=str(cwd) if cwd else None,
        check=True,
        capture_output=True,
        text=True,
    )


def _docker_exec(container: str, command: str) -> subprocess.CompletedProcess[str]:
    return _run(["docker", "exec", container, "sh", "-lc", command])


def _docker_exec_detached(container: str, command: str) -> subprocess.CompletedProcess[str]:
    return _run(["docker", "exec", "-d", container, "sh", "-lc", command])


def _bench_get_json(path: str) -> tuple[int, dict]:
    code = (
        "import json, urllib.request;"
        f"resp = urllib.request.urlopen('http://127.0.0.1:{PORT}{path}', timeout=2);"
        "body = json.loads(resp.read().decode());"
        "print(json.dumps({'status': resp.status, 'body': body}))"
    )
    out = _run(["docker", "exec", BENCH_CONTAINER, "python3", "-c", code]).stdout.strip()
    payload = json.loads(out)
    return int(payload["status"]), payload["body"]


def _wait_for(path: str, predicate, timeout_s: float = 5.0) -> dict:
    deadline = time.time() + timeout_s
    last_body: dict | None = None
    while time.time() < deadline:
        status, body = _bench_get_json(path)
        assert status == 200
        last_body = body
        if predicate(body):
            return body
        time.sleep(0.05)
    raise AssertionError(f"timed out waiting for {path}; last body={last_body!r}")


def _containers_ready() -> bool:
    if shutil.which("docker") is None:
        return False
    out = _run(["docker", "ps", "--format", "{{.Names}}"]).stdout.splitlines()
    return BENCH_CONTAINER in out and POSTGRES_CONTAINER in out


@pytest.mark.integration
def test_real_pg_routes_preserve_models_across_request_boundaries() -> None:
    if not _containers_ready():
        pytest.skip("bench/postgres Docker containers are not running")

    _run(
        ["zig", "build", "-Doptimize=ReleaseFast", "-Dtarget=aarch64-linux-gnu"],
        cwd=ROOT,
    )

    _docker_exec(
        POSTGRES_CONTAINER,
        """
        psql -v ON_ERROR_STOP=1 -U snek -d snek -c "
        DROP TABLE IF EXISTS theses;
        DROP TABLE IF EXISTS ideas;
        CREATE TABLE ideas (
            id TEXT PRIMARY KEY,
            description TEXT NOT NULL
        );
        CREATE TABLE theses (
            id TEXT PRIMARY KEY,
            idea_id TEXT NOT NULL REFERENCES ideas(id),
            summary TEXT NOT NULL
        );
        INSERT INTO ideas (id, description) VALUES ('idea-1', 'hello');
        INSERT INTO theses (id, idea_id, summary) VALUES ('thesis-1', 'idea-1', 'world');
        "
        """,
    )

    _docker_exec(
        BENCH_CONTAINER,
        "pkill -f '[o]wnership_models.py' >/dev/null 2>&1 || true; rm -f /tmp/ownership_models.log",
    )
    _docker_exec_detached(
        BENCH_CONTAINER,
        f"cd /bench/scenarios && PYTHONPATH=/bench/snek_root:/bench/scenarios PORT={PORT} python3 ownership_models.py >/tmp/ownership_models.log 2>&1",
    )

    try:
        _wait_for("/clean", lambda body: body.get("id") == "idea-1")

        status, body = _bench_get_json("/reset")
        assert status == 200
        assert body == {"ok": True}

        status, body = _bench_get_json("/clean")
        assert status == 200
        assert body == {"id": "idea-1", "description": "hello"}

        status, body = _bench_get_json("/mutate")
        assert status == 200
        assert body == {"id": "idea-1", "description": "changed-in-route"}

        status, body = _bench_get_json("/await-pass")
        assert status == 200
        assert body == {"id": "idea-1", "description": "hello"}

        status, body = _bench_get_json("/await-mutate")
        assert status == 200
        assert body == {"id": "idea-1", "description": "changed-in-helper"}

        status, body = _bench_get_json("/nested")
        assert status == 200
        assert body == {"id": "idea-1", "description": "hello"}

        status, body = _bench_get_json("/cache/store")
        assert status == 200
        assert body == {"stored": True}

        status, body = _bench_get_json("/cache/get")
        assert status == 200
        assert body == {"id": "idea-1", "description": "hello"}

        status, body = _bench_get_json("/view/store")
        assert status == 200
        assert body == {"stored": True}

        status, body = _bench_get_json("/view/get")
        assert status == 200
        assert body == {"ready": True, "description": "hello"}

        status, body = _bench_get_json("/dirty-raw")
        assert status == 200
        assert "mutated" in body["error"]

        status, body = _bench_get_json("/thread/store")
        assert status == 200
        assert body == {"queued": True}
        body = _wait_for("/thread/get", lambda payload: payload.get("id") == "idea-1")
        assert body == {"id": "idea-1", "description": "hello"}

        status, body = _bench_get_json("/thread/mutate/store")
        assert status == 200
        assert body == {"queued": True}
        body = _wait_for(
            "/thread/mutate/get",
            lambda payload: payload.get("description") == "changed-in-thread",
        )
        assert body == {"id": "idea-1", "description": "changed-in-thread"}

        status, body = _bench_get_json("/thread/view/store")
        assert status == 200
        assert body == {"queued": True}
        body = _wait_for("/thread/view/get", lambda payload: payload.get("ready") is True)
        assert body == {"ready": True, "description": "hello"}
    finally:
        _docker_exec(
            BENCH_CONTAINER,
            "pkill -f '[o]wnership_models.py' >/dev/null 2>&1 || true",
        )
