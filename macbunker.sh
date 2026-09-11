#!/bin/bash
# macbunker — snapshot and restore a Mac: dotfiles, ~/.claude, app lists, macOS defaults, git repos.
# https://github.com/bytebunkerlabs/macbunker
#
# Runs on stock macOS only (bash 3.2, bsdtar, LibreSSL, launchd). Restore needs nothing installed.
# Snapshots are built locally in ~/.macbunker/snapshots and then published to
# <root>/snapshots/<timestamp>/ (root defaults to iCloud Drive/mac-backups). They are encrypted
# (AES-256-CBC, PBKDF2) with a passphrase kept in the login keychain.
#
#   macbunker init [--root DIR] [--generate]   install the toolkit (default: iCloud Drive/mac-backups), set up passphrase + schedule
#   macbunker backup                      take a snapshot now (and publish pending ones)
#   macbunker publish                     push snapshots that are still only local into the root
#   macbunker restore [options]           restore onto this Mac (see --help)
#   macbunker verify [SNAPSHOT]           decrypt + checksum a snapshot without touching anything
#   macbunker list | status               what exists, how old, is the schedule running
#   macbunker schedule | unschedule       daily launchd job (runs via ~/Applications/macbunker.app)
#   macbunker set-passphrase [--generate] store the passphrase in the login keychain
#   macbunker show-passphrase             print it so you can save it in a password manager
#
set -eu
set -o pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/Applications/Visual Studio Code.app/Contents/Resources/app/bin:/usr/bin:/bin:/usr/sbin:/sbin"

VERSION="1.2.1"
SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in /*) ;; *) SCRIPT_PATH="$PWD/$SCRIPT_PATH" ;; esac
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs"

# Always-readable local mirror of the toolkit + staging area for snapshots (launchd jobs cannot
# read iCloud Drive until macOS has been told to allow it, so nothing critical may depend on it).
LOCAL="$HOME/.macbunker"
LOCAL_SNAPS="$LOCAL/snapshots"
LOGDIR="$LOCAL/logs"
LAUNCHER="$HOME/.local/bin/macbunker"
APP="$HOME/Applications/macbunker.app"
KEYCHAIN_SERVICE="macbunker"
LABEL="ai.bytebunkerlabs.macbunker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# Unattended runs: record the moment the script starts, before any protected file is touched,
# so a run that stalls on a permission dialog can be told apart from one that started late.
if [ "${1:-}" = backup ] && [ ! -t 1 ]; then
  printf '%s [macbunker] launcher start (pid %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$"
fi

# Root = where the installed toolkit and the snapshots live.
#   MACBUNKER_ROOT env > a snapshot's toolkit/ copy > the folder this script is installed in > iCloud default
if [ -n "${MACBUNKER_ROOT:-}" ]; then
  ROOT="$MACBUNKER_ROOT"
elif [ "$(basename "$SCRIPT_DIR")" = "toolkit" ] && [ -d "$SCRIPT_DIR/../../../snapshots" ]; then
  ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
elif [ -d "$SCRIPT_DIR/snapshots" ] && [ -f "$SCRIPT_DIR/include.txt" ]; then
  ROOT="$SCRIPT_DIR"
else
  ROOT="$ICLOUD/mac-backups"
fi
SNAPDIR="$ROOT/snapshots"

readable() { cat "$1" >/dev/null 2>&1; }   # TCC denies open(), not stat(); so really try to read

# Config files: installed copy > local mirror > the defaults shipped next to this script (a git checkout).
pick_file() {
  local d
  for d in "$ROOT" "$LOCAL" "$SCRIPT_DIR"; do
    if readable "$d/$1"; then printf '%s' "$d/$1"; return 0; fi
  done
  printf '%s' "$ROOT/$1"
}
CONF="$(pick_file macbunker.conf)"
INCLUDE_FILE="$(pick_file include.txt)"
EXCLUDE_FILE="$(pick_file exclude.txt)"
DEFAULTS_FILE="$(pick_file defaults-restore.txt)"

# Defaults; override in macbunker.conf
MACBUNKER_RETENTION=14
MACBUNKER_EXTRA_DESTS=""
MACBUNKER_REPO_ROOTS="$HOME/Documents:$HOME/Projects:$HOME/dev:$HOME/Desktop"
MACBUNKER_REPO_DEPTH=4
MACBUNKER_REPO_SKIP=""
MACBUNKER_MAX_BUNDLE_MB=1024
MACBUNKER_MAX_PATCH_MB=200
MACBUNKER_REPO_OWNERS=""
MACBUNKER_SCHEDULE_HOUR=13
MACBUNKER_SCHEDULE_MINUTE=30
MACBUNKER_PBKDF2_ITER=200000
# shellcheck disable=SC1090
readable "$CONF" && . "$CONF"

LOGFILE=""
DRY=0
PASS=""
CLEANUP_DIR=""

# ── helpers ──────────────────────────────────────────────────────────────────
log()  { printf '%s [macbunker] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${LOGFILE:-/dev/null}"; }
warn() { printf '%s [macbunker] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "${LOGFILE:-/dev/null}" >&2; }
die()  { warn "$*"; exit 1; }
run()  { if [ "$DRY" = 1 ]; then log "[dry-run] $*"; else "$@"; fi; }
hsize() { du -sh "$1" 2>/dev/null | cut -f1; }
uid()  { id -u; }

root_readable() { readable "$ROOT/include.txt"; }
root_writable() {
  local probe="$SNAPDIR/.probe.$$"
  mkdir -p "$SNAPDIR" 2>/dev/null || return 1
  ( : > "$probe" ) 2>/dev/null || return 1
  rm -f "$probe" 2>/dev/null
  return 0
}

get_passphrase() {
  if [ -n "${MACBUNKER_PASSPHRASE:-}" ]; then printf '%s' "$MACBUNKER_PASSPHRASE"; return 0; fi
  local p
  if p="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)" && [ -n "$p" ]; then
    printf '%s' "$p"; return 0
  fi
  if [ -t 0 ]; then
    read -r -s -p "macbunker passphrase: " p </dev/tty; echo >&2
    [ -n "$p" ] || die "empty passphrase"
    printf '%s' "$p"; return 0
  fi
  die "no passphrase available: run 'macbunker set-passphrase' (or set MACBUNKER_PASSPHRASE)"
}

encrypt_file() { # plain enc
  openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter "$MACBUNKER_PBKDF2_ITER" -salt \
    -pass fd:3 -in "$1" -out "$2" 3<<<"$PASS"
}
decrypt_file() { # enc plain
  openssl enc -d -aes-256-cbc -md sha256 -pbkdf2 -iter "$MACBUNKER_PBKDF2_ITER" \
    -pass fd:3 -in "$1" -out "$2" 3<<<"$PASS"
}
seal() { # plain enc shafile  (writes checksum of plaintext, encrypts, deletes plaintext)
  (cd "$(dirname "$1")" && shasum -a 256 "$(basename "$1")") > "$3"
  encrypt_file "$1" "$2"
  rm -f "$1"
}
unseal() { # enc shafile plain
  decrypt_file "$1" "$3" 2>/dev/null || die "decrypt failed for $(basename "$1") — wrong passphrase?"
  local expect actual
  expect="$(cut -d' ' -f1 "$2")"
  actual="$(shasum -a 256 "$3" | cut -d' ' -f1)"
  [ "$expect" = "$actual" ] || die "checksum mismatch for $(basename "$1") — snapshot is damaged or not fully synced"
  log "decrypted and verified $(basename "$1") ($(hsize "$3"))"
}

# Make sure iCloud has actually downloaded everything under a directory (evicted files show as .name.icloud).
ensure_downloaded() {
  local dir="$1" tries=0 n ph logical
  case "$dir" in "$ICLOUD"*) ;; *) return 0 ;; esac
  command -v brctl >/dev/null 2>&1 || return 0
  while :; do
    n="$(find "$dir" -name '.*.icloud' 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -eq 0 ] && return 0
    find "$dir" -name '.*.icloud' 2>/dev/null | while IFS= read -r ph; do
      logical="$(dirname "$ph")/$(basename "$ph" .icloud | sed 's/^\.//')"
      brctl download "$logical" >/dev/null 2>&1 || true
    done
    tries=$((tries + 1))
    [ "$tries" -gt 120 ] && die "iCloud still has $n undownloaded file(s) under $dir after 10 minutes"
    [ $((tries % 6)) -eq 1 ] && log "waiting for iCloud to download $n file(s) under $(basename "$dir") ..."
    sleep 5
  done
}

latest_snapshot() { ls -1 "$SNAPDIR" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort | tail -n 1; }

# Copy the toolkit into the always-readable local mirror and ~/.local/bin (only when the installed copy is readable).
mirror_toolkit() {
  root_readable || return 0
  mkdir -p "$LOCAL" "$(dirname "$LAUNCHER")"
  local f
  for f in macbunker.sh macbunker.conf include.txt exclude.txt defaults-restore.txt README.md; do
    [ -f "$ROOT/$f" ] && cp "$ROOT/$f" "$LOCAL/$f" 2>/dev/null || true
  done
  chmod +x "$LOCAL/macbunker.sh" 2>/dev/null || true
  cp "$ROOT/macbunker.sh" "$LAUNCHER" && chmod +x "$LAUNCHER"
}

# Move finished local snapshots into the root (atomic per snapshot: copy to a temp name, then rename).
publish_pending() {
  local s tmp
  [ -d "$LOCAL_SNAPS" ] || return 0
  ls -1 "$LOCAL_SNAPS" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort | while IFS= read -r s; do
    [ -f "$LOCAL_SNAPS/$s/.complete" ] || continue
    if [ -d "$SNAPDIR/$s" ]; then rm -rf "$LOCAL_SNAPS/$s"; continue; fi
    if ! root_writable; then
      warn "$ROOT is not writable from this process; snapshot $s stays in $LOCAL_SNAPS until 'macbunker publish' runs from Terminal"
      return 0
    fi
    tmp="$SNAPDIR/.incoming-$s"
    rm -rf "$tmp"
    if cp -R "$LOCAL_SNAPS/$s" "$tmp" 2>>"${LOGFILE:-/dev/null}" \
       && [ "$(du -sk "$tmp" | cut -f1)" -ge "$(du -sk "$LOCAL_SNAPS/$s" | cut -f1)" ] \
       && mv "$tmp" "$SNAPDIR/$s"; then
      rm -rf "$LOCAL_SNAPS/$s"
      log "published snapshot $s to $(printf '%s' "$SNAPDIR" | sed "s|$HOME|~|") ($(hsize "$SNAPDIR/$s"))"
    else
      rm -rf "$tmp"
      warn "could not publish $s; kept locally in $LOCAL_SNAPS"
    fi
  done || true
}

pending_count() { ls -1 "$LOCAL_SNAPS" 2>/dev/null | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' || true; }

# ── backup pieces ────────────────────────────────────────────────────────────
write_manifest() { # file snapname
  {
    echo "macbunker $VERSION snapshot $2"
    echo "created:   $(date)"
    echo "host:      $(scutil --get ComputerName 2>/dev/null || hostname)"
    echo "user:      $USER   home: $HOME"
    echo "macos:     $(sw_vers -productVersion) build $(sw_vers -buildVersion)   arch: $(uname -m)"
    echo "hardware:  $(system_profiler SPHardwareDataType 2>/dev/null | grep -E 'Model Name|Model Identifier|Chip|Memory|Serial' | sed 's/^ *//' | tr '\n' ';')"
    echo "claude:    $(claude --version 2>/dev/null | head -n 1 || echo none)"
    echo "homebrew:  $(brew --version 2>/dev/null | head -n 1 || echo none)"
    echo "shell:     $SHELL"
    echo
    echo "contents:"
    echo "  home.tar.gz.enc   encrypted tar of every path in include.txt (minus exclude.txt), plus _macbunker/defaults/*.plist and metadata"
    echo "  repos.tar.gz.enc  encrypted git bundles / patches / .env files for repos listed in repos.tsv"
    echo "  Brewfile, apps.txt, repos.tsv, manifest.txt   plaintext inventories"
    echo "  toolkit/          copy of macbunker.sh and its config as of this snapshot"
    echo
    echo "restore on a fresh Mac:  bash \"$ROOT/macbunker.sh\" restore --snapshot $2 --repos mine"
  } > "$1"
}

