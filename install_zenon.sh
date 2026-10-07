#!/usr/bin/env bash

# ==============================================================================
# zINGO - zenon INstall and GO, v16.0.630631-1
# Convenience install script for COPA-DATA zenon Service Engine v16.0.630631 in containers
# Requires: Docker Engine >= 28.0.0, Docker Compose >= 2.36.0
#
# Runs as a one-line install on Debian-family industrial edge devices:
#
#   curl -fsSL https://github.com/COPA-DATA/zINGO/releases/latest/download/install_zenon.sh | sudo bash                                      # interactive
#   curl -fsSL https://github.com/COPA-DATA/zINGO/releases/latest/download/install_zenon.sh | sudo bash -s -- -u --accept-eula --up   # unattended
#
# Run with -h/--help for the full list of options.
#
# This script is licensed under the MIT License. The zenon software and container
# images it installs are subject to the END USER LICENSE AGREEMENT FOR COPA-DATA
# SOFTWARE, which must be accepted before installing (see --accept-eula).
# ==============================================================================

set -eo pipefail

# ==============================================================================
# Constants
# ==============================================================================

PROJECT_NAME="zINGO - zenon INstall and GO"
SOFTWARE_NAME="COPA-DATA zenon Service Engine"
SOFTWARE_VERSION="16.0.630631"
# zINGO's own version: the Service Engine build it installs, plus a script revision.
ZINGO_VERSION="${SOFTWARE_VERSION}-1"
# This exact version's release asset - used in printed re-run commands, so they reinstall the same version.
SCRIPT_URL="https://github.com/COPA-DATA/zINGO/releases/download/v${ZINGO_VERSION}/install_zenon.sh"

REQUIRED_DOCKER_VERSION="28.0.0"
REQUIRED_COMPOSE_VERSION="2.36.0"

COMPOSE_PKG_URL="https://copadatawebsiteassets.azureedge.net/additional/520de9fe-189e-42be-9d09-6e2fcf14706d?sv=2014-02-14&sr=b&sig=qbVa4fYzSfjAYP6Ui%2BoVj%2BS4mpD8lv8XUbtNtVDNo14%3D&st=2019-12-31T23%3A00%3A00Z&se=2999-12-31T23%3A00%3A00Z&sp=r&rscd=attachment%3Bfilename%3DServiceEngine-16.0.630631-LinuxContainerComposePackage.zip"

EULA_NAME="END USER LICENSE AGREEMENT FOR COPA-DATA SOFTWARE"
EULA_URL="https://www.copadata.com/en/terms-conditions/"

DEFAULT_INSTALL_DIR="zenon-compose"
NETWORK_OVERRIDE="zenon-network/zenon-network-override.yaml"
BECKHOFF_MARKER="/etc/os-release.d/666-bhf"
DEBIAN_REPO_LIST="/etc/apt/sources.list.d/zenon-debian-official.list"
DEBIAN_REPO_PIN="/etc/apt/preferences.d/zenon-debian-official"
NFT_RULES_FILE="/etc/nftables.conf.d/51-zenon-docker.conf"
# Records what the last real run installed and where - for a future update mechanism.
INSTALL_RECORD="/var/lib/zingo/install.env"

# Distro packages that conflict with docker-ce (per Docker's own install docs).
CONFLICTING_PACKAGE_CANDIDATES=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)

TOTAL_STEPS=7

# ==============================================================================
# Options (set by parse_args)
# ==============================================================================

ORIGINAL_ARGS=()
DRY_RUN=false
UNATTENDED=false
SKIP_PREREQS=false
NO_DOWNLOAD=false
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
OVERRIDES_ARG=""
OVERRIDES_SET=false
ENV_KV=()
AUTO_START=false
ACCEPT_EULA=false
LOG_FILE=""

# ==============================================================================
# Run state (reported in the summary)
# ==============================================================================

DOCKER_STATUS_SUMMARY=""
PACKAGE_SOURCES_SUMMARY="None (package sources were not modified)"
COMPOSE_PKG_DIR=""
MERGED=false
DOCKER_VER=""
COMPOSE_VER=""
PREREQ_REPORT=""
PUBLISHED_TCP_PORTS=()
PUBLISHED_UDP_PORTS=()
SELECTED_OVERRIDES=()
CONFLICTING_PACKAGES=()
REMOVED_PACKAGES=()
FRESH_DOWNLOAD=false
ENV_SEEDED=false
INSTALL_RECORD_WRITTEN=false
# Dry run only: editor changes, carried into (or flagged next to) the equivalent unattended command.
DRY_RUN_ENV_EDITS=()
DRY_RUN_ENV_REMOVED=()
DRY_RUN_EDITED_OVERRIDES=()
OS_ID="unknown"
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY_NAME=""
HOST_OS="debian"
HOST_STEPS=()
EULA_ACCEPTED_VIA=""
CURRENT_STEP=0

# ==============================================================================
# Command-line parsing
# ==============================================================================

print_help() {
    cat <<EOF
${PROJECT_NAME} v${ZINGO_VERSION}

Usage: install_zenon.sh [OPTIONS]

Installs ${SOFTWARE_NAME} v${SOFTWARE_VERSION}
(requires Docker Engine >= ${REQUIRED_DOCKER_VERSION} and Docker Compose >= ${REQUIRED_COMPOSE_VERSION}).

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
      --accept-eula           Accept the "${EULA_NAME}"
                              (${EULA_URL}).
                              Required with --unattended; interactive runs ask instead.

Prerequisites:
      --skip-prereqs          Assume Docker/Compose/curl/unzip are installed; skip checks and installation.

Compose package:
      --no-download           Don't download the package; reuse the one already in --install-dir.
      --install-dir DIR       Directory to extract the package into (default: ./${DEFAULT_INSTALL_DIR}).
      --overrides LIST        Comma-separated override files, relative to the package dir, to merge into
                              compose.merged.yaml (device drivers, protocol gateways, logging, redundancy,
                              zenon Network, ...).
      --env KEY=VALUE         Set KEY=VALUE in '.env'. Repeatable.
      --up                    Run 'docker compose up -d' once setup is complete.

Options that take a value also accept the --option=VALUE form.

Environment:
  EDITOR                      Editor used to review files (default: nano, then vi).

Examples:
  One-line interactive install from a real terminal:
    curl -fsSL ${SCRIPT_URL} | sudo bash

  Unattended install with an override and a preset env var:
    curl -fsSL ${SCRIPT_URL} | sudo bash -s -- -u --accept-eula \\
      --overrides "process-gateways/OPCUA/process-gateway-opcua-override.yaml" \\
      --env IIOT_SERVICES_URL=https://iiot.example.com --env DEVICE_MANAGEMENT_AGENT_NAME=new_device --up
EOF
}

