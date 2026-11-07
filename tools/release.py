"""Veroeffentlicht den letzten Commit als GitHub-Release.

Aufruf: python tools/release.py "Was neu ist"

Das Update-Skript der Tester holt immer das neueste Release. Ein einfaches
git push erreicht sie also nicht, erst dieses Skript. Es nimmt nur Committetes,
die ZIP enthaelt nur das, was WoW braucht, im Ordner HunterFlow.
"""

import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPDATE_SCRIPT = ROOT / "tools" / "HunterFlow-Update.bat"
ADDON_PATHS = ["HunterFlow.lua", "HunterFlow.toc", "Sounds", "Textures"]


def run(*args):
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True, encoding="utf-8").stdout.strip()


def main():
    if run("git", "branch", "--show-current") != "main":
        raise SystemExit("Abbruch: Releases nur von main.")

    toc = run("git", "show", "HEAD:HunterFlow.toc")
    match = re.search(r"^## Version:\s*(\S+)", toc, re.MULTILINE)
    if not match:
        raise SystemExit("Abbruch: keine Version in der toc.")
    version = match.group(1)
    tag = "v" + version

    # Der Einzeiler im Update-Skript braucht Windows-Zeilenenden.
    script = UPDATE_SCRIPT.read_bytes()
    if script.count(b"\n") != script.count(b"\r\n"):
        raise SystemExit("Abbruch: Update-Skript hat keine CRLF-Zeilenenden.")

    if run("git", "tag", "--list", tag):
        raise SystemExit(f"Abbruch: {tag} gibt es schon. Erst die Version in der toc erhoehen.")

    dirty = run("git", "status", "--short")
    if dirty:
        print("Hinweis: nicht Committetes bleibt draussen:")
        print(dirty)

    notes = sys.argv[1] if len(sys.argv) > 1 else f"HunterFlow {version}"
    with tempfile.TemporaryDirectory() as temp:
        archive = Path(temp) / "HunterFlow.zip"
        run("git", "archive", "--format=zip", "--prefix=HunterFlow/", "-o", str(archive), "HEAD", *ADDON_PATHS)
        with zipfile.ZipFile(archive) as content:
            if "HunterFlow/HunterFlow.toc" not in content.namelist():
                raise SystemExit("Abbruch: ZIP hat nicht den erwarteten Aufbau.")

        run("git", "push", "origin", "main")
        url = run(
            "gh", "release", "create", tag, str(archive), str(UPDATE_SCRIPT),
            "--target", run("git", "rev-parse", "HEAD"),
            "--title", f"HunterFlow {version}",
            "--notes", notes,
        )
    print(f"Veroeffentlicht: {url}")


if __name__ == "__main__":
    main()
