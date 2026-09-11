#!/bin/bash
# ==============================================================================
# Node.js Universal V5 Production Egg - Startup Script
# Security-hardened successor to V4.
# ==============================================================================
set -uo pipefail
cd /home/container || exit 1

# A static jq binary is fetched into .bin at install time (see _install.sh)
# because the runtime image does not ship jq itself, only the install
# container does, and system packages installed there never carry over.
# Putting .bin first on PATH lets that persisted copy be found here.
export PATH="/home/container/.bin:$PATH"

# ------------------------------------------------------------------------------
# State (declared early so redact_line/logging helpers can reference them)
# ------------------------------------------------------------------------------
STOPPING=0
CHILD_PID=""
CHILD_PGID=""
MONITOR_PID=""
BACKUP_PID=""
START_TIME=$(date +%s)
PM=""
START_CMD_ARR=()
START_CMD_DISPLAY=""
POST_BUILD_ALREADY_RUN=0

# ------------------------------------------------------------------------------
# Secret redaction - defined first, used by every log/notify function below.
# ------------------------------------------------------------------------------
SECRET_VAR_NAMES=(TOKEN ACCESS_TOKEN DISCORD_CLIENT_SECRET GITHUB_CLIENT_SECRET GITLAB_CLIENT_SECRET
    MYSQL_PASSWORD POSTGRES_PASSWORD DATABASE_URL MONGODB_URI REDIS_PASSWORD SESSION_SECRET
    JWT_SECRET COOKIE_SECRET API_KEY DISCORD_WEBHOOK_URL PRIVATE_KEY OAUTH_CLIENT_SECRET)

redact_line() {
    local line="$*" name val
    for name in "${SECRET_VAR_NAMES[@]}"; do
        val="${!name:-}"
        [[ -n "$val" ]] && line="${line//$val/[REDACTED]}"
    done
    printf '%s' "$line"
}

# ------------------------------------------------------------------------------
# Logging helpers - every line passes through redact_line
# ------------------------------------------------------------------------------
INFO()     { echo -e "\033[1;34m[INFO]\033[0m     $(redact_line "$*")"; }
SUCCESS()  { echo -e "\033[1;32m[SUCCESS]\033[0m  $(redact_line "$*")"; }
WARNING()  { echo -e "\033[1;33m[WARNING]\033[0m  $(redact_line "$*")"; }
ERROR()    { echo -e "\033[1;31m[ERROR]\033[0m    $(redact_line "$*")"; }
BACKUP()   { echo -e "\033[1;36m[BACKUP]\033[0m   $(redact_line "$*")"; }
MONITOR()  { echo -e "\033[1;35m[MONITOR]\033[0m  $(redact_line "$*")"; }
SECURITY() { echo -e "\033[1;91m[SECURITY]\033[0m $(redact_line "$*")"; }
SEPARATOR(){ echo -e "\033[1;37m------------------------------------------------------------\033[0m"; }

# ------------------------------------------------------------------------------
# Safe .env loader
# Never uses `source`/`.` on the file. Only accepts KEY=VALUE lines, skips
# comments/blank lines, strips surrounding quotes. Nothing is executed.
# Dangerous variable names are blocked unless explicitly allowed.
# ------------------------------------------------------------------------------
DANGEROUS_ENV_VARS=(PATH LD_PRELOAD LD_LIBRARY_PATH BASH_ENV ENV IFS SHELL)

is_dangerous_var() {
    local name="$1" d
    for d in "${DANGEROUS_ENV_VARS[@]}"; do
        [[ "$name" == "$d" ]] && return 0
    done
    return 1
}

load_env_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    INFO "Loading environment variables from $file (safe parser)..."
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" =~ ^[[:space:]]*export[[:space:]]+ ]]; then
            line="${line#*export}"
        fi
        if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"
            if is_dangerous_var "$key" && [[ "${ALLOW_DANGEROUS_ENV:-0}" != "1" ]]; then
                WARNING "Refusing to set dangerous variable '$key' from .env (set ALLOW_DANGEROUS_ENV=1 to override)"
                continue
            fi
            printf -v "$key" '%s' "$value"
            export "$key"
        else
            WARNING "Ignoring invalid .env line: ${line:0:40}"
        fi
    done < "$file"
    SUCCESS "Environment variables loaded safely"
}

manage_env_file() {
    if [[ -f ".env.example" ]] && [[ ! -f ".env" ]]; then
        INFO "Creating .env from .env.example..."
        cp .env.example .env
        chmod 600 .env 2>/dev/null || true
        SUCCESS ".env file created (permissions restricted to owner)"
    fi
    load_env_file ".env"
}

