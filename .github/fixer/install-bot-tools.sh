#!/bin/sh
# Installs dimhidden-bot's own GitHub tools on the fixer Droid Computer. The maintainer runs this once per computer:
#   droid computer ssh dimhidden-fixer -- sh -s < .github/fixer/install-bot-tools.sh
#
# Why: the computer's `gh` is a Factory wrapper that drops GH_TOKEN and signs in as the maintainer's work account,
# and its global and system git config send github.com through Factory's proxy with the work token. bot-gh and
# bot-git skip both and only ever use DIMHIDDEN_BOT_TOKEN.
set -eu
BOT_HOME="$HOME/.local/share/dimhidden-bot"
mkdir -p "$BOT_HOME/gh-config" "$HOME/.local/bin"
chmod 700 "$BOT_HOME"

load_token() {
  if [ -n "${DIMHIDDEN_BOT_TOKEN:-}" ]; then printf %s "$DIMHIDDEN_BOT_TOKEN"; return; fi
  [ -r /etc/droid/environment ] && (set -a; . /etc/droid/environment >/dev/null 2>&1; printf %s "${DIMHIDDEN_BOT_TOKEN:-}")
}

# Official gh release, verified against its published checksum.
if [ ! -x "$BOT_HOME/gh/bin/gh" ]; then
  token=$(load_token)
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo "unsupported arch" >&2; exit 1 ;; esac
  tag=$(curl -fsSL -H "Authorization: Bearer $token" https://api.github.com/repos/cli/cli/releases/latest |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')
  v=${tag#v}
  name="gh_${v}_linux_${arch}.tar.gz"
  cd "$BOT_HOME"
  curl -fsSLO "https://github.com/cli/cli/releases/download/$tag/$name"
  curl -fsSL "https://github.com/cli/cli/releases/download/$tag/gh_${v}_checksums.txt" | grep " $name\$" | sha256sum -c -
  tar xzf "$name" && rm -f "$name"
  rm -rf gh && mv "gh_${v}_linux_${arch}" gh
fi

cat > "$HOME/.local/bin/bot-gh" <<'SH'
#!/bin/sh
# GitHub CLI as dimhidden-bot. Bypasses the Factory gh wrapper, which swaps in the maintainer's work token.
set -eu
token="${DIMHIDDEN_BOT_TOKEN:-}"
if [ -z "$token" ] && [ -r /etc/droid/environment ]; then
  token=$(set -a; . /etc/droid/environment >/dev/null 2>&1; printf %s "${DIMHIDDEN_BOT_TOKEN:-}")
fi
[ -n "$token" ] || { echo "bot-gh: DIMHIDDEN_BOT_TOKEN is not available" >&2; exit 1; }
exec env -u GITHUB_TOKEN -u GH_HOST -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN \
  -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  GH_CONFIG_DIR="$HOME/.local/share/dimhidden-bot/gh-config" GH_TOKEN="$token" \
  GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
  "$HOME/.local/share/dimhidden-bot/gh/bin/gh" "$@"
SH

cat > "$HOME/.local/bin/bot-git" <<'SH'
#!/bin/sh
# git as dimhidden-bot. Skips the machine's global and system git config, which route github.com through
# Factory's proxy and rewrite URLs to carry the maintainer's work token.
exec env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  GIT_CONFIG_GLOBAL="$HOME/.local/share/dimhidden-bot/gitconfig" GIT_CONFIG_NOSYSTEM=1 git "$@"
SH

cat > "$BOT_HOME/gitconfig" <<CONF
[user]
	name = DimHidden Bot
	email = 357736521+dimhidden-bot@users.noreply.github.com
[credential "https://github.com"]
	helper =
	helper = !$HOME/.local/bin/bot-gh auth git-credential
[init]
	defaultBranch = main
CONF
chmod 700 "$HOME/.local/bin/bot-gh" "$HOME/.local/bin/bot-git"
chmod 600 "$BOT_HOME/gitconfig"

login=$("$HOME/.local/bin/bot-gh" api user --jq .login)
echo "bot-gh acts as: $login"
[ "$login" = dimhidden-bot ]

"$HOME/.local/bin/bot-gh" repo fork Jalohann/DimHidden --clone=false >/dev/null 2>&1 || true
if [ ! -d "$HOME/DimHidden/.git" ]; then
  "$HOME/.local/bin/bot-git" clone -q https://github.com/dimhidden-bot/DimHidden.git "$HOME/DimHidden"
  "$HOME/.local/bin/bot-git" -C "$HOME/DimHidden" remote add upstream https://github.com/Jalohann/DimHidden.git
fi
"$HOME/.local/bin/bot-git" -C "$HOME/DimHidden" fetch -q upstream
echo "ready: ~/DimHidden, author $("$HOME/.local/bin/bot-git" config user.name)"