dump_brew() { # Brewfile
  if command -v brew >/dev/null 2>&1; then
    local args="--force --taps --formulae --casks --vscode --uv --npm"
    command -v mas >/dev/null 2>&1 && args="$args --mas"
    # shellcheck disable=SC2086
    brew bundle dump $args --file="$1" >>"${LOGFILE:-/dev/null}" 2>&1 || warn "brew bundle dump failed (see log)"
  else
    warn "Homebrew not installed; no Brewfile written"
  fi
}

# Export preference domains WITHOUT touching sandboxed apps: their preferences live in
# ~/Library/Containers, and reading those is what macOS calls "accessing data from other apps",
# a permission it re-asks for on every unattended run. Only domains backed by a plain plist in
# ~/Library/Preferences are exported; media/mail/browser domains are skipped as well (they trigger
# media-library prompts and are useless on another Mac anyway).
export_defaults() { # dir
  mkdir -p "$1"
  local d
  # Enumerate plain plists directly: 'defaults domains' scans app containers too, which is itself a
  # protected read.
  ls "$HOME/Library/Preferences" 2>/dev/null | sed -n 's/\.plist$//p' | while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$d" in .GlobalPreferences* | ByHost) continue ;; esac
    [ -d "$HOME/Library/Containers/$d" ] && continue
    [ -d "$HOME/Library/Group Containers/$d" ] && continue
    case "$d" in
      group.* | com.apple.Music* | com.apple.iTunes* | com.apple.itunes* | com.apple.amp.* | com.apple.Photos* | com.apple.photos* | \
      com.apple.mail* | com.apple.icloudmailagent | com.apple.MobileSMS* | com.apple.Safari* | com.apple.TV | com.apple.podcasts* | com.apple.news*)
        continue ;;
    esac
    defaults export "$d" "$1/$d.plist" 2>/dev/null || true
  done
  defaults export NSGlobalDomain "$1/NSGlobalDomain.plist" 2>/dev/null || true
  log "exported $(ls "$1" | wc -l | tr -d ' ') preference domains (sandboxed apps' domains skipped: macOS protects their data)"
}

