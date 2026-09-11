#!/bin/bash
# ==============================================================================
# Node.js Universal V5 Production Egg - Installation Script
# Runs inside the installation container (debian-based) before the server
# is ever started.
# ==============================================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

INFO()     { echo -e "\033[1;34m[INFO]\033[0m     $*"; }
SUCCESS()  { echo -e "\033[1;32m[SUCCESS]\033[0m  $*"; }
WARNING()  { echo -e "\033[1;33m[WARNING]\033[0m  $*"; }
ERROR()    { echo -e "\033[1;31m[ERROR]\033[0m    $*"; }
SECURITY() { echo -e "\033[1;91m[SECURITY]\033[0m $*"; }

trap 'ERROR "Installation failed on line $LINENO running: $BASH_COMMAND"' ERR

INFO "Starting Node.js Universal V5 installation..."

apt-get update
apt-get install -y --no-install-recommends \
    git curl wget unzip zip \
    build-essential gcc g++ make \
    python3 python3-dev python3-pip \
    libtool openssl ca-certificates jq netcat-openbsd

apt-get clean
rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------------------------
# Pin tool versions for reproducibility. Bump these deliberately, never track
# @latest/@stable in a production image.
# ------------------------------------------------------------------------------
YARN_VERSION="${YARN_VERSION:-4.5.0}"
PNPM_VERSION="${PNPM_VERSION:-9.12.0}"
BUN_VERSION="${BUN_VERSION:-1.1.30}"

INFO "Enabling Corepack (pinned yarn ${YARN_VERSION} / pnpm ${PNPM_VERSION})..."
corepack enable
corepack prepare "yarn@${YARN_VERSION}" --activate
corepack prepare "pnpm@${PNPM_VERSION}" --activate

# ------------------------------------------------------------------------------
# Bun install: download first, verify, THEN execute - never pipe curl
# directly into a shell.
# ------------------------------------------------------------------------------
INFO "Installing Bun ${BUN_VERSION}..."
BUN_INSTALLER=$(mktemp)
curl -fsSL https://bun.sh/install -o "$BUN_INSTALLER"
if [[ ! -s "$BUN_INSTALLER" ]]; then
    ERROR "Bun installer download failed or was empty"
    exit 1
fi
# Sanity-check it looks like a shell script before executing, rather than
# blindly trusting the download.
if ! head -c 64 "$BUN_INSTALLER" | grep -q '^#!'; then
    ERROR "Bun installer does not look like a shell script, refusing to run it"
    exit 1
fi
bash "$BUN_INSTALLER" "bun-v${BUN_VERSION}"
rm -f "$BUN_INSTALLER"
export PATH="$HOME/.bun/bin:$PATH"
SUCCESS "Bun installed"

# devDependency build tools (typescript/ts-node/tsx/nodemon) are intentionally
# NOT installed globally here. Each project should own its own pinned
# versions via its own devDependencies; the startup script installs those
# automatically when RUN_BUILD=1. This avoids global/local version drift.

mkdir -p /mnt/server
cd /mnt/server

# ------------------------------------------------------------------------------
# Persist a static jq binary for the RUNTIME container.
# apt-get above only installs jq into this install container (debian-based);
# it never carries over to the runtime image (e.g. yolks:nodejs_20), which
# doesn't ship jq. /mnt/server does persist as /home/container at runtime, so
# a copy placed in .bin here will still be there and on PATH at boot
# (_startup.sh prepends it). Best-effort only: never fails the install.
# ------------------------------------------------------------------------------
INFO "Persisting a static jq binary for the runtime container..."
mkdir -p .bin
JQ_ARCH=""
case "$(uname -m)" in
    x86_64)  JQ_ARCH="amd64" ;;
    aarch64) JQ_ARCH="arm64" ;;
    *)       WARNING "Unsupported architecture for static jq ($(uname -m)), skipping" ;;
esac
if [[ -n "$JQ_ARCH" ]]; then
    JQ_URL="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${JQ_ARCH}"
    if curl -fsSL -m 30 -o .bin/jq "$JQ_URL" 2>/dev/null && [[ -s .bin/jq ]]; then
        chmod +x .bin/jq
        SUCCESS "Static jq persisted to .bin/jq for runtime use"
    else
        WARNING "Could not download static jq (non-fatal) - _startup.sh will retry at boot"
        rm -f .bin/jq
    fi
fi