# ------------------------------------------------------------------------------
# Discord status webhook (embeds) - payload always built with jq so every
# value is correctly JSON-escaped. Length-limited to Discord's embed limits.
# One retry with backoff; never blocks startup/shutdown on failure.
# ------------------------------------------------------------------------------
discord_notify() {
    local title="$1" description="$2" color="$3"
    [[ "${ENABLE_DISCORD_STATUS:-0}" == "1" ]] || return 0
    [[ -n "${DISCORD_WEBHOOK_URL:-}" ]] || return 0
    command -v jq &>/dev/null || { WARNING "jq not available, skipping Discord notification"; return 0; }

    title="$(redact_line "$title")"
    description="$(redact_line "$description")"
    title="${title:0:256}"
    description="${description:0:4000}"

    local node_ver ram_line uptime_m
    node_ver=$(node --version 2>/dev/null || echo "unknown")
    uptime_m=$(( ( $(date +%s) - START_TIME ) / 60 ))
    ram_line=$(free -m 2>/dev/null | awk '/Mem:/{printf "%sMB / %sMB", $3, $2}')

    local payload
    payload=$(jq -n \
        --arg title "$title" \
        --arg desc "$description" \
        --argjson color "$color" \
        --arg server "${SERVER_NAME:-Unknown}" \
        --arg node "$node_ver" \
        --arg uptime "${uptime_m}m" \
        --arg ram "${ram_line:-N/A}" \
        '{embeds: [{title: $title, description: $desc, color: $color, fields: [
            {name: "Server", value: $server, inline: true},
            {name: "Node.js", value: $node, inline: true},
            {name: "Uptime", value: $uptime, inline: true},
            {name: "RAM", value: $ram, inline: true}
        ]}]}' 2>/dev/null)

    [[ -n "$payload" ]] || { WARNING "Failed to build Discord payload"; return 0; }

    local attempt http_code
    for attempt in 1 2; do
        http_code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
            -H "Content-Type: application/json" -X POST -d "$payload" \
            "$DISCORD_WEBHOOK_URL" 2>/dev/null || echo "000")
        [[ "$http_code" =~ ^2 ]] && return 0
        [[ "$attempt" -eq 1 ]] && sleep 2
    done
    WARNING "Discord notification failed (http $http_code)"
    return 0
}

security_alert() {
    local what="$1"
    discord_notify "Security: ${what} executed" "An admin-configured override command ran on this server." 15158332
}

# ------------------------------------------------------------------------------
# Health check system - runs AFTER manage_env_file, so REQUIRED_ENV_VARS
# defined only in .env are correctly validated.
# ------------------------------------------------------------------------------
check_db_reachable() {
    local label="$1" host="$2" port="$3"
    [[ -n "$host" ]] || return 0
    if command -v nc &>/dev/null && nc -z -w3 "$host" "$port" 2>/dev/null; then
        SUCCESS "$label reachable at ${host}:${port}"
    else
        WARNING "$label not reachable yet at ${host}:${port} (may start later)"
    fi
}

run_health_check() {
    local errors=0
    SEPARATOR
    INFO "Running startup health check..."

    if command -v node &>/dev/null; then
        SUCCESS "Node.js: $(node --version)"
    else
        ERROR "Node.js not found"; errors=$((errors+1))
    fi

    # curl is genuinely required (downloads, webhooks, health pings) and
    # ships in every yolks image, so it stays a hard failure.
    if ! command -v curl &>/dev/null; then
        ERROR "Required tool 'curl' not found in runtime image"; errors=$((errors+1))
    fi

    # jq is a convenience tool, not a runtime dependency: every call site in
    # this script already checks `command -v jq` and degrades gracefully
    # (get_script_from_package_json, discord_notify, show_startup_summary).
    # It should never be able to crash-loop the whole server. Try to self-heal
    # first (a copy may already be persisted at .bin/jq by _install.sh, or we
    # can fetch one now), but only ever WARN if it's still missing after that.
    if ! command -v jq &>/dev/null; then
        WARNING "'jq' not found (runtime images don't ship it) - attempting self-heal..."
        mkdir -p /home/container/.bin 2>/dev/null
        if [[ -w /home/container/.bin ]]; then
            local jq_arch jq_url
            case "$(uname -m)" in
                x86_64)  jq_arch="amd64" ;;
                aarch64) jq_arch="arm64" ;;
                *)       jq_arch="" ;;
            esac
            if [[ -n "$jq_arch" ]]; then
                jq_url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${jq_arch}"
                if curl -fsSL -m 15 -o /home/container/.bin/jq "$jq_url" 2>/dev/null \
                    && [[ -s /home/container/.bin/jq ]]; then
                    chmod +x /home/container/.bin/jq
                fi
            fi
        fi
    fi
    if command -v jq &>/dev/null; then
        SUCCESS "jq: available ($(jq --version 2>/dev/null))"
    else
        WARNING "jq unavailable - JSON parsing/Discord embeds/package name display will be degraded, but the app will still start normally"
    fi

    if [[ "${PACKAGE_MANAGER:-auto}" != "auto" ]] && ! command -v "${PACKAGE_MANAGER}" &>/dev/null; then
        ERROR "Package manager '${PACKAGE_MANAGER}' not found"; errors=$((errors+1))
    fi

    if [[ -f "package.json" ]]; then
        if command -v jq &>/dev/null && ! jq empty package.json >/dev/null 2>&1; then
            ERROR "package.json is not valid JSON"; errors=$((errors+1))
        else
            SUCCESS "package.json found and valid"
        fi
    else
        WARNING "package.json not found (falling back to MAIN_FILE)"
    fi

    if [[ -n "${MAIN_FILE:-}" ]]; then
        case "${MAIN_FILE}" in
            *.js|*.mjs|*.cjs|*.ts) : ;;
            *) ERROR "MAIN_FILE '${MAIN_FILE}' has a disallowed extension (.js/.mjs/.cjs/.ts only)"; errors=$((errors+1)) ;;
        esac
    fi

    [[ -n "${PORT:-}" ]] && SUCCESS "PORT: ${PORT}" || WARNING "PORT not set, defaulting to 8080"
    [[ -n "${HOST:-}" ]] && SUCCESS "HOST: ${HOST}" || WARNING "HOST not set, defaulting to 0.0.0.0"

    if [[ -w . ]]; then
        SUCCESS "Write permissions OK in $(pwd)"
    else
        ERROR "No write permissions in /home/container"; errors=$((errors+1))
    fi

    if [[ "${ENABLE_BACKUPS:-0}" == "1" ]]; then
        local bloc="${BACKUP_LOCATION:-/home/container/backups}"
        mkdir -p "$bloc" 2>/dev/null
        if [[ -w "$bloc" ]]; then
            SUCCESS "Backup location writable: $bloc"
        else
            ERROR "Backup location not writable: $bloc"; errors=$((errors+1))
        fi
    fi

    if [[ -n "${REQUIRED_ENV_VARS:-}" ]]; then
        IFS=',' read -ra req_vars <<< "$REQUIRED_ENV_VARS"
        local v vname
        for v in "${req_vars[@]}"; do
            vname="$(echo "$v" | xargs)"
            [[ -z "$vname" ]] && continue
            if [[ -z "${!vname:-}" ]]; then
                ERROR "Required environment variable '$vname' is not set"
                errors=$((errors+1))
            else
                SUCCESS "Required variable '$vname' is set"
            fi
        done
    fi

    check_db_reachable "MySQL/MariaDB" "${MYSQL_HOST:-}" "${MYSQL_PORT:-3306}"
    check_db_reachable "PostgreSQL" "${POSTGRES_HOST:-}" "${POSTGRES_PORT:-5432}"
    check_db_reachable "Redis" "${REDIS_HOST:-}" "${REDIS_PORT:-6379}"
    check_db_reachable "MongoDB" "${MONGODB_HOST:-}" "${MONGODB_PORT:-27017}"

    if [[ $errors -gt 0 ]]; then
        ERROR "Health check failed with $errors error(s)"
        exit 1
    fi
    SUCCESS "Health check passed"
    SEPARATOR
}