expand_includes() { # outfile   (paths relative to $HOME; globs allowed on lines without spaces)
  local out="$1" line p
  : > "$out"
  readable "$INCLUDE_FILE" || die "cannot read include list ($INCLUDE_FILE)"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
      *[\*\?\[]*)
        # shellcheck disable=SC2086
        (cd "$HOME" && for p in $line; do [ -e "$p" ] || [ -L "$p" ] && printf '%s\n' "$p"; done) >> "$out" ;;
      *)
        if [ -e "$HOME/$line" ] || [ -L "$HOME/$line" ]; then printf '%s\n' "$line" >> "$out"; fi ;;
    esac
  done < "$INCLUDE_FILE"
}

build_home_tar() { # stage listfile   -> stage/home.tar.gz
  local stage="$1" list="$2" line
  EX=(--exclude .DS_Store)
  if readable "$EXCLUDE_FILE"; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in '' | '#'*) continue ;; esac
      EX+=(--exclude "$line")
    done < "$EXCLUDE_FILE"
  fi
  log "archiving $(wc -l < "$list" | tr -d ' ') home paths"
  # ACLs/flags are deliberately not archived: macOS puts "deny delete" ACLs on ~/Library folders, which
  # would make the restored/staged copies undeletable.
  tar -cf "$stage/home.tar" --no-acls --no-fflags --no-mac-metadata "${EX[@]}" -C "$HOME" -T "$list" 2>>"${LOGFILE:-/dev/null}" || warn "tar reported warnings (see log)"
  tar -rf "$stage/home.tar" --no-acls --no-fflags --no-mac-metadata -C "$stage" _macbunker 2>>"${LOGFILE:-/dev/null}"
  gzip -f "$stage/home.tar"
}

repo_is_mine() { # remote bundle
  local o
  [ "$2" = yes ] && [ "$1" = "-" ] && return 0
  for o in $MACBUNKER_REPO_OWNERS; do
    case "$1" in *"/$o/"* | *":$o/"*) return 0 ;; esac
  done
  return 1
}