get_script_from_package_json() {
    local script_name="$1"
    [[ -f "package.json" ]] && command -v jq &>/dev/null || { echo ""; return; }
    jq -r ".scripts[\"$script_name\"] // empty" package.json 2>/dev/null
}

detect_pm() {
    if [[ "${PACKAGE_MANAGER:-auto}" != "auto" ]]; then echo "${PACKAGE_MANAGER}"; return; fi
    if [[ -f "bun.lockb" || -f "bun.lock" ]]; then echo "bun"
    elif [[ -f "pnpm-lock.yaml" ]]; then echo "pnpm"
    elif [[ -f "yarn.lock" ]]; then echo "yarn"
    elif [[ -f "package-lock.json" || -f "npm-shrinkwrap.json" ]]; then echo "npm"
    elif [[ -f "package.json" ]]; then echo "npm"
    else echo "none"
    fi
}

install_deps() {
    local pm="$1"
    local want_dev=0
    [[ "${RUN_BUILD:-0}" == "1" ]] && want_dev=1
    [[ "${NODE_ENV:-production}" != "production" ]] && want_dev=1

    INFO "Installing dependencies using $pm (dev deps: $([[ $want_dev -eq 1 ]] && echo included || echo omitted))..."
    case "$pm" in
        bun)
            if [[ $want_dev -eq 1 ]]; then bun install; else bun install --production; fi ;;
        pnpm)
            if [[ "${RUN_CI:-0}" == "1" ]]; then pnpm install --frozen-lockfile
            elif [[ $want_dev -eq 1 ]]; then pnpm install
            else pnpm install --prod
            fi ;;
        yarn)
            if [[ "${RUN_CI:-0}" == "1" ]]; then yarn install --frozen-lockfile
            elif [[ $want_dev -eq 1 ]]; then yarn install
            else yarn install --production
            fi ;;
        npm)
            if [[ "${RUN_CI:-0}" == "1" && -f "package-lock.json" ]]; then
                if [[ $want_dev -eq 1 ]]; then npm ci; else npm ci --omit=dev; fi
            elif [[ $want_dev -eq 1 ]]; then npm install
            else npm install --omit=dev
            fi ;;
        none) WARNING "No package.json found, skipping dependency installation"; return 0 ;;
    esac
    SUCCESS "Dependencies installed successfully"
}

run_build() {
    [[ "${RUN_BUILD:-0}" == "1" ]] || return 0
    local pm="$1"
    INFO "Running build script..."
    case "$pm" in
        bun) bun run build ;;
        pnpm) pnpm run build ;;
        yarn) yarn run build ;;
        npm) npm run build ;;
        *) WARNING "No package manager detected, skipping build" ;;
    esac
    SUCCESS "Build completed"
}

# ------------------------------------------------------------------------------
# Secure git authentication - token is NEVER embedded in the remote URL.
# A short-lived GIT_ASKPASS helper answers both the username and password
# prompts correctly, so token-based auth works against GitHub, GitLab,
# Bitbucket, and Gitea (GitHub accepts the token as either; GitLab/Bitbucket
# app passwords generally need the real account/username paired with the
# token, which V4 did not support - USERNAME is now actually wired in here).
# ------------------------------------------------------------------------------
ASKPASS_FILE=""
setup_git_auth() {
    [[ -n "${ACCESS_TOKEN:-}" ]] || return 0
    SECURITY "Configuring temporary credential helper for private repository access (token will not be logged or stored in the repo URL)."
    ASKPASS_FILE="$(mktemp)"
    cat > "$ASKPASS_FILE" <<'ASKPASS'
#!/bin/bash
case "$1" in
    *[Uu]sername*) echo "${GIT_USERNAME_INTERNAL:-x-access-token}" ;;
    *) echo "$GIT_ACCESS_TOKEN_INTERNAL" ;;
esac
ASKPASS
    chmod 700 "$ASKPASS_FILE"
    export GIT_ASKPASS="$ASKPASS_FILE"
    export GIT_ACCESS_TOKEN_INTERNAL="${ACCESS_TOKEN}"
    export GIT_USERNAME_INTERNAL="${USERNAME:-}"
    export GIT_TERMINAL_PROMPT=0
}

cleanup_git_auth() {
    [[ -n "$ASKPASS_FILE" ]] && rm -f "$ASKPASS_FILE"
    unset GIT_ASKPASS GIT_ACCESS_TOKEN_INTERNAL GIT_USERNAME_INTERNAL 2>/dev/null || true
}
trap cleanup_git_auth EXIT