# ------------------------------------------------------------------------------
# Package manager detection
# ------------------------------------------------------------------------------
detect_pm() {
    if [[ "${PACKAGE_MANAGER:-auto}" != "auto" ]]; then
        echo "${PACKAGE_MANAGER}"; return
    fi
    if [[ -f "bun.lockb" || -f "bun.lock" ]]; then echo "bun"
    elif [[ -f "pnpm-lock.yaml" ]]; then echo "pnpm"
    elif [[ -f "yarn.lock" ]]; then echo "yarn"
    elif [[ -f "package-lock.json" || -f "npm-shrinkwrap.json" ]]; then echo "npm"
    elif [[ -f "package.json" ]]; then echo "npm"
    else echo "none"
    fi
}

get_script_from_package_json() {
    local script_name="$1"
    [[ -f "package.json" ]] && command -v jq &>/dev/null || { echo ""; return; }
    jq -r ".scripts[\"$script_name\"] // empty" package.json 2>/dev/null
}

detect_dependency_changes() {
    local hash_file=".lockfile_hash" current_hash="$1"
    if [[ -f "$hash_file" ]] && [[ "$(cat "$hash_file")" == "$current_hash" ]]; then
        return 1
    fi
    printf '%s' "$current_hash" > "$hash_file"
    return 0
}

