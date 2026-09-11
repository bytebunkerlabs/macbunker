# macbunker

Daily, encrypted snapshot of everything on a Mac that a disk wipe or a new machine would otherwise lose,
and a one-command restore. Built after a real wipe took `~/.claude`, `~/dev`, SSH keys and shell config
with it while everything in iCloud survived, so it puts snapshots in iCloud Drive by default.

It captures:

- **AI coding tools:** `~/.claude` (memory, transcripts, settings, plugins), `~/.claude.json` (login, MCP
  servers, per-project trust), Codex, Copilot, Cursor, the Claude Desktop MCP config
- **Dotfiles and secrets:** SSH and GPG keys, zsh/bash config, oh-my-zsh custom plugins, git and gh config,
  VS Code / Cursor user settings, iTerm2, `~/bin`, AWS/kube/docker credentials
- **App inventory:** a Brewfile with taps, formulae, casks, VS Code extensions, uv tools and npm globals,
  plus a listing of `/Applications` for everything else
- **macOS preferences:** every `defaults` domain, with a curated list applied on restore
- **Git repos:** remote, branch, dirty/unpushed/stash counts for every repo; full-history bundles for
  anything with no remote or unpushed commits; patches for uncommitted work; untracked files for your own
  repos; `.env` files no remote will ever have

Stock macOS only: bash 3.2, bsdtar, LibreSSL, launchd, `osacompile`. Restore needs nothing installed.
Tested on macOS 26 (Apple silicon). Snapshots are AES-256-CBC + PBKDF2 encrypted; the passphrase lives in
the login keychain. A typical snapshot is 100-300 MB.

## Install

```bash
git clone https://github.com/bytebunkerlabs/macbunker
cd macbunker
./macbunker.sh init            # add --generate for a random passphrase, --root DIR to install somewhere other than iCloud Drive
macbunker backup               # first snapshot
macbunker show-passphrase      # put it in your password manager NOW
```

`init` copies the toolkit into `iCloud Drive/mac-backups/` (so it survives a wipe and is reachable from a
fresh Mac), creates `macbunker.conf` from the example, stores a passphrase in your keychain, installs the daily
launchd job, and puts a `macbunker` command in `~/.local/bin`. Rerun `init` from a newer checkout to upgrade;
your config files are kept.

## Daily use

```bash
macbunker status          # is the schedule running, how old is the newest snapshot, can it reach the root
macbunker backup          # take one now
macbunker publish         # push any snapshot that is still only on this disk into the root
macbunker list            # all snapshots
macbunker verify          # decrypt the newest one and prove it is readable
```

Edit `macbunker.conf`, `include.txt`, `exclude.txt`, `defaults-restore.txt` in the root; the next backup picks
them up. `MACBUNKER_EXTRA_DESTS` mirrors each snapshot to an external SSD or another cloud folder whenever it
is mounted.

## How the daily job works (and the one permission it needs)

A launchd job ticks every 30 minutes and launches `~/Applications/macbunker.app`, a tiny AppleScript
wrapper, which runs `macbunker backup`. The script itself decides whether today's backup is due (at or after
the time in `macbunker.conf`, once per day, tracked in `~/.macbunker/last-backup-date`). A Mac that is asleep
at that time runs it on the first tick after waking. Ticks are logged to `~/.macbunker/logs/scheduler.log`.
(launchd's own calendar scheduling is not used: it only rereads the time zone at boot, so on a Mac set up
in one zone and used in another it fires hours off until the next reboot.)

The wrapper exists because of macOS privacy controls: a launchd job that is just `/bin/bash` is silently
denied access to iCloud Drive and Documents and is never prompted. An app has its own identity, so macOS
can ask once. **On the first scheduled run, click Allow when asked whether macbunker may access iCloud Drive
and your Documents folder**, or add `~/Applications/macbunker.app` under System Settings > Privacy & Security >
Full Disk Access.

Even without that permission nothing is lost: each backup is built in `~/.macbunker/snapshots/` first and only
then copied into the root. If the copy is refused, the snapshot waits there and `macbunker status` says so;
running `macbunker publish` (or any `macbunker backup`) from Terminal pushes it up.

