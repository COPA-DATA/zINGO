# zINGO - zenon INstall and GO

**zINGO** is a convenience install script for running zenon Service Engine in containers. [`install_zenon.sh`](install_zenon.sh) sets up **COPA-DATA zenon Service Engine v16.0.630631** on a Debian-family Linux host: it checks/installs Docker Engine and Docker Compose, downloads and extracts the Compose package, lets you pick optional override files, and can bring the stack up.  
It's built to run interactively and unattended on industrial edge devices.

> [!NOTE]
> zINGO only prepares the **environment** for zenon Service Engine: it installs Docker, downloads and configures the Compose package, and starts the stack. It does not contain, build or modify any zenon software. The binaries that actually run are the **official COPA-DATA releases**: the Compose package comes from the COPA-DATA download server, and the container images are pulled from the official COPA-DATA registry (`copadata.azurecr.io`), unchanged.

## Requirements

- A Debian-family Linux host (Ubuntu, Debian, Raspberry Pi OS, and most vendor derivatives - see [How it detects your OS](#how-it-detects-your-os)) is required. Other distributions are not supported for prerequisite installation; with Docker/Compose already installed they can still be used via `--skip-prereqs`.
- `bash`, and either already has, or can install, `curl` and `unzip`.
- Root privileges - run it with `sudo` yourself (locally or in the `curl | sudo bash` pipeline); the script doesn't self-elevate and exits with a re-run hint if it isn't already root.

## Quick start

The examples install zINGO **v16.0.630631-1**, i.e. zenon Service Engine 16.0.630631, which this README describes. Other versions: see [Releases](https://github.com/COPA-DATA/zINGO/releases).

**One-line install, interactively** (run this from a real terminal so its prompts work):

```bash
curl -fsSL https://github.com/COPA-DATA/zINGO/releases/download/v16.0.630631-1/install_zenon.sh | sudo bash
```

**Run a local copy** (the script is already on the device, e.g. copied via `scp` or a USB stick):

```bash
chmod +x install_zenon.sh
sudo ./install_zenon.sh
```

**One-line install, fully unattended** (no prompts; needed for cloud-init, provisioning tools, CI, or anywhere else with no terminal attached):

```bash
curl -fsSL https://github.com/COPA-DATA/zINGO/releases/download/v16.0.630631-1/install_zenon.sh | sudo bash -s -- -u --accept-eula \
  --overrides "process-gateways/OPCUA/process-gateway-opcua-override.yaml" \
  --env IIOT_SERVICES_URL=https://iiot.example.com --env DEVICE_MANAGEMENT_AGENT_NAME=new_device --up
```

A version-specific URL always installs exactly that zenon Service Engine build - recommended for provisioning scripts, so every device gets the same version. To always get the newest version instead, use the `latest` URL:

```bash
curl -fsSL https://github.com/COPA-DATA/zINGO/releases/latest/download/install_zenon.sh | sudo bash
```

Each release also has a `SHA256SUMS` file; verify a downloaded copy with `sha256sum -c SHA256SUMS`.

Unattended runs must pass `--accept-eula` - see [License](#license).

## What it does

1. **Runs OS-specific pre-steps**, if the detected OS has any - see [Device/OS-specific remarks](#deviceos-specific-remarks).
2. **Checks prerequisites.** Confirms Docker Engine ≥ 28.0.0 and Docker Compose ≥ 2.36.0, plus `curl` and `unzip`, are present and current. Anything missing or outdated gets installed/upgraded from Docker's official apt repository (`download.docker.com`, see [How it detects your OS](#how-it-detects-your-os)). Distro packages that conflict with `docker-ce` (`docker.io`, `docker-compose`, `podman-docker`, `containerd`, `runc`, ...) are listed in the assessment and removed first, as recommended by Docker's install docs. apt never prompts: it waits up to 5 minutes for a dpkg lock held by another apt process (e.g. `unattended-upgrades` right after boot) and keeps locally modified config files.

   `--skip-prereqs` skips this step and assumes Docker/Compose/curl/unzip are already installed.
3. **Verifies Docker works** by pulling and running a `busybox` smoke-test container from Docker Hub (`docker run --rm busybox echo "Hello zenon!"`).
4. **Downloads and extracts the zenon Compose package** from the COPA-DATA Azure CDN into `./zenon-compose` (or `--install-dir`) - this step is real even under `--dry-run` (see [Dry runs](#dry-runs)). Downloads are retried on transient network errors. `--no-download` skips this and reuses an already-extracted directory instead, so `--env`/`--overrides` can be re-applied without downloading again.
5. **Selects Compose overrides** (device drivers, protocol gateways, logging, redundancy, zenon Network, ...), either from `--overrides` or an interactive picker. Selecting the zenon Network override together with a companion override (logging server, device management agent, remote transport) automatically uncomments that companion's matching `services:` block in the network override file (it normally requires manual editing per its own readme). When interactive, offers to open the selected file(s) in an editor first - several carry settings (certificates, ports, credentials) worth reviewing - then merges the selection into `compose.merged.yaml` via `docker compose config`.
6. **Configures `.env`**: seeds it from the package's `example.env` on first extraction, applies any `--env KEY=VALUE` values you passed (values are written literally, so `&`, `|` etc. are safe), then - only when running interactively (i.e. not `-u`/`--unattended`) - offers to open it in an editor for review. This comes after override selection because overrides often introduce new variables.
7. **Runs OS-specific post-steps**, if the detected OS has any - see [Device/OS-specific remarks](#deviceos-specific-remarks).
8. **Starts the stack** with `docker compose up -d` if `--up` was passed.
9. **Writes the install record** `/var/lib/zingo/install.env` - see [Install record](#install-record).
10. **Prints a summary** of what was installed/configured, with the exact commands to review `.env` and start the stack yourself if it wasn't auto-started.

Every step is safe to re-run.

## Dry runs

`--dry-run` only simulates the steps that would actually change the system: the Docker smoke-test container (a dry run only checks that the daemon is reachable via `docker info`), `perform_installation` (installing/upgrading Docker/Compose), applying the Beckhoff nftables ruleset, and `docker compose up -d`. It does **not** simulate downloading and extracting the Compose package, seeding `.env`, applying `--env`, or merging overrides into `compose.merged.yaml` - those happen for real, so you can inspect the exact files a real run would produce. Because of that:

- `unzip` is required even for `--dry-run` (unless you also pass `--no-download`, in which case nothing is downloaded and the check is skipped) - the installer fails fast with a clear message rather than silently falling back to a real, non-dry-run prerequisite install.
- Once the summary is shown, everything the dry run itself downloaded/extracted is deleted again (`compose.yaml`, `.env`, `compose.merged.yaml`, any override edits, the whole install directory), so no trace of the dry run is left on disk - also when it fails or is interrupted. A directory reused via `--no-download` is never touched, and a dry run refuses to download into an install directory that already contains files (it would overwrite and then delete them).
- The summary's final step prints the equivalent `-u`/`--unattended` command - with every option this run actually resolved to (`--skip-prereqs`, `--no-download`, `--install-dir`, the overrides you picked, every `--env` you passed, `--up`) - that would perform the same install for real.

## Options

```
General:
  -h, --help                  Show this help and exit.
  -v, --version               Print the zINGO version and exit.
  -d, --dry-run               Simulate: don't install packages, run containers or change the firewall.
                              The Compose package is still downloaded, then removed again at the end.
                              Prints the equivalent unattended command for a real run.
  -u, --unattended            Never prompt; accept the default answer everywhere.
                              Required when no terminal is attached (provisioning tools, cloud-init, CI).
      --log-file FILE         Also append all output to FILE (e.g. /var/log/zingo.log).

License:
      --accept-eula           Accept the "END USER LICENSE AGREEMENT FOR COPA-DATA SOFTWARE"
                              (https://www.copadata.com/en/terms-conditions/).
                              Required with --unattended; interactive runs ask instead.

Prerequisites:
      --skip-prereqs          Assume Docker/Compose/curl/unzip are installed; skip checks and installation.

Compose package:
      --no-download           Don't download the package; reuse the one already in --install-dir.
      --install-dir DIR       Directory to extract the package into (default: ./zenon-compose).
      --overrides LIST        Comma-separated override files, relative to the package dir, to merge into
                              compose.merged.yaml (device drivers, protocol gateways, logging, redundancy,
                              zenon Network, ...).
      --env KEY=VALUE         Set KEY=VALUE in '.env'. Repeatable.
      --up                    Run 'docker compose up -d' once setup is complete.

Options that take a value also accept the --option=VALUE form.

Environment:
  EDITOR                      Editor used to review files (default: nano, then vi).
```

Run `install_zenon.sh --help` for the same reference, and `install_zenon.sh --dry-run` to preview what a run would do without touching the system.

### Examples

```bash
# Preview what would happen, without installing or downloading anything
./install_zenon.sh --dry-run -u --accept-eula

# Unattended install with one override and a preset env var, then start the stack
sudo ./install_zenon.sh -u --accept-eula \
  --overrides "process-gateways/OPCUA/process-gateway-opcua-override.yaml" \
  --env ZENON_PORT=4840 --up

# Prerequisites already installed elsewhere; just fetch and configure the package
sudo ./install_zenon.sh --skip-prereqs --env ZENON_PORT=4840
```

## How it detects your OS

Docker only publishes apt repositories for `ubuntu`, `debian`, and `raspbian`. Some industrial images report a vendor `ID` in `/etc/os-release` instead - e.g. the Siemens IoT2050 sets `ID=industrial-os`. Prerequisites are installed only when `apt-get` is present; otherwise the script stops with an error (install Docker yourself and use `--skip-prereqs`). Any `ID` other than the three above is mapped onto the plain `debian` apt repo, using `VERSION_CODENAME` from `/etc/os-release`. Before any package is touched, the script verifies Docker actually publishes a `Release` file for that codename, and stops with an error if not.

## Device/OS-specific remarks

At startup, the script detects which OS it's running on (`detect_host_os`) and passes that name from the main flow to two functions:

- `run_pre_steps OS` - runs first, before the prerequisites are checked or installed;
- `run_post_steps OS` - runs after the Compose package is configured, before the stack is started.

The OS name is `<os>-<major version>`: `rt-linux` when Beckhoff's `/etc/os-release.d/666-bhf` marker file exists (RT Linux itself reports `ID=debian`), otherwise the `ID` from `/etc/os-release`; the version is the major part of `VERSION_ID`.

| OS name | Example os-release | Pre-steps | Post-steps |
|---|---|---|---|
| `rt-linux-13` (Beckhoff RT Linux 13) | `ID=debian`, `VERSION_ID="13"` + marker file | - | Add nftables ruleset |
| `industrial-os-4` (Siemens Industrial OS 4.x) | `ID=industrial-os`, `VERSION_ID="4.3.4"` | Add the official Debian repo (kept, low priority) | - |
| anything else, e.g. `debian-12`, `industrial-os-3` | | - | - |

The detected OS and every step that ran are listed in the summary. Under `--dry-run`, steps only print what they would do. To support another OS or version, add a case for its name to `run_pre_steps` / `run_post_steps`.

### Siemens Industrial OS 4.x

Industrial OS's own apt sources don't provide everything `docker-ce` depends on (e.g. nftables/iptables). As a pre-step, the script adds the official Debian repository for the OS's codename (`/etc/apt/sources.list.d/zenon-debian-official.list`, e.g. `bookworm`). It's pinned to priority 100 (`/etc/apt/preferences.d/zenon-debian-official`), so apt only takes packages from Debian that the Industrial OS sources don't offer, and never replaces Siemens' own packages. Both files are **kept** after the install, so later `apt-get upgrade` runs keep the Debian-sourced packages (e.g. nftables/iptables) up to date; thanks to the low priority, Siemens' own packages still always win. The summary lists both files. To remove the repo later: `sudo rm /etc/apt/sources.list.d/zenon-debian-official.list /etc/apt/preferences.d/zenon-debian-official && sudo apt-get update`.

### Beckhoff RT Linux 13 (CX9240, CX5340)

On Beckhoff RT Linux 13, relying on Docker to manage its own firewall rules hasn't held up in practice, and neither did Docker's experimental native nftables backend. So, as a post-step, the script installs a small **static** nftables ruleset (`/etc/nftables.conf.d/51-zenon-docker.conf`) that's independent of whatever Docker itself manages:

- **forward** chain: allows traffic between the detected default-route (WAN) interface and the Docker bridge networks (`docker0` and any `br-*` user-defined network), both directions, plus bridge-to-bridge forwarding.
- **input** chain: allows the TCP/UDP ports the *selected* compose overrides actually publish (taken from `docker compose config` rendered with `.env` applied - the same values `docker compose up` will use, whether the compose files use long or short port syntax or `${VAR:-default}` references).

These rules merge directly into Beckhoff's own pre-existing `table inet filter` `forward`/`input` base chains (no `type ... hook ...` is redeclared - that requires those chains to already exist), which is why this is scoped to Beckhoff specifically rather than applied to any nftables-only device: elsewhere, declaring a same-named table without a hook would just create inert chains the kernel never invokes. The script applies the ruleset with `systemctl reload nftables` followed by a `docker` restart; if that reload fails or `systemctl` isn't available, it warns and leaves the file written but unapplied for manual verification.

## Install record

Every successful real run (not `--dry-run`) writes `/var/lib/zingo/install.env`, recording what was installed and where - so tooling such as a future update mechanism can find an existing installation:

```bash
# Written by zINGO (install_zenon.sh) on each successful run - do not edit.
ZINGO_RECORD_FORMAT=1
ZINGO_VERSION=16.0.630631-1
SOFTWARE_VERSION=16.0.630631
INSTALLED_AT=2026-10-07T08:44:12Z
INSTALL_DIR=/home/admin/zenon-compose
COMPOSE_FILE=compose.merged.yaml
OVERRIDES=process-gateways/OPCUA/process-gateway-opcua-override.yaml
HOST_OS=debian-12
```

- `INSTALL_DIR` is absolute; `COMPOSE_FILE` is relative to it (`compose.yaml`, or `compose.merged.yaml` when overrides were merged); `OVERRIDES` is the comma-separated `--overrides` list.
- Values are shell-quoted, so read the file with `source /var/lib/zingo/install.env` in bash rather than parsing it.
- It describes the **last** run only: running zINGO again (e.g. into another `--install-dir`) replaces it. It's replaced atomically, so readers never see a half-written file.
- `ZINGO_RECORD_FORMAT` is bumped only when keys change incompatibly, so readers can check it first.

## Notes

- **Log file:** `--log-file FILE` appends everything the script prints (stdout and stderr) to `FILE`, with a timestamped header per run - useful for unattended installs nobody watches. Prompts and editors use the terminal directly, so answers you type aren't logged. If the file can't be written, the script warns and continues without it.

- **Internet access required for:** Docker's apt repository (prerequisite install), Docker Hub (the verification container), the COPA-DATA Azure CDN (the Compose package), and the COPA-DATA registry (container images pulled by Compose later).
- **Root:** required for everything except `--dry-run`. The script does not self-elevate - always invoke it with `sudo` (locally, or as `curl | sudo bash`); otherwise it exits immediately with a re-run hint.
- **Prompts under `curl | bash`:** even though stdin is consumed by the piped script, prompts are read from `/dev/tty` (the controlling terminal), so interactive installs still work when run from a real terminal. Anywhere with no terminal at all (headless provisioning, systemd units, CI) **must** pass `-u`/`--unattended` - the script checks for a terminal up front and exits immediately with an error if none is attached and `-u` wasn't given.

## Versioning

zINGO's version is the zenon Service Engine build it installs, plus a script revision: `v16.0.630631-1` is the first revision for Service Engine 16.0.630631. A script-only fix bumps the suffix (`-2`, ...); a new Service Engine build resets it to `-1`. `--version` prints it, and it's shown in the welcome dialog, the setup summary, the log file and the install record.

## Contributing

How to work on the script, test changes and release new versions is described in [CONTRIBUTING.md](CONTRIBUTING.md).

## License

- **This script** is licensed under the MIT License.
- **The zenon software and container images** it downloads and starts are **not** covered by the MIT License. They are subject to the [END USER LICENSE AGREEMENT FOR COPA-DATA SOFTWARE](https://www.copadata.com/en/terms-conditions/).

The script asks you to accept the EULA before it changes anything on the system:

- **Interactive runs** show the EULA notice and ask; the default answer is *no*. Declining exits immediately, before any package, repository or file is touched.
- **Unattended runs** (`-u`) must pass `--accept-eula`; otherwise they exit with an error. By passing it you confirm that you have read and accept the EULA.