# Installs dependencies. If RUN_BUILD is enabled, devDependencies are always
# installed regardless of NODE_ENV, since TypeScript/Next.js/NestJS build
# tooling normally lives there and NODE_ENV=production would otherwise strip
# it before the build step runs.
install_deps() {
    local pm="$1" needs_install=0
    local content_hash
    content_hash=$( { cat package.json 2>/dev/null
        local lock
        for lock in package-lock.json yarn.lock pnpm-lock.yaml bun.lockb bun.lock npm-shrinkwrap.json; do
            [[ -f "$lock" ]] && cat "$lock" 2>/dev/null
        done
        echo "$pm"
    } | sha256sum | cut -d' ' -f1)

    if [[ "${FORCE_REINSTALL:-0}" == "1" ]]; then
        WARNING "Force reinstall enabled"; needs_install=1
    elif [[ ! -d "node_modules" ]]; then
        INFO "node_modules not found"; needs_install=1
    elif detect_dependency_changes "$content_hash"; then
        INFO "Dependency changes detected"; needs_install=1
    fi

    if [[ $needs_install -eq 0 ]]; then
        SUCCESS "Dependencies already up to date, skipping install"
        return 0
    fi

    local want_dev=0
    [[ "${RUN_BUILD:-0}" == "1" ]] && want_dev=1
    [[ "${NODE_ENV:-production}" != "production" ]] && want_dev=1

    if [[ "${REQUIRE_LOCKFILE:-0}" == "1" ]]; then
        case "$pm" in
            npm)  [[ -f package-lock.json ]] || { ERROR "REQUIRE_LOCKFILE=1 but package-lock.json is missing"; return 1; } ;;
            yarn) [[ -f yarn.lock ]] || { ERROR "REQUIRE_LOCKFILE=1 but yarn.lock is missing"; return 1; } ;;
            pnpm) [[ -f pnpm-lock.yaml ]] || { ERROR "REQUIRE_LOCKFILE=1 but pnpm-lock.yaml is missing"; return 1; } ;;
            bun)  [[ -f bun.lockb || -f bun.lock ]] || { ERROR "REQUIRE_LOCKFILE=1 but bun.lock(b) is missing"; return 1; } ;;
        esac
    elif [[ "$pm" != "none" ]]; then
        case "$pm" in
            npm)  [[ -f package-lock.json ]] || WARNING "No package-lock.json found; installs will not be reproducible" ;;
            yarn) [[ -f yarn.lock ]] || WARNING "No yarn.lock found; installs will not be reproducible" ;;
            pnpm) [[ -f pnpm-lock.yaml ]] || WARNING "No pnpm-lock.yaml found; installs will not be reproducible" ;;
            bun)  [[ -f bun.lockb || -f bun.lock ]] || WARNING "No bun lockfile found; installs will not be reproducible" ;;
        esac
    fi

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
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        ERROR "Dependency installation failed (exit $rc)"
        return $rc
    fi

    if [[ "${AUDIT_CHECK:-0}" == "1" ]]; then
        INFO "Running dependency audit (non-fatal)..."
        case "$pm" in
            npm)  npm audit --audit-level="${AUDIT_LEVEL:-high}" || WARNING "Audit reported issues" ;;
            pnpm) pnpm audit --audit-level="${AUDIT_LEVEL:-high}" || WARNING "Audit reported issues" ;;
            yarn) yarn audit --level "${AUDIT_LEVEL:-high}" || WARNING "Audit reported issues" ;;
            bun)  bun audit || WARNING "Audit reported issues" ;;
        esac
    fi

    SUCCESS "Dependencies installed successfully"

    if [[ "${RUN_BUILD:-0}" == "1" && "${PRUNE_DEV_AFTER_BUILD:-0}" == "1" ]]; then
        run_build "$pm" || return 1
        INFO "Pruning devDependencies after build..."
        case "$pm" in
            npm)  npm prune --omit=dev ;;
            pnpm) pnpm prune --prod ;;
            yarn) yarn install --production ;;
            bun)  : ;;
        esac
        POST_BUILD_ALREADY_RUN=1
    fi
    return 0
}

run_prisma() {
    if [[ "${RUN_PRISMA_GENERATE:-0}" == "1" ]]; then
        INFO "Running Prisma generate..."
        npx prisma generate || { ERROR "Prisma generate failed"; return 1; }
        SUCCESS "Prisma generate completed"
    fi
    if [[ "${RUN_MIGRATIONS:-0}" == "1" ]]; then
        INFO "Running database migrations..."
        if npx prisma migrate deploy; then
            SUCCESS "Migrations completed"
        else
            ERROR "Prisma migrate deploy failed"
            if [[ "${PRISMA_ALLOW_DB_PUSH_FALLBACK:-0}" == "1" ]]; then
                WARNING "PRISMA_ALLOW_DB_PUSH_FALLBACK=1 - falling back to 'prisma db push' (can cause data loss)"
                security_alert "Prisma db push fallback"
                npx prisma db push || { ERROR "Prisma db push also failed"; return 1; }
            else
                ERROR "Refusing to auto-fallback to 'prisma db push' (set PRISMA_ALLOW_DB_PUSH_FALLBACK=1 to allow). Aborting startup."
                return 1
            fi
        fi
    fi
    return 0
}

run_build() {
    [[ "${RUN_BUILD:-0}" == "1" ]] || return 0
    [[ "${POST_BUILD_ALREADY_RUN:-0}" == "1" ]] && return 0
    local pm="$1"
    INFO "Running build script..."
    case "$pm" in
        bun) bun run build ;;
        pnpm) pnpm run build ;;
        yarn) yarn run build ;;
        npm) npm run build ;;
        *) WARNING "No package manager detected, skipping build"; return 0 ;;
    esac
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        ERROR "Build failed (exit $rc)"
        return $rc
    fi
    SUCCESS "Build completed"
    return 0
}

# ------------------------------------------------------------------------------
# Safe git pull (auto update) - never force-pushes over local changes
# ------------------------------------------------------------------------------
safe_git_pull() {
    [[ "${AUTO_UPDATE:-0}" == "1" ]] || return 0
    [[ -d .git ]] || return 0
    INFO "Checking for repository updates..."
    if ! git diff --quiet || ! git diff --cached --quiet; then
        WARNING "Uncommitted changes detected. Skipping git pull to avoid conflicts."
        return 0
    fi
    if git pull --rebase --quiet 2>/dev/null; then
        SUCCESS "Repository updated successfully"
    else
        WARNING "Rebase pull failed, attempting normal pull..."
        if git pull --quiet 2>/dev/null; then
            SUCCESS "Repository updated successfully"
        else
            ERROR "Git pull failed, continuing with existing code"
            discord_notify "Auto-update failed" "git pull failed on startup; continuing with existing code." 16753920
        fi
    fi
}