# ------------------------------------------------------------------------------
# User upload mode
# ------------------------------------------------------------------------------
if [[ "${USER_UPLOAD:-0}" == "true" ]] || [[ "${USER_UPLOAD:-0}" == "1" ]]; then
    INFO "User upload mode - skipping git clone"
    if [[ -f package.json ]]; then
        PM=$(detect_pm)
        install_deps "$PM"
        [[ "${RUN_PRISMA_GENERATE:-0}" == "1" ]] && npx prisma generate
        run_build "$PM"
    fi
    SUCCESS "Installation complete"
    exit 0
fi

# ------------------------------------------------------------------------------
# Git clone (secure)
# ------------------------------------------------------------------------------
if [[ -z "${GIT_ADDRESS:-}" ]]; then
    ERROR "GIT_ADDRESS is empty but USER_UPLOAD is disabled"
    exit 1
fi

GIT_URL="${GIT_ADDRESS}"

# Reject credentials embedded directly in the address - they would leak into
# `git remote -v`, process listings, and logs, defeating the askpass helper.
if [[ "$GIT_URL" =~ ://[^/@]+:[^/@]+@ ]]; then
    ERROR "GIT_ADDRESS appears to contain embedded credentials (user:pass@host). Use the separate 'Git Username'/'Git Access Token' fields instead."
    exit 1
fi

if [[ ! "$GIT_URL" == *.git ]] && [[ ! "$GIT_URL" == *"?"* ]]; then
    GIT_URL="${GIT_URL}.git"
fi

setup_git_auth

CLONE_OK=1
if [[ -d .git ]]; then
    INFO "Repository already exists, pulling latest..."
    git pull || CLONE_OK=0
else
    INFO "Cloning repository..."
    if [[ -n "${BRANCH:-}" ]]; then
        git clone --single-branch --branch "${BRANCH}" "$GIT_URL" . || CLONE_OK=0
    else
        git clone "$GIT_URL" . || CLONE_OK=0
    fi
fi

cleanup_git_auth

if [[ "$CLONE_OK" -ne 1 ]]; then
    ERROR "Git clone/pull failed - aborting installation"
    exit 1
fi

# ------------------------------------------------------------------------------
# Dependencies / build
# ------------------------------------------------------------------------------
if [[ -f package.json ]]; then
    PM=$(detect_pm)
    install_deps "$PM"

    if [[ "${REBUILD_NATIVE:-0}" == "1" ]]; then
        INFO "Rebuilding native modules..."
        case "$PM" in
            bun) bun rebuild ;;
            pnpm) pnpm rebuild ;;
            yarn) yarn rebuild ;;
            npm) npm rebuild ;;
        esac
    fi

    if [[ "${AUDIT_CHECK:-0}" == "1" ]]; then
        INFO "Running dependency audit (non-fatal)..."
        case "$PM" in
            npm)  npm audit --audit-level="${AUDIT_LEVEL:-high}" || WARNING "Audit reported issues" ;;
            pnpm) pnpm audit --audit-level="${AUDIT_LEVEL:-high}" || WARNING "Audit reported issues" ;;
            yarn) yarn audit --level "${AUDIT_LEVEL:-high}" || WARNING "Audit reported issues" ;;
            bun)  bun audit || WARNING "Audit reported issues" ;;
        esac
    fi

    if [[ -n "${CUSTOM_INSTALL_CMD:-}" ]]; then
        SECURITY "Running CUSTOM_INSTALL_CMD (admin-configured only). Review this command before enabling it."
        bash -c "${CUSTOM_INSTALL_CMD}"
    fi

    [[ "${RUN_PRISMA_GENERATE:-0}" == "1" ]] && { INFO "Running Prisma generate..."; npx prisma generate; }

    run_build "$PM"
else
    WARNING "No package.json found"
fi

if [[ "${ENABLE_BACKUPS:-0}" == "1" ]]; then
    mkdir -p "${BACKUP_LOCATION:-/home/container/backups}"
    chmod 700 "${BACKUP_LOCATION:-/home/container/backups}" 2>/dev/null || true
    SUCCESS "Backup directory prepared at ${BACKUP_LOCATION:-/home/container/backups}"
fi

SUCCESS "Installation complete!"
exit 0