# require_arg OPTION VALUE -> exits with a usage error when VALUE is missing.
require_arg() {
    if [ -z "$2" ] || [[ "$2" == -* ]]; then
        echo "Option $1 requires a value." >&2
        echo >&2
        print_help >&2
        exit 1
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--dry-run)                 DRY_RUN=true ;;
            -u|--unattended)              UNATTENDED=true ;;
            --skip-prereqs)               SKIP_PREREQS=true ;;
            --no-download)                NO_DOWNLOAD=true ;;
            --up)                         AUTO_START=true ;;
            --accept-eula)                ACCEPT_EULA=true ;;
            -v|--version)
                echo "${PROJECT_NAME} v${ZINGO_VERSION} (installs ${SOFTWARE_NAME} v${SOFTWARE_VERSION})"
                exit 0
                ;;
            -h|--help)
                print_help
                exit 0
                ;;
            --install-dir)
                require_arg "$1" "${2-}"
                INSTALL_DIR="$2"
                shift
                ;;
            --install-dir=*)
                require_arg "--install-dir" "${1#*=}"
                INSTALL_DIR="${1#*=}"
                ;;
            --overrides)
                require_arg "$1" "${2-}"
                OVERRIDES_ARG="$2"
                OVERRIDES_SET=true
                shift
                ;;
            --overrides=*)
                # An empty value is allowed here: it explicitly selects no overrides.
                OVERRIDES_ARG="${1#*=}"
                OVERRIDES_SET=true
                ;;
            --env)
                require_arg "$1" "${2-}"
                ENV_KV+=("$2")
                shift
                ;;
            --log-file)
                require_arg "$1" "${2-}"
                LOG_FILE="$2"
                shift
                ;;
            --log-file=*)
                require_arg "--log-file" "${1#*=}"
                LOG_FILE="${1#*=}"
                ;;
            --env=*)
                require_arg "--env" "${1#*=}"
                ENV_KV+=("${1#*=}")
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Unknown option: $1" >&2
                echo >&2
                print_help >&2
                exit 1
                ;;
        esac
        shift
    done
}

# ==============================================================================
# Generic helpers
# ==============================================================================

# Shell-quotes the arguments so they can be pasted back into a command line.
quote_args() {
    [ $# -gt 0 ] || return 0
    local quoted
    quoted="$(printf '%q ' "$@")"
    printf '%s' "${quoted% }"
}

# join_by SEPARATOR ITEM... -> prints the items joined by SEPARATOR.
join_by() {
    local sep="$1"
    shift
    [ $# -gt 0 ] || return 0
    printf '%s' "$1"
    shift
    printf '%s' "${@/#/$sep}"
}

# in_array ITEM ELEMENT... -> 0 if ITEM is one of the elements.
in_array() {
    local needle="$1" x
    shift
    for x in "$@"; do
        [ "$x" = "$needle" ] && return 0
    done
    return 1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Paths removed on exit (success, error or Ctrl-C): temp files, partial downloads, dry-run output.
CLEANUP_PATHS=()

register_cleanup() {
    CLEANUP_PATHS+=("$1")
}

run_cleanup() {
    local p
    for p in "${CLEANUP_PATHS[@]}"; do
        case "$p" in
            ""|/) continue ;;
        esac
        rm -rf -- "$p"
    done
}

# ==============================================================================
# Terminal output & prompts
# ==============================================================================

log_info()  { printf '%s\n' "$*"; }
log_ok()    { printf '[ OK ] %s\n' "$*"; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[FAIL] %s\n' "$*" >&2; }

log_step() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    printf '\n[%d/%d] %s\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$*"
}

wait_for_enter() {
    if [ "$UNATTENDED" = false ]; then
        echo
        read -rp "Press Enter to continue..." < /dev/tty || true
    fi
}

# show_info TITLE TEXT -> a titled notice that doesn't need acknowledgment; TEXT may contain \n escapes.
show_info()  { printf '\n=== %s ===\n%b\n' "$1" "$2"; }
# A notice that waits for Enter when interactive.
show_msg()   { show_info "$@"; wait_for_enter; }
# Like show_msg, but on stderr.
show_error() { show_info "$@" >&2; wait_for_enter; }

# /dev/tty is the controlling terminal even when stdin (fd0) is a pipe.
has_tty() {
    # -r/-w lie when there's no real controlling terminal; try opening it.
    { : < /dev/tty; } 2>/dev/null && { : > /dev/tty; } 2>/dev/null
}

# ask_yesno TITLE DETAILS QUESTION [DEFAULT=false] -> 0=yes/1=no.
# Auto-resolves to DEFAULT when unattended. DETAILS may be empty.
ask_yesno() {
    local title="$1" details="$2" question="$3" default="${4:-false}"

    if [ "$UNATTENDED" = true ]; then
        local decision="no"
        [ "$default" = true ] && decision="yes"
        log_info "[auto] ${title}: ${question} -> ${decision}"
        [ "$default" = true ]
        return
    fi

    printf '\n=== %s ===\n' "$title"
    if [ -n "$details" ]; then
        printf '%b\n' "$details"
    fi

    local suffix="[y/N]"
    [ "$default" = true ] && suffix="[Y/n]"
    local yn
    while true; do
        yn=""
        if ! read -rp "${question} ${suffix} " yn < /dev/tty; then
            [ "$default" = true ]
            return
        fi
        case "$yn" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            "")    [ "$default" = true ]; return ;;
            *)     echo "Please answer yes (y) or no (n)." ;;
        esac
    done
}

# Opens $1 in $EDITOR (or nano, then vi) on the controlling terminal; returns 1 if none found.
open_in_editor() {
    local editor_cmd="${EDITOR:-nano}"
    if ! command -v "$editor_cmd" >/dev/null 2>&1; then
        command -v vi >/dev/null 2>&1 || return 1
        editor_cmd="vi"
    fi
    "$editor_cmd" "$1" < /dev/tty > /dev/tty 2>&1
}

# ==============================================================================
# Preconditions
# ==============================================================================

# No self-elevation: must already be root (run via sudo, or "curl | sudo bash").
require_root() {
    if [ "$EUID" -ne 0 ] && [ "$DRY_RUN" = false ]; then
        log_error "Root privileges are required for this script."
        echo "Re-run with sudo, e.g.:" >&2
        echo "  curl -fsSL ${SCRIPT_URL} | sudo bash -s -- $(quote_args "${ORIGINAL_ARGS[@]}")" >&2
        exit 1
    fi
}

# No terminal and no -u means nobody can answer the prompts - fail fast instead of
# guessing. Past this point, UNATTENDED=false implies a terminal is attached.
require_terminal_or_unattended() {
    if [ "$UNATTENDED" = false ] && ! has_tty; then
        log_error "No terminal attached; re-run with -u/--unattended for a non-interactive install, e.g.:"
        echo "  curl -fsSL ${SCRIPT_URL} | sudo bash -s -- $(quote_args -u "${ORIGINAL_ARGS[@]}")" >&2
        exit 1
    fi
}

