"""Makes each GitHub release's text match release-notes/vX.Y.Z.md.

Run by .github/workflows/release-notes.yml whenever a notes file changes on main. A release
body is the notes, then the download link, install steps and checksum that
Scripts/publish-release.sh adds, starting at the "### Download" heading. Only the part above
that heading is replaced; the rest is kept as it is. (So don't use a "### Download" heading in
the notes themselves.)
"""

import json
import os
import pathlib
import re
import urllib.error
import urllib.request

REPO = os.environ["GITHUB_REPOSITORY"]
TOKEN = os.environ["GH_TOKEN"]
API = f"https://api.github.com/repos/{REPO}"
FOOTER = re.compile(r"^### Download\s*$", re.M)


def call(method, url, data=None):
    req = urllib.request.Request(
        url,
        method=method,
        data=None if data is None else json.dumps(data).encode(),
        headers={
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)


for path in sorted(pathlib.Path("release-notes").glob("v*.md")):
    tag = path.stem
    try:
        release = call("GET", f"{API}/releases/tags/{tag}")
    except urllib.error.HTTPError as err:
        if err.code == 404:
            print(f"{tag}: no published release yet, skipped")
            continue
        raise
    body = (release.get("body") or "").replace("\r\n", "\n")
    match = FOOTER.search(body)
    footer = body[match.start():] if match else ""
    notes = path.read_text().strip()
    new_body = f"{notes}\n\n{footer}" if footer else f"{notes}\n"
    if new_body.strip() == body.strip():
        print(f"{tag}: already up to date")
        continue
    # Body only: leaving out make_latest keeps whichever release is Latest as it is.
    call("PATCH", f"{API}/releases/{release['id']}", {"body": new_body})
    print(f"{tag}: release page updated")
