"""Command-line frontend of the mantis-xray distribution.

Presentation only: every scientific operation goes through core.Session, so the
CLI, the library API and the JSON-lines engine share one implementation.
"""
import argparse
from contextlib import redirect_stdout
import json
from pathlib import Path
import sys

from . import __version__


def validate_pipeline(document):
    if not isinstance(document, dict) or set(document) - {"protocol", "steps"}:
        raise ValueError("Pipeline must be an object with protocol and steps")
    protocol = document.get("protocol", 1)
    if type(protocol) is not int or protocol != 1:
        raise ValueError("Unsupported pipeline protocol")
    steps = document.get("steps")
    if not isinstance(steps, list) or not steps:
        raise ValueError("Pipeline steps must be a non-empty list")
    for step in steps:
        if not isinstance(step, dict) or set(step) - {"method", "params"}:
            raise ValueError("Each step must contain method and params only")
        if not isinstance(step.get("method"), str) or not isinstance(step.get("params", {}), dict):
            raise ValueError("Step method must be a string and params an object")
    if steps[0]["method"] not in {"open", "build_stack"}:
        raise ValueError("The first step must open a dataset or build_stack")
    return steps


def execute_pipeline(document, base):
    steps = validate_pipeline(document)
    with redirect_stdout(sys.stderr):
        from mantis_xray.core.session import Session
        session = Session()
        result = None
        for index, step in enumerate(steps):
            params = dict(step.get("params", {}))
            for name in ("path",):
                if params.get(name):
                    p = Path(params[name]).expanduser()
                    params[name] = str(p if p.is_absolute() else base / p)
            if "paths" in params:
                params["paths"] = [str(p if p.is_absolute() else base / p)
                                   for p in map(Path, params["paths"])]
            try:
                result = session.dispatch(step["method"], params)
            except Exception as exc:
                raise ValueError(f"Step {index + 1} ({step['method']}): {exc}") from exc
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description="Headless MANTiS spectral analysis; macOS GUI is a separate application.")
    parser.add_argument("--version", action="version", version=f"mantis-xray CLI {__version__}")
    parser.add_argument("--batch", nargs="?", const="Mantis_batch_settings.txt", help="Legacy batch settings file")
    commands = parser.add_subparsers(dest="command")
    inspect = commands.add_parser("inspect", help="Read a stack and report shape, axes and spectra as JSON")
    inspect.add_argument("path")
    inspect.add_argument("--pre-normalized", action="store_true")
    pipeline = commands.add_parser("pipeline", help="Execute a reproducible JSON analysis pipeline")
    pipeline.add_argument("path")
    batch = commands.add_parser("batch", help="Run legacy Mantis_batch_settings.txt through the shared core")
    batch.add_argument("path", nargs="?", default="Mantis_batch_settings.txt")
    analyze = commands.add_parser("analyze", help="Normalize, run PCA/clustering and export numeric results")
    analyze.add_argument("path")
    norm = analyze.add_mutually_exclusive_group(required=True)
    norm.add_argument("--pre-normalized", action="store_true")
    norm.add_argument("--i0", help="Measured two-column energy/I0 file")
    analyze.add_argument("--components", type=int, default=3)
    analyze.add_argument("--clusters", type=int)
    analyze.add_argument("--seed", type=int, default=0)
    analyze.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    if args.batch and args.command:
        parser.error("--batch cannot be combined with a subcommand")
    try:
        if args.batch or args.command == "batch":
            from .batch import parse_settings, to_pipeline
            path = Path(args.batch or args.path).expanduser().resolve()
            document = to_pipeline(parse_settings(path), path.parent)
            base = path.parent
        elif args.command == "pipeline":
            path = Path(args.path).expanduser().resolve()
            document = json.loads(path.read_text())
            base = path.parent
        elif args.command == "inspect":
            document = {"steps": [{"method": "open", "params": {"path": args.path, "pre_normalized": args.pre_normalized}}]}
            base = Path.cwd()
        elif args.command == "analyze":
            steps = [{"method": "open", "params": {"path": args.path}}]
            steps.append({"method": "normalize", "params": {"mode": "pre_normalized"} if args.pre_normalized else {"mode": "file", "path": args.i0}})
            steps.append({"method": "pca", "params": {"components": args.components}})
            if args.clusters is not None:
                steps.append({"method": "cluster", "params": {"clusters": args.clusters, "components": args.components, "seed": args.seed}})
            suffix = Path(args.output).suffix.lower()
            fmt = {".npz": "npz", ".h5": "hdf5", ".hdf5": "hdf5"}.get(suffix)
            if fmt is None:
                raise ValueError("Analysis output must end in .npz, .h5 or .hdf5")
            steps.append({"method": "export", "params": {"path": args.output, "format": fmt}})
            document, base = {"steps": steps}, Path.cwd()
        else:
            parser.print_help()
            return 0
        result = execute_pipeline(document, base)
        print(json.dumps(result, allow_nan=False))
        return 0
    except (ValueError, OSError, RuntimeError, ImportError, TypeError, KeyError) as exc:
        print(f"mantis-xray: {exc}", file=sys.stderr)
        return 1
