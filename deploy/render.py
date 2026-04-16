#!/usr/bin/env python3
"""Render deploy/templates/* per site into deploy/sites/<site>/.

CSV column names become ${VAR} placeholders (uppercased). Only CSV-defined
columns are substituted — unrelated ${VAR} tokens (shell variables, bash
arrays) pass through unchanged. Identical to render.sh behavior.

Usage:
    ./render.py                  # render only NEW sites (skip existing)
    ./render.py austin           # render 'austin' only if new
    ./render.py -o               # render ALL, overwrite existing
    ./render.py -o austin        # render 'austin', overwrite if exists
"""

import argparse, csv, os, re, shutil, stat, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CSV_PATH = HERE / "sites.csv"
TEMPLATES = HERE / "templates"
OUT = HERE / "sites"


def subst(text: str, env: dict[str, str], allowed: set[str]) -> str:
    """Replace ${VAR} tokens where VAR is in the allowed set."""
    def replace(m):
        name = m.group(1)
        return env[name] if name in allowed and name in env else m.group(0)
    return re.sub(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}', replace, text)


def render_site(site: str, env: dict[str, str], allowed: set[str]):
    site_out = OUT / site
    if site_out.exists():
        shutil.rmtree(site_out)
    site_out.mkdir(parents=True)

    for template in sorted(TEMPLATES.iterdir()):
        if not template.is_file():
            continue
        output = site_out / template.name
        rendered = subst(template.read_text(), env, allowed)
        if rendered and not rendered.endswith('\n'):
            rendered += '\n'
        output.write_text(rendered)
        if template.stat().st_mode & stat.S_IXUSR:
            output.chmod(output.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP)
        print(f"[{site}] rendered {output}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("site", nargs="?", default=None, help="render only this site")
    parser.add_argument("-o", "--overwrite", action="store_true",
                        help="overwrite existing site dirs (default: skip)")
    args = parser.parse_args()

    if not CSV_PATH.exists():
        sys.exit(f"FATAL: {CSV_PATH} not found")
    if not TEMPLATES.is_dir():
        sys.exit(f"FATAL: {TEMPLATES} not found")

    with open(CSV_PATH, newline="") as f:
        reader = csv.DictReader(f)
        headers = [h.upper() for h in reader.fieldnames]
        allowed = set(headers)
        rows = list(reader)

    seen, skipped = set(), 0
    for row in rows:
        env = {k.upper(): v for k, v in row.items()}
        site = env.get("SITE", "")
        if not site:
            print("WARN: row has no 'site' column — skipping", file=sys.stderr)
            continue
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', site):
            sys.exit(f"FATAL: unsafe site name '{site}'")
        if site in seen:
            sys.exit(f"FATAL: duplicate site '{site}' in sites.csv")
        seen.add(site)

        if args.site and site != args.site:
            continue

        if (OUT / site).exists() and not args.overwrite:
            skipped += 1
            continue

        render_site(site, env, allowed)

    if skipped:
        print(f"{skipped} existing site(s) skipped (use -o to overwrite)")


if __name__ == "__main__":
    main()