# --log-file: tees stdout and stderr (kept separate) into LOG_FILE. Prompts and editors
# use /dev/tty directly, so they keep working; typed answers aren't logged.
start_logging() {
    [ -n "$LOG_FILE" ] || return 0
    if ! { mkdir -p "$(dirname "$LOG_FILE")" && printf '\n===== %s - %s v%s %s =====\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$PROJECT_NAME" "$ZINGO_VERSION" "$(quote_args "${ORIGINAL_ARGS[@]}")" >> "$LOG_FILE"; } 2>/dev/null; then
        log_warn "Cannot write to log file '${LOG_FILE}'; continuing without it."
        return 0
    fi
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
}

# ==============================================================================
# License (EULA)
# ==============================================================================

# Unattended runs must pass --accept-eula; interactive runs are asked (default: no).
# Runs before anything on the system is changed, so declining leaves no trace.
require_eula_acceptance() {
    local notice="The ${SOFTWARE_NAME} software and container images installed by this\nscript are subject to the \"${EULA_NAME}\"\n${EULA_URL}\n\n(This installer script itself is licensed under the MIT License.)"

    if [ "$ACCEPT_EULA" = true ]; then
        EULA_ACCEPTED_VIA="--accept-eula"
        log_info "EULA accepted via --accept-eula."
        return 0
    fi

    if [ "$UNATTENDED" = true ]; then
        show_error "EULA Not Accepted" "${notice}\n\nUnattended installs must accept the EULA explicitly. After reading it, re-run with --accept-eula, e.g.:\n  curl -fsSL ${SCRIPT_URL} | sudo bash -s -- $(quote_args "${ORIGINAL_ARGS[@]}" --accept-eula)"
        exit 1
    fi

    if ask_yesno "License Agreement" "$notice" "Have you read and do you accept the EULA?" false; then
        EULA_ACCEPTED_VIA="interactive prompt"
        log_ok "EULA accepted."
    else
        show_error "EULA Not Accepted" "The EULA must be accepted to install ${SOFTWARE_NAME}.\nExiting - nothing on this system was changed."
        exit 1
    fi
}

# ==============================================================================
# Version & Docker inspection
# ==============================================================================

# Extracts the first X.Y[.Z] from arbitrary version output ("Docker version 28.1.1, build ...").
clean_version() {
    printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1 || true
}

# Returns 0 if $1 >= $2, 1 otherwise
version_gte() {
    local v1 v2
    v1="$(clean_version "$1")"
    v2="$(clean_version "$2")"
    [ -n "$v1" ] && [ -n "$v2" ] || return 1
    [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -n1)" = "$v2" ]
}

has_compose() {
    command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1
}

get_installed_docker_version() {
    command -v docker >/dev/null 2>&1 || return 0
    local raw
    # The server version needs a running daemon; fall back to the client version otherwise.
    raw="$(docker version --format '{{.Server.Version}}' 2>/dev/null)" || raw=""
    if [ -z "$raw" ]; then
        raw="$(docker --version 2>/dev/null)" || raw=""
    fi
    clean_version "$raw"
}

get_installed_compose_version() {
    has_compose || return 0
    clean_version "$(docker compose version --short 2>/dev/null || true)"
}

# Sets global CONFLICTING_PACKAGES to the installed distro packages that clash with docker-ce.
find_conflicting_docker_packages() {
    CONFLICTING_PACKAGES=()
    command -v dpkg-query >/dev/null 2>&1 || return 0
    local pkg status
    for pkg in "${CONFLICTING_PACKAGE_CANDIDATES[@]}"; do
        status="$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" || status=""
        if [ "$status" = "install ok installed" ]; then
            CONFLICTING_PACKAGES+=("$pkg")
        fi
    done
}

# Reads ID/VERSION_ID/VERSION_CODENAME/PRETTY_NAME from /etc/os-release in a
# subshell, so a malformed file can't abort the installer.
read_os_release() {
    if [ ! -r /etc/os-release ]; then
        OS_PRETTY_NAME="unknown (no /etc/os-release)"
        return 0
    fi
    local values
    values="$(
        set +e
        # shellcheck disable=SC1091
        . /etc/os-release >/dev/null 2>&1
        printf '%s\n%s\n%s\n%s\n' "${ID:-unknown}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}" "${PRETTY_NAME:-}"
    )" || true
    { read -r OS_ID; read -r OS_VERSION_ID; read -r OS_CODENAME; read -r OS_PRETTY_NAME; } <<< "$values" || true
    OS_ID="${OS_ID:-unknown}"
    OS_PRETTY_NAME="${OS_PRETTY_NAME:-$OS_ID}"
}

# version_status LABEL CURRENT REQUIRED -> one line of the prerequisite report.
version_status() {
    local label="$1" current="$2" required="$3"
    if [ -z "$current" ]; then
        echo "  ${label}: missing (requires >= ${required})"
    elif version_gte "$current" "$required"; then
        echo "  ${label}: v${current} (OK)"
    else
        echo "  ${label}: v${current} (update required, >= ${required})"
    fi
}

# check_prereqs [TOOL...] -> sets DOCKER_VER, COMPOSE_VER and PREREQ_REPORT;
# returns 0 when Docker/Compose meet the minimums and every TOOL is installed.
check_prereqs() {
    local ok=true tool
    DOCKER_VER="$(get_installed_docker_version)"
    COMPOSE_VER="$(get_installed_compose_version)"
    PREREQ_REPORT="$(version_status "Docker Engine" "$DOCKER_VER" "$REQUIRED_DOCKER_VERSION")"$'\n'
    PREREQ_REPORT+="$(version_status "Docker Compose" "$COMPOSE_VER" "$REQUIRED_COMPOSE_VERSION")"
    version_gte "$DOCKER_VER" "$REQUIRED_DOCKER_VERSION" || ok=false
    version_gte "$COMPOSE_VER" "$REQUIRED_COMPOSE_VERSION" || ok=false
    for tool in "$@"; do
        if command -v "$tool" >/dev/null 2>&1; then
            PREREQ_REPORT+=$'\n'"  ${tool}: OK"
        else
            PREREQ_REPORT+=$'\n'"  ${tool}: missing"
            ok=false
        fi
    done
    [ "$ok" = true ]
}

# ==============================================================================
# Prerequisite installation (Debian family only)
# ==============================================================================

# Maps the detected distro onto the closest Docker apt repo (ubuntu/debian/raspbian, else debian).
resolve_docker_apt_distro() {
    case "$OS_ID" in
        ubuntu)          echo "ubuntu" ;;
        debian|raspbian) echo "$OS_ID" ;;
        *)               echo "debian" ;;
    esac
}

