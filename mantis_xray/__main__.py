"""Command-line entry point: headless analysis, pipelines and legacy batch runs."""
from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
