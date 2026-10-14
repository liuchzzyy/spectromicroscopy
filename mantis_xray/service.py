"""Private, sequential JSON Lines computation engine (protocol version 1).

stdout is a protocol transport, never a diagnostic stream. A malformed request
gets its own error response and does not discard the session or following lines.
"""
from contextlib import redirect_stdout
import json
import os
import sys
import traceback

PROTOCOL = 1


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON field: {key}")
        result[key] = value
    return result


def _reject_constant(value):
    raise ValueError(f"Nonfinite JSON number: {value}")


def main():
    """Reserve the original fd for JSON, redirect even native-library prints."""
    sys.stdout.flush()
    with os.fdopen(os.dup(sys.stdout.fileno()), "w", encoding="utf-8", buffering=1) as output:
        os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
        with redirect_stdout(sys.stderr):
            try:
                return _serve(output)
            except BrokenPipeError:
                # A closed frontend has abandoned the session; exit without a traceback.
                return 0


def _serve(output):
    """Read one request and emit one flushed response per input line."""
    with redirect_stdout(sys.stderr):
        from .core.session import BASE_METHODS, Session, SessionError
        from .core.advanced import ADVANCED_METHODS
        from . import __version__
        session = Session()
    for line in sys.stdin.buffer:
        ident = None
        try:
            line = line.decode("utf-8", errors="strict")
            message = json.loads(line, object_pairs_hook=_unique_object, parse_constant=_reject_constant)
            if not isinstance(message, dict):
                raise SessionError("Request must be an object")
            if type(message.get("id")) not in (str, int):
                raise SessionError("id must be a string or integer")
            ident = message["id"]
            # Also reject overflow such as 1e999 anywhere in the document.
            json.dumps(message, allow_nan=False)
            if type(message.get("protocol")) is not int or message["protocol"] != PROTOCOL:
                raise SessionError(f"Supported protocol is {PROTOCOL}", "unsupported_protocol")
            method, params = message.get("method"), message.get("params", {})
            if not isinstance(method, str) or not method:
                raise SessionError("method must be a nonempty string")
            if not isinstance(params, dict):
                raise SessionError("params must be an object")
            with redirect_stdout(sys.stderr):
                if method == "hello":
                    if params:
                        raise SessionError("hello takes no parameters")
                    result = {"engine_version": __version__, "protocol": PROTOCOL,
                              "capabilities": ["hello", *BASE_METHODS, *ADVANCED_METHODS]}
                else:
                    result = session.dispatch(method, params)
            response = {"id": ident, "protocol": PROTOCOL, "ok": True, "result": result}
            encoded = json.dumps(response, allow_nan=False)
        except Exception as exc:
            if isinstance(exc, SessionError):
                code = exc.code
            elif isinstance(exc, (ValueError, TypeError, OverflowError)):
                code = "invalid_request"
            elif isinstance(exc, OSError):
                code = "file_error"
            else:
                code = "internal_error"
                traceback.print_exc(file=sys.stderr)
            encoded = json.dumps({"id": ident, "protocol": PROTOCOL, "ok": False,
                                  "error": {"code": code, "message": str(exc)}}, allow_nan=False)
        output.write(encoded + "\n")
        output.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
