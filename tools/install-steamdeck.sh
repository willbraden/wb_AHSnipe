#!/usr/bin/env bash
# Install or update wb_AHSnipe in WoW Forever on a Steam Deck (or any Linux
# setup running Battle.net under Proton/Wine).
#
# Run from Desktop Mode (Konsole):
#   curl -fsSL https://raw.githubusercontent.com/willbraden/wb_AHSnipe/main/tools/install-steamdeck.sh | bash
#
# Run it again any time to update. Your settings and max prices live in WTF/,
# so they are kept.
#
# If it can't find WoW, pass the _forever_ folder yourself:
#   bash install-steamdeck.sh "/path/to/World of Warcraft/_forever_"
# or set WOW_DIR to it.

set -euo pipefail

REPO="willbraden/wb_AHSnipe"
BRANCH="main"
NAME="wb_AHSnipe"
FLAVOR="_forever_"

bold=$'\e[1m'; green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'; rst=$'\e[0m'
info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "${green}✔${rst} $*"; }
warn() { printf '%s\n' "${yellow}!${rst} $*"; }
die()  { printf '%s\n' "${red}✘ $*${rst}" >&2; exit 1; }

# --- Find the WoW Forever folder --------------------------------------------
find_wow() {
  local roots=(
    "$HOME/.steam/steam/steamapps/compatdata"
    "$HOME/.local/share/Steam/steamapps/compatdata"
    "$HOME/.steam"
    "$HOME/.local/share/Steam"
    /run/media/*/steamapps/compatdata        # SD card
    /run/media/*/*/steamapps/compatdata
    "$HOME/Games"                            # Heroic / Lutris
    "$HOME/.var/app/com.heroicgameslauncher.hgl"
    "$HOME/.var/app/net.lutris.Lutris"
  )
  local r
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    find "$r" -maxdepth 12 -type d -path "*/World of Warcraft/$FLAVOR" 2>/dev/null
  done | awk '!seen[$0]++'
}

WOW="${1:-${WOW_DIR:-}}"
if [[ -z "$WOW" ]]; then
  info "Looking for World of Warcraft/$FLAVOR…"
  mapfile -t found < <(find_wow)
  case "${#found[@]}" in
    0) die "Couldn't find a 'World of Warcraft/$FLAVOR' folder. Launch WoW Forever once, or pass the path: bash $0 \"/path/to/World of Warcraft/$FLAVOR\"" ;;
    1) WOW="${found[0]}" ;;
    *)
      warn "Found more than one install:"
      for i in "${!found[@]}"; do info "[$((i + 1))] ${found[$i]}"; done
      if [[ -t 0 ]]; then
        read -rp "  Which one? [1] " pick
        pick="${pick:-1}"
      else
        pick=1
        warn "Using [1]. To pick another, run with the path as the first argument."
      fi
      WOW="${found[$((pick - 1))]}"
      ;;
  esac
fi
[[ -d "$WOW" ]] || die "Not a folder: $WOW"
ADDONS="$WOW/Interface/AddOns"
mkdir -p "$ADDONS"
ok "WoW Forever: $WOW"

# --- Download the latest version --------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz"
info "Downloading $REPO ($BRANCH)…"
if command -v curl >/dev/null; then
  curl -fsSL "$url" -o "$tmp/src.tar.gz" || die "Download failed: $url"
elif command -v wget >/dev/null; then
  wget -qO "$tmp/src.tar.gz" "$url" || die "Download failed: $url"
else
  die "Need curl or wget."
fi
tar -xzf "$tmp/src.tar.gz" -C "$tmp"
src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
[[ -f "$src/$NAME.toc" ]] || die "Download doesn't look like $NAME (no $NAME.toc)."

# --- Install ----------------------------------------------------------------
dest="$ADDONS/$NAME"
if [[ -d "$dest" ]]; then
  backup="$tmp/previous-$NAME"
  mv "$dest" "$backup"
  info "Replacing the installed version."
fi
mkdir -p "$dest"
# Only what the game needs: Lua/TOC/XML, the spacer texture, and the font.
cp "$src/$NAME.toc" "$src"/*.lua "$src"/*.xml "$dest"/
[[ -f "$src/spacer.tga" ]] && cp "$src/spacer.tga" "$dest"/
[[ -d "$src/fonts" ]] && cp -r "$src/fonts" "$dest"/

ver="$(grep -m1 '^## Version:' "$dest/$NAME.toc" | cut -d: -f2- | xargs || true)"
ok "Installed $NAME${ver:+ $ver} to:"
info "$dest"
echo
info "${bold}Fully restart WoW${rst} (not just /reload) so it picks up new files."
info "Your max prices and settings are kept."
