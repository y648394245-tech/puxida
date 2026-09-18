#!/bin/bash
# PXD GitHub one-click installer (concise). Downloads pxd-concise-son.tar.gz from Releases.
set -o pipefail
# Shared compatibility code, embedded into both standalone installers.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH
pxd_error() { printf '[pxd] ERROR: %s\n' "$*" >&2; return 1; }
pxd_preflight() {
    [ "${BASH_VERSINFO[0]}" -ge 4 ] || { pxd_error "Bash 4 or newer is required"; return 1; }
    [ "$(id -u)" = 0 ] || { pxd_error 'Run as root'; return 1; }
    [ "$(uname -s)" = Linux ] || return 1
    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) pxd_error 'This package contains x86_64 binaries only; an ARM/other build is required.'; return 1;;
    esac
}

# Match actual POSIX/FLOCK holders by Linux device major/minor and inode.
# Never unlink lock files: doing so creates a second independent lock inode.
pxd_lock_pids() {
    local f dev ino key p cmd
    for f in /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock /var/lib/rpm/.rpm.lock /usr/lib/sysimage/rpm/.rpm.lock /lib/apk/db/lock; do
        [ -e "$f" ] || continue
        read -r dev ino < <(stat -Lc '%d %i' "$f")
        printf -v key '%02x:%02x:%s' "$(( ((dev >> 8) & 4095) | ((dev >> 32) & 4294963200) ))" "$(( (dev & 255) | ((dev >> 12) & 4294967040) ))" "$ino"
        awk -v k="$key" '$2 != "->" && $6 == k && $5 > 1 {print $5}' /proc/locks
    done
    for f in /run/yum.pid /run/dnf.pid /var/cache/dnf/metadata_lock.pid; do
        [ -f "$f" ] || continue
        read -r p < "$f"
        case "$p" in ''|*[!0-9]*) continue;; esac
        [ "$p" -gt 1 ] && [ -r "/proc/$p/cmdline" ] || continue
        IFS= read -r cmd < "/proc/$p/comm" || continue
        case "$cmd" in yum|dnf|dnf5) echo "$p";; esac
    done | sort -u
}
pxd_is_ancestor() {
    local p=$$
    while [ "$p" -gt 1 ] 2>/dev/null; do
        [ "$p" = "$1" ] && return 0
        p=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
    done
    return 1
}
# Only signal processes that still hold a package lock; never delete lock files.
pxd_pid_start() {
    local record
    IFS= read -r record < "/proc/$1/stat" || return 1
    record=${record##*) }
    set -- $record
    [ "$#" -ge 20 ] || return 1
    printf '%s\n' "${20}"
}
pxd_signal_holder() {
    local pid=$1 signal=$2 stamp=$3 current
    [ "$pid" -gt 1 ] 2>/dev/null || return 1
    pxd_is_ancestor "$pid" && return 1
    current=$(pxd_pid_start "$pid") || return 1
    [ "$current" = "$stamp" ] || return 1
    pxd_lock_pids | grep -qx "$pid" || return 1
    [ "$(pxd_pid_start "$pid")" = "$stamp" ] || return 1
    echo "[pxd] 终止占用软件包锁的进程 PID=$pid，信号=$signal" >&2
    kill -"$signal" "$pid" 2>/dev/null || return 1
    PXD_PACKAGE_INTERRUPTED=1
}
pxd_centiseconds() {
    local uptime unused whole fraction
    read -r uptime unused < /proc/uptime || return 1
    whole=${uptime%.*}; fraction=${uptime#*.}; fraction=${fraction}00
    printf '%s\n' "$((10#$whole * 100 + 10#${fraction:0:2}))"
}
pxd_unlock() {
    local started now holders pid stamp key
    local -A seen=()
    started=$(pxd_centiseconds) || return 1
    while :; do
        holders=$(pxd_lock_pids | sort -u)
        [ -n "$holders" ] || return 0
        now=$(pxd_centiseconds) || return 1
        if [ "$((now - started))" -ge 290 ]; then
            pxd_error "3 秒内未能释放软件包锁（PID: $holders）；进程可能处于不可中断状态。"
            return 1
        fi
        for pid in $holders; do
            stamp=$(pxd_pid_start "$pid") || continue
            key=$pid:$stamp
            if [ "$((now - started))" -ge 180 ]; then
                pxd_signal_holder "$pid" KILL "$stamp" || true
            elif [ -z "${seen[$key]:-}" ]; then
                seen[$key]=1
                pxd_signal_holder "$pid" TERM "$stamp" || true
            fi
        done
        sleep 0.1
    done
}
pxd_pkg_run() {
    local n rc=1
    for n in 1 2 3; do
        pxd_unlock || return 1
        if [ "${PXD_PACKAGE_INTERRUPTED:-0}" = 1 ] && command -v dpkg >/dev/null 2>&1; then
            env DEBIAN_FRONTEND=noninteractive dpkg --configure --pending </dev/null || return 1
            PXD_PACKAGE_INTERRUPTED=0
        fi
        if "$@" </dev/null; then return 0; else rc=$?; fi
        echo "[pxd] Package command failed ($rc), attempt $n/3" >&2
        [ "$n" -eq 3 ] || sleep 1
    done
    return "$rc"
}
apt_ensure_lock_free() { pxd_unlock; }
apt_safe() { pxd_pkg_run env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=0 -o Acquire::Retries=2 -o Acquire::http::Timeout=30 "$@"; }

pxd_os() {
    PXD_ID=unknown; PXD_VERSION=''
    if [ -f /etc/os-release ]; then
        PXD_ID=$(. /etc/os-release; echo "$ID")
        PXD_VERSION=$(. /etc/os-release; echo "$VERSION_ID")
    fi
}
pkg_install() {
    pxd_os
    local yum_opts=()
    if [ "$PXD_ID" = centos ] && [ "${PXD_VERSION%%.*}" = 7 ]; then
        mkdir -p /etc/yum.repos.d
        if [ ! -f /etc/yum.repos.d/pxd-centos7-vault.repo ]; then
            cat > /etc/yum.repos.d/pxd-centos7-vault.repo <<'VAULT'
[pxd-c7-base]
name=CentOS 7.9 archive base
baseurl=https://vault.centos.org/7.9.2009/os/$basearch/
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[pxd-c7-updates]
name=CentOS 7.9 archive updates
baseurl=https://vault.centos.org/7.9.2009/updates/$basearch/
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
[pxd-c7-extras]
name=CentOS 7.9 archive extras
baseurl=https://vault.centos.org/7.9.2009/extras/$basearch/
enabled=0
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
VAULT
        fi
        yum_opts=('--disablerepo=*' --enablerepo=pxd-c7-base,pxd-c7-updates,pxd-c7-extras)
    fi
    if command -v apt-get >/dev/null 2>&1; then
        pxd_pkg_run env DEBIAN_FRONTEND=noninteractive dpkg --configure --pending &&
        apt_safe update && apt_safe install -y --no-install-recommends "$@"
    elif command -v dnf >/dev/null 2>&1; then
        pxd_pkg_run dnf -y --setopt=timeout=30 install "$@"
    elif command -v yum >/dev/null 2>&1; then
        pxd_pkg_run yum -y --setopt=timeout=30 "${yum_opts[@]}" install "$@"
    elif command -v apk >/dev/null 2>&1; then
        pxd_pkg_run apk add --no-cache "$@"
    elif command -v zypper >/dev/null 2>&1; then
        pxd_pkg_run zypper --non-interactive install "$@"
    elif command -v pacman >/dev/null 2>&1; then
        pxd_pkg_run pacman -S --needed --noconfirm "$@"
    else
        pxd_error 'Unsupported package manager'; return 1
    fi
}

# Minimal HTTP fallback for the package server when no downloader is installed.
# HTTPS, redirects and chunked responses remain the job of curl/wget/Python.
pxd_http_fetch() (
    local url=$1 dest=$2 authority host port path status header length='' size watchdog self=$BASHPID
    case "$url" in http://*) ;; *) return 1;; esac
    authority=${url#http://}; path=/${authority#*/}; authority=${authority%%/*}
    host=${authority%:*}; port=${authority##*:}
    [ "$host" != "$port" ] || port=80
    [[ "$host" =~ ^[a-zA-Z0-9.-]+$ && "$port" =~ ^[0-9]+$ ]] || return 1
    ( sleep 30; kill -TERM "$self" 2>/dev/null ) & watchdog=$!
    trap 'kill "$watchdog" 2>/dev/null || true' EXIT
    exec 3<>"/dev/tcp/$host/$port" || return 1
    printf 'GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$path" "$authority" >&3
    IFS= read -r -t 30 status <&3 || return 1
    [[ "$status" == HTTP/*' 200 '* ]] || return 1
    while IFS= read -r -t 30 header <&3; do
        header=${header%$'\r'}
        [ -n "$header" ] || break
        case "${header,,}" in
            content-length:*) length=${header#*:}; length=${length//[[:space:]]/};;
            transfer-encoding:*) return 1;;
        esac
    done
    [[ "$length" =~ ^[0-9]+$ ]] || return 1
    cat <&3 > "$dest" || return 1
    size=$(wc -c < "$dest")
    [ "$size" -eq "$length" ] && [ "$size" -gt 0 ]
)

# Prefer existing curl; retain wget/Python fallbacks and TLS verification.
pxd_fetch() {
    local url=$1 dest=$2 tmp n py
    tmp="${dest}.part.$$"
    for n in 1 2 3; do
        rm -f "$tmp"
        if command -v curl >/dev/null 2>&1; then
            curl -fSL --connect-timeout 30 --retry 2 -o "$tmp" "$url" && [ -s "$tmp" ] && { mv -f "$tmp" "$dest"; return; }
        fi
        if command -v wget >/dev/null 2>&1; then
            wget -q -T 30 -O "$tmp" "$url" && [ -s "$tmp" ] && { mv -f "$tmp" "$dest"; return; }
        fi
        for py in python3 python; do
            command -v "$py" >/dev/null 2>&1 || continue
            "$py" - "$url" "$tmp" <<'PYFETCH' && [ -s "$tmp" ] && { mv -f "$tmp" "$dest"; return; }
import sys, shutil
try:
    from urllib.request import urlopen
except ImportError:
    from urllib2 import urlopen
with open(sys.argv[2], 'wb') as dst:
    src = urlopen(sys.argv[1], timeout=30)
    shutil.copyfileobj(src, dst)
    src.close()
PYFETCH
        done
        if pxd_http_fetch "$url" "$tmp"; then mv -f "$tmp" "$dest"; return; fi
        if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
            pkg_install wget ca-certificates || return 1
        fi
        sleep 2
    done
    rm -f "$tmp"
    pxd_error "Download failed: $url"
}
pxd_fetch_text() {
    local f rc
    f=$(mktemp) || return 1
    pxd_fetch "$1" "$f"; rc=$?
    [ "$rc" -ne 0 ] || cat "$f"
    rm -f "$f"
    return "$rc"
}

for arg in "$@"; do
    case "$arg" in -h|--help)
        echo 'PXD concise installer: bash install [install.sh options]'
        echo 'Environment: PANEL_PORT, PANEL_USERNAME, PANEL_PASSWORD, PANEL_INSTALL_DOCKER (default y).'
        echo 'Requires root, Bash and x86_64 Linux; no curl required.'
        exit 0;;
    esac
done
pxd_preflight || exit 1
if [ "${PXD_INTERACTIVE:-0}" = 1 ]; then
    [ -r /dev/tty ] && [ -w /dev/tty ] || { pxd_error '交互安装需要 SSH 终端'; exit 1; }
    while :; do
        read -r -p '设置面板端口 [默认 20999]: ' PANEL_PORT </dev/tty || exit 1
        PANEL_PORT=${PANEL_PORT:-20999}
        [[ "$PANEL_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$PANEL_PORT" -le 65535 ] && break
        echo '端口必须为 1 到 65535。' >/dev/tty
    done
    while :; do
        read -r -p '设置面板账号 [默认 admin]: ' PANEL_USERNAME </dev/tty || exit 1
        PANEL_USERNAME=${PANEL_USERNAME:-admin}
        [[ "$PANEL_USERNAME" =~ ^[a-zA-Z0-9_]{3,30}$ ]] && break
        echo '账号需要 3 到 30 位字母、数字或下划线。' >/dev/tty
    done
    while :; do
        read -r -s -p '设置面板密码（8 到 30 位字母、数字或 _!@#$%*,.?）: ' PANEL_PASSWORD </dev/tty || exit 1
        printf '\n' >/dev/tty
        [[ "$PANEL_PASSWORD" =~ ^[a-zA-Z0-9_!@#$%*,.?]{8,30}$ ]] || { echo '密码格式不符合要求。' >/dev/tty; continue; }
        read -r -s -p '再次输入密码: ' pxd_password_confirm </dev/tty || exit 1
        printf '\n' >/dev/tty
        [ "$PANEL_PASSWORD" = "$pxd_password_confirm" ] && break
        echo '两次密码不一致，请重试。' >/dev/tty
    done
    unset pxd_password_confirm
    export PANEL_PORT PANEL_USERNAME PANEL_PASSWORD
fi
# Validate all presets before downloading or changing system packages.
pxd_presets() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --port|--username|--password)
                [ "$#" -ge 2 ] || { pxd_error "Missing value for $1"; return 1; }
                case "$1" in
                    --port) PANEL_PORT=$2;;
                    --username) PANEL_USERNAME=$2;;
                    --password) PANEL_PASSWORD=$2;;
                esac
                shift 2;;
            *) shift;;
        esac
    done
    export PANEL_PORT=${PANEL_PORT:-41275}
    export PANEL_USERNAME=${PANEL_USERNAME:-admin}
    export PANEL_PASSWORD=${PANEL_PASSWORD:-12345678}
    [[ "$PANEL_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$PANEL_PORT" -le 65535 ] || { pxd_error '端口必须为 1 到 65535'; return 1; }
    [[ "$PANEL_USERNAME" =~ ^[a-zA-Z0-9_]{3,30}$ ]] || { pxd_error '账号必须为 3 到 30 位字母、数字或下划线'; return 1; }
    [[ "$PANEL_PASSWORD" =~ ^[a-zA-Z0-9_!@#$%*,.?]{8,30}$ ]] || { pxd_error '密码必须为 8 到 30 位字母、数字或 _!@#$%*,.?'; return 1; }
}
pxd_presets "$@" || exit 1

REPO=${PXD_REPO:-y648394245-tech/puxida}
RELEASE_TAG=${PXD_RELEASE_TAG:-latest}
if [ "$RELEASE_TAG" = latest ]; then
    PKG_URL=${PXD_PACKAGE_URL:-https://github.com/${REPO}/releases/latest/download/pxd-concise-son.tar.gz}
else
    PKG_URL=${PXD_PACKAGE_URL:-https://github.com/${REPO}/releases/download/${RELEASE_TAG}/pxd-concise-son.tar.gz}
fi
TEMP_DIR=$(mktemp -d /tmp/pxd-install.XXXXXXXX) || exit 1
trap 'rm -rf "$TEMP_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
pxd_fetch "$PKG_URL" "$TEMP_DIR/package.tgz" || exit 1
if ! command -v tar >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
    pkg_install tar gzip || exit 1
fi
mkdir "$TEMP_DIR/package" || exit 1
tar -tzf "$TEMP_DIR/package.tgz" > "$TEMP_DIR/members" || exit 1
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$TEMP_DIR/members"; then
    pxd_error 'Unsafe archive path'; exit 1
fi
tar -xzf "$TEMP_DIR/package.tgz" -C "$TEMP_DIR/package" || exit 1
# Accept the original flat archive as well as a named top-level directory.
if [ -f "$TEMP_DIR/package/install.sh" ]; then
    cd "$TEMP_DIR/package" || exit 1
else
    # 自动探测含 install.sh 的一级子目录（兼容 pxd_full_father / pxd_concise_son）
    sub=""
    for candidate in "$TEMP_DIR/package"/*/install.sh; do
        [ -f "$candidate" ] || continue
        sub=${candidate%/install.sh}; break
    done
    [ -n "$sub" ] && cd "$sub" || cd "$TEMP_DIR/package/pxd_concise_son" || exit 1
fi
for f in install.sh 1panel-core 1panel-agent 1pctl; do
    [ -s "$f" ] || { pxd_error "Missing package file: $f"; exit 1; }
done
chmod +x install.sh 1panel-core 1panel-agent 1pctl || exit 1
export PANEL_INSTALL_DOCKER=${PANEL_INSTALL_DOCKER:-y}
export PANEL_PORT=${PANEL_PORT:-41275}
export PANEL_USERNAME=${PANEL_USERNAME:-admin}
export PANEL_PASSWORD=${PANEL_PASSWORD:-12345678}
bash ./install.sh --non-interactive --lang zh --port "$PANEL_PORT" --username "$PANEL_USERNAME" "$@"
rc=$?
if [ "$rc" -eq 0 ]; then
    touch /tmp/1panel-installed-flag
    echo "[pxd] 安装及服务验证成功，访问 http://<服务器IP>:$PANEL_PORT"
else
    mkdir -p /var/log/pxd-install
    [ ! -f install.log ] || cp install.log "/var/log/pxd-install/failed-$(date +%Y%m%d-%H%M%S).log"
    echo "[pxd] 安装失败，退出码 $rc；不会标记成功。日志目录 /var/log/pxd-install" >&2
fi
exit "$rc"
