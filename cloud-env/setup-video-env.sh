#!/usr/bin/env bash
# Video-editing environment for Claude Code cloud sessions (Ubuntu 24.04, CPU only).
#
# Installs, only when missing:
#   - FFmpeg + FFprobe (libx264/x265, libass, fribidi/harfbuzz for Arabic subtitles)
#   - Arabic Noto fonts (Noto Sans / Naskh / Kufi Arabic)
#   - yt-dlp
#   - faster-whisper + whisper-ctranslate2 CLI, and the large-v3 model (~3 GB)
#   - HyperFrames CLI (pinned to the tested version) and its AI skills
#   - Noto Sans Arabic SemiBold/Bold/ExtraBold/Black (caption weights)
#   - 3D toolkit: Blender 5.2.3 as a Python module (Cycles), scikit-image, OpenCV
#     in /opt/video-env/blender, run with `blender-python`
#   - Proxy settings for Node and Chrome so renders can reach the network
#
# Safe to run any number of times. One failing step does not stop the others,
# and the script always exits 0 so a slow download never blocks the session.
#
# Paste this whole file into: environment settings -> Edit -> Setup script.
# Skip the 3 GB model download by changing WHISPER_MODEL below to "" (empty).

set -uo pipefail

HYPERFRAMES_VERSION="0.9.8"
FASTER_WHISPER_VERSION="1.2.1"
WHISPER_CT2_VERSION="0.5.8"
WHISPER_MODEL="large-v3"
CA_BUNDLE="/root/.ccr/ca-bundle.crt"
PROFILE_FILE="/etc/profile.d/video-env.sh"