## Restoring onto a wiped or brand-new Mac

1. Create the user with the **same short username as the source Mac**. `~/.claude/projects/` and
   `~/.claude.json` key everything by absolute path, so a different username orphans memory and transcripts.
2. Sign in to iCloud, turn on iCloud Drive, and wait until Finder shows `mac-backups` with the newest
   snapshot folder present (`macbunker` will force-download what it needs, but the folder must exist).
3. Open **Terminal** (not a session inside Claude Code or Codex: restore replaces their state directories
   while it runs) and:

   ```bash
   bash "$HOME/Library/Mobile Documents/com~apple~CloudDocs/mac-backups/macbunker.sh" restore --repos mine
   ```

   Or from a fresh clone of this repo: `./macbunker.sh restore --repos mine` (it finds the iCloud root on its
   own; set `MACBUNKER_ROOT` if you installed elsewhere). Add `--dry-run` first to see the plan.

   It will, in order: install Xcode Command Line Tools, Homebrew and everything in the Brewfile; install
   oh-my-zsh if your `.zshrc` uses it; put back every path in `include.txt` (anything already there is moved
   to `~/macbunker-restore-<ts>/replaced/`, never deleted; protected `~/Library` folders are merged into);
   apply the preference domains in `defaults-restore.txt`; re-clone your repos (bundles for anything that was
   unpushed, patches for uncommitted work, `.env` files); install Claude Code and uv if they were present;
   reinstall launch agents, rebuild `macbunker.app` and re-enable the schedule.
4. Do the manual bits it prints at the end (Full Disk Access for macbunker.app and your terminal, app sign-ins,
   Time Machine) and reboot once.

`--repos all` also re-clones third-party checkouts. `--repos none` (default) leaves repos alone; `repos.tsv`
in the snapshot tells you what existed and where. A repo that already exists on the target is never touched;
its saved patches stay in the work dir for you to apply by hand.

## What a snapshot contains

```
snapshots/2026-09-07_181501/
  manifest.txt        host, macOS version, hardware, tool versions, how to restore
  Brewfile            brew bundle dump (taps, formulae, casks, vscode, uv, npm, mas)
  apps.txt            /Applications listing
  repos.tsv           every repo: path, remote, branch, dirty, unpushed, stashes, what was captured
  home.tar.gz.enc     encrypted: include.txt paths + _macbunker/defaults/*.plist + metadata
  home.sha256         checksum of the plaintext archive (verified on restore)
  repos.tar.gz.enc    encrypted: git bundles, patches, untracked files, .env files
  repos.sha256
  toolkit/            copy of macbunker.sh and its config as of this snapshot
  .complete           written last; restore refuses to trust a snapshot without it
```

## What is not captured

App binaries (reinstalled via Brewfile; the rest are listed in `apps.txt`), Keychain (iCloud Keychain handles
it), Mail/Messages/Photos, browser profiles, Docker images, Python venvs and node_modules (rebuild them),
untracked files in third-party clones, repos listed in `MACBUNKER_REPO_SKIP`, repos whose `.git` is over the
bundle size cap. This is a second layer, not a Time Machine replacement.

## Security notes

- The archives contain private keys, tokens and `.env` files. They are only ever written encrypted; the
  plaintext tar exists briefly in a private temp dir and is deleted.
- Encryption is `openssl enc -aes-256-cbc -md sha256 -pbkdf2 -iter 200000`, chosen because it works
  identically with the LibreSSL shipped in macOS and Homebrew's OpenSSL. Integrity comes from the SHA-256 of
  the plaintext, checked before anything is restored.
- The passphrase is a generic-password item in the login keychain (service `macbunker`), readable only by
  `/usr/bin/security`. The login keychain does not sync between Macs: keep the passphrase in a password
  manager or the snapshots are unreadable after a wipe.
- Changing the passphrase (`macbunker set-passphrase`) only affects new snapshots; old ones keep the old one
  until they age out.

## License

MIT