# Never prompts: waits for a dpkg lock held by e.g. unattended-upgrades (common right
# after boot) instead of failing, and keeps locally modified config files.
apt_get() {
    apt-get -y -o DPkg::Lock::Timeout=300 \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

remove_conflicting_docker_packages() {
    find_conflicting_docker_packages
    [ ${#CONFLICTING_PACKAGES[@]} -gt 0 ] || return 0
    log_warn "Removing distro packages that conflict with docker-ce: ${CONFLICTING_PACKAGES[*]}"
    apt_get remove "${CONFLICTING_PACKAGES[@]}"
    REMOVED_PACKAGES=("${CONFLICTING_PACKAGES[@]}")
}

perform_installation() {
    show_info "Installing Prerequisites" "Installing/upgrading Docker Engine, Docker Compose, curl and unzip.\nThis may take a few minutes."

    export DEBIAN_FRONTEND=noninteractive

    # curl is needed to set up the Docker repo below. It's normally already there
    # ("curl | sudo bash"), so only then pay for an extra 'apt-get update'.
    if ! command -v curl >/dev/null 2>&1; then
        apt_get update
        apt_get install ca-certificates curl
    fi

    local repo_distro codename="$OS_CODENAME"
    repo_distro="$(resolve_docker_apt_distro)"

    # Verify Docker publishes this codename before touching any installed packages.
    if [ -z "$codename" ] || ! curl -fsSL --connect-timeout 15 -o /dev/null \
        "https://download.docker.com/linux/${repo_distro}/dists/${codename}/Release"; then
        show_error "No Docker Repository" "No network connection to Docker apt repo or Docker does not publish repository for '${repo_distro}/${codename:-<unknown>}' (OS '${OS_ID}').\n\nInstall Docker Engine >= ${REQUIRED_DOCKER_VERSION} and Compose >= ${REQUIRED_COMPOSE_VERSION} manually, then re-run with --skip-prereqs."
        exit 1
    fi

    remove_conflicting_docker_packages

    # apt reads the ASCII-armored key directly, so no gnupg is needed.
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${repo_distro}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${repo_distro} ${codename} stable" \
        > /etc/apt/sources.list.d/docker.list

    # One update for all repos: the OS's own, Docker's, and any added by pre-steps.
    apt_get update
    apt_get install ca-certificates unzip \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    PACKAGE_SOURCES_SUMMARY="/etc/apt/sources.list.d/docker.list & /etc/apt/keyrings/docker.asc (repo: ${repo_distro}/${codename})"

    systemctl enable --now docker || true

    if check_prereqs unzip; then
        DOCKER_STATUS_SUMMARY="Installed / upgraded (Docker v${DOCKER_VER}, Compose v${COMPOSE_VER})"
        show_info "Installation Successful" "$PREREQ_REPORT"
    else
        show_error "Version Verification Failed" "${PREREQ_REPORT}\nThe installed versions don't meet the required minimums.\nPlease check the configured package repositories."
        exit 1
    fi
}

ensure_prerequisites() {
    if [ "$SKIP_PREREQS" = true ]; then
        DOCKER_STATUS_SUMMARY="Skipped (--skip-prereqs; assumed installed)"
        PACKAGE_SOURCES_SUMMARY="None (--skip-prereqs)"
        log_info "Skipping prerequisite checks and installation (--skip-prereqs)."
        return 0
    fi

    local all_ok=false report
    check_prereqs curl unzip && all_ok=true
    report="$PREREQ_REPORT"
    if [ "$all_ok" = false ]; then
        find_conflicting_docker_packages
        if [ ${#CONFLICTING_PACKAGES[@]} -gt 0 ]; then
            report+=$'\n'"  Replaced by docker-ce: ${CONFLICTING_PACKAGES[*]}"
        fi
    fi

    local welcome="Welcome to ${PROJECT_NAME}\nInstalling ${SOFTWARE_NAME} v${SOFTWARE_VERSION}\n\n"
    welcome+="Internet sources used during setup:\n"
    welcome+="  1. Docker repositories (download.docker.com) -> Engine & Compose\n"
    welcome+="  2. Docker Hub (registry-1.docker.io)         -> verification container\n"
    welcome+="  3. COPA-DATA Azure CDN (azureedge.net)       -> Compose ZIP package\n"
    welcome+="  4. COPA-DATA Registry (copadata.azurecr.io)  -> container images\n\n"
    welcome+="System prerequisites:\n${report}\n"

    local title="${PROJECT_NAME} v${ZINGO_VERSION}"

    # A dry run still downloads/extracts for real, so unzip is required;
    # fail fast instead of falling through to a real prerequisite install.
    if [ "$DRY_RUN" = true ] && [ "$NO_DOWNLOAD" = false ] && ! command -v unzip >/dev/null 2>&1; then
        show_error "Dry Run Cannot Proceed" "${welcome}\n[DRY RUN] A dry run still downloads and extracts the real Compose package so you can preview the result, which requires 'unzip'.\n\nInstall 'unzip' and re-run, or pass --no-download to skip fetching the package."
        exit 1
    fi

    if [ "$DRY_RUN" = true ]; then
        DOCKER_STATUS_SUMMARY="Simulated (dry run - no system changes made)"
        PACKAGE_SOURCES_SUMMARY="Simulated (dry run)"
        show_msg "$title" "${welcome}\n[DRY RUN] Nothing will be installed; continuing with the simulated setup."
        return 0
    fi

    if [ "$all_ok" = true ]; then
        DOCKER_STATUS_SUMMARY="Already OK (Docker v${DOCKER_VER}, Compose v${COMPOSE_VER})"
        PACKAGE_SOURCES_SUMMARY="None (package sources were already up to date)"
        show_msg "$title" "${welcome}\nAll prerequisites are in place."
        return 0
    fi

    if ! command -v apt-get >/dev/null 2>&1; then
        show_error "Unsupported System" "${welcome}\nPrerequisites can only be installed on Debian-family systems (apt-get not found).\n\nInstall Docker Engine >= ${REQUIRED_DOCKER_VERSION}, Compose >= ${REQUIRED_COMPOSE_VERSION}, curl and unzip manually, then re-run with --skip-prereqs."
        exit 1
    fi

    if ! ask_yesno "$title" "${welcome}\nOne or more prerequisites are missing or outdated." \
        "Install/update Docker, Compose, curl and unzip now?" true; then
        show_error "Installation Aborted" "Cannot proceed without the required system prerequisites."
        exit 1
    fi
    perform_installation
}

# ==============================================================================
# Docker verification
# ==============================================================================

test_docker_installation() {
    if [ "$DRY_RUN" = true ]; then
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            log_ok "Docker daemon is reachable. [DRY RUN] Skipping the test container."
        else
            log_info "[DRY RUN] Docker daemon not reachable; skipping the test container."
        fi
        return 0
    fi

    log_info "Running a test container: docker run --rm busybox echo \"Hello zenon!\""
    local output
    if command -v docker >/dev/null 2>&1 && output="$(docker run --rm busybox echo "Hello zenon!" 2>&1)"; then
        log_ok "Docker works. Container output: ${output}"
        return 0
    fi
    show_error "Docker Verification Failed" "Failed to run the busybox test container.\n\nError output:\n  ${output}\n\nPlease check the Docker service status (systemctl status docker)."
    return 1
}

# ==============================================================================
# Compose package: download
# ==============================================================================

# The compose file the stack runs from: the merged one once overrides were merged.
compose_file() {
    if [ "$MERGED" = true ]; then echo "compose.merged.yaml"; else echo "compose.yaml"; fi
}

download_compose_package() {
    if [ "$NO_DOWNLOAD" = true ]; then
        # Reuse an already-extracted package so --env/--overrides still apply.
        if [ -f "${INSTALL_DIR}/compose.yaml" ]; then
            COMPOSE_PKG_DIR="$(cd "$INSTALL_DIR" && pwd)"
            log_info "Skipping download; reusing the package in ${COMPOSE_PKG_DIR}."
        else
            log_info "Skipping download; no extracted package found in '${INSTALL_DIR}'."
        fi
        return 0
    fi

    # A dry run deletes what it extracted afterwards, so never let it touch an existing install.
    if [ "$DRY_RUN" = true ] && [ -d "$INSTALL_DIR" ] && [ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
        show_error "Dry Run Cannot Proceed" "[DRY RUN] '${INSTALL_DIR}' already contains files, which a dry run would overwrite and then delete.\n\nPass --no-download to preview against the existing package, or choose another --install-dir."
        return 1
    fi

    if ! mkdir -p "$INSTALL_DIR"; then
        show_error "Download Error" "Could not create the install directory '${INSTALL_DIR}'."
        return 1
    fi
    local pkg_dir
    pkg_dir="$(cd "$INSTALL_DIR" && pwd)"
    FRESH_DOWNLOAD=true
    [ "$DRY_RUN" = true ] && register_cleanup "$pkg_dir"

    local zip_file="${pkg_dir}/compose_package.zip"
    register_cleanup "$zip_file"

    show_info "Downloading Package" "Downloading ${SOFTWARE_NAME} v${SOFTWARE_VERSION} Compose package...\nURL: ${COMPOSE_PKG_URL}"
    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$COMPOSE_PKG_URL" -o "$zip_file"; then
        show_error "Download Error" "Failed to download the Compose package.\nCheck the network connection and any proxy settings (https_proxy)."
        return 1
    fi

    log_info "Extracting into ${pkg_dir}..."
    if ! unzip -oq "$zip_file" -d "$pkg_dir"; then
        show_error "Extraction Error" "Failed to extract the Compose package with 'unzip'."
        return 1
    fi
    rm -f "$zip_file"
    COMPOSE_PKG_DIR="$pkg_dir"

    if [ -f "${pkg_dir}/example.env" ] && [ ! -f "${pkg_dir}/.env" ]; then
        cp "${pkg_dir}/example.env" "${pkg_dir}/.env"
        ENV_SEEDED=true
    fi

    log_ok "Compose package extracted to ${pkg_dir}."
}

# ==============================================================================
# Compose package: overrides & .env
# ==============================================================================

# enable_network_override_companions PKG_DIR OVERRIDE...
# Uncomments zenon-network-override.yaml's companion block for each service also
# defined by another selected override.
enable_network_override_companions() {
    local pkg_dir="$1"
    shift
    local network_file="${pkg_dir}/${NETWORK_OVERRIDE}"
    [ -f "$network_file" ] || return 0

    local defined=() ov key
    for ov in "$@"; do
        [ "$ov" = "$NETWORK_OVERRIDE" ] && continue
        while IFS= read -r key; do
            defined+=("$key")
        done < <(grep -oE '^  [A-Za-z0-9_-]+:' "${pkg_dir}/${ov}" | tr -d ' :')
    done
    [ ${#defined[@]} -gt 0 ] || return 0

    local tmp enabled=() active=false svc line
    tmp="$(mktemp)"
    register_cleanup "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*##\ uncomment\ if\  ]]; then
            echo "$line"
            active=false
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*#([A-Za-z0-9_-]+): ]]; then
            svc="${BASH_REMATCH[1]}"
            active=false
            if in_array "$svc" "${defined[@]}"; then
                active=true
                enabled+=("$svc")
            fi
        fi
        if [ "$active" = true ] && [[ "$line" =~ ^([[:space:]]*)#(.*)$ ]]; then
            echo "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        else
            echo "$line"
            [[ "$line" =~ ^[[:space:]]*# ]] || active=false
        fi
    done < "$network_file" > "$tmp" || return 1
    # Write in place (rather than mv) to keep the file's owner and permissions.
    cat "$tmp" > "$network_file" || return 1

    if [ ${#enabled[@]} -gt 0 ]; then
        log_ok "Enabled companion services in ${NETWORK_OVERRIDE}: ${enabled[*]}"
    fi
}

configure_compose_overrides() {
    local pkg_dir="$COMPOSE_PKG_DIR"

    # Discover override YAML files anywhere in the package, relative to pkg_dir.
    local override_files=() f
    while IFS= read -r f; do
        f="${f#"$pkg_dir"/}"
        case "$f" in
            compose.yaml|compose.merged.yaml|compose.combined.yaml) continue ;;
        esac
        override_files+=("$f")
    done < <(find "$pkg_dir" -mindepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) | sort)

    if [ ${#override_files[@]} -eq 0 ]; then
        log_info "No compose override files found in the package."
        return 0
    fi

    local selected=() item
    if [ "$OVERRIDES_SET" = true ]; then
        local raw=()
        IFS=',' read -ra raw <<< "$OVERRIDES_ARG"
        for item in "${raw[@]}"; do
            item="$(trim "$item")"
            if [ -n "$item" ]; then
                selected+=("$item")
            fi
        done
    elif [ "$UNATTENDED" = true ]; then
        log_info "Unattended: no compose overrides selected by default (pass --overrides to select some)."
    else
        echo
        echo "Available compose overrides (device drivers, protocol gateways, logging, zenon Network, ...):"
        local idx=1
        for f in "${override_files[@]}"; do
            printf '  [%2d] %s\n' "$idx" "$f"
            idx=$((idx + 1))
        done
        local sel_nums="" num
        read -rp "Numbers of the overrides to include, space-separated (e.g. 1 3 5), or Enter for none: " sel_nums < /dev/tty || true
        for num in $sel_nums; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#override_files[@]}" ]; then
                item="${override_files[$((num - 1))]}"
                in_array "$item" "${selected[@]}" || selected+=("$item")
            else
                log_warn "Ignoring invalid selection '${num}' (expected 1-${#override_files[@]})."
            fi
        done
    fi

    # Drop selections that don't match an actual override file (catches typos).
    local valid=()
    for item in "${selected[@]}"; do
        if in_array "$item" "${override_files[@]}"; then
            valid+=("$item")
        else
            log_warn "Override '${item}' not found in the package; skipping. Available: ${override_files[*]}"
        fi
    done
    selected=("${valid[@]}")

    # Exposed globally for the summary and the equivalent unattended command.
    SELECTED_OVERRIDES=("${selected[@]}")

    if [ ${#selected[@]} -eq 0 ]; then
        log_info "No overrides selected; the base compose.yaml will be used."
        return 0
    fi
    log_ok "Selected overrides: ${selected[*]}"

    if in_array "$NETWORK_OVERRIDE" "${selected[@]}" \
        && ! enable_network_override_companions "$pkg_dir" "${selected[@]}"; then
        show_error "Override Error" "Failed to update '${NETWORK_OVERRIDE}'."
        return 1
    fi

    if [ "$UNATTENDED" = false ] && ask_yesno "Review Override Files" \
        "Several overrides carry settings (certificates, ports, credentials) worth reviewing before they are merged." \
        "Open the selected override file(s) in an editor now?" true; then
        local sum_before
        for item in "${selected[@]}"; do
            log_info "Opening ${item} for review..."
            sum_before="$(cksum < "${pkg_dir}/${item}")"
            open_in_editor "${pkg_dir}/${item}" || log_warn "No terminal editor (nano/vi) found; edit '${pkg_dir}/${item}' manually."
            # No option carries override edits into the unattended command; flag them instead.
            if [ "$DRY_RUN" = true ] && [ "$(cksum < "${pkg_dir}/${item}")" != "$sum_before" ]; then
                DRY_RUN_EDITED_OVERRIDES+=("$item")
            fi
        done
    fi

    # ---- Merge compose.yaml + overrides into compose.merged.yaml ----
    local cmd_flags=(-f compose.yaml)
    for item in "${selected[@]}"; do
        cmd_flags+=(-f "$item")
    done

    if ! has_compose; then
        if [ "$DRY_RUN" = true ]; then
            log_warn "[DRY RUN] 'docker compose' is not available; skipping the merge."
            return 0
        fi
        show_error "Compose Generation Error" "'docker compose' is not installed or not functional."
        return 1
    fi

    log_info "Merging compose.yaml and ${#selected[@]} override(s) into compose.merged.yaml..."
    local err_msg
    if err_msg="$(cd "$pkg_dir" && docker compose "${cmd_flags[@]}" config --no-interpolate 2>&1 > compose.merged.yaml)"; then
        MERGED=true
        log_ok "Wrote ${pkg_dir}/compose.merged.yaml"
        return 0
    fi

    rm -f "${pkg_dir}/compose.merged.yaml"
    if [ "$DRY_RUN" = true ]; then
        log_warn "[DRY RUN] 'docker compose config' failed (${err_msg}); continuing with the simulated setup."
        return 0
    fi
    show_error "Compose Generation Error" "Failed to generate compose.merged.yaml using 'docker compose config --no-interpolate'.\n\nError details:\n${err_msg}"
    return 1
}

# set_env_value FILE KEY VALUE -> replaces KEY's line(s), or appends one. VALUE is taken literally.
set_env_value() {
    local file="$1" tmp
    tmp="$(mktemp)"
    register_cleanup "$tmp"
    ENV_KEY="$2" ENV_VALUE="$3" awk '
        BEGIN { key = ENVIRON["ENV_KEY"]; value = ENVIRON["ENV_VALUE"]; found = 0 }
        index($0, key "=") == 1 { print key "=" value; found = 1; next }
        { print }
        END { if (!found) print key "=" value }
    ' "$file" > "$tmp" || return 1
    # Write in place (rather than mv) to keep the file's owner and permissions.
    cat "$tmp" > "$file"
}

# Applies --env KEY=VALUE pairs non-interactively, regardless of mode.
apply_env_overrides() {
    [ ${#ENV_KV[@]} -gt 0 ] || return 0

    local env_file="${COMPOSE_PKG_DIR}/.env"
    if [ ! -f "$env_file" ]; then
        log_warn "No .env found in ${COMPOSE_PKG_DIR}; ignoring ${#ENV_KV[@]} --env value(s)."
        return 0
    fi

    local kv key value
    for kv in "${ENV_KV[@]}"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        if [ "$key" = "$kv" ] || ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            log_warn "Ignoring malformed --env value '${kv}' (expected KEY=VALUE)."
            continue
        fi
        if ! set_env_value "$env_file" "$key" "$value"; then
            show_error "Environment Error" "Failed to set ${key} in '${env_file}'."
            return 1
        fi
        log_ok "Set ${key} in .env"
    done
}

# env_entries FILE -> the file's KEY=VALUE lines as set_env_value matches them, one per key (last wins).
env_entries() {
    awk 'match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
             k = substr($0, 1, RLENGTH - 1)
             if (!(k in line)) order[++n] = k
             line[k] = $0
         }
         END { for (i = 1; i <= n; i++) print line[order[i]] }' "$1"
}

# record_env_edits BEFORE AFTER -> compares two env_entries outputs: changed or added
# lines go to DRY_RUN_ENV_EDITS, keys that disappeared to DRY_RUN_ENV_REMOVED.
record_env_edits() {
    local -A before=() after=()
    local line key
    while IFS= read -r line; do
        [ -n "$line" ] && before["${line%%=*}"]="$line"
    done <<< "$1"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        after["$key"]=1
        [ "${before[$key]-}" = "$line" ] || DRY_RUN_ENV_EDITS+=("$line")
    done <<< "$2"
    # Walk BEFORE again (rather than the hash) to keep the file's order.
    while IFS= read -r line; do
        key="${line%%=*}"
        [ -z "$line" ] || [ -n "${after[$key]-}" ] || DRY_RUN_ENV_REMOVED+=("$key")
    done <<< "$1"
}

configure_env_variables() {
    apply_env_overrides || return 1

    local env_file="${COMPOSE_PKG_DIR}/.env"
    [ "$UNATTENDED" = false ] && [ -f "$env_file" ] || return 0

    local origin="The existing '.env' file was kept."
    [ "$ENV_SEEDED" = true ] && origin="A '.env' file was created from 'example.env'."

    if ask_yesno "Configure Environment Variables" \
        "${origin}\nThe selected overrides may need additional settings - see their README files." \
        "Open '.env' in an editor now?" true; then
        # A dry run's .env is deleted afterwards, so its edits are carried into the
        # equivalent unattended command instead.
        local before
        before="$(env_entries "$env_file")"
        if open_in_editor "$env_file"; then
            if [ "$DRY_RUN" = true ]; then
                record_env_edits "$before" "$(env_entries "$env_file")"
            fi
        else
            show_msg "Editor Warning" "No terminal editor (nano/vi) found. Please edit '.env' manually at:\n${env_file}"
        fi
    fi
}

configure_compose_package() {
    if [ ! -d "$COMPOSE_PKG_DIR" ]; then
        log_info "No Compose package to configure."
        return 0
    fi
    # Overrides first: they often introduce new variables that belong in .env.
    configure_compose_overrides || return 1
    configure_env_variables
}

# ==============================================================================
# Published ports
# ==============================================================================

# add_published_port PROTO PORT -> PORT may be a single port or a range (8000-8010).
add_published_port() {
    [ -n "$2" ] || return 0
    if ! [[ "$2" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
        log_warn "Ignoring unparseable published port '$2'."
        return 0
    fi
    if [ "$1" = "udp" ]; then
        PUBLISHED_UDP_PORTS+=("$2")
    else
        PUBLISHED_TCP_PORTS+=("$2")
    fi
}

# Populates the global PUBLISHED_TCP_PORTS/PUBLISHED_UDP_PORTS arrays (sorted numerically).
#
# compose.merged.yaml is kept uninterpolated (so later .env edits still apply), so it is
# rendered once more by 'docker compose config' with .env applied - exactly what
# 'docker compose up' will use. That output always lists every port like this:
#     - mode: ingress
#       target: 4841
#       published: "4841"
#       protocol: tcp
collect_published_ports() {
    PUBLISHED_TCP_PORTS=()
    PUBLISHED_UDP_PORTS=()
    [ "$MERGED" = true ] || return 0
    if ! has_compose; then
        log_warn "'docker compose' not available; cannot determine the published ports."
        return 0
    fi

    local resolved err
    resolved="$(mktemp)"
    register_cleanup "$resolved"
    if ! err="$(cd "$COMPOSE_PKG_DIR" && docker compose -f compose.merged.yaml config 2>&1 > "$resolved")"; then
        log_warn "Could not resolve compose.merged.yaml with .env; published ports unknown. ${err}"
        return 0
    fi

    # 'published:' (absent when Docker picks a random host port) always precedes the
    # entry's 'protocol:', so the protocol line completes each port entry.
    local line published=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+published:[[:space:]]*\"([^\"]*)\" ]]; then
            published="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+protocol:[[:space:]]*([a-z]+) ]]; then
            add_published_port "${BASH_REMATCH[1]}" "$published"
            published=""
        fi
    done < "$resolved"

    # shellcheck disable=SC2207
    PUBLISHED_TCP_PORTS=($(printf '%s\n' "${PUBLISHED_TCP_PORTS[@]}" | sort -n))
    # shellcheck disable=SC2207
    PUBLISHED_UDP_PORTS=($(printf '%s\n' "${PUBLISHED_UDP_PORTS[@]}" | sort -n))
    return 0
}

# ==============================================================================
# OS-specific pre- and post-steps
#
# main detects the OS once (detect_host_os) and passes it to:
#   run_pre_steps OS  - before the prerequisites are checked/installed
#   run_post_steps OS - after the Compose package is configured, before the stack starts
# To support another OS: add a case for its name to both.
# ==============================================================================

# Prints the OS name with its major version, e.g.:
#   rt-linux-13      Beckhoff RT Linux 13 (os-release says debian 13; detected via marker file)
#   industrial-os-4  Siemens Industrial OS 4.x
#   debian-12        anything else: <ID>-<major VERSION_ID>
# Expects read_os_release to have run.
detect_host_os() {
    local name="$OS_ID"
    # Beckhoff's own marker file, not nftables presence alone.
    [ -f "$BECKHOFF_MARKER" ] && name="rt-linux"
    local major="${OS_VERSION_ID%%.*}"
    echo "${name}${major:+-$major}"
}

# run_pre_steps OS
run_pre_steps() {
    case "$1" in
        industrial-os-4) add_debian_official_repo ;;
        *)               log_info "No pre-steps for '$1'." ;;
    esac
}

# run_post_steps OS
run_post_steps() {
    case "$1" in
        rt-linux-13)     apply_static_nftables_rules || true ;;
        *)               log_info "No post-steps for '$1'." ;;
    esac
}

# ---- Siemens Industrial OS 4.x ----
# Its own apt sources lack packages docker-ce depends on (nftables/iptables), so the
# official Debian repo is added and kept - pinned low, so Debian packages are only
# used where the Industrial OS sources have no candidate.

add_debian_official_repo() {
    if [ -z "$OS_CODENAME" ]; then
        log_warn "No VERSION_CODENAME in /etc/os-release; cannot add the official Debian repository."
        return 0
    fi

    local signed_by=""
    if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
        signed_by=" [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg]"
    fi

    local repo_desc="official Debian '${OS_CODENAME}' repository, kept with low priority (Pin-Priority 100)"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would add the ${repo_desc}: ${DEBIAN_REPO_LIST}, ${DEBIAN_REPO_PIN}"
        HOST_STEPS+=("Pre: [DRY RUN] would add the ${repo_desc}")
        return 0
    fi

    log_info "Pre-step: adding the ${repo_desc} for packages missing from the Industrial OS sources."
    echo "deb${signed_by} http://deb.debian.org/debian ${OS_CODENAME} main" > "$DEBIAN_REPO_LIST"
    cat > "$DEBIAN_REPO_PIN" <<'EOF'
# Managed by install_zenon.sh - only use Debian packages the OS's own sources don't provide.
Package: *
Pin: origin deb.debian.org
Pin-Priority: 100
EOF
    log_ok "Added ${DEBIAN_REPO_LIST} and ${DEBIAN_REPO_PIN}."
    HOST_STEPS+=("Pre: added the ${repo_desc}")
    # Entries starting with a space are shown as continuation lines in the summary.
    HOST_STEPS+=(" Source: ${DEBIAN_REPO_LIST}")
    HOST_STEPS+=(" Pin:    ${DEBIAN_REPO_PIN}")
}

# ---- Beckhoff RT Linux ----

# Writes PUBLISHED_TCP_PORTS/PUBLISHED_UDP_PORTS into a static nftables ruleset
# for Beckhoff RT Linux 13 (see "Device/OS-specific remarks" in the README).
apply_static_nftables_rules() {
    if ! command -v nft >/dev/null 2>&1; then
        log_warn "'nft' not found; skipping the static nftables rules."
        return 0
    fi
    # Skip if no overrides were merged - nothing new for the firewall to allow.
    if [ "$MERGED" = false ]; then
        log_info "No overrides merged; no static nftables rules needed."
        return 0
    fi

    local wan_if
    wan_if="$(ip route show default 2>/dev/null | awk '/^default/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"
    if [ -z "$wan_if" ]; then
        log_warn "Could not detect the default-route interface; skipping static nftables rules for Docker traffic. Add them manually if needed."
        return 1
    fi

    local tcp_list udp_list
    tcp_list="$(join_by ', ' "${PUBLISHED_TCP_PORTS[@]}")"
    udp_list="$(join_by ', ' "${PUBLISHED_UDP_PORTS[@]}")"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would write ${NFT_RULES_FILE}: wan=${wan_if}, tcp={${tcp_list}}, udp={${udp_list}}"
        return 0
    fi

    local input_rules=""
    if [ -n "$tcp_list" ]; then
        input_rules+="        iifname \"${wan_if}\" tcp dport { ${tcp_list} } accept"$'\n'
    fi
    if [ -n "$udp_list" ]; then
        input_rules+="        iifname \"${wan_if}\" udp dport { ${udp_list} } accept"$'\n'
    fi

    mkdir -p "$(dirname "$NFT_RULES_FILE")"
    cat > "$NFT_RULES_FILE" <<EOF
# Managed by install_zenon.sh - static rules for zenon's Docker networking.
# Re-run the installer, or edit and 'systemctl reload nftables' to update by hand.
table inet filter {
    chain forward {
        iifname "docker0" oifname "${wan_if}" accept
        iifname "br-*" oifname "${wan_if}" accept
        iifname "${wan_if}" oifname "docker0" accept
        iifname "${wan_if}" oifname "br-*" accept
        iifname "br-*" oifname "br-*" accept
    }
    chain input {
${input_rules}    }
}
EOF

    if command -v systemctl >/dev/null 2>&1 && systemctl reload nftables 2>/dev/null; then
        systemctl restart docker >/dev/null 2>&1 || true
        log_ok "Post-step: applied static nftables rules (${NFT_RULES_FILE}): WAN '${wan_if}', TCP {${tcp_list}}, UDP {${udp_list}}."
        HOST_STEPS+=("Post: static nftables rules in ${NFT_RULES_FILE}")
    else
        log_warn "'systemctl reload nftables' failed or is unavailable; ${NFT_RULES_FILE} was written but not applied - verify manually."
        HOST_STEPS+=("Post: ${NFT_RULES_FILE} written but NOT applied - verify manually")
        return 1
    fi
}

# ==============================================================================
# Stack startup
# ==============================================================================

start_stack() {
    local file
    file="$(compose_file)"
    if [ -z "$COMPOSE_PKG_DIR" ] || { [ "$DRY_RUN" = false ] && [ ! -f "${COMPOSE_PKG_DIR}/${file}" ]; }; then
        log_warn "No compose file available; cannot auto-start (--up ignored)."
        return 1
    fi

    if ! has_compose; then
        log_warn "'docker compose' not found; cannot auto-start."
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would run: docker compose -f ${file} up -d (in ${COMPOSE_PKG_DIR})"
        return 0
    fi

    log_info "Running 'docker compose -f ${file} up -d' in ${COMPOSE_PKG_DIR}..."
    ( cd "$COMPOSE_PKG_DIR" && docker compose -f "$file" up -d )
}

# ==============================================================================
# Install record
# ==============================================================================

# Writes INSTALL_RECORD as bash-sourceable KEY=VALUE lines (values %q-quoted), replacing the
# previous run's record. Bump ZINGO_RECORD_FORMAT on incompatible changes to the keys.
write_install_record() {
    [ "$DRY_RUN" = false ] && [ -n "$COMPOSE_PKG_DIR" ] || return 0

    local tmp
    if ! mkdir -p "$(dirname "$INSTALL_RECORD")" || ! tmp="$(mktemp "${INSTALL_RECORD}.XXXXXX")"; then
        log_warn "Could not write the install record ${INSTALL_RECORD}."
        return 0
    fi
    register_cleanup "$tmp"
    {
        echo "# Written by zINGO (install_zenon.sh) on each successful run - do not edit."
        printf '%s=%s\n' \
            ZINGO_RECORD_FORMAT 1 \
            ZINGO_VERSION "$(quote_args "$ZINGO_VERSION")" \
            SOFTWARE_VERSION "$(quote_args "$SOFTWARE_VERSION")" \
            INSTALLED_AT "$(quote_args "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")" \
            INSTALL_DIR "$(quote_args "$COMPOSE_PKG_DIR")" \
            COMPOSE_FILE "$(quote_args "$(compose_file)")" \
            OVERRIDES "$(quote_args "$(join_by ',' "${SELECTED_OVERRIDES[@]}")")" \
            HOST_OS "$(quote_args "$HOST_OS")"
    } > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$INSTALL_RECORD" && INSTALL_RECORD_WRITTEN=true
    if [ "$INSTALL_RECORD_WRITTEN" = true ]; then
        log_ok "Wrote install record ${INSTALL_RECORD}."
    else
        log_warn "Could not write the install record ${INSTALL_RECORD}."
    fi
}

# ==============================================================================
# Summary
# ==============================================================================

# Reconstructs every option this run actually resolved to.
build_equivalent_unattended_command() {
    # The EULA was accepted in this run (it's a precondition), so carry that over.
    local args=(-u --accept-eula)
    [ "$SKIP_PREREQS" = true ] && args+=(--skip-prereqs)
    [ "$NO_DOWNLOAD" = true ] && args+=(--no-download)
    [ "$INSTALL_DIR" != "$DEFAULT_INSTALL_DIR" ] && args+=(--install-dir "$INSTALL_DIR")
    if [ ${#SELECTED_OVERRIDES[@]} -gt 0 ]; then
        args+=(--overrides "$(join_by ',' "${SELECTED_OVERRIDES[@]}")")
    fi
    # --env values are applied in order, so .env edits go last; a passed value for
    # a key that was then edited is dropped as superseded.
    local kv edited_keys=()
    for kv in "${DRY_RUN_ENV_EDITS[@]}"; do
        edited_keys+=("${kv%%=*}")
    done
    for kv in "${ENV_KV[@]}"; do
        in_array "${kv%%=*}" "${edited_keys[@]}" || args+=(--env "$kv")
    done
    for kv in "${DRY_RUN_ENV_EDITS[@]}"; do
        args+=(--env "$kv")
    done
    [ "$AUTO_START" = true ] && args+=(--up)
    [ -n "$LOG_FILE" ] && args+=(--log-file "$LOG_FILE")

    echo "curl -fsSL ${SCRIPT_URL} | sudo bash -s -- $(quote_args "${args[@]}")"
}

summary_section() { printf '\n%s\n' "$1"; }
summary_row()     { printf '   %-18s %s\n' "$1" "$2"; }
summary_bullet()  { printf '   • %s\n' "$1"; }
summary_command() { printf '       %s\n' "$1"; }

show_summary() {
    local rule="======================================================================"
    printf '\n%s\n  zINGO v%s - Setup Summary (%s v%s)\n%s\n' "$rule" "$ZINGO_VERSION" "$SOFTWARE_NAME" "$SOFTWARE_VERSION" "$rule"

    if [ "$DRY_RUN" = true ]; then
        printf '\n  DRY RUN - no packages, containers or firewall rules were changed.\n'
    fi

    summary_section "1. Host"
    summary_row "OS:" "${OS_PRETTY_NAME} (steps: ${HOST_OS})"
    if [ ${#HOST_STEPS[@]} -eq 0 ]; then
        summary_row "Host steps:" "none"
    else
        local host_step
        for host_step in "${HOST_STEPS[@]}"; do
            if [[ "$host_step" == " "* ]]; then
                printf '     %s\n' "${host_step# }"
            else
                summary_bullet "$host_step"
            fi
        done
    fi

    summary_section "2. Docker"
    summary_row "Status:" "$DOCKER_STATUS_SUMMARY"
    summary_row "Package sources:" "$PACKAGE_SOURCES_SUMMARY"
    if [ ${#REMOVED_PACKAGES[@]} -gt 0 ]; then
        summary_row "Removed packages:" "${REMOVED_PACKAGES[*]}"
    fi

    summary_section "3. Compose package"
    local compose_path="" env_path=""
    if [ -n "$COMPOSE_PKG_DIR" ]; then
        compose_path="${COMPOSE_PKG_DIR}/$(compose_file)"
        env_path="${COMPOSE_PKG_DIR}/.env"
    fi
    summary_row "Directory:" "${COMPOSE_PKG_DIR:-Not downloaded}"
    summary_row "Compose file:" "${compose_path:-n/a}"
    summary_row "Environment file:" "${env_path:-n/a}"
    if [ ${#SELECTED_OVERRIDES[@]} -gt 0 ]; then
        summary_row "Overrides:" "$(join_by ', ' "${SELECTED_OVERRIDES[@]}")"
    else
        summary_row "Overrides:" "none"
    fi
    summary_row "EULA:" "accepted (${EULA_ACCEPTED_VIA})"
    [ "$INSTALL_RECORD_WRITTEN" = true ] && summary_row "Install record:" "$INSTALL_RECORD"

    summary_section "4. Exposed ports"
    if [ ${#PUBLISHED_TCP_PORTS[@]} -eq 0 ] && [ ${#PUBLISHED_UDP_PORTS[@]} -eq 0 ]; then
        summary_bullet "None (no merged overrides publish host ports)."
    else
        [ ${#PUBLISHED_TCP_PORTS[@]} -gt 0 ] && summary_row "TCP:" "${PUBLISHED_TCP_PORTS[*]}"
        [ ${#PUBLISHED_UDP_PORTS[@]} -gt 0 ] && summary_row "UDP:" "${PUBLISHED_UDP_PORTS[*]}"
        if [ "$HOST_OS" = "rt-linux-13" ]; then
            summary_bullet "Allowed via the static nftables ruleset for Beckhoff RT Linux 13 (see the README)."
        else
            summary_bullet "Published by Docker itself once the stack is started."
        fi
    fi

    local start_cmd
    start_cmd="cd $(quote_args "$COMPOSE_PKG_DIR") && sudo docker compose"
    [ "$MERGED" = true ] && start_cmd+=" -f compose.merged.yaml"
    start_cmd+=" up -d"

    summary_section "5. Next steps"
    if [ -n "$env_path" ]; then
        summary_bullet "Read the README.md of the Compose package, and of every selected override, before"
        printf '     %s\n' "starting the stack - they document required manual setup (certificates, ports, ...)."
    fi
    if [ "$DRY_RUN" = true ]; then
        # The cleanup registered at download time removes them right after this summary.
        if [ "$FRESH_DOWNLOAD" = true ]; then
            summary_bullet "The files downloaded by this dry run are removed again (${COMPOSE_PKG_DIR})."
        fi
        summary_bullet "To perform this exact install for real, unattended, run:"
        summary_command "$(build_equivalent_unattended_command)"
        if [ ${#DRY_RUN_ENV_EDITS[@]} -gt 0 ]; then
            summary_bullet "Includes your .env edits as --env values (shown in plain text - mind any secrets)."
        fi
        if [ ${#DRY_RUN_ENV_REMOVED[@]} -gt 0 ]; then
            summary_bullet "Not included - keys you deleted or commented out in .env can't be passed with"
            printf '     %s\n' "--env; remove them by hand after the install: ${DRY_RUN_ENV_REMOVED[*]}"
        fi
        if [ ${#DRY_RUN_EDITED_OVERRIDES[@]} -gt 0 ]; then
            summary_bullet "Not included - your edits to these override files; re-apply them by hand after"
            printf '     %s\n' "the install: $(join_by ', ' "${DRY_RUN_EDITED_OVERRIDES[@]}")"
        fi
    elif [ -n "$env_path" ]; then
        if [ "$AUTO_START" = true ]; then
            summary_bullet "Containers were started automatically (--up). To restart or apply changes:"
            summary_command "$start_cmd"
        else
            summary_bullet "Edit environment variables:"
            summary_command "sudoedit $(quote_args "$env_path")"
            summary_bullet "Start the application containers:"
            summary_command "$start_cmd"
        fi
    else
        summary_bullet "The Compose package was not downloaded. Run the script again to set it up."
    fi
    echo
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    ORIGINAL_ARGS=("$@")
    parse_args "$@"
    require_root
    start_logging
    require_terminal_or_unattended
    require_eula_acceptance

    trap run_cleanup EXIT
    trap 'echo; log_warn "Interrupted."; exit 130' INT TERM

    read_os_release
    HOST_OS="$(detect_host_os)"

    log_step "Running pre-steps"
    log_info "Detected OS: ${OS_PRETTY_NAME} -> '${HOST_OS}'"
    run_pre_steps "$HOST_OS"

    log_step "Checking prerequisites"
    ensure_prerequisites

    log_step "Verifying Docker"
    test_docker_installation || exit 1

    log_step "Fetching Compose package"
    download_compose_package || exit 1

    log_step "Configuring Compose package"
    configure_compose_package || exit 1

    log_step "Running post-steps"
    collect_published_ports
    run_post_steps "$HOST_OS"

    log_step "Starting containers"
    if [ "$AUTO_START" = true ]; then
        start_stack || log_warn "Automatic startup failed; start the stack manually with the command shown below."
    else
        log_info "Skipped (pass --up to start the stack automatically)."
    fi

    write_install_record
    show_summary
}

main "$@"