# ------------------------------------------------------------------------------
# Startup command detection - builds an ARGV ARRAY (START_CMD_ARR), never a
# string that gets eval'd/shell-interpreted. Priority: CUSTOM_STARTUP_CMD
# (admin only) > package.json scripts > MAIN_FILE > common entrypoints.
# "dev" script is intentionally NOT used as a production fallback unless
# explicitly opted in.
# ------------------------------------------------------------------------------
detect_start_cmd() {
    local pm="$1"
    START_CMD_ARR=()
    START_CMD_DISPLAY=""

    if [[ -n "${CUSTOM_STARTUP_CMD:-}" ]]; then
        SECURITY "Using CUSTOM_STARTUP_CMD (admin-configured). This bypasses autodetection and uses a shell."
        security_alert "CUSTOM_STARTUP_CMD"
        START_CMD_ARR=(bash -c "${CUSTOM_STARTUP_CMD}")
        START_CMD_DISPLAY="[CUSTOM_STARTUP_CMD - admin configured]"
        return 0
    fi

    local script_priority=(start production serve)
    [[ "${ALLOW_DEV_SCRIPT_FALLBACK:-0}" == "1" ]] && script_priority+=(dev)

    if [[ -f "package.json" ]]; then
        local script script_cmd
        for script in "${script_priority[@]}"; do
            script_cmd=$(get_script_from_package_json "$script")
            if [[ -n "$script_cmd" ]]; then
                case "$pm" in
                    bun)  START_CMD_ARR=(bun run "$script") ;;
                    pnpm) START_CMD_ARR=(pnpm run "$script") ;;
                    yarn) START_CMD_ARR=(yarn run "$script") ;;
                    npm)  START_CMD_ARR=(npm run "$script") ;;
                esac
                if [[ ${#START_CMD_ARR[@]} -gt 0 ]]; then
                    START_CMD_DISPLAY="${START_CMD_ARR[*]}"
                    return 0
                fi
            fi
        done
    fi

    local -a node_args_arr=()
    [[ -n "${NODE_ARGS:-}" ]] && read -ra node_args_arr <<< "$NODE_ARGS"

    if [[ -n "${MAIN_FILE:-}" ]] && [[ -f "${MAIN_FILE}" ]]; then
        case "${MAIN_FILE}" in
            *.ts) START_CMD_ARR=(npx tsx "${MAIN_FILE}" "${node_args_arr[@]}") ;;
            *)    START_CMD_ARR=(node "${MAIN_FILE}" "${node_args_arr[@]}") ;;
        esac
        START_CMD_DISPLAY="${START_CMD_ARR[*]}"
        return 0
    fi

    local entry
    for entry in index.js server.js app.js main.js dist/index.js dist/server.js dist/main.js; do
        if [[ -f "$entry" ]]; then
            START_CMD_ARR=(node "$entry" "${node_args_arr[@]}")
            START_CMD_DISPLAY="${START_CMD_ARR[*]}"
            return 0
        fi
    done

    return 1
}

# ------------------------------------------------------------------------------
# Monitoring - prefers cgroup limits so percentages reflect the container's
# actual quota rather than host-level /proc stats.
# ------------------------------------------------------------------------------
read_mem_pct() {
    if [[ -r /sys/fs/cgroup/memory.max && -r /sys/fs/cgroup/memory.current ]]; then
        local limit used
        limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
        used=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
        if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -gt 0 ]]; then
            echo $(( used * 100 / limit )); return
        fi
    elif [[ -r /sys/fs/cgroup/memory/memory.limit_in_bytes && -r /sys/fs/cgroup/memory/memory.usage_in_bytes ]]; then
        local limit used
        limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)
        used=$(cat /sys/fs/cgroup/memory/memory.usage_in_bytes 2>/dev/null)
        if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -lt 9223372036854771712 ]] && [[ "$limit" -gt 0 ]]; then
            echo $(( used * 100 / limit )); return
        fi
    fi
    free 2>/dev/null | awk '/Mem:/{printf "%d", ($3/$2)*100}'
}

