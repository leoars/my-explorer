#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Deterministic CLI/MCP integration checks. Uses a disposable local fake broker only."""
import argparse
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

LIMIT = 1_048_576
UUID = "12345678-1234-1234-1234-123456789abc"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", default=".build/debug/myexplorer")
    options = parser.parse_args()
    executable = str(Path(options.executable).resolve())
    assert Path(executable).is_file(), "Build first: swift build --product myexplorer"
    with tempfile.TemporaryDirectory(prefix="mx-auto-", dir="/tmp") as temporary:
        root = Path(temporary)
        token = root / "token"
        token.write_text("smoke-private-token\n")
        token.chmod(0o600)
        config = root / "config.json"
        socket_path = root / "broker.sock"
        config.write_text(json.dumps({"socketPath": str(socket_path), "clientID": "smoke-client", "tokenFile": str(token)}))
        requests = []
        failures = []
        stopped = threading.Event()
        broker = socket.socket(socket.AF_UNIX)
        broker.bind(str(socket_path))
        broker.listen(8)
        broker.settimeout(0.1)
        mode = ["normal"]

        def serve():
            while not stopped.is_set():
                try:
                    connection, _ = broker.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                try:
                    with connection:
                        connection.settimeout(2)
                        data = b""
                        while not data.endswith(b"\n"):
                            chunk = connection.recv(4096)
                            if not chunk:
                                break
                            data += chunk
                            assert len(data) <= LIMIT + 1
                        if not data:
                            continue
                        request = json.loads(data)
                        assert request["clientID"] == "smoke-client"
                        assert request["token"] == "smoke-private-token"
                        assert isinstance(request["arguments"], dict)
                        requests.append(request)
                        if mode[0] == "timeout":
                            stopped.wait(16)
                            continue
                        if mode[0] == "malformed":
                            connection.sendall(b'{"ok":false}\n')
                        elif mode[0] == "oversized":
                            connection.sendall(b'x' * (LIMIT + 2) + b'\n')
                        elif mode[0] == "failure":
                            connection.sendall(b'{"ok":false,"error":"forbidden"}\n')
                        else:
                            connection.sendall(json.dumps({"ok": True, "result": {"method": request["method"], "arguments": request["arguments"]}}, ensure_ascii=False).encode() + b"\n")
                except (BrokenPipeError, ConnectionResetError):
                    pass
                except Exception as error:
                    failures.append(error)
        thread = threading.Thread(target=serve, daemon=True)
        thread.start()
        clean_env = dict(os.environ)
        clean_env.pop("MYEXPLORER_CONFIG", None)

        def run(arguments, data=b"", configured=True, timeout=5, env=None):
            if isinstance(data, dict):
                data = json.dumps(data, ensure_ascii=False, indent=2).encode()
            command = [executable] + (["--config", str(config)] if configured else []) + arguments
            result = subprocess.run(command, input=data, capture_output=True, timeout=timeout, env=env or clean_env)
            assert b"smoke-private-token" not in result.stdout + result.stderr
            return result

        def mcp(messages, configured=True):
            payload = b"\n".join(json.dumps(message).encode() if not isinstance(message, bytes) else message for message in messages) + b"\n"
            result = run(["mcp"], payload, configured=configured)
            assert result.returncode == 0, result.stderr.decode()
            return [json.loads(line) for line in result.stdout.splitlines()]

        initialize = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "1"}}}
        initialized = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        try:
            assert json.loads(run(["capabilities"]).stdout)["result"]["method"] == "capabilities.get"
            aliases = {
                "connections.list": {}, "connections.prepare": {"name": "日本語", "provider": "s3", "bucket": "test"},
                "connections.authenticate": {"planID": UUID}, "connections.validate": {"planID": UUID}, "connections.apply": {"planID": UUID},
                "locations.list": {"url": "file:///tmp/ç", "limit": 200},
                "transfers.plan": {"sources": ["file:///tmp/a"], "destination": "file:///tmp/b", "conflict": "fail"},
                "transfers.start": {"planID": UUID, "idempotencyKey": "retry-1"}, "transfers.status": {"jobID": UUID}, "transfers.cancel": {"jobID": UUID},
                "deletions.plan": {"sources": ["file:///tmp/a"], "recursive": False}, "deletions.start": {"planID": UUID, "idempotencyKey": "retry-2"},
                "deletions.status": {"jobID": UUID}, "deletions.cancel": {"jobID": UUID},
                "preferences.get": {}, "preferences.update": {"language": "ja", "showFileExtensions": True, "fonts": {"files": 14}}, "audit.list": {"limit": 3}
            }
            for method, arguments in aliases.items():
                response = run(method.split("."), arguments)
                assert response.returncode == 0, response.stderr.decode()
                assert json.loads(response.stdout)["result"] == {"method": method, "arguments": arguments}
            assert run(["call", "preferences.get"], {}).returncode == 0
            environment = dict(clean_env, MYEXPLORER_CONFIG=str(config))
            assert run(["capabilities"], configured=False, env=environment).returncode == 0
            count = len(requests)
            for arguments in [{"url": "file:///tmp", "limit": 201}, {"url": "file:///tmp", "limit": True}, {"url": "file:///tmp", "token": "injection"}]:
                assert run(["locations", "list"], arguments).returncode != 0
            assert run(["--socket", str(socket_path), "capabilities"]).returncode != 0
            assert run(["call", "grants.create"], {}).returncode != 0
            assert run(["capabilities"], b"{} {} ").returncode != 0
            assert run(["capabilities"], b" " * (LIMIT + 1)).returncode != 0
            assert len(requests) == count
            tools = mcp([initialize, initialized, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}], configured=False)
            assert tools[0]["result"]["protocolVersion"] == "2025-11-25"
            catalog = tools[1]["result"]["tools"]
            assert len(catalog) == 18 and all(t["inputSchema"]["type"] == "object" for t in catalog)
            assert not any("grant" in t["name"] for t in catalog)
            call = {"jsonrpc": "2.0", "id": "call", "method": "tools/call", "params": {"name": "locations_list", "arguments": {"url": "file:///tmp"}}}
            result = mcp([initialize, initialized, call])[-1]["result"]
            assert result["isError"] is False and result["structuredContent"]["ok"] is True
            assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
            invalids = [b"{", [], {"jsonrpc": "2.0", "id": None, "method": "ping"}, {"jsonrpc": "2.0", "id": True, "method": "ping"}, {"jsonrpc": "2.0", "id": 1.5, "method": "ping"}, {"jsonrpc": "1.0", "id": 3, "method": "ping"}]
            errors = mcp(invalids)
            assert len(errors) == len(invalids) and all("error" in value for value in errors)
            before = len(requests)
            notification = dict(call); notification.pop("id")
            results = mcp([initialize, initialized, notification, {"jsonrpc": "2.0", "method": "unknown_notification"}, {"jsonrpc": "2.0", "id": 4, "method": "ping"}])
            assert len(results) == 2 and len(requests) == before
            assert mcp([call])[0]["error"]["code"] == -32002
            assert mcp([initialize, call])[-1]["error"]["code"] == -32002
            bad_call = dict(call, params={"name": "locations_list", "arguments": {"url": "file:///tmp", "limit": 201}})
            assert mcp([initialize, initialized, bad_call])[-1]["error"]["code"] == -32602
            bad_params = {"jsonrpc": "2.0", "id": 8, "method": "tools/list", "params": []}
            assert mcp([initialize, initialized, bad_params])[-1]["error"]["code"] == -32602
            assert run(["mcp"], b"x" * (LIMIT + 1)).returncode != 0
            token.chmod(0o644)
            assert run(["capabilities"]).returncode != 0
            token.chmod(0o600)
            actual = root / "actual-token"; token.rename(actual); token.symlink_to(actual)
            assert run(["capabilities"]).returncode != 0
            token.unlink(); os.mkfifo(token)
            assert run(["capabilities"], timeout=2).returncode != 0
            token.unlink(); actual.rename(token)
            old_config = config.read_bytes(); config.unlink(); os.mkfifo(config)
            assert run(["capabilities"], timeout=2).returncode != 0
            config.unlink(); config.write_bytes(old_config)
            for scenario in ["failure", "malformed", "oversized"]:
                mode[0] = scenario
                failed = run(["capabilities"])
                assert failed.returncode != 0
                result = mcp([initialize, initialized, call])[-1]["result"]
                assert result["isError"] is True and result["structuredContent"]["ok"] is False
            mode[0] = "timeout"
            start = time.monotonic()
            timed = run(["capabilities"], timeout=19)
            assert timed.returncode != 0 and b"timed out" in timed.stderr and time.monotonic() - start < 18
        finally:
            stopped.set(); broker.close(); thread.join(timeout=2)
        assert not failures, failures
        unavailable = run(["capabilities"])
        assert unavailable.returncode != 0 and b"unavailable" in unavailable.stderr
        print("Automation smoke passed: 18 CLI methods, MCP lifecycle/schema/errors, credentials, bounds, notifications, and socket timeout; no cloud access.")


if __name__ == "__main__":
    main()
