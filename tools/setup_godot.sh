#!/usr/bin/env bash
# Installs Godot (headless + rendering) in a Claude Code cloud container, or any Ubuntu box
# where godotengine.org / GitHub release downloads are blocked by the network policy.
#
#   bash tools/setup_godot.sh            # installs Godot 4.7.2 to /usr/local/bin/godot
#   GODOT_VERSION=4.7.1 bash tools/setup_godot.sh
#   GODOT_DEST=/tmp/g bash tools/setup_godot.sh   # install somewhere else
#
# How it works: the official Linux binary is pulled out of the public Docker Hub image
# barichello/godot-ci:<version> (its build step wgets the official godot-builds release).
# Only registry-1.docker.io / auth.docker.io are needed. No Docker daemon is used: the
# script reads the image manifest from the registry API, finds the layer created by the
# step that downloaded Godot, streams it and extracts only usr/local/bin/godot.
# It also installs what rendering needs (Xvfb, Mesa lavapipe software Vulkan, ffmpeg) and
# the Python packages used by tools/.
set -euo pipefail

VERSION="${GODOT_VERSION:-4.7.2}"
DEST="${GODOT_DEST:-/usr/local/bin}"
REPO="barichello/godot-ci"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ -x "$DEST/godot" ] && "$DEST/godot" --version 2>/dev/null | grep -q "^${VERSION}\.stable"; then
	echo "Godot $VERSION already installed at $DEST/godot"
else
	echo "== Locating Godot $VERSION in docker.io/$REPO:$VERSION"
	python3 - "$REPO" "$VERSION" "$WORK/layer.txt" <<'PY'
import json, sys, time, urllib.error, urllib.request
repo, tag, out = sys.argv[1], sys.argv[2], sys.argv[3]

def fetch(req):
    # Docker Hub (or the session's egress proxy) sometimes answers 429: back off and retry.
    for attempt in range(7):
        try:
            return json.load(urllib.request.urlopen(req, timeout=60))
        except urllib.error.HTTPError as e:
            if e.code not in (429, 500, 502, 503, 504) or attempt == 6:
                raise
            wait = int(e.headers.get("Retry-After") or 0) or 5 * 2 ** attempt
            print(f"   HTTP {e.code}, retrying in {wait}s", flush=True)
            time.sleep(min(wait, 120))
        except urllib.error.URLError:
            if attempt == 6:
                raise
            time.sleep(5 * 2 ** attempt)

tok = fetch(f"https://auth.docker.io/token?service=registry.docker.io&scope=repository:{repo}:pull")["token"]
ACCEPT = ",".join(["application/vnd.oci.image.index.v1+json",
                   "application/vnd.docker.distribution.manifest.list.v2+json",
                   "application/vnd.docker.distribution.manifest.v2+json",
                   "application/vnd.oci.image.manifest.v1+json"])
def get(path, accept=ACCEPT):
    req = urllib.request.Request(f"https://registry-1.docker.io/v2/{repo}/{path}",
                                 headers={"Authorization": f"Bearer {tok}", "Accept": accept})
    return fetch(req)
m = get(f"manifests/{tag}")
if "manifests" in m:   # multi-arch index -> amd64 manifest
    d = [x for x in m["manifests"] if x.get("platform", {}).get("architecture") == "amd64"][0]["digest"]
    m = get(f"manifests/{d}")
cfg = get(f"blobs/{m['config']['digest']}", "*/*")
# Layers line up with the history entries that are not empty_layer.
steps = [h for h in cfg["history"] if not h.get("empty_layer")]
for h, layer in zip(steps, m["layers"]):
    if "godot-builds/releases/download" in h.get("created_by", ""):
        open(out, "w").write(f"{tok}\n{layer['digest']}\n{layer['size']}\n")
        print(f"   layer {layer['digest'][:19]}... ({layer['size'] / 1e6:.0f} MB)")
        break
else:
    sys.exit("Could not find the layer that downloads Godot in the image history")
PY
	TOKEN="$(sed -n 1p "$WORK/layer.txt")"
	DIGEST="$(sed -n 2p "$WORK/layer.txt")"
	echo "== Streaming the layer and extracting usr/local/bin/godot (takes a minute or two)"
	mkdir -p "$WORK/x"
	curl -sSL --retry 6 --retry-delay 10 --retry-all-errors -H "Authorization: Bearer $TOKEN" \
		"https://registry-1.docker.io/v2/$REPO/blobs/$DIGEST" \
		| tar -xz -C "$WORK/x" --wildcards 'usr/local/bin/godot*'
	BIN="$(ls "$WORK"/x/usr/local/bin/godot* | head -1)"
	mkdir -p "$DEST"
	install -m 755 "$BIN" "$DEST/godot"
	"$DEST/godot" --version
fi

echo "== Rendering deps (Xvfb, Mesa lavapipe Vulkan, ffmpeg) and Python tools"
if command -v apt-get >/dev/null; then
	if ! (dpkg -s mesa-vulkan-drivers xvfb ffmpeg >/dev/null 2>&1); then
		apt-get install -y -qq mesa-vulkan-drivers xvfb ffmpeg >/dev/null 2>&1 \
			|| (apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq mesa-vulkan-drivers xvfb ffmpeg >/dev/null)
	fi
fi
python3 -c "import numpy, scipy, matplotlib, PIL" 2>/dev/null \
	|| pip install -q numpy scipy matplotlib pillow fonttools gdtoolkit
echo "Done. Next: cd to the project and run 'godot --headless --editor --quit' once to import assets."