start_monitoring() {
    [[ "${ENABLE_MONITORING:-0}" == "1" ]] || return 0
    local interval="${MONITOR_INTERVAL:-60}"
    local cpu_alert="${CPU_ALERT:-90}"
    local ram_alert="${RAM_ALERT:-90}"
    local disk_alert="${DISK_ALERT:-90}"
    local health_url="${HEALTHCHECK_URL:-}"

    (
        while true; do
            sleep "$interval"
            local ram_pct disk_pct cpu_pct
            ram_pct=$(read_mem_pct)
            disk_pct=$(df -P /home/container 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
            cpu_pct=$(top -bn1 2>/dev/null | awk -F',' '/Cpu\(s\)/{gsub(/[^0-9.]/,"",$1); print int(100-$4)}' 2>/dev/null)

            [[ -n "$ram_pct" ]] && [[ "$ram_pct" -ge "$ram_alert" ]] 2>/dev/null && {
                MONITOR "High RAM usage: ${ram_pct}%"
                discord_notify "High RAM Usage" "RAM usage at ${ram_pct}% (threshold ${ram_alert}%)" 16753920
            }
            [[ -n "$disk_pct" ]] && [[ "$disk_pct" -ge "$disk_alert" ]] 2>/dev/null && {
                MONITOR "High disk usage: ${disk_pct}%"
                discord_notify "High Disk Usage" "Disk usage at ${disk_pct}% (threshold ${disk_alert}%)" 16753920
            }
            [[ -n "$cpu_pct" ]] && [[ "$cpu_pct" -ge "$cpu_alert" ]] 2>/dev/null && {
                MONITOR "High CPU usage: ${cpu_pct}%"
                discord_notify "High CPU Usage" "CPU usage at ${cpu_pct}% (threshold ${cpu_alert}%)" 16753920
            }
            if [[ -n "$health_url" ]]; then
                if ! curl -sf -m 5 -o /dev/null "$health_url"; then
                    MONITOR "Application health check failed: $health_url"
                    discord_notify "Health Check Failed" "GET ${health_url} did not return success" 15158332
                fi
            fi
        done
    ) &
    MONITOR_PID=$!
    MONITOR "Monitoring started (interval: ${interval}s, PID: $MONITOR_PID)"
}

# ------------------------------------------------------------------------------
# Backup system - verifies tar's exit code AND the resulting archive's
# integrity before declaring success or rotating older backups. Checks free
# disk space first. Writes to a .tmp name and only renames into place on
# success, so a failed run can never masquerade as a valid backup.
# ------------------------------------------------------------------------------
run_backup_now() {
    local location="${BACKUP_LOCATION:-/home/container/backups}"
    mkdir -p "$location"

    local avail_kb
    avail_kb=$(df -Pk /home/container 2>/dev/null | awk 'NR==2{print $4}')
    if [[ -n "$avail_kb" ]] && [[ "$avail_kb" -lt "${BACKUP_MIN_FREE_KB:-102400}" ]]; then
        ERROR "Insufficient free disk space for backup (${avail_kb}KB available), skipping"
        discord_notify "Backup Skipped" "Not enough free disk space to safely create a backup." 16753920
        return 1
    fi

    local ts exclude_rel
    ts=$(date +%Y%m%d-%H%M%S)
    exclude_rel=$(realpath --relative-to=/home/container "$location" 2>/dev/null || echo "backups")

    BACKUP "Creating backup backup-${ts}.tar.gz..."
    local tmp_archive="${location}/.backup-${ts}.tar.gz.tmp"
    local err_log; err_log=$(mktemp)
    if tar --exclude="./${exclude_rel}" --exclude="./node_modules" --exclude="./.git" \
           -czf "$tmp_archive" . 2>"$err_log"; then
        if tar -tzf "$tmp_archive" >/dev/null 2>&1; then
            mv "$tmp_archive" "${location}/backup-${ts}.tar.gz"
            BACKUP "Backup verified and saved: backup-${ts}.tar.gz"
        else
            ERROR "Backup archive failed integrity verification, discarding"
            rm -f "$tmp_archive" "$err_log"
            return 1
        fi
    else
        ERROR "Backup command failed: $(tail -c 300 "$err_log")"
        rm -f "$tmp_archive" "$err_log"
        return 1
    fi
    rm -f "$err_log"

    local retention="${BACKUP_RETENTION:-5}"
    local count
    count=$(ls -1t "${location}"/backup-*.tar.gz 2>/dev/null | wc -l)
    if [[ "$count" -gt "$retention" ]]; then
        ls -1t "${location}"/backup-*.tar.gz 2>/dev/null | tail -n +"$((retention+1))" | xargs -r rm -f
        BACKUP "Rotated old backups, keeping most recent $retention"
    fi
    return 0
}

start_backup_scheduler() {
    [[ "${ENABLE_BACKUPS:-0}" == "1" ]] || return 0
    local interval_min="${BACKUP_INTERVAL:-60}"
    (
        while true; do
            sleep "$((interval_min * 60))"
            run_backup_now
        done
    ) &
    BACKUP_PID=$!
    BACKUP "Automatic backups enabled (every ${interval_min} minutes, PID: $BACKUP_PID)"
}

# Restore: rejects any filename containing a path separator or "..", inspects
# archive contents for absolute paths / traversal entries before extracting
# anything, uses --no-same-owner, and only reports success after checking
# tar's actual exit code.
restore_backup_if_requested() {
    [[ -n "${RESTORE_BACKUP:-}" ]] || return 0
    local location="${BACKUP_LOCATION:-/home/container/backups}"

    if [[ "${RESTORE_BACKUP}" == *"/"* ]] || [[ "${RESTORE_BACKUP}" == *".."* ]]; then
        ERROR "Invalid RESTORE_BACKUP value '${RESTORE_BACKUP}' (must be a bare filename, no path separators)"
        return 0
    fi

    local target="${location}/${RESTORE_BACKUP}"
    if [[ ! -f "$target" ]]; then
        ERROR "Requested restore backup not found: ${RESTORE_BACKUP}"
        return 0
    fi

    if tar -tzf "$target" 2>/dev/null | grep -qE '^(/|\.\./|.*/\.\./)'; then
        ERROR "Backup archive '${RESTORE_BACKUP}' contains unsafe paths, refusing to restore"
        discord_notify "Restore Refused" "Archive ${RESTORE_BACKUP} contained unsafe paths and was not restored." 15158332
        return 0
    fi

    WARNING "Restore requested from ${RESTORE_BACKUP}. Creating emergency backup first..."
    run_backup_now || WARNING "Emergency pre-restore backup failed; continuing with restore anyway"

    BACKUP "Restoring from ${RESTORE_BACKUP}..."
    if tar -xzf "$target" -C /home/container --no-same-owner 2>/tmp/restore.log; then
        SUCCESS "Restore completed from ${RESTORE_BACKUP}. Remove RESTORE_BACKUP variable to avoid restoring again."
    else
        ERROR "Restore failed, see /tmp/restore.log. Original files may be partially overwritten."
        discord_notify "Restore Failed" "tar extraction failed for ${RESTORE_BACKUP}." 15158332
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Proxy / anti-DDoS documentation & env passthrough
# ------------------------------------------------------------------------------
apply_proxy_settings() {
    if [[ "${PROXY_MODE:-0}" == "1" ]]; then
        INFO "Proxy mode enabled. TRUST_PROXY=${TRUST_PROXY:-1}, CLOUDFLARE_PROXY=${CLOUDFLARE_PROXY:-0}"
        export TRUST_PROXY="${TRUST_PROXY:-1}"
        export CLOUDFLARE_PROXY="${CLOUDFLARE_PROXY:-0}"
    fi
    if [[ "${RATE_LIMIT_ENABLED:-0}" == "1" ]]; then
        INFO "Rate limiting hint enabled for app: RATE_LIMIT_REQUESTS=${RATE_LIMIT_REQUESTS:-100}/min"
        export RATE_LIMIT_ENABLED RATE_LIMIT_REQUESTS
    fi
    WARNING "Reminder: this egg does not replace external DDoS protection (Cloudflare/Nginx/HAProxy); it only exposes hints for app-level handling."
}

check_node_options() {
    [[ -n "${NODE_OPTIONS:-}" ]] || return 0
    if [[ "$NODE_OPTIONS" =~ --inspect(-brk)?=0\.0\.0\.0 ]]; then
        WARNING "NODE_OPTIONS binds the debugger to 0.0.0.0 - this exposes a remote-code-execution surface if the port is reachable. Strongly recommend binding to 127.0.0.1 instead."
    fi
    export NODE_OPTIONS
}

show_startup_summary() {
    SEPARATOR
    echo -e "\033[1;32mSTARTUP SUMMARY\033[0m"
    echo -e "  Node.js:          $(node --version)"
    echo -e "  Package Manager:  $PM"
    if [[ -f "package.json" ]] && command -v jq &>/dev/null; then
        echo -e "  Application:      $(jq -r '.name // "unknown"' package.json 2>/dev/null)"
    fi
    echo -e "  Startup Command:  $START_CMD_DISPLAY"
    echo -e "  PORT:             ${PORT:-8080}"
    echo -e "  HOST:             ${HOST:-0.0.0.0}"
    echo -e "  NODE_ENV:         ${NODE_ENV:-production}"
    [[ -n "${NODE_OPTIONS:-}" ]] && echo -e "  Memory Limit:     ${NODE_OPTIONS}"

    local features=()
    [[ "${RUN_BUILD:-0}" == "1" ]] && features+=("Build")
    [[ "${RUN_PRISMA_GENERATE:-0}" == "1" || "${RUN_MIGRATIONS:-0}" == "1" ]] && features+=("Prisma")
    [[ "${AUTO_UPDATE:-0}" == "1" ]] && features+=("Auto-Update")
    [[ "${ENABLE_MONITORING:-0}" == "1" ]] && features+=("Monitoring")
    [[ "${ENABLE_BACKUPS:-0}" == "1" ]] && features+=("Auto-Backups")
    [[ "${ENABLE_DISCORD_STATUS:-0}" == "1" ]] && features+=("Discord-Status")
    [[ "${PROXY_MODE:-0}" == "1" ]] && features+=("Proxy-Mode")
    [[ -n "${CUSTOM_STARTUP_CMD:-}" ]] && features+=("Custom-Startup[ADMIN]")
    [[ ${#features[@]} -gt 0 ]] && echo -e "  Features:         ${features[*]}"

    echo -e "  Crash Restart:    Enabled (max ${MAX_CRASHES:-5} in ${CRASH_WINDOW:-300}s window)"
    SEPARATOR
}

# ------------------------------------------------------------------------------
# Graceful shutdown - waits up to SHUTDOWN_TIMEOUT seconds for the child's
# process group to exit after SIGTERM, then escalates to SIGKILL.
# ------------------------------------------------------------------------------
cleanup() {
    STOPPING=1
    INFO "Shutdown signal received, stopping gracefully..."
    discord_notify "Server Offline" "The server is shutting down." 15158332

    if [[ -n "$CHILD_PID" ]]; then
        local pgid="${CHILD_PGID:-$CHILD_PID}"
        kill -TERM "-$pgid" 2>/dev/null || kill -TERM "$CHILD_PID" 2>/dev/null
        local waited=0 timeout="${SHUTDOWN_TIMEOUT:-15}"
        while kill -0 "$CHILD_PID" 2>/dev/null && [[ $waited -lt $timeout ]]; do
            sleep 1; waited=$((waited+1))
        done
        if kill -0 "$CHILD_PID" 2>/dev/null; then
            WARNING "Application did not exit within ${timeout}s, forcing shutdown"
            kill -KILL "-$pgid" 2>/dev/null || kill -KILL "$CHILD_PID" 2>/dev/null
        fi
    fi
    [[ -n "$MONITOR_PID" ]] && kill "$MONITOR_PID" 2>/dev/null
    [[ -n "$BACKUP_PID" ]] && kill "$BACKUP_PID" 2>/dev/null
    wait 2>/dev/null
    exit 0
}
trap cleanup SIGTERM SIGINT

# ------------------------------------------------------------------------------
# Application run loop - time-windowed crash-loop detection with exponential
# backoff. Runs the child in its own session/process group via `setsid` so
# shutdown can signal the whole group, not just a package-manager wrapper PID.
# ------------------------------------------------------------------------------
run_app_loop() {
    local -a crash_times=()
    local max_crashes="${MAX_CRASHES:-5}"
    local crash_window="${CRASH_WINDOW:-300}"
    local base_wait="${CRASH_WAIT:-5}"
    local attempt_in_window=0

    while true; do
        setsid "${START_CMD_ARR[@]}" &
        CHILD_PID=$!
        CHILD_PGID=$CHILD_PID
        wait "$CHILD_PID"
        local exit_code=$?
        CHILD_PID=""

        [[ $STOPPING -eq 1 ]] && break

        if [[ $exit_code -eq 0 ]]; then
            INFO "Application exited normally (code 0)."
            break
        fi

        local now; now=$(date +%s)
        crash_times+=("$now")
        local -a kept=() t
        for t in "${crash_times[@]}"; do
            [[ $(( now - t )) -le $crash_window ]] && kept+=("$t")
        done
        crash_times=("${kept[@]}")
        attempt_in_window=${#crash_times[@]}

        ERROR "Application crashed with exit code $exit_code (${attempt_in_window}/${max_crashes} crashes in last ${crash_window}s)"
        discord_notify "Server Crashed" "Exit code: ${exit_code}. Crashes in window: ${attempt_in_window}/${max_crashes}" 15158332

        if [[ $attempt_in_window -ge $max_crashes ]]; then
            ERROR "Crash-loop detected: ${max_crashes} crashes within ${crash_window}s. Stopping automatic restarts."
            discord_notify "Server Stopped" "Crash-loop detected (${max_crashes} crashes / ${crash_window}s). Manual intervention required." 15158332
            exit 1
        fi

        local backoff=$(( base_wait * (2 ** (attempt_in_window - 1)) ))
        [[ $backoff -gt 60 ]] && backoff=60
        WARNING "Restarting in ${backoff}s (exponential backoff)..."
        sleep "$backoff"
        discord_notify "Server Restarted" "Restarting after crash (${attempt_in_window}/${max_crashes} in window)..." 16776960
    done
}

# ==============================================================================
# MAIN
# .env is loaded BEFORE the health check, so REQUIRED_ENV_VARS defined only
# in .env are correctly validated.
# ==============================================================================
manage_env_file
run_health_check
restore_backup_if_requested
safe_git_pull

PM=$(detect_pm)
INFO "Detected package manager: $PM"

if [[ -n "${NODE_PACKAGES:-}" ]]; then
    INFO "Installing additional packages: ${NODE_PACKAGES}"
    valid=1
    for pkg in ${NODE_PACKAGES}; do
        [[ "$pkg" =~ ^[A-Za-z0-9@/_.-]+$ ]] || { ERROR "Rejecting unsafe package spec: $pkg"; valid=0; }
        [[ "$pkg" == -* ]] && { ERROR "Rejecting package spec that looks like a flag: $pkg"; valid=0; }
    done
    if [[ $valid -eq 1 ]]; then
        case "$PM" in
            bun) bun add ${NODE_PACKAGES} ;;
            pnpm) pnpm add ${NODE_PACKAGES} ;;
            yarn) yarn add ${NODE_PACKAGES} ;;
            *) npm install ${NODE_PACKAGES} ;;
        esac
        SUCCESS "Additional packages installed"
    else
        ERROR "Skipping NODE_PACKAGES install due to invalid entries"
    fi
fi

if [[ -n "${UNNODE_PACKAGES:-}" ]]; then
    INFO "Removing packages: ${UNNODE_PACKAGES}"
    case "$PM" in
        bun) bun remove ${UNNODE_PACKAGES} ;;
        pnpm) pnpm remove ${UNNODE_PACKAGES} ;;
        yarn) yarn remove ${UNNODE_PACKAGES} ;;
        *) npm uninstall ${UNNODE_PACKAGES} ;;
    esac
    SUCCESS "Packages removed"
fi

install_deps "$PM" || { ERROR "Aborting startup due to dependency install failure"; exit 1; }

if [[ -n "${CUSTOM_INSTALL_CMD:-}" ]]; then
    SECURITY "Running CUSTOM_INSTALL_CMD (admin-configured). Ensure you trust this command."
    security_alert "CUSTOM_INSTALL_CMD"
    bash -c "${CUSTOM_INSTALL_CMD}"
    SUCCESS "Custom install command completed"
fi

run_prisma || { ERROR "Aborting startup due to Prisma failure"; exit 1; }
run_build "$PM" || { ERROR "Aborting startup due to build failure"; exit 1; }
apply_proxy_settings
check_node_options

if ! detect_start_cmd "$PM"; then
    ERROR "No start command or main file found!"
    ERROR "Set a 'start' script in package.json, or set MAIN_FILE, or set CUSTOM_STARTUP_CMD."
    exit 1
fi

show_startup_summary

export PORT="${PORT:-8080}"
export HOST="${HOST:-0.0.0.0}"
export NODE_ENV="${NODE_ENV:-production}"

start_monitoring
start_backup_scheduler

discord_notify "Server Online" "The server has started successfully." 3066993

INFO "Starting application: $START_CMD_DISPLAY"
run_app_loop
