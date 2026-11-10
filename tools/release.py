"""Veroeffentlicht den letzten Commit als GitHub-Release und laedt die ZIP auf CurseForge.

Aufruf:
  python tools/release.py "Was neu ist"        GitHub-Release, danach CurseForge
  python tools/release.py --nur-curseforge "Was neu ist"
                                               nur CurseForge, fuer eine Version, die
                                               auf GitHub schon veroeffentlicht ist

Das Update-Skript der Tester holt immer das neueste Release. Ein einfaches
git push erreicht sie also nicht, erst dieses Skript. Es nimmt nur Committetes,
die ZIP enthaelt nur das, was WoW braucht, im Ordner HunterFlow.

Der CurseForge-Schluessel liegt im Windows Credential Manager (Dienst
gamervibes-curseforge, Benutzer upload_token), nie im Repo. Eintragen mit
D:\\GamerVibes\\Tools\\CurseForge\\curseforge_zugang_eintragen.py. Fehlt er, laeuft
nur der GitHub-Teil.
"""

import json
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
import uuid
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
UPDATE_SCRIPT = ROOT / "tools" / "HunterFlow-Update.bat"
ADDON_PATHS = ["HunterFlow.lua", "HunterFlow.toc", "LICENSE", "Sounds", "Textures"]
# Liegen noch im Repo, werden vom Add-on aber nicht mehr benutzt.
ADDON_EXCLUDE = [":(exclude)Textures/FrostFill.tga", ":(exclude)Textures/FrostTrack.tga"]

CURSEFORGE_API = "https://wow.curseforge.com/api"
CURSEFORGE_PROJECT_ID = 1794598  # "About Project" auf curseforge.com/wow/addons/hunterflow
# Spielversion auf CurseForge. Interface 16001 in der toc entspricht dem Client 1.60.1.
CURSEFORGE_GAME_VERSION = "1.60.1"
KEYRING_SERVICE = "gamervibes-curseforge"
KEYRING_USER = "upload_token"


def run(*args):
    return subprocess.run(args, cwd=ROOT, check=True, capture_output=True, text=True, encoding="utf-8").stdout.strip()


def toc_version(ref):
    toc = run("git", "show", f"{ref}:HunterFlow.toc")
    match = re.search(r"^## Version:\s*(\S+)", toc, re.MULTILINE)
    if not match:
        raise SystemExit("Abbruch: keine Version in der toc.")
    return match.group(1)


def build_archive(ref, archive):
    run("git", "archive", "--format=zip", "--prefix=HunterFlow/", "-o", str(archive), ref, *ADDON_PATHS, *ADDON_EXCLUDE)
    with zipfile.ZipFile(archive) as content:
        if "HunterFlow/HunterFlow.toc" not in content.namelist():
            raise SystemExit("Abbruch: ZIP hat nicht den erwarteten Aufbau.")


def curseforge_token():
    try:
        import keyring
    except ImportError:
        return None
    return keyring.get_password(KEYRING_SERVICE, KEYRING_USER)


def curseforge_request(token, path, data=None, content_type=None):
    request = urllib.request.Request(CURSEFORGE_API + path, data=data, method="POST" if data else "GET")
    request.add_header("X-Api-Token", token)
    request.add_header("User-Agent", "HunterFlow-Release")
    if content_type:
        request.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:500]
        raise SystemExit(f"CurseForge meldet {error.code}: {detail}") from None


def curseforge_game_version_id(token):
    versions = curseforge_request(token, "/game/versions")
    matches = [v for v in versions if v.get("name") == CURSEFORGE_GAME_VERSION]
    if len(matches) != 1:
        found = ", ".join(f"{v['id']} (Typ {v.get('gameVersionTypeID')})" for v in matches) or "keine"
        raise SystemExit(f"Abbruch: Spielversion {CURSEFORGE_GAME_VERSION} nicht eindeutig gefunden: {found}")
    return matches[0]["id"]


def curseforge_upload(archive, version, notes):
    """Laedt die ZIP als Release-Datei hoch. Die Freigabe macht danach CurseForge."""
    token = curseforge_token()
    if not token:
        print("CurseForge uebersprungen: kein Schluessel im Credential Manager.")
        return
    if not CURSEFORGE_PROJECT_ID:
        print("CurseForge uebersprungen: CURSEFORGE_PROJECT_ID ist in tools/release.py noch nicht eingetragen.")
        return

    metadata = {
        "changelog": notes,
        "changelogType": "text",
        "displayName": f"HunterFlow {version}",
        "gameVersions": [curseforge_game_version_id(token)],
        "releaseType": "release",
    }
    boundary = uuid.uuid4().hex
    parts = [
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\n"
        f"Content-Type: application/json\r\n\r\n{json.dumps(metadata)}\r\n".encode("utf-8"),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"HunterFlow-{version}.zip\"\r\n"
        f"Content-Type: application/zip\r\n\r\n".encode("utf-8"),
        archive.read_bytes(),
        f"\r\n--{boundary}--\r\n".encode("utf-8"),
    ]
    result = curseforge_request(
        token,
        f"/projects/{CURSEFORGE_PROJECT_ID}/upload-file",
        data=b"".join(parts),
        content_type=f"multipart/form-data; boundary={boundary}",
    )
    print(f"CurseForge: Datei {result.get('id')} hochgeladen, Freigabe durch CurseForge steht aus.")


def main():
    args = sys.argv[1:]
    only_curseforge = "--nur-curseforge" in args
    args = [a for a in args if a != "--nur-curseforge"]

    if run("git", "branch", "--show-current") != "main":
        raise SystemExit("Abbruch: Releases nur von main.")

    version = toc_version("HEAD")
    tag = "v" + version
    notes = args[0] if args else f"HunterFlow {version}"

    if only_curseforge:
        # Genau der Stand des GitHub-Releases, nicht ein spaeterer Commit.
        if not run("git", "tag", "--list", tag):
            raise SystemExit(f"Abbruch: {tag} gibt es noch nicht. Erst ohne --nur-curseforge veroeffentlichen.")
        version = toc_version(tag)
        with tempfile.TemporaryDirectory() as temp:
            archive = Path(temp) / "HunterFlow.zip"
            build_archive(tag, archive)
            curseforge_upload(archive, version, notes)
        return

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

    with tempfile.TemporaryDirectory() as temp:
        archive = Path(temp) / "HunterFlow.zip"
        build_archive("HEAD", archive)

        run("git", "push", "origin", "main")
        url = run(
            "gh", "release", "create", tag, str(archive), str(UPDATE_SCRIPT),
            "--target", run("git", "rev-parse", "HEAD"),
            "--title", f"HunterFlow {version}",
            "--notes", notes,
        )
        print(f"Veroeffentlicht: {url}")
        curseforge_upload(archive, version, notes)


if __name__ == "__main__":
    main()