log() { printf '[video-env] %s\n' "$*"; }
warn() { printf '[video-env] WARNING: %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0

apt_install() {
	local missing=()
	for pkg in "$@"; do
		dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
	done
	if [ ${#missing[@]} -eq 0 ]; then
		log "apt packages already present: $*"
		return 0
	fi
	if [ "$APT_UPDATED" -eq 0 ]; then
		$SUDO apt-get update -q >/dev/null 2>&1 || warn "apt-get update failed"
		APT_UPDATED=1
	fi
	log "installing apt packages: ${missing[*]}"
	$SUDO apt-get install -y -q --no-install-recommends "${missing[@]}" >/dev/null
}

# 1. FFmpeg / FFprobe, fonts, NSS tools (for Chrome certificates), espeak-ng (offline TTS used only for test clips)
apt_install ffmpeg fonts-noto-core fontconfig libnss3-tools espeak-ng || warn "apt install step failed"
fc-list :lang=ar family 2>/dev/null | grep -qi "Noto Sans Arabic" || $SUDO fc-cache -f >/dev/null 2>&1

# 2. Python tools: yt-dlp, faster-whisper, whisper-ctranslate2
PIP="python3 -m pip"
PIP_FLAGS="-q --disable-pip-version-check"
$PIP --version >/dev/null 2>&1 || apt_install python3-pip
# Debian/Ubuntu system Python refuses global installs without this flag.
$PIP install --help 2>/dev/null | grep -q -- "--break-system-packages" &&
	python3 -c 'import sys; sys.exit(0 if sys.prefix == "/usr" else 1)' &&
	PIP_FLAGS="$PIP_FLAGS --break-system-packages"
[ "$(id -u)" -eq 0 ] && PIP_FLAGS="$PIP_FLAGS --root-user-action=ignore"

if have yt-dlp; then
	log "yt-dlp already installed ($(yt-dlp --version))"
else
	log "installing yt-dlp"
	$PIP install $PIP_FLAGS yt-dlp || warn "yt-dlp install failed"
fi

if python3 -c 'import faster_whisper' 2>/dev/null && have whisper-ctranslate2; then
	log "faster-whisper already installed"
else
	log "installing faster-whisper $FASTER_WHISPER_VERSION + whisper-ctranslate2 $WHISPER_CT2_VERSION"
	$PIP install $PIP_FLAGS "faster-whisper==$FASTER_WHISPER_VERSION" "whisper-ctranslate2==$WHISPER_CT2_VERSION" ||
		warn "whisper install failed"
fi

# 3. Whisper model (cached in ~/.cache/huggingface; only downloaded when absent)
if [ -n "$WHISPER_MODEL" ] && python3 -c 'import faster_whisper' 2>/dev/null; then
	log "ensuring Whisper model $WHISPER_MODEL is cached"
	python3 - "$WHISPER_MODEL" <<'PY' || warn "Whisper model download failed; it will download on first use"
import sys
from faster_whisper.utils import download_model
name = sys.argv[1]
try:
    path = download_model(name, local_files_only=True)
    print(f"[video-env] model {name} already cached at {path}")
except Exception:
    print(f"[video-env] downloading model {name} (about 3 GB)...")
    path = download_model(name)
    print(f"[video-env] model {name} cached at {path}")
PY
fi

# 4. HyperFrames CLI (pinned; reinstalled only if missing or a different version)
if ! have npm; then
	warn "npm not found; skipping HyperFrames"
elif have hyperframes && [ "$(hyperframes --version 2>/dev/null)" = "$HYPERFRAMES_VERSION" ]; then
	log "HyperFrames $HYPERFRAMES_VERSION already installed"
else
	log "installing HyperFrames $HYPERFRAMES_VERSION"
	$SUDO npm install -g --no-fund --no-audit "hyperframes@$HYPERFRAMES_VERSION" >/dev/null || warn "HyperFrames install failed"
fi

# 4b. HyperFrames AI skills (into ~/.claude/skills and ~/.agents/skills)
if ! have hyperframes; then
	warn "HyperFrames missing; skipping its skills"
elif [ -f "$HOME/.claude/skills/hyperframes/SKILL.md" ]; then
	log "HyperFrames skills already installed"
else
	log "installing HyperFrames skills"
	(cd "$HOME" && NODE_USE_ENV_PROXY=1 hyperframes skills >/dev/null 2>&1) || warn "HyperFrames skills install failed"
fi

# 4c. Extra Noto Sans Arabic weights used by the Reel captions (SemiBold .. Black)
FONT_DIR="/usr/local/share/fonts/noto-arabic-weights"
NOTO_URL="https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts/NotoSansArabic/hinted/ttf"
$SUDO mkdir -p "$FONT_DIR"
fonts_added=0
for w in SemiBold Bold ExtraBold Black; do
	f="$FONT_DIR/NotoSansArabic-$w.ttf"
	if [ -s "$f" ]; then continue; fi
	log "downloading Noto Sans Arabic $w"
	if $SUDO curl -sSfL -m 120 -o "$f" "$NOTO_URL/NotoSansArabic-$w.ttf"; then
		fonts_added=1
	else
		$SUDO rm -f "$f"; warn "could not download Noto Sans Arabic $w"
	fi
done
[ "$fonts_added" -eq 1 ] && $SUDO fc-cache -f >/dev/null 2>&1
[ "$fonts_added" -eq 0 ] && log "Noto Sans Arabic weights already present"

# 4d. 3D toolkit: Blender as a Python module (Cycles renderer) + scikit-image + OpenCV,
#     in an isolated environment. Run scripts with: blender-python script.py
BLENDER_VENV="/opt/video-env/blender"
BPY_VERSION="5.2.3"
if [ -x "$BLENDER_VENV/bin/python" ] && "$BLENDER_VENV/bin/python" -c "import bpy, skimage, cv2" >/dev/null 2>&1; then
	log "Blender $BPY_VERSION toolkit already installed"
else
	log "installing Blender $BPY_VERSION toolkit (about 1 minute)"
	PY313="$(command -v python3.13 || echo /usr/local/bin/python3.13)"
	$SUDO mkdir -p "$(dirname "$BLENDER_VENV")"
	if have uv || [ -x "$HOME/.local/bin/uv" ]; then
		UV="$(command -v uv || echo "$HOME/.local/bin/uv")"
		$SUDO "$UV" venv -q --python "$PY313" "$BLENDER_VENV" &&
			$SUDO "$UV" pip install -q --python "$BLENDER_VENV/bin/python" "bpy==$BPY_VERSION" scikit-image opencv-python-headless ||
			warn "Blender toolkit install failed"
	else
		$SUDO "$PY313" -m venv "$BLENDER_VENV" &&
			$SUDO "$BLENDER_VENV/bin/pip" install -q "bpy==$BPY_VERSION" scikit-image opencv-python-headless ||
			warn "Blender toolkit install failed"
	fi
fi
$SUDO tee /usr/local/bin/blender-python >/dev/null <<EOF
#!/usr/bin/env bash
exec "$BLENDER_VENV/bin/python" "\$@"
EOF
$SUDO chmod +x /usr/local/bin/blender-python

# 5. Proxy configuration for every new shell.
#    The proxy address itself is injected by the platform each session; never hard-code it.
#    Node's built-in fetch ignores HTTPS_PROXY unless NODE_USE_ENV_PROXY=1 (Node >= 22.21).
log "writing $PROFILE_FILE"
$SUDO tee "$PROFILE_FILE" >/dev/null <<'EOF'
# Added by cloud-env/setup-video-env.sh
export NODE_USE_ENV_PROXY=1
if [ -z "${NODE_EXTRA_CA_CERTS:-}" ] && [ -f /root/.ccr/ca-bundle.crt ]; then
	export NODE_EXTRA_CA_CERTS=/root/.ccr/ca-bundle.crt
fi
# Keep Chrome's certificate store in sync with the proxy CA (cheap when unchanged).
[ -x /usr/local/bin/video-env-chrome-ca ] && /usr/local/bin/video-env-chrome-ca >/dev/null 2>&1
EOF
for rc in /root/.bashrc /etc/bash.bashrc; do
	[ -f "$rc" ] && ! grep -q "$PROFILE_FILE" "$rc" &&
		printf '\n[ -f %s ] && . %s\n' "$PROFILE_FILE" "$PROFILE_FILE" | $SUDO tee -a "$rc" >/dev/null
done

# 6. Chrome (HyperFrames/Remotion renders) trusts the proxy CA, so web fonts load
#    without --ignore-certificate-errors. Re-imports only when the bundle changes.
$SUDO tee /usr/local/bin/video-env-chrome-ca >/dev/null <<'EOF'
#!/usr/bin/env bash
BUNDLE=/root/.ccr/ca-bundle.crt
DB="$HOME/.pki/nssdb"
STAMP="$DB/.video-env-ca.sha256"
[ -f "$BUNDLE" ] && command -v certutil >/dev/null || exit 0
SUM=$(sha256sum "$BUNDLE" | cut -d' ' -f1)
[ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SUM" ] && exit 0
mkdir -p "$DB"
certutil -d "sql:$DB" -L >/dev/null 2>&1 || certutil -d "sql:$DB" -N --empty-password
TMP=$(mktemp -d)
awk -v d="$TMP" '/BEGIN CERT/{n++} n{print > (d "/c-" n ".pem")}' "$BUNDLE"
for f in "$TMP"/c-*.pem; do
	certutil -d "sql:$DB" -A -t "C,," -n "ccr-proxy-$(basename "$f" .pem)" -i "$f" 2>/dev/null
done
rm -rf "$TMP"
echo "$SUM" > "$STAMP"
EOF
$SUDO chmod +x /usr/local/bin/video-env-chrome-ca
/usr/local/bin/video-env-chrome-ca || warn "could not import proxy CA into Chrome's store"

# 7. Status helper: run `video-env-check` at any time.
$SUDO tee /usr/local/bin/video-env-check >/dev/null <<'EOF'
#!/usr/bin/env bash
ok() { printf '%-12s Ready      %s\n' "$1:" "$2"; }
bad() { printf '%-12s Not Ready  %s\n' "$1:" "$2"; }
v=$(ffmpeg -version 2>/dev/null | head -1 | awk '{print $3}') && [ -n "$v" ] && ok FFmpeg "$v" || bad FFmpeg ""
v=$(ffprobe -version 2>/dev/null | head -1 | awk '{print $3}') && [ -n "$v" ] && ok FFprobe "$v" || bad FFprobe ""
v=$(python3 -c 'import faster_whisper; print(faster_whisper.__version__)' 2>/dev/null) && command -v whisper-ctranslate2 >/dev/null &&
	ok Whisper "faster-whisper $v, model large-v3 $(python3 -c 'from faster_whisper.utils import download_model as d; d("large-v3", local_files_only=True); print("cached")' 2>/dev/null || echo 'NOT cached')" ||
	bad Whisper ""
v=$(yt-dlp --version 2>/dev/null) && ok yt-dlp "$v" || bad yt-dlp ""
v=$(hyperframes --version 2>/dev/null) && ok Hyperframes "$v" || bad Hyperframes ""
fc-list :lang=ar family 2>/dev/null | grep -qi "Noto Sans Arabic" && ok "Arabic font" "Noto Sans/Naskh/Kufi Arabic" || bad "Arabic font" ""
n=$(ls /usr/local/share/fonts/noto-arabic-weights/NotoSansArabic-*.ttf 2>/dev/null | wc -l)
[ "$n" -eq 4 ] && ok "Font weights" "Noto Sans Arabic SemiBold/Bold/ExtraBold/Black" || bad "Font weights" "$n of 4"
[ -f "$HOME/.claude/skills/hyperframes/SKILL.md" ] && ok "HF skills" "$(ls "$HOME/.claude/skills" | grep -c .) skills" || bad "HF skills" ""
v=$(blender-python -c 'import bpy, skimage, cv2; print("Blender", bpy.app.version_string, "| OpenCV", cv2.__version__, "| scikit-image", skimage.__version__)' 2>/dev/null) && ok Blender3D "$v" || bad Blender3D ""
EOF
$SUDO chmod +x /usr/local/bin/video-env-check

log "done"
/usr/local/bin/video-env-check
exit 0
