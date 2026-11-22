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
# The first run also:
#   - remembers your WoW folder (~/.config/wb_AHSnipe/wow_dir), so later runs
#     skip the search
#   - adds an "Update AH Snipe" icon to your desktop and app menu. Double-click
#     it to update. Right-click it > Add to Steam to update from Game Mode.
#
# If it can't find WoW, pass the _forever_ folder yourself:
#   bash install-steamdeck.sh "/path/to/World of Warcraft/_forever_"
# or set WOW_DIR to it.

set -euo pipefail

REPO="willbraden/wb_AHSnipe"
BRANCH="main"
NAME="wb_AHSnipe"
FLAVOR="_forever_"

CONF_DIR="$HOME/.config/wb_AHSnipe"
mkdir -p "$CONF_DIR"
# Keep a copy of this run's output (handy when it runs from Game Mode, where
# there's no window): ~/.config/wb_AHSnipe/last-update.log
exec > >(tee "$CONF_DIR/last-update.log") 2>&1
echo "wb_AHSnipe update: $(date '+%Y-%m-%d %H:%M:%S')"

bold=$'\e[1m'; green=$'\e[32m'; yellow=$'\e[33m'; red=$'\e[31m'; rst=$'\e[0m'
info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "${green}✔${rst} $*"; }
warn() { printf '%s\n' "${yellow}!${rst} $*"; }
die()  { printf '%s\n' "${red}✘ $*${rst}" >&2; exit 1; }

# --- Find the WoW Forever folder --------------------------------------------
# Looks for any folder named _forever_ that looks like a WoW install, under
# your home folder (Steam, Proton prefixes, Heroic, Lutris, Bottles…) and any
# SD card or extra drive.
looks_like_wow() {
  local d="$1"
  [[ -d "$d/Interface" || -d "$d/WTF" || -d "$d/Data" ]] && return 0
  compgen -G "$d/*.exe" >/dev/null && return 0
  return 1
}

find_wow() {
  local roots=("$HOME" /run/media /media /mnt)
  local r d
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    while IFS= read -r d; do
      looks_like_wow "$d" && echo "$d"
    done < <(find -L "$r" -maxdepth 16 \
               \( -name dosdevices -o -name .cache -o -name Trash -o -name proc -o -name sys \) -prune \
               -o -type d -name "$FLAVOR" -print 2>/dev/null)
  done | awk '!seen[$0]++'
}

SAVED="$CONF_DIR/wow_dir"

WOW="${1:-${WOW_DIR:-}}"
if [[ -z "$WOW" && -f "$SAVED" ]]; then
  WOW="$(cat "$SAVED")"
  [[ -d "$WOW" ]] || { warn "Saved WoW folder is gone, searching again."; WOW=""; }
fi
if [[ -z "$WOW" ]]; then
  info "Looking for your WoW Forever folder ($FLAVOR), this can take a minute…"
  mapfile -t found < <(find_wow)
  case "${#found[@]}" in
    0) die "Couldn't find a $FLAVOR folder. Launch WoW Forever once, or pass the path: bash $0 \"/path/to/World of Warcraft/$FLAVOR\"" ;;
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
mkdir -p "$CONF_DIR"
printf '%s\n' "$WOW" > "$SAVED"

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
# The addon shows this in its chat tab at login, so you can confirm the update.
STAMP="$(date '+%Y-%m-%d %H:%M')"
printf -- '-- Written by the installer.\nwb_AHSnipe_Build = "%s"\n' "$STAMP" > "$dest/Build.lua"

ver="$(grep -m1 '^## Version:' "$dest/$NAME.toc" | cut -d: -f2- | xargs || true)"
ok "Installed $NAME${ver:+ $ver} ($STAMP) to:"
info "$dest"
echo
info "${bold}Fully restart WoW${rst} (not just /reload) so it picks up new files."
info "Your max prices and settings are kept."
info "In game, the AH Snipe chat tab will say: Installed: $STAMP"

# --- One-click updater icon ------------------------------------------------
# A small launcher that always pulls the newest installer. From Desktop Mode it
# opens Konsole so you can watch; from Game Mode it runs quietly (Game Mode
# can't show a terminal). Either way the result is in last-update.log, and the
# addon shows the install time in its chat tab.
BIN="$HOME/.local/bin/wb-ahsnipe-update"
mkdir -p "$(dirname "$BIN")"
cat > "$BIN" <<LAUNCHER
#!/usr/bin/env bash
URL="https://raw.githubusercontent.com/$REPO/$BRANCH/tools/install-steamdeck.sh"
if [[ "\${1:-}" != "--here" && "\${XDG_CURRENT_DESKTOP:-}" != *gamescope* ]] && command -v konsole >/dev/null; then
  konsole -e bash -c "'\$0' --here; echo; read -rp 'Press Enter to close.'" && exit 0
fi
curl -fsSL "\$URL" -o /tmp/wb-ahsnipe-install.sh && bash /tmp/wb-ahsnipe-install.sh </dev/null
LAUNCHER
chmod +x "$BIN"

APP="$HOME/.local/share/applications/wb-ahsnipe-update.desktop"
first=0; [[ -f "$APP" ]] || first=1
mkdir -p "$(dirname "$APP")"
cat > "$APP" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Update AH Snipe
Comment=Download and install the latest wb_AHSnipe for WoW Forever
Exec=$BIN
Icon=system-software-update
Terminal=false
Categories=Game;
DESKTOP
chmod +x "$APP"
if [[ -d "$HOME/Desktop" ]]; then
  cp "$APP" "$HOME/Desktop/"
  chmod +x "$HOME/Desktop/wb-ahsnipe-update.desktop"
  command -v gio >/dev/null && gio set "$HOME/Desktop/wb-ahsnipe-update.desktop" metadata::trusted true 2>/dev/null || true
fi
if [[ $first == 1 ]]; then
  echo
  ok "Added an ${bold}Update AH Snipe${rst} icon to your desktop and app menu."
  info "Next time, just double-click it. To update from Game Mode: right-click it > Add to Steam."
fi
