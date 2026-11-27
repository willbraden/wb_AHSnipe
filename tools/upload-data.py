#!/usr/bin/env python3
"""Upload this machine's AH data to the wb_AHSnipe GitHub repo.

Used by both machines:
  - Steam Deck: the updater (install-steamdeck.sh) runs it after each update.
  - PC: the "Upload AH data" icon (upload-ah-data.bat) runs it.

  python upload-data.py --machine deck|pc --wow "<path to World of Warcraft/_forever_>"

It uploads whichever of these exist, to data/<machine>/ in one commit:
  wb_AHSnipe.lua                  Snipe's saved data (logs, buys, sells, dips)
  TradeSkillMaster.lua            TSM's saved data (sales history)      PC only
  TradeSkillMaster_AppHelper.lua  TSM app helper's saved data           PC only
  AppData.lua                     TSM desktop app's region prices        PC only
Files that haven't changed since the last upload are skipped, and nothing is
committed when none changed.

Needs a GitHub token in the token file: a fine-grained token for this repo
only, with Contents: Read and write.
  Linux / Deck: ~/.config/wb_AHSnipe/github-token
  Windows:      %APPDATA%\\wb_AHSnipe\\github-token
Exit WoW first: the game only writes its saved data when it closes.
"""
import argparse, base64, glob, hashlib, json, os, sys, time, urllib.error, urllib.request

REPO, BRANCH = "willbraden/wb_AHSnipe", "main"
API = "https://api.github.com"


def token_path():
    if os.name == "nt":
        return os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "wb_AHSnipe", "github-token")
    return os.path.expanduser("~/.config/wb_AHSnipe/github-token")


def find_files(wow):
    """name in the repo -> local path, for the files that exist."""
    out = {}
    svs = glob.glob(os.path.join(wow, "WTF", "Account", "*", "SavedVariables", "wb_AHSnipe.lua"))
    if svs:
        sv = max(svs, key=os.path.getmtime)  # the account you played last
        out["wb_AHSnipe.lua"] = sv
        folder = os.path.dirname(sv)
        for name in ("TradeSkillMaster.lua", "TradeSkillMaster_AppHelper.lua"):
            p = os.path.join(folder, name)
            if os.path.isfile(p):
                out[name] = p
    app = os.path.join(wow, "Interface", "AddOns", "TradeSkillMaster_AppHelper", "AppData.lua")
    if os.path.isfile(app):
        out["AppData.lua"] = app
    return out


def git_sha(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


class GitHub:
    def __init__(self, token):
        self.head = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "wb_AHSnipe-upload"}

    def call(self, method, path, body=None):
        req = urllib.request.Request(API + path, method=method, headers=self.head,
                                     data=json.dumps(body).encode() if body is not None else None)
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)


def upload(gh, machine, files, label):
    """One commit with every changed file. Returns the names uploaded."""
    ref = gh.call("GET", f"/repos/{REPO}/git/ref/heads/{BRANCH}")
    head = ref["object"]["sha"]
    base_tree = gh.call("GET", f"/repos/{REPO}/git/commits/{head}")["tree"]["sha"]
    # What's there now, to skip unchanged files.
    have = {}
    try:
        tree = gh.call("GET", f"/repos/{REPO}/git/trees/{base_tree}?recursive=1")
        have = {t["path"]: t["sha"] for t in tree.get("tree", []) if t["type"] == "blob"}
    except urllib.error.HTTPError:
        pass
    entries, changed = [], []
    for name, path in sorted(files.items()):
        data = open(path, "rb").read()
        dest = f"data/{machine}/{name}"
        if have.get(dest) == git_sha(data):
            continue
        blob = gh.call("POST", f"/repos/{REPO}/git/blobs",
                       {"content": base64.b64encode(data).decode(), "encoding": "base64"})
        entries.append({"path": dest, "mode": "100644", "type": "blob", "sha": blob["sha"]})
        changed.append(name)
    if not entries:
        return []
    tree = gh.call("POST", f"/repos/{REPO}/git/trees", {"base_tree": base_tree, "tree": entries})
    commit = gh.call("POST", f"/repos/{REPO}/git/commits",
                     {"message": f"{'PC' if machine == 'pc' else 'Deck'} data {label}", "tree": tree["sha"], "parents": [head]})
    gh.call("PATCH", f"/repos/{REPO}/git/refs/heads/{BRANCH}", {"sha": commit["sha"]})
    return changed


def main():
    ap = argparse.ArgumentParser(description="Upload this machine's AH data to GitHub.")
    ap.add_argument("--machine", required=True, choices=["deck", "pc"])
    ap.add_argument("--wow", required=True, help="the World of Warcraft/_forever_ folder")
    ap.add_argument("--token-file", default=token_path())
    a = ap.parse_args()

    if not os.path.isfile(a.token_file):
        print(f"Not uploaded: no GitHub token in {a.token_file}")
        return 2
    files = find_files(a.wow)
    if not files:
        print(f"Not uploaded: no saved data under {a.wow} (play once, then exit the game).")
        return 2
    gh = GitHub(open(a.token_file).read().strip())
    label = time.strftime("%Y-%m-%d %H:%M")
    for attempt in range(3):
        try:
            changed = upload(gh, a.machine, files, label)
            break
        except urllib.error.HTTPError as e:
            # 422 on the ref update: the other machine uploaded at the same moment. Try again on top.
            if e.code == 422 and attempt < 2:
                time.sleep(2)
                continue
            msg = e.read().decode(errors="replace")[:300]
            print(f"Upload failed: HTTP {e.code} {msg}")
            if e.code in (401, 403, 404):
                print("Check the token: this repo only, Contents: Read and write, not expired.")
            return 1
        except Exception as e:  # network down, etc.
            print(f"Upload failed: {e}")
            return 1
    if changed:
        print(f"Uploaded to data/{a.machine}/: {', '.join(changed)}")
    else:
        print("Nothing new to upload: the data on GitHub is already current.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
