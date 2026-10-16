"""Exercise the JSONL boundary in real, isolated engine processes."""
import json
import os
from pathlib import Path
import subprocess
import sys

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]


def request(method, params=None, ident=1, protocol=1):
    return {"id": ident, "protocol": protocol, "method": method,
            "params": {} if params is None else params}


def run_engine(messages, command=None):
    lines = [message if isinstance(message, str) else json.dumps(message) for message in messages]
    process = subprocess.run(command or [sys.executable, "-m", "mantis_xray.service"],
                             input="\n".join(lines) + "\n", text=True, capture_output=True,
                             cwd=ROOT, timeout=30, env={**os.environ, "MPLBACKEND": "Agg"})
    assert process.returncode == 0, process.stderr
    responses = [json.loads(line) for line in process.stdout.splitlines()]
    assert len(responses) == len(messages), (process.stdout, process.stderr)
    for response in responses:
        assert response["protocol"] == 1
        json.dumps(response, allow_nan=False)
    return responses, process


def test_hello_is_real_process_and_advertises_actual_dispatch():
    from mantis_xray.core.advanced import ADVANCED_METHODS
    replies, process = run_engine([request("hello")])
    hello = replies[0]
    assert hello["ok"] and hello["id"] == 1
    assert hello["result"]["engine_version"] == "3.3.2"
    assert hello["result"]["protocol"] == 1
    methods = hello["result"]["capabilities"]
    assert len(methods) == len(set(methods))
    assert {"hello", "open", "inspect_file", "build_stack", "export", *ADVANCED_METHODS} <= set(methods)
    assert "Traceback" not in process.stderr


@pytest.mark.parametrize("message,code,ident", [
    ("{bad", "invalid_request", None),
    ("", "invalid_request", None),
    ("[]", "invalid_request", None),
    ("null", "invalid_request", None),
    ({"protocol": 1, "method": "hello"}, "invalid_request", None),
    (request("hello", ident=True), "invalid_request", None),
    (request("hello", ident=[]), "invalid_request", None),
    (request("hello", protocol=2), "unsupported_protocol", 1),
    (request("hello", protocol=True), "unsupported_protocol", 1),
    (request("hello", protocol=1.0), "unsupported_protocol", 1),
    ({"id": 1, "method": "hello"}, "unsupported_protocol", 1),
    (request(12), "invalid_request", 1),
    (request("hello", params=[]), "invalid_request", 1),
    ('{"id":1,"protocol":1,"method":"hello","params":null}', "invalid_request", 1),
    (request("hello", {"extra": 1}), "invalid_request", 1),
    (request("not_a_method"), "unknown_method", 1),
    (request("open"), "invalid_request", 1),
    (request("view"), "invalid_state", 1),
    ('{"id":1,"protocol":1,"method":"hello","params":{"x":NaN}}', "invalid_request", None),
    ('{"id":1,"protocol":1,"method":"hello","params":{"x":1e999}}', "invalid_request", 1),
    ('{"id":1,"id":2,"protocol":1,"method":"hello"}', "invalid_request", None),
])
def test_bad_message_is_structured_and_process_recovers(message, code, ident):
    replies, _ = run_engine([message, request("hello", ident="after-error")])
    assert replies[0]["ok"] is False
    assert replies[0]["id"] == ident
    assert replies[0]["error"]["code"] == code
    assert replies[0]["error"]["message"]
    assert replies[1]["ok"] and replies[1]["id"] == "after-error"


def test_real_pipeline_advanced_dispatch_and_full_export(tmp_path):
    data = np.arange(6 * 3 * 5, dtype=float).reshape(6, 3, 5) + 20
    source = tmp_path / "data.npz"
    np.savez(source, data=data, energies=np.arange(5) + 280)
    target = tmp_path / "result.npz"
    replies, _ = run_engine([
        request("open", {"path": str(source)}, ident=1),
        request("normalize", {"mode": "roi", "bounds": [0, 0, 1, 1]}, ident=2),
        request("pca", {"components": 2}, ident=3),
        request("spectral_roi", {"pre": [0, 2], "post": [3, 5]}, ident=4),
        request("export", {"path": str(target), "format": "npz"}, ident=5),
    ])
    assert all(reply["ok"] for reply in replies), replies
    assert [reply["id"] for reply in replies] == [1, 2, 3, 4, 5]
    expected = -np.log(data[:, :, 3:5].mean(axis=2) / data[:, :, :2].mean(axis=2))
    with np.load(target) as archive:
        np.testing.assert_allclose(archive["results/spectral_roi/map"], expected)
        np.testing.assert_array_equal(archive["raw_data"], data)
        assert archive["results/pca/pcaimages"].shape == data.shape
    # A second engine cannot see the first engine's dataset.
    fresh, _ = run_engine([request("view")])
    assert fresh[0]["error"]["code"] == "invalid_state"


def test_stdout_isolation_catches_python_and_native_diagnostics():
    # Inject diagnostics at the plugin boundary, including native fd writes that
    # contextlib.redirect_stdout alone cannot capture.
    command = [sys.executable, "-c", """
import os
from mantis_xray.core.session import Session
original = Session.dispatch
def noisy(self, method, params):
    print('python diagnostic')
    os.write(1, b'native diagnostic\\n')
    return original(self, method, params)
Session.dispatch = noisy
from mantis_xray.service import main
raise SystemExit(main())
"""]
    replies, process = run_engine([request("view"), request("hello")], command=command)
    assert replies[0]["error"]["code"] == "invalid_state"
    assert replies[1]["ok"]
    assert "python diagnostic" in process.stderr
    assert "native diagnostic" in process.stderr


def test_response_is_flushed_before_eof():
    import selectors
    with subprocess.Popen([sys.executable, "-m", "mantis_xray.service"],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                          text=True, cwd=ROOT) as process:
        try:
            process.stdin.write(json.dumps(request("hello")) + "\n")
            process.stdin.flush()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                assert selector.select(timeout=20), "engine buffered response until EOF"
            assert json.loads(process.stdout.readline())["ok"]
            assert process.poll() is None
        finally:
            process.stdin.close()
            process.wait(timeout=10)


def test_invalid_utf8_line_does_not_terminate_engine():
    payload = b'{"id":1,"protocol":1,"method":"hel\xfflo"}\n' + json.dumps(request("hello")).encode() + b'\n'
    process = subprocess.run([sys.executable, "-m", "mantis_xray.service"], input=payload,
                             capture_output=True, cwd=ROOT, timeout=30)
    assert process.returncode == 0, process.stderr
    replies = [json.loads(line) for line in process.stdout.splitlines()]
    assert len(replies) == 2
    assert replies[0]["error"]["code"] == "invalid_request"
    assert replies[1]["ok"]
