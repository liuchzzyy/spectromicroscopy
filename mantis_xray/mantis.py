"""Legacy batch entry, forwarded to the independently versioned CLI package."""
from .__main__ import main as _main


def main():
    return _main(["--batch"])


if __name__ == "__main__":
    raise SystemExit(main())
