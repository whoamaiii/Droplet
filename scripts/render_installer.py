#!/usr/bin/env python3
"""Fills scripts/install.sh.in for one release (called by scripts/release.sh).

Every value is checked against a strict pattern before it is placed inside
the shell script, so nothing in release.env can inject shell syntax."""
import argparse
from pathlib import Path
import re
import sys

TEMPLATE = Path(__file__).resolve().with_name("install.sh.in")
PATTERNS = {
    "VERSION": r"[0-9]+\.[0-9]+(\.[0-9]+)?",
    "ZIP_URL": r"https://[A-Za-z0-9.-]+/[A-Za-z0-9._~%/+-]*\.zip",
    "SHA256": r"[0-9a-f]{64}",
    "BUNDLE_ID": r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+",
}


def render(template, values):
    text = template
    for key, pattern in PATTERNS.items():
        value = values[key]
        if not re.fullmatch(pattern, value):
            raise ValueError(f"{key} has an unexpected value: {value!r}")
        text = text.replace(f"@{key}@", value)
    leftover = re.findall(r"@[A-Z_]+@", text)
    if leftover:
        raise ValueError(f"unfilled placeholders: {', '.join(sorted(set(leftover)))}")
    return text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--zip-url", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--bundle-id", required=True)
    args = parser.parse_args(argv)
    try:
        script = render(TEMPLATE.read_text(), {"VERSION": args.version, "ZIP_URL": args.zip_url,
                                               "SHA256": args.sha256.lower(), "BUNDLE_ID": args.bundle_id})
    except ValueError as error:
        print(f"render_installer: {error}", file=sys.stderr)
        return 1
    args.output.write_text(script)
    args.output.chmod(0o755)
    return 0


if __name__ == "__main__":
    sys.exit(main())