scan_one_repo() { # repo tsv outdir
  local repo="$1" tsv="$2" out="$3"
  local rel slug remote branch dirty unpushed stashes gitkb bundle=no patch=no secrets=no note=""
  rel="${repo#$HOME/}"
  slug="$(printf '%s' "$rel" | tr '/ ' '__')"

  local skip=0 s oldifs="$IFS"
  IFS=':'
  for s in $MACBUNKER_REPO_SKIP; do [ "$s" = "$rel" ] && skip=1; done
  IFS="$oldifs"
  if [ "$skip" = 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" "?" "?" "?" "?" no no no "skipped: listed in MACBUNKER_REPO_SKIP" >> "$tsv"
    return 0
  fi

  if [ -n "$(find "$repo" -maxdepth 3 -name '.*.icloud' 2>/dev/null | head -n 1)" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "-" "?" "?" "?" "?" no no no "skipped: files evicted from iCloud" >> "$tsv"
    return 0
  fi

  remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
  if [ -z "$remote" ]; then
    local first
    first="$(git -C "$repo" remote 2>/dev/null | head -n 1 || true)"
    [ -n "$first" ] && remote="$(git -C "$repo" remote get-url "$first" 2>/dev/null || true)"
  fi
  branch="$(git -C "$repo" symbolic-ref --short -q HEAD 2>/dev/null || git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')"
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  unpushed="$(git -C "$repo" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
  stashes="$(git -C "$repo" stash list 2>/dev/null | wc -l | tr -d ' ')"
  gitkb="$(du -sk "$repo/.git" 2>/dev/null | cut -f1)"; [ -n "$gitkb" ] || gitkb=0

  # Full history bundle when the remote can't reproduce it (no remote, unpushed commits, or stashes)
  if [ -z "$remote" ] || [ "$unpushed" -gt 0 ] || [ "$stashes" -gt 0 ]; then
    if [ "$gitkb" -le $((MACBUNKER_MAX_BUNDLE_MB * 1024)) ]; then
      if git -C "$repo" bundle create "$out/$slug.bundle" --all >/dev/null 2>&1; then bundle=yes
      else note="${note}bundle failed; "; rm -f "$out/$slug.bundle"; fi
    else
      note="${note}bundle skipped (.git is $((gitkb / 1024)) MB, cap ${MACBUNKER_MAX_BUNDLE_MB}); "
    fi
  fi

  # Uncommitted work: tracked diff + untracked (non-ignored) files
  if [ "$dirty" -gt 0 ]; then
    if git -C "$repo" diff --binary HEAD > "$out/$slug.patch" 2>/dev/null && [ -s "$out/$slug.patch" ]; then
      if [ "$(du -sk "$out/$slug.patch" | cut -f1)" -le $((MACBUNKER_MAX_PATCH_MB * 1024)) ]; then patch=yes
      else rm -f "$out/$slug.patch"; note="${note}patch too large; "; fi
    else
      rm -f "$out/$slug.patch"
    fi
    # Untracked files are only captured for your own repos; in third-party clones they are almost always
    # build output or downloaded tooling. Size is measured recursively from inside the repo, because an
    # untracked entry can be a whole nested checkout.
    local ucount ukb
    ucount="$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$ucount" -gt 0 ]; then
      if repo_is_mine "${remote:--}" "$bundle"; then
        ukb="$(cd "$repo" && git ls-files --others --exclude-standard -z 2>/dev/null | xargs -0 du -sk 2>/dev/null | awk '{s+=$1} END {print s+0}')"
        [ -n "$ukb" ] || ukb=0
        if [ "$ukb" -le $((MACBUNKER_MAX_PATCH_MB * 1024)) ]; then
          git -C "$repo" ls-files --others --exclude-standard -z 2>/dev/null \
            | tar -czf "$out/$slug.untracked.tgz" -C "$repo" --null -T - 2>/dev/null && patch=yes
        else
          note="${note}untracked files skipped ($ucount files, $((ukb / 1024)) MB > cap ${MACBUNKER_MAX_PATCH_MB}); "
        fi
      else
        note="${note}$ucount untracked file(s) not captured (third-party repo); "
      fi
    fi
  fi

  # gitignored secrets (.env and friends) that no remote will ever have
  local sfiles
  sfiles="$(cd "$repo" && find . -maxdepth 3 -type f \( -name .env -o -name '.env.*' -o -name '*.env' -o -name 'secrets.*' -o -name '*.secret' \) \
            -not -path '*/node_modules/*' -not -path '*/.venv/*' 2>/dev/null || true)"
  if [ -n "$sfiles" ]; then
    printf '%s\n' "$sfiles" | tar -czf "$out/$slug.secrets.tgz" -C "$repo" -T - 2>/dev/null && secrets=yes
  fi

  [ -n "$remote" ] || remote="-"
  [ -n "$note" ] || note="-"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$rel" "$remote" "$branch" "$dirty" "$unpushed" "$stashes" "$bundle" "$patch" "$secrets" "$note" >> "$tsv"
}

scan_repos() { # tsv outdir
  local tsv="$1" out="$2" root gitdir n
  mkdir -p "$out"
  printf 'path\tremote\tbranch\tdirty_files\tunpushed_commits\tstashes\tbundle\tpatch\tsecrets\tnote\n' > "$tsv"
  printf '%s' "$MACBUNKER_REPO_ROOTS" | tr ':' '\n' | while IFS= read -r root; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth "$MACBUNKER_REPO_DEPTH" -type d -name .git \
      -not -path '*/node_modules/*' -not -path '*/.venv/*' -not -path '*/Library/*' 2>/dev/null
  done | sort -u > "$out/.gitdirs"
  n="$(wc -l < "$out/.gitdirs" | tr -d ' ')"
  log "scanning $n git repos under $(printf '%s' "$MACBUNKER_REPO_ROOTS" | sed "s|$HOME|~|g")"
  while IFS= read -r gitdir; do
    [ -n "$gitdir" ] || continue
    scan_one_repo "${gitdir%/.git}" "$tsv" "$out" || warn "repo scan failed: $gitdir"
  done < "$out/.gitdirs"
  rm -f "$out/.gitdirs"
  log "repos needing bundles/patches: $(ls "$out" 2>/dev/null | wc -l | tr -d ' ') artifact(s), $(hsize "$out")"
}

prune_snapshots() {
  local old
  ls -1 "$SNAPDIR" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort -r | tail -n +$((MACBUNKER_RETENTION + 1)) | while IFS= read -r old; do
    log "pruning old snapshot $old"
    rm -rf "$SNAPDIR/$old"
  done || true
  # local pending snapshots are capped too, so a long outage cannot fill the disk
  ls -1 "$LOCAL_SNAPS" 2>/dev/null | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$' | sort -r | tail -n +$((MACBUNKER_RETENTION + 1)) | while IFS= read -r old; do
    rm -rf "$LOCAL_SNAPS/$old"
  done || true
  find "$LOGDIR" -name '*.log' -mtime +60 -delete 2>/dev/null || true
}

copy_extra_dests() { # snap
  local d
  printf '%s' "$MACBUNKER_EXTRA_DESTS" | tr ':' '\n' | while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -d "$d" ]; then
      mkdir -p "$d/snapshots" && cp -R "$1" "$d/snapshots/" && log "copied snapshot to $d"
      cp "$LOCAL"/macbunker.sh "$LOCAL"/*.txt "$LOCAL"/macbunker.conf "$LOCAL"/README.md "$d/" 2>/dev/null || true
    else
      warn "extra destination not mounted, skipped: $d"
    fi
  done || true
}

cmd_backup() {
  local ts snap stage f src
  mkdir -p "$LOCAL_SNAPS" "$LOGDIR"
  mirror_toolkit
  readable "$INCLUDE_FILE" || die "no include.txt readable at $ROOT, $LOCAL or $SCRIPT_DIR — run 'macbunker init' first"
  ts="$(date +%Y-%m-%d_%H%M%S)"
  LOGFILE="$LOGDIR/backup-$ts.log"
  snap="$LOCAL_SNAPS/$ts"
  stage="$(mktemp -d "${TMPDIR:-/tmp}/macbunker.XXXXXX")"
  CLEANUP_DIR="$stage"
  trap 'rm -rf "$CLEANUP_DIR"' EXIT
  PASS="$(get_passphrase)"
  log "macbunker $VERSION backup -> $snap (config from $(dirname "$INCLUDE_FILE" | sed "s|$HOME|~|"))"
  mkdir -p "$snap" "$stage/_macbunker/defaults" "$stage/repos"

  write_manifest "$snap/manifest.txt" "$ts"
  dump_brew "$snap/Brewfile"
  { echo "# /Applications"; ls /Applications 2>/dev/null; echo; echo "# ~/Applications"; ls "$HOME/Applications" 2>/dev/null; } > "$snap/apps.txt"

  export_defaults "$stage/_macbunker/defaults"
  expand_includes "$stage/_macbunker/include-expanded.txt"
  cp "$INCLUDE_FILE" "$stage/_macbunker/include.txt" 2>/dev/null || true
  cp "$EXCLUDE_FILE" "$stage/_macbunker/exclude.txt" 2>/dev/null || true
  cp "$DEFAULTS_FILE" "$stage/_macbunker/defaults-restore.txt" 2>/dev/null || true
  crontab -l > "$stage/_macbunker/crontab.txt" 2>/dev/null || true
  launchctl list > "$stage/_macbunker/launchctl-list.txt" 2>/dev/null || true
  (command -v claude >/dev/null 2>&1 && claude mcp list) > "$stage/_macbunker/claude-mcp-list.txt" 2>/dev/null || true

  build_home_tar "$stage" "$stage/_macbunker/include-expanded.txt"
  seal "$stage/home.tar.gz" "$snap/home.tar.gz.enc" "$snap/home.sha256"
  log "home archive sealed: $(hsize "$snap/home.tar.gz.enc")"

  scan_repos "$snap/repos.tsv" "$stage/repos"
  if [ -n "$(ls -A "$stage/repos" 2>/dev/null)" ]; then
    tar -czf "$stage/repos.tar.gz" -C "$stage" repos
    seal "$stage/repos.tar.gz" "$snap/repos.tar.gz.enc" "$snap/repos.sha256"
    log "repos archive sealed: $(hsize "$snap/repos.tar.gz.enc")"
  fi

  mkdir -p "$snap/toolkit"
  for f in macbunker.sh macbunker.conf include.txt exclude.txt defaults-restore.txt README.md; do
    src="$(pick_file "$f")"
    readable "$src" && cp "$src" "$snap/toolkit/" || true
  done
  date > "$snap/.complete"
  log "snapshot $ts built locally ($(hsize "$snap"))"

  publish_pending
  copy_extra_dests "$snap" 2>/dev/null || true
  prune_snapshots
  local pend; pend="$(pending_count)"
  if [ "$pend" -gt 0 ]; then
    warn "$pend snapshot(s) are still only on this disk ($LOCAL_SNAPS). Run 'macbunker publish' from Terminal, or grant $APP Full Disk Access so the scheduled job can write to $ROOT."
  else
    log "done: $(ls -1 "$SNAPDIR" 2>/dev/null | grep -cE '^[0-9]{4}-' || echo 0) snapshot(s) in $(printf '%s' "$SNAPDIR" | sed "s|$HOME|~|"), newest $ts"
  fi
}

cmd_publish() {
  mkdir -p "$LOGDIR"; LOGFILE="$LOGDIR/publish.log"
  root_writable || die "$ROOT is not writable from this process (run from Terminal, or grant $APP Full Disk Access)"
  mirror_toolkit
  publish_pending
  prune_snapshots
  log "pending local snapshots: $(pending_count)"
}

# ── restore pieces ───────────────────────────────────────────────────────────
step_xcode() {
  xcode-select -p >/dev/null 2>&1 && return 0
  log "installing Xcode Command Line Tools (a system dialog will appear; click Install)"
  [ "$DRY" = 1 ] && return 0
  xcode-select --install 2>/dev/null || true
  until xcode-select -p >/dev/null 2>&1; do sleep 15; done
}

step_brew() { # Brewfile
  [ -f "$1" ] || { warn "no Brewfile in snapshot; skipping apps"; return 0; }
  if ! command -v brew >/dev/null 2>&1; then
    log "installing Homebrew (you may be asked for your password)"
    if [ "$DRY" != 1 ]; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || eval "$(/usr/local/bin/brew shellenv)" 2>/dev/null || true
    fi
  fi
  log "brew bundle install from $(basename "$(dirname "$1")")/Brewfile ($(grep -c -vE '^\s*(#|$)' "$1") entries)"
  run brew bundle install --file="$1" || warn "brew bundle had failures; rerun later with: brew bundle --file=\"$1\""
}

step_tools_pre() {
  if [ ! -d "$HOME/.oh-my-zsh" ] && grep -q 'oh-my-zsh' "$HOME/.zshrc" 2>/dev/null; then
    log "installing oh-my-zsh"
    if [ "$DRY" != 1 ]; then
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended --keep-zshrc || warn "oh-my-zsh install failed"
    fi
  fi
}

step_home() { # work
  local work="$1" list="$work/stage/home/_macbunker/include-expanded.txt" p src dst n=0
  [ -f "$list" ] || die "snapshot is missing _macbunker/include-expanded.txt"
  while IFS= read -r p || [ -n "$p" ]; do
    [ -n "$p" ] || continue
    src="$work/stage/home/$p"; dst="$HOME/$p"
    [ -e "$src" ] || [ -L "$src" ] || continue
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      if [ "$DRY" = 1 ]; then
        log "[dry-run] replace ~/$p (current copy would go to replaced/)"
        n=$((n + 1)); continue
      fi
      mkdir -p "$work/replaced/$(dirname "$p")"
      if ! mv "$dst" "$work/replaced/$p" 2>/dev/null; then
        # macOS protects some ~/Library folders with a "deny delete" ACL: keep a copy, then merge into it
        cp -RP "$dst" "$work/replaced/$p" 2>/dev/null || true
        if [ -d "$dst" ] && [ ! -L "$dst" ] && [ -d "$src" ]; then
          cp -RPp "$src/." "$dst/" || warn "merge into ~/$p had errors"
          n=$((n + 1)); continue
        fi
        rm -rf "$dst" 2>/dev/null || { warn "cannot replace protected ~/$p; left as is"; continue; }
      fi
    fi
    run mkdir -p "$(dirname "$dst")"
    run cp -RPp "$src" "$dst"
    n=$((n + 1))
  done < "$list"
  if [ "$DRY" != 1 ]; then
    if [ -d "$HOME/.ssh" ]; then
      chmod 700 "$HOME/.ssh"
      find "$HOME/.ssh" -type f -name '*.pub' -exec chmod 644 {} \;
      find "$HOME/.ssh" -type f ! -name '*.pub' -exec chmod 600 {} \;
    fi
    [ -f "$HOME/.claude.json" ] && chmod 600 "$HOME/.claude.json"
    [ -f "$HOME/.claude/settings.json" ] && log "restored ~/.claude ($(hsize "$HOME/.claude")) and ~/.claude.json"
  fi
  log "restored $n home path(s); anything replaced was moved to $work/replaced/"
}

step_defaults() { # work all
  local work="$1" all="$2" ddir="$work/stage/home/_macbunker/defaults" d f
  [ -d "$ddir" ] || { warn "no exported preferences in snapshot"; return 0; }
  if [ "$all" = 1 ]; then ls "$ddir" | sed 's/\.plist$//'
  else grep -vE '^[[:space:]]*(#|$)' "$work/stage/home/_macbunker/defaults-restore.txt" 2>/dev/null || grep -vE '^[[:space:]]*(#|$)' "$DEFAULTS_FILE"
  fi | while IFS= read -r d; do
    f="$ddir/$d.plist"
    [ -f "$f" ] || { warn "no saved preferences for $d"; continue; }
    run defaults import "$d" "$f" || warn "defaults import failed for $d"
  done || true
  log "preferences applied; restarting Dock/Finder"
  run killall Dock Finder SystemUIServer 2>/dev/null || true
}

step_repos() { # tsv rdir mode
  local tsv="$1" rdir="$2" mode="$3"
  local rel remote branch dirty unpushed stashes bundle patch secrets note dst slug
  [ "$mode" = none ] && { log "repos: not restored (use --repos mine or --repos all)"; return 0; }
  [ -f "$tsv" ] || { warn "no repos.tsv in snapshot"; return 0; }
  tail -n +2 "$tsv" | while IFS=$'\t' read -r rel remote branch dirty unpushed stashes bundle patch secrets note; do
    [ -n "$rel" ] || continue
    if [ "$mode" = mine ] && ! repo_is_mine "$remote" "$bundle"; then continue; fi
    dst="$HOME/$rel"; slug="$(printf '%s' "$rel" | tr '/ ' '__')"
    if [ -e "$dst" ]; then
      # Never touch a repo that is already there; its saved artifacts stay in the work dir for manual use.
      if ls "$rdir/$slug".* >/dev/null 2>&1; then
        log "repo exists, left untouched: ~/$rel (saved patch/untracked/.env artifacts: $rdir/$slug.*)"
      else
        log "repo exists, left untouched: ~/$rel"
      fi
      continue
    elif [ "$bundle" = yes ] && [ -f "$rdir/$slug.bundle" ]; then
      log "restoring ~/$rel from bundle"
      run mkdir -p "$(dirname "$dst")"
      run git clone -q "$rdir/$slug.bundle" "$dst" || { warn "bundle clone failed: $rel"; continue; }
      if [ "$remote" != "-" ]; then run git -C "$dst" remote set-url origin "$remote"; run git -C "$dst" fetch -q origin || true; fi
    elif [ "$remote" != "-" ]; then
      log "cloning ~/$rel from $remote"
      run mkdir -p "$(dirname "$dst")"
      run git clone -q "$remote" "$dst" || { warn "clone failed: $rel"; continue; }
    else
      warn "no remote and no bundle for ~/$rel; skipped"
      continue
    fi
    [ "$branch" != "?" ] && [ "$DRY" != 1 ] && git -C "$dst" checkout -q "$branch" 2>/dev/null || true
    [ -f "$rdir/$slug.patch" ] && { run git -C "$dst" apply --3way "$rdir/$slug.patch" || warn "patch did not apply cleanly: $rel (saved at $rdir/$slug.patch)"; }
    [ -f "$rdir/$slug.untracked.tgz" ] && run tar -xzf "$rdir/$slug.untracked.tgz" -C "$dst"
    [ -f "$rdir/$slug.secrets.tgz" ] && run tar -xzf "$rdir/$slug.secrets.tgz" -C "$dst"
  done
  return 0
}

step_tools_post() {
  if [ -d "$HOME/.claude" ] && ! claude --version >/dev/null 2>&1; then
    log "installing Claude Code"
    [ "$DRY" = 1 ] || curl -fsSL https://claude.ai/install.sh | bash || warn "Claude Code install failed"
  fi
  if [ -L "$HOME/.local/bin/uv" ] || [ -d "$HOME/.local/share/uv" ] && ! uv --version >/dev/null 2>&1; then
    log "installing uv"
    [ "$DRY" = 1 ] || curl -LsSf https://astral.sh/uv/install.sh | sh || warn "uv install failed"
  fi
}

step_launchagents() {
  local p
  for p in "$HOME"/Library/LaunchAgents/*.plist; do
    [ -f "$p" ] || continue
    [ "$(basename "$p")" = "$LABEL.plist" ] && continue
    run launchctl bootstrap "gui/$(uid)" "$p" 2>/dev/null || true
  done
  if [ "$DRY" = 1 ]; then log "[dry-run] would install the daily macbunker schedule"; else cmd_schedule; fi
}

cmd_restore() {
  local snapname="" repos="none" alldef=0 nobrew=0 nodef=0 nohome=0 norepos=0 notools=0 yes=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --snapshot) snapname="$2"; shift 2 ;;
      --dry-run) DRY=1; shift ;;
      --repos) repos="$2"; shift 2 ;;
      --all-defaults) alldef=1; shift ;;
      --no-brew) nobrew=1; shift ;;
      --no-defaults) nodef=1; shift ;;
      --no-home) nohome=1; shift ;;
      --no-repos) norepos=1; shift ;;
      --no-tools) notools=1; shift ;;
      --yes | -y) yes=1; shift ;;
      *) die "unknown restore option: $1 (see 'macbunker help')" ;;
    esac
  done
  case "$repos" in none | mine | all) ;; *) die "--repos must be none, mine or all" ;; esac
  local snap
  case "$snapname" in
    /*) snap="$snapname" ;;
    "") [ -d "$SNAPDIR" ] || die "no snapshots at $SNAPDIR — is iCloud Drive signed in and finished syncing? (or set MACBUNKER_ROOT)"
        snapname="$(latest_snapshot)"; [ -n "$snapname" ] || die "no snapshots found in $SNAPDIR"
        snap="$SNAPDIR/$snapname" ;;
    *)  snap="$SNAPDIR/$snapname"; [ -d "$snap" ] || snap="$LOCAL_SNAPS/$snapname" ;;
  esac
  [ -d "$snap" ] || die "snapshot not found: $snapname"
  snapname="$(basename "$snap")"
  ensure_downloaded "$snap"
  [ -f "$snap/.complete" ] || warn "snapshot $snapname has no .complete marker; the backup may have been interrupted"

  local ts work
  ts="$(date +%Y-%m-%d_%H%M%S)"
  work="$HOME/macbunker-restore-$ts"
  echo
  echo "macbunker $VERSION restore"
  echo "  snapshot:  $snapname  ($(hsize "$snap"))"
  echo "  taken on:  $(sed -n 's/^created: *//p' "$snap/manifest.txt" 2>/dev/null) from $(sed -n 's/^host: *//p' "$snap/manifest.txt" 2>/dev/null)"
  echo "  target:    $HOME on $(scutil --get ComputerName 2>/dev/null || hostname)"
  echo "  steps:     $([ $notools = 0 ] && printf 'xcode-clt ')$([ $nobrew = 0 ] && printf 'homebrew+apps ')$([ $nohome = 0 ] && printf 'dotfiles+~/.claude ')$([ $nodef = 0 ] && printf 'defaults ')$([ $norepos = 0 ] && printf 'repos=%s ' "$repos")$([ $notools = 0 ] && printf 'tools ')schedule"
  echo "  replaced files go to: $work/replaced/"
  [ "$DRY" = 1 ] && echo "  DRY RUN: nothing will be changed"
  echo
  if [ "$yes" != 1 ] && [ "$DRY" != 1 ]; then
    [ -t 0 ] || die "restore needs a terminal (or pass --yes)"
    read -r -p "Proceed? [y/N] " a </dev/tty
    case "$a" in y | Y | yes) ;; *) die "aborted" ;; esac
  fi

  mkdir -p "$work/stage/home" "$work/replaced"
  LOGFILE="$work/restore.log"
  PASS="$(get_passphrase)"
  unseal "$snap/home.tar.gz.enc" "$snap/home.sha256" "$work/stage/home.tar.gz"
  tar -xzf "$work/stage/home.tar.gz" --no-acls --no-fflags -C "$work/stage/home" 2>>"$LOGFILE" || warn "tar extract reported warnings"
  rm -f "$work/stage/home.tar.gz"
  if [ -f "$snap/repos.tar.gz.enc" ]; then
    unseal "$snap/repos.tar.gz.enc" "$snap/repos.sha256" "$work/stage/repos.tar.gz"
    tar -xzf "$work/stage/repos.tar.gz" -C "$work/stage" && rm -f "$work/stage/repos.tar.gz"
  fi

  [ $notools = 0 ] && step_xcode
  [ $nobrew = 0 ] && step_brew "$snap/Brewfile"
  [ $notools = 0 ] && step_tools_pre
  [ $nohome = 0 ] && step_home "$work"
  [ $nodef = 0 ] && step_defaults "$work" "$alldef"
  [ $norepos = 0 ] && step_repos "$snap/repos.tsv" "$work/stage/repos" "$repos"
  [ $notools = 0 ] && step_tools_post
  step_launchagents

  echo
  log "restore finished. Log: $LOGFILE"
  cat <<EOF

