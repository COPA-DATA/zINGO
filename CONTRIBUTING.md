# Working on zINGO

How to work on this repository: setting up, testing changes, the conventions the script follows, and how versions are released - for a new zenon Service Engine patch as well as for fixes to already-released versions.

User documentation (what the script does, its options) is in [README.md](README.md).

## Contents of the repository

| File | Purpose |
|---|---|
| `install_zenon.sh` | The installer itself - the only file users download. |
| `README.md` | User documentation: what the script does, options, OS-specific behavior. |
| `CONTRIBUTING.md` | This file: how to work on the repository and release it. |
| `LICENSE` | MIT license for the script (not for the zenon software it installs). |
| `.github/workflows/release.yml` | Checks on every pull request/push; publishes the GitHub Release for `v*` tags. |

## Getting started

```bash
git clone https://github.com/COPA-DATA/zINGO.git
cd zINGO
```

You need:

- **bash ≥ 4** and **[ShellCheck](https://www.shellcheck.net/)** for the local checks. On Windows, Git Bash works for linting and dry runs (`pip install shellcheck-py` provides ShellCheck).
- **A Debian-family Linux machine with Docker** (VM or real device) for anything beyond a dry run.
- Ideally access to the **edge devices with OS-specific steps** (see [Testing](#testing)).

## Making a change

1. Create a branch from `main` (or from `release/<build>` when fixing an older version - see [How to: fix an older version](#how-to-fix-an-older-version)).
2. Change the script, and keep the documentation in sync (see [Keep in sync](#keep-in-sync)).
3. Run the [local checks](#local-checks) and [test](#testing) on the affected devices.
4. Open a pull request against `main`. The *Lint & smoke test* check must pass before merging.
5. Releasing is a separate step - see [Releasing](#releasing).

### Local checks

The same checks the pipeline runs on every pull request:

```bash
bash -n install_zenon.sh
shellcheck install_zenon.sh
./install_zenon.sh --version
./install_zenon.sh --help > /dev/null

# Dry run: downloads and extracts the real Compose package, merges an override,
# then removes everything again. Needs no root and changes nothing on the system.
./install_zenon.sh --dry-run -u --accept-eula --skip-prereqs \
  --install-dir /tmp/zenon-compose \
  --overrides "process-gateways/OPCUA/process-gateway-opcua-override.yaml"
```

Without Docker (e.g. on Windows), the dry run skips the merge with a warning; the pipeline runs it with Docker.

### Testing

The pipeline only covers lint and a dry run on Ubuntu. Before a release, test real installs on the devices your change affects:

| Device / OS | Why |
|---|---|
| Debian 12/13 or Ubuntu (VM is fine) | Default path: prerequisite install, download, overrides, `--up` |
| Beckhoff RT Linux 13 (CX9240, CX5340) | Post-step: static nftables ruleset |
| Siemens Industrial OS 4.x (IOT2050) | Pre-step: official Debian repository |

Run both an **interactive** install and an **unattended** one (`-u --accept-eula ...`), and re-run once on the same device - every step must be safe to re-run.

### Conventions in `install_zenon.sh`

- **Structure:** constants at the top, then sections separated by `# ===` banners; `main` at the bottom calls the steps in order. The last line is `main "$@"`, so a truncated `curl | bash` download never runs a partial script.
- **Output:** use `log_info` / `log_ok` / `log_warn` / `log_error` for log lines, `show_info` / `show_msg` / `show_error` for titled notices, and `ask_yesno` for questions. Never `read` from stdin directly - prompts read from `/dev/tty` (stdin is the script itself under `curl | bash`).
- **Unattended mode:** every prompt must have a default that `ask_yesno` takes automatically under `-u`. New choices need a command-line option so unattended runs can set them.
- **Dry run:** anything that changes the system (packages, containers, firewall, files outside the install directory) must check `DRY_RUN` and only print what it would do.
- **Errors:** `set -eo pipefail` is active, but functions called as `step || exit 1` run without `set -e`, so check commands that can fail explicitly (`|| return 1`).
- **Temporary files:** create them with `mktemp` and `register_cleanup` them; they're removed on exit, also on errors and Ctrl-C.
- **Editing files in place:** write to a temp file first, then `cat tmp > file` only if that succeeded - this keeps owner and permissions and never truncates the file on failure.
- **OS-specific behavior:** add a case to `run_pre_steps` / `run_post_steps` instead of `if` checks spread through the script, and document it in the README's *Device/OS-specific remarks*.

### Keep in sync

| When you change... | ...also update |
|---|---|
| An option | `parse_args`, `print_help`, the README's *Options* block, and `build_equivalent_unattended_command` (if the option should carry over from a dry run) |
| A step in `main` | `TOTAL_STEPS` and the README's *What it does* list |
| An OS-specific step | The README's *Device/OS-specific remarks* table and section |
| The install record keys | The README's *Install record* section; bump `ZINGO_RECORD_FORMAT` on incompatible changes |

## Versioning

zINGO's version is the zenon Service Engine build it installs, plus a script revision:

```
v16.0.630631-1
 └────┬─────┘ └─ script revision: -1 for a new zenon build, -2, -3, ... for script-only fixes
  zenon Service Engine build
```

In `install_zenon.sh`:

```bash
SOFTWARE_VERSION="16.0.630631"          # zenon Service Engine build
ZINGO_VERSION="${SOFTWARE_VERSION}-1"   # the "-1" is the script revision
```

## Branches, tags and releases

There is always exactly **one** `install_zenon.sh`. Different zenon builds are not separate files; each one is a **Git tag** - a frozen snapshot of the repository pointing at that build.

```
main ──●────────●────────●────────●──────────▶   newest zenon build
       │        │        │        │
  v16.0.630631-1│  v16.0.640000-1 │
          v16.0.630631-2    v16.0.650000-1
       │
       └── release/16.0.630631 ──●──▶   maintenance branch, only if needed
```

| Element | Rule |
|---|---|
| `main` | Always the script for the **newest** zenon build. Changes only via pull request. |
| Tag `v<build>-<revision>` | One per published version. Never moved or deleted. |
| GitHub Release | One per tag, created by the release workflow, with `install_zenon.sh` and `SHA256SUMS` attached. |
| `release/<build>` | Maintenance branch for an **older** zenon build. Created only when that build needs a fix after a newer build is on `main`. |

### Download URLs

Users download release assets, never files from a branch (a branch URL changes with every commit):

```bash
# A specific version - reproducible, recommended for provisioning scripts
https://github.com/COPA-DATA/zINGO/releases/download/v16.0.630631-1/install_zenon.sh

# Newest release
https://github.com/COPA-DATA/zINGO/releases/latest/download/install_zenon.sh
```

The README's examples use the **version-specific** URL of the version it describes, so the README of every tag installs exactly that version. The script prints its own version-specific URL (`SCRIPT_URL`) in re-run hints and in the unattended command a dry run suggests, for the same reason.

## Releasing

### Release workflow

`.github/workflows/release.yml` runs on every pushed tag `v*` (steps 1-3 also run on every pull request and push to `main` / `release/**`):

1. **Lint:** `bash -n` and `shellcheck` on `install_zenon.sh`.
2. **Version check** (tags only): the tag must equal the version `install_zenon.sh --version` reports.
3. **Smoke test:** `--version`, `--help`, and a real dry run on the Ubuntu runner. This downloads the actual Compose package, so a broken `COMPOSE_PKG_URL` fails the build.
4. **Publish:** create the GitHub Release with `install_zenon.sh`, `SHA256SUMS` and generated release notes. The release is marked **latest only if its tag is the highest version** (see [The "latest" release](#the-latest-release)).

The workflow uses only the built-in `GITHUB_TOKEN` (no secrets to set up). Releases are titled `zINGO v<version> (zenon Service Engine <build>)`; their notes contain the version-specific install command plus GitHub's generated list of changes since the previous tag.

If the workflow fails on a tag (e.g. the version check), fix the cause, then delete and re-push the tag - this is only safe as long as no release was published for it (with the tag ruleset active, this needs a ruleset bypass by an admin):

```bash
git push --delete origin v16.0.640000-1 && git tag -d v16.0.640000-1
# fix, commit, push, then tag again
```

### How to: release a new zenon patch

Done on `main`.

1. Create a branch, e.g. `zenon-16.0.640000`.
2. In `install_zenon.sh`, update:
   - `SOFTWARE_VERSION`
   - `COMPOSE_PKG_URL` (the new build's Compose package download link)
   - the script revision in `ZINGO_VERSION` back to `-1`
   - the version in the header comment (lines 4-5)
   - `REQUIRED_DOCKER_VERSION` / `REQUIRED_COMPOSE_VERSION`, if the new build requires newer versions
3. In `README.md`, update every version mention: the intro paragraph, the version line and URLs in *Quick start*, the *Install record* example and the *Versioning* section. Searching for the old build number (e.g. `630631`) finds them all.
4. Run the [local checks](#local-checks) and [test](#testing) on real devices.
5. Open a pull request; merge once the checks pass.
6. Tag and push - the release workflow publishes the release:

   ```bash
   git switch main && git pull
   git tag v16.0.640000-1
   git push origin v16.0.640000-1
   ```

### How to: fix the current version (script-only)

Same as a new zenon patch, but only bump the script revision (`-1` → `-2`) in `ZINGO_VERSION`, the header comment and the README's version mentions, then tag `v16.0.640000-2`.

### How to: fix an older version

For a zenon build that is no longer on `main`, e.g. `16.0.630631` while `main` is at `16.0.640000`:

1. If the bug also exists on `main`, **fix it on `main` first** (normal pull request), so the newest script never misses a fix.
2. Create the maintenance branch from the old version's last tag - only the first time; afterwards just switch to it:

   ```bash
   git switch -c release/16.0.630631 v16.0.630631-1
   # later fixes: git switch release/16.0.630631 && git pull
   ```

3. Apply the fix - preferably by copying the commit from `main`:

   ```bash
   git cherry-pick <commit-sha-from-main>
   ```

4. Bump the script revision (`-1` → `-2`) in `ZINGO_VERSION`, the header comment and the README's version mentions, and commit.
5. Push the branch, then tag and push:

   ```bash
   git push -u origin release/16.0.630631
   git tag v16.0.630631-2
   git push origin v16.0.630631-2
   ```

The old release `v16.0.630631-1` stays untouched, so existing links to it keep working.

### The "latest" release

GitHub marks the most recently *published* release as "Latest" by default. Publishing `v16.0.630631-2` after `v16.0.640000-1` would then make `releases/latest/download/install_zenon.sh` serve the **old** zenon build. The release workflow therefore passes `--latest=false` for any tag that isn't the highest version. When publishing a release by hand, untick **"Set as the latest release"** for maintenance releases.

## Repository settings

- **Branch protection / ruleset for `main` and `release/**`:** require a pull request and the *Lint & smoke test* check to pass.
- **Tag ruleset for `v*`:** block updates and deletions, so a published version can't be moved. (Restrict creation to maintainers if needed.)
- **Immutable releases:** enable, so the assets of a published release can't be replaced.
- **Actions → General → Workflow permissions:** "Read repository contents" is enough as default; the release job requests `contents: write` itself.

## Install record and future updates

Every real run writes `/var/lib/zingo/install.env` with `ZINGO_VERSION`, `SOFTWARE_VERSION`, `INSTALL_DIR`, `COMPOSE_FILE`, `OVERRIDES` and more (see the README's *Install record* section). A future update mechanism can compare `ZINGO_VERSION` against the newest release from:

```
https://api.github.com/repos/COPA-DATA/zINGO/releases/latest
```

This is only reliable if the "latest" rule above is followed. If keys in the install record ever change incompatibly, bump `ZINGO_RECORD_FORMAT` in `write_install_record`.