Still manual (macOS does not let a script do these):
  - System Settings > Privacy & Security > Full Disk Access: add $APP (so the daily
    backup can write to iCloud Drive) and your terminal app
  - Sign in again to the App Store, your password manager, Claude ('claude'), gh ('gh auth status'), VPN, etc.
  - Time Machine: pick a disk (macbunker is not a substitute)
  - Reboot once so login items, launch agents and preference changes all settle
  - Review what was replaced: $work/replaced/ (delete it when you are happy)
EOF
}

# ── other commands ───────────────────────────────────────────────────────────
cmd_verify() {
  local snapname="${1:-}" tmp n p snap
  case "$snapname" in
    /*) snap="$snapname" ;;
    "") snapname="$(latest_snapshot)"; [ -n "$snapname" ] || die "no snapshots in $SNAPDIR"; snap="$SNAPDIR/$snapname" ;;
    *)  snap="$SNAPDIR/$snapname"; [ -d "$snap" ] || snap="$LOCAL_SNAPS/$snapname" ;;
  esac
  [ -d "$snap" ] || die "snapshot not found: $snapname"
  ensure_downloaded "$snap"
  PASS="$(get_passphrase)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/macbunker-verify.XXXXXX")"
  CLEANUP_DIR="$tmp"
  trap 'rm -rf "$CLEANUP_DIR"' EXIT
  unseal "$snap/home.tar.gz.enc" "$snap/home.sha256" "$tmp/home.tar.gz"
  n="$(tar -tzf "$tmp/home.tar.gz" | wc -l | tr -d ' ')"
  log "home archive: $n entries"
  for p in .claude/ .claude.json .ssh/ .zshrc _macbunker/defaults/; do
    if tar -tzf "$tmp/home.tar.gz" | grep -q "^$p"; then log "  ok  $p"; else warn "  MISSING $p"; fi
  done
  log "  memory dirs: $(tar -tzf "$tmp/home.tar.gz" | grep -c '/memory/MEMORY.md$' || true)   transcripts: $(tar -tzf "$tmp/home.tar.gz" | grep -c '^\.claude/projects/.*\.jsonl$' || true)"
  if [ -f "$snap/repos.tar.gz.enc" ]; then
    unseal "$snap/repos.tar.gz.enc" "$snap/repos.sha256" "$tmp/repos.tar.gz"
    log "repos archive: $(tar -tzf "$tmp/repos.tar.gz" | grep -vc '/$') file(s)"
  fi
  log "verify OK for $(basename "$snap")"
}

cmd_list() {
  local s
  printf '%-22s %8s  %-9s %s\n' SNAPSHOT SIZE STATUS LOCATION
  ls -1 "$SNAPDIR" 2>/dev/null | grep -E '^[0-9]{4}-' | sort | while IFS= read -r s; do
    printf '%-22s %8s  %-9s %s\n' "$s" "$(hsize "$SNAPDIR/$s")" \
      "$([ -f "$SNAPDIR/$s/.complete" ] && echo complete || echo PARTIAL)" \
      "$([ -n "$(find "$SNAPDIR/$s" -name '.*.icloud' 2>/dev/null | head -n 1)" ] && echo 'root (evicted locally)' || echo root)"
  done || true
  ls -1 "$LOCAL_SNAPS" 2>/dev/null | grep -E '^[0-9]{4}-' | sort | while IFS= read -r s; do
    printf '%-22s %8s  %-9s %s\n' "$s" "$(hsize "$LOCAL_SNAPS/$s")" \
      "$([ -f "$LOCAL_SNAPS/$s/.complete" ] && echo complete || echo PARTIAL)" "LOCAL ONLY (~/.macbunker/snapshots) — run 'macbunker publish'"
  done || true
  return 0
}

cmd_status() {
  local latest age pend
  echo "macbunker $VERSION"
  echo "root:        $ROOT"
  if root_readable; then echo "root access: readable$(root_writable && echo ', writable' || echo ', NOT writable')"; else echo "root access: NOT readable from this process — run 'macbunker init' or check permissions"; fi
  latest="$(latest_snapshot)"
  if [ -n "$latest" ]; then
    age=$(( ( $(date +%s) - $(stat -f %m "$SNAPDIR/$latest") ) / 3600 ))
    echo "latest:      $latest  (${age}h ago, $(hsize "$SNAPDIR/$latest"), $([ -f "$SNAPDIR/$latest/.complete" ] && echo complete || echo PARTIAL))"
    echo "snapshots:   $(ls -1 "$SNAPDIR" | grep -c -E '^[0-9]{4}-') kept (retention $MACBUNKER_RETENTION), $(hsize "$SNAPDIR") total"
    [ "$age" -gt 48 ] && echo "             ** latest snapshot is older than 2 days **"
  else
    echo "latest:      none yet — run 'macbunker backup'"
  fi
  pend="$(pending_count)"
  [ "$pend" -gt 0 ] && echo "pending:     $pend snapshot(s) only on this disk — run 'macbunker publish'"
  if launchctl print "gui/$(uid)/$LABEL" >/dev/null 2>&1; then
    printf 'schedule:    daily at %02d:%02d (%s)' "$MACBUNKER_SCHEDULE_HOUR" "$MACBUNKER_SCHEDULE_MINUTE" "$LABEL"
    launchctl print "gui/$(uid)/$LABEL" 2>/dev/null | grep -q 'last exit code = 0' && echo ", last run OK" || echo ""
  else
    echo "schedule:    NOT installed — run 'macbunker schedule'"
  fi
  echo "app:         $([ -d "$APP" ] && echo "$APP (grant it Full Disk Access once)" || echo 'not built — run macbunker schedule')"
  if security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    echo "passphrase:  in login keychain (save it in your password manager too: 'macbunker show-passphrase')"
  else
    echo "passphrase:  MISSING — run 'macbunker set-passphrase --generate'"
  fi
  echo "extra dests: ${MACBUNKER_EXTRA_DESTS:-none}"
  echo "repo owners: ${MACBUNKER_REPO_OWNERS:-none set (edit macbunker.conf)}"
  echo "logs:        $LOGDIR"
  return 0
}

cmd_set_passphrase() {
  local p p2 esc
  if [ "${1:-}" = "--generate" ]; then
    p="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | cut -c1-40)"
  else
    [ -t 0 ] || die "set-passphrase needs a terminal (or use --generate)"
    read -r -s -p "New passphrase (12+ chars): " p </dev/tty; echo
    read -r -s -p "Again: " p2 </dev/tty; echo
    [ "$p" = "$p2" ] || die "passphrases do not match"
    [ ${#p} -ge 12 ] || die "use at least 12 characters"
  fi
  esc="$(printf '%s' "$p" | sed 's/[\\"]/\\&/g')"
  security delete-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1 || true
  printf 'add-generic-password -a "%s" -s "%s" -l "macbunker backup passphrase" -T /usr/bin/security -w "%s"\n' "$USER" "$KEYCHAIN_SERVICE" "$esc" \
    | security -i >/dev/null
  log "passphrase stored in the login keychain (service '$KEYCHAIN_SERVICE')."
  log "NOW save it in your password manager — without it every snapshot is unreadable:  macbunker show-passphrase"
  log "existing snapshots keep the OLD passphrase until they age out; take a new backup now."
}

cmd_show_passphrase() {
  local p
  p="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)" || die "no passphrase in keychain"
  printf '%s\n' "$p"
}

# A real app bundle is needed because macOS privacy controls (TCC) attribute a launchd job to its
# executable: a bare /bin/bash is a platform binary that gets denied iCloud Drive access with no prompt.
# An AppleScript applet has its own identity, so macOS can prompt once (or you grant it Full Disk Access).
build_app() {
  [ -d "$APP" ] && [ -x "$APP/Contents/MacOS/applet" ] && return 0
  local src
  src="$(mktemp "${TMPDIR:-/tmp}/macbunker.XXXXXX.applescript")"
  cat > "$src" <<'EOF'
set homeDir to POSIX path of (path to home folder)
set launcher to homeDir & ".macbunker/macbunker.sh"
set logFile to homeDir & ".macbunker/logs/launchd.log"
do shell script "/bin/bash " & quoted form of launcher & " backup >> " & quoted form of logFile & " 2>&1"
EOF
  mkdir -p "$(dirname "$APP")"
  rm -rf "$APP"
  osacompile -o "$APP" "$src" || die "osacompile failed to build $APP"
  rm -f "$src"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LABEL" "$APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $LABEL" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleName macbunker" "$APP/Contents/Info.plist" 2>/dev/null || true
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || warn "ad-hoc codesign failed (the app still works, but macOS may re-ask for permission)"
  log "built $APP"
}

cmd_schedule() {
  mkdir -p "$LOCAL" "$LOGDIR" "$HOME/Library/LaunchAgents"
  mirror_toolkit
  [ -x "$LOCAL/macbunker.sh" ] || { cp "$SCRIPT_PATH" "$LOCAL/macbunker.sh" && chmod +x "$LOCAL/macbunker.sh"; }
  build_app
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP/Contents/MacOS/applet</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>MACBUNKER_ROOT</key><string>$ROOT</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>$MACBUNKER_SCHEDULE_HOUR</integer>
    <key>Minute</key><integer>$MACBUNKER_SCHEDULE_MINUTE</integer>
  </dict>
  <key>StandardOutPath</key><string>$LOGDIR/launchd.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/launchd.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(uid)" "$PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(uid)" "$PLIST"
  launchctl enable "gui/$(uid)/$LABEL"
  log "scheduled daily backup at $(printf '%02d:%02d' "$MACBUNKER_SCHEDULE_HOUR" "$MACBUNKER_SCHEDULE_MINUTE") via $LABEL (missed runs fire at next wake)"
  log "first run: macOS may ask whether macbunker may access iCloud Drive / Documents — click Allow, or add $APP under System Settings > Privacy & Security > Full Disk Access"
}

cmd_unschedule() {
  launchctl bootout "gui/$(uid)" "$PLIST" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  log "schedule removed ($APP left in place)"
}

# Install (or upgrade) the toolkit from a git checkout into the root. Existing config files are kept.
cmd_init() {
  local gen=0 f login
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT="$2"; SNAPDIR="$ROOT/snapshots"; shift 2 ;;
      --generate) gen=1; shift ;;
      *) die "unknown init option: $1" ;;
    esac
  done
  [ -f "$SCRIPT_DIR/include.txt" ] && [ -f "$SCRIPT_DIR/macbunker.conf.example" ] \
    || die "run init from a git checkout of macbunker (git clone https://github.com/bytebunkerlabs/macbunker && cd macbunker && ./macbunker.sh init)"
  case "$ROOT" in "$ICLOUD"*) [ -d "$ICLOUD" ] || die "iCloud Drive is not available; sign in to iCloud, or install elsewhere with --root DIR" ;; esac
  mkdir -p "$ROOT/snapshots" "$LOCAL" "$LOGDIR"
  cp "$SCRIPT_DIR/macbunker.sh" "$ROOT/macbunker.sh" && chmod +x "$ROOT/macbunker.sh"
  cp "$SCRIPT_DIR/README.md" "$ROOT/README.md" 2>/dev/null || true
  for f in include.txt exclude.txt defaults-restore.txt; do
    [ -f "$ROOT/$f" ] || cp "$SCRIPT_DIR/$f" "$ROOT/$f"
  done
  if [ ! -f "$ROOT/macbunker.conf" ]; then
    cp "$SCRIPT_DIR/macbunker.conf.example" "$ROOT/macbunker.conf"
    login="$(gh api user -q .login 2>/dev/null || git config --get github.user 2>/dev/null || true)"
    if [ -n "$login" ]; then
      sed -i '' "s|^MACBUNKER_REPO_OWNERS=.*|MACBUNKER_REPO_OWNERS=\"$login\"|" "$ROOT/macbunker.conf"
      log "macbunker.conf created; MACBUNKER_REPO_OWNERS set to \"$login\" (add your orgs there)"
    else
      log "macbunker.conf created; edit MACBUNKER_REPO_OWNERS in it so your repos count as yours"
    fi
  fi
  log "toolkit installed in $ROOT"
  MACBUNKER_ROOT="$ROOT" exec /bin/bash "$ROOT/macbunker.sh" _finish-init "$gen"
}

cmd_finish_init() { # gen
  mirror_toolkit
  if ! security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" >/dev/null 2>&1; then
    if [ "$1" = 1 ]; then cmd_set_passphrase --generate
    elif [ -t 0 ]; then cmd_set_passphrase
    else warn "no passphrase yet: run 'macbunker set-passphrase' (or --generate)"; fi
  fi
  cmd_schedule
  cat <<EOF

macbunker is installed.
  root:       $ROOT
  command:    macbunker   (in ~/.local/bin; add it to PATH if 'macbunker' is not found)
  next:       macbunker backup            take the first snapshot now
              macbunker show-passphrase   save the passphrase in your password manager
              macbunker status            check on it any time
  edit:       $ROOT/macbunker.conf, include.txt, exclude.txt, defaults-restore.txt
EOF
}

cmd_help() {
  cat <<EOF
macbunker $VERSION — back up and restore a Mac (dotfiles, ~/.claude, apps, defaults, repos)
root: $ROOT     local mirror + staging: $LOCAL

  macbunker init [--root DIR] [--generate]   install/upgrade the toolkit from this checkout, set passphrase + schedule
  macbunker backup                     snapshot now (built in ~/.macbunker/snapshots, published to <root>/snapshots/)
  macbunker publish                    push snapshots that are still only local into the root
  macbunker restore [options]          restore onto this Mac from a snapshot
      --snapshot NAME|/path          which snapshot (default: newest in root)
      --repos none|mine|all          re-clone git repos (default none; 'mine' = owners in macbunker.conf)
      --all-defaults                 apply every saved preference domain, not just defaults-restore.txt
      --no-brew --no-home --no-defaults --no-repos --no-tools   skip a step
      --dry-run                      decrypt and show what would happen, change nothing
      --yes                          do not ask for confirmation
  macbunker verify [SNAPSHOT]          decrypt + checksum a snapshot, list what is inside
  macbunker list                       snapshots with size / completeness / location
  macbunker status                     latest snapshot age, schedule, passphrase, root access
  macbunker schedule | unschedule      install / remove the daily launchd job (runs via ~/Applications/macbunker.app)
  macbunker set-passphrase [--generate]   store the encryption passphrase in the login keychain
  macbunker show-passphrase            print it (save it in your password manager!)

Edit include.txt / exclude.txt / defaults-restore.txt / macbunker.conf in the root to change what is captured.
EOF
}

case "${1:-help}" in
  init)            shift; cmd_init "$@" ;;
  _finish-init)    cmd_finish_init "${2:-0}" ;;
  backup)          shift; cmd_backup "$@" ;;
  publish)         cmd_publish ;;
  restore)         shift; cmd_restore "$@" ;;
  verify)          shift; cmd_verify "$@" ;;
  list)            cmd_list ;;
  status)          cmd_status ;;
  schedule)        cmd_schedule ;;
  unschedule)      cmd_unschedule ;;
  set-passphrase)  shift; cmd_set_passphrase "$@" ;;
  show-passphrase) cmd_show_passphrase ;;
  help | -h | --help) cmd_help ;;
  *) die "unknown command: $1 (try 'macbunker help')" ;;
esac
