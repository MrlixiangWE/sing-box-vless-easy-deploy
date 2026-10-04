#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 颜色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""
        OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

# -----------------------
# 检查 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        err "此脚本需要 root 权限"
        err "请使用: sudo bash -c \"\$(curl -fsSL ...)\" 或切换到 root 用户"
        exit 1
    fi
}

check_root

# -----------------------
# 安装依赖
install_deps() {
    info "安装系统依赖..."
    
    case "$OS" in
        alpine)
            apk update || { err "apk update 失败"; exit 1; }
            apk add --no-cache bash curl ca-certificates openssl openrc jq || {
                err "依赖安装失败"
                exit 1
            }
            
            if ! rc-service --list 2>/dev/null | grep -q "^openrc"; then
                rc-update add openrc boot >/dev/null 2>&1 || true
                rc-service openrc start >/dev/null 2>&1 || true
            fi
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || { err "apt update 失败"; exit 1; }
            apt-get install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl jq || {
                err "依赖安装失败"
                exit 1
            }
            ;;
        *)
            warn "未识别的系统类型，尝试继续..."
            ;;
    esac
    
    info "依赖安装完成"
}

install_deps

# -----------------------
# 配置节点后缀名
echo "请输入节点名称（留空则默认协议名）："
read -r user_name
# 如果用户输入非空，则添加后缀并覆盖保存到文件
if [[ -n "$user_name" ]]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    suffix=""
fi

# -----------------------
# 配置端口和密码
get_config() {
    info "=== 配置 VLESS Reality ==="
    if [ -n "${SINGBOX_PORT_REALITY:-}" ]; then
        PORT_REALITY="$SINGBOX_PORT_REALITY"
        info "使用环境变量端口 (Reality): $PORT_REALITY"
    else
        read -p "请输入 VLESS Reality 端口（留空则随机 10000-60000）: " USER_PORT_REALITY
        if [ -z "$USER_PORT_REALITY" ]; then
            PORT_REALITY=$(shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000)))
            info "使用随机端口 (Reality): $PORT_REALITY"
        else
            PORT_REALITY="$USER_PORT_REALITY"
        fi
    fi

    if [ -n "${SINGBOX_REALITY_SNI:-}" ]; then
        REALITY_SNI_HOST="$SINGBOX_REALITY_SNI"
    else
        read -p "请输入 Reality 伪装域名 SNI（留空则 addons.mozilla.org）: " USER_SNI
        REALITY_SNI_HOST="${USER_SNI:-addons.mozilla.org}"
    fi
    info "Reality SNI: $REALITY_SNI_HOST"

    UUID=$(cat /proc/sys/kernel/random/uuid)
    info "已生成 UUID: $UUID"
}

get_config

# -----------------------
# sing-box 二进制安装（低内存友好）
#
# 小内存 LXC/Incus 容器上 `apk add sing-box` 会在解包阶段被 cgroup OOM
# killer 杀掉（表现为 apk 走到 8x% 后 "Killed"）。这里改为直接抓官方静态
# 二进制：下载到磁盘 -> 解压 -> 原子替换，峰值内存只有几 MB。
# 官方 release 是 CGO_ENABLED=0 静态编译，musl/glibc 通用，不需要 edge 仓库。
# -----------------------
SB_BIN_PATH="${SB_BIN_PATH:-/usr/bin/sing-box}"

sb_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  SB_ARCH="amd64" ;;
        aarch64|arm64) SB_ARCH="arm64" ;;
        armv7l|armv7)  SB_ARCH="armv7" ;;
        armv6l)        SB_ARCH="armv6" ;;
        s390x)         SB_ARCH="s390x" ;;
        riscv64)       SB_ARCH="riscv64" ;;
        *) err "不支持的 CPU 架构: $(uname -m)"; return 1 ;;
    esac
    return 0
}

sb_latest_version() {
    local v=""
    v=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 20 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//') || true
    if [ -z "$v" ]; then
        # GitHub API 有 IP 限流（共享住宅 IP 上很容易撞到），退回跟随 latest 跳转取 tag
        v=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 20 \
            https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
            | sed 's#.*/tag/v##') || true
    fi
    echo "$v"
}

# 挑一个"真磁盘"上的临时目录。
# 关键：/tmp 在很多小容器里是 tmpfs（内存盘），往里解压 ~80MB 的 sing-box
# 二进制等于直接吃掉内存，会再次触发 OOM killer。同时做空间预检。
sb_workdir() {
    local d fstype avail
    for d in "${SB_TMPDIR:-}" /var/tmp /tmp /root .; do
        [ -z "$d" ] && continue
        [ -d "$d" ] || continue
        fstype=$(stat -f -c %T "$d" 2>/dev/null || echo unknown)
        case "$fstype" in
            tmpfs|ramfs) continue ;;
        esac
        avail=$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$avail" ] && [ "$avail" -ge 204800 ] 2>/dev/null; then
            echo "$d"; return 0
        fi
    done
    return 1
}

# 判断本机 libc：Alpine 是 musl，官方 linux-<arch> 包是动态链接 glibc 的，
# 在 musl 上会报 "cannot execute: required file not found"，必须用 -musl 包。
sb_detect_libc() {
    if [ -f /etc/alpine-release ]; then echo musl; return 0; fi
    if ldd --version 2>&1 | head -n1 | grep -qi musl; then echo musl; return 0; fi
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then echo musl; return 0; fi
    echo glibc
}

# 尝试安装某一个 libc 变体；$1 为资产后缀（"" 或 "-musl"）
sb_try_install() {
    local suffix="$1" tmpd pkg url bin
    pkg="sing-box-${SB_VER}-linux-${SB_ARCH}${suffix}"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${pkg}.tar.gz"

    tmpd=$(mktemp -d "$SB_WORKDIR/singbox.XXXXXX") || return 1
    if ! curl -fL --retry 3 --retry-delay 2 -o "$tmpd/sb.tar.gz" "$url"; then
        warn "下载失败: ${pkg}.tar.gz"; rm -rf "$tmpd"; return 1
    fi
    if ! tar -xzf "$tmpd/sb.tar.gz" -C "$tmpd"; then
        warn "解压失败: ${pkg}.tar.gz（磁盘空间不足？）"; rm -rf "$tmpd"; return 1
    fi
    bin=$(find "$tmpd" -type f -name sing-box | head -n1)
    if [ -z "$bin" ]; then
        warn "${pkg} 内未找到 sing-box"; rm -rf "$tmpd"; return 1
    fi

    # 关键一步：先在临时目录里真的跑一次，确认这个变体能在本机执行，
    # 再往 /usr/bin 放。否则会装上一个跑不起来的二进制，
    # 直到后面调用 sing-box 时才炸，报错还指向别的行号。
    chmod +x "$bin"
    if ! "$bin" version >/dev/null 2>&1; then
        warn "${pkg} 在本机无法执行（libc 不匹配），尝试其他变体"
        rm -rf "$tmpd"; return 1
    fi

    if ! install -m 0755 "$bin" "${SB_BIN_PATH}.new"; then
        warn "写入 ${SB_BIN_PATH}.new 失败"; rm -rf "$tmpd"; return 1
    fi
    if ! mv -f "${SB_BIN_PATH}.new" "$SB_BIN_PATH"; then
        warn "替换 $SB_BIN_PATH 失败"; rm -rf "$tmpd"; return 1
    fi
    rm -rf "$tmpd"
    info "使用变体: ${pkg}"
    return 0
}

fetch_singbox_binary() {
    sb_detect_arch || return 1

    SB_VER="${SINGBOX_VERSION:-}"
    if [ -z "$SB_VER" ]; then
        SB_VER="$(sb_latest_version)"
    fi
    case "$SB_VER" in
        ""|*[!0-9.]*)
            err "无法确定 sing-box 版本号（GitHub 不可达或被限流）"
            err "可手动指定后重跑：SINGBOX_VERSION=1.14.0 bash $0"
            return 1
            ;;
    esac

    SB_WORKDIR="$(sb_workdir)" || {
        err "找不到可用的解压目录：需要 ≥200MB 空闲磁盘，且不能是 tmpfs 内存盘"
        err "sing-box 二进制解压后约 80MB。先看 df -h，或指定 SB_TMPDIR=/path"
        return 1
    }

    local libc
    libc="$(sb_detect_libc)"
    info "准备安装 sing-box v${SB_VER} (linux-${SB_ARCH}, libc=${libc})"
    info "解压目录: $SB_WORKDIR ($(df -Pk "$SB_WORKDIR" | awk 'NR==2{printf "%d MB 可用", $4/1024}'))"

    # musl 机器优先拿 -musl（静态链接）；glibc 机器优先拿默认包。
    # 任一失败自动回退到另一个，两个都不行才报错。
    if [ "$libc" = "musl" ]; then
        sb_try_install "-musl" || sb_try_install "" || {
            err "sing-box 安装失败：musl 与 glibc 两个变体都装不上"
            return 1
        }
    else
        sb_try_install "" || sb_try_install "-musl" || {
            err "sing-box 安装失败：glibc 与 musl 两个变体都装不上"
            return 1
        }
    fi

    if [ ! -e /usr/local/bin/sing-box ]; then
        ln -sf "$SB_BIN_PATH" /usr/local/bin/sing-box 2>/dev/null || true
    fi
    info "已安装: $("$SB_BIN_PATH" version | head -n1)"
    return 0
}

# 按容器实际可用内存算一个 Go 堆软上限，降低运行期被 OOM 杀掉的概率
calc_gomemlimit() {
    local m="" mb="" limit=""
    if [ -r /sys/fs/cgroup/memory.max ]; then
        m=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
    elif [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        m=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
    fi
    if [ -n "$m" ] && [ "$m" != "max" ] && [ "$m" -gt 0 ] 2>/dev/null && [ "$m" -lt 137438953472 ] 2>/dev/null; then
        mb=$(( m / 1024 / 1024 ))
    else
        mb=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || true)
    fi
    if [ -z "$mb" ] || ! [ "$mb" -gt 0 ] 2>/dev/null; then
        mb=512
    fi
    limit=$(( mb * 60 / 100 ))
    if [ "$limit" -lt 48 ]; then limit=48; fi
    if [ "$limit" -gt 1024 ]; then limit=1024; fi
    echo "${limit}MiB"
}

# -----------------------
# 安装 sing-box
install_singbox() {
    info "开始安装 sing-box..."

    if command -v sing-box >/dev/null 2>&1; then
        CURRENT_VERSION=$(sing-box version 2>/dev/null | head -1 || echo "unknown")
        warn "检测到已安装 sing-box: $CURRENT_VERSION"
        read -p "是否重新安装？(y/N): " REINSTALL
        if [[ ! "$REINSTALL" =~ ^[Yy]$ ]]; then
            info "跳过 sing-box 安装"
            return 0
        fi
    fi

    fetch_singbox_binary || {
        err "sing-box 安装失败"
        exit 1
    }

    if ! command -v sing-box >/dev/null 2>&1; then
        err "sing-box 安装后未找到可执行文件"
        exit 1
    fi
    # 真跑一次，别只看文件在不在
    if ! sing-box version >/dev/null 2>&1; then
        err "sing-box 已安装但无法执行："
        sing-box version || true
        exit 1
    fi

    INSTALLED_VERSION=$(sing-box version | head -1)
    info "sing-box 安装成功: $INSTALLED_VERSION"
}

install_singbox

# -----------------------
# 生成 Reality 密钥对和自签名证书
generate_reality_keys() {
    info "生成 Reality 密钥对..."
    REALITY_KEYS=$(sing-box generate reality-keypair)
    REALITY_PK=$(echo "$REALITY_KEYS" | grep "PrivateKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "PublicKey" | awk '{print $NF}' | tr -d '\r')
    REALITY_SID=$(sing-box generate rand 8 --hex)
    
    # 立即保存公钥和 SID
    mkdir -p /etc/sing-box
    echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub
    echo -n "$REALITY_SID" > /etc/sing-box/.reality_sid
    
    info "Reality PK: $REALITY_PK"
    info "Reality PUB: $REALITY_PUB"
    info "Reality SID: $REALITY_SID"
}

generate_reality_keys

# -----------------------
# 生成配置文件
CONFIG_PATH="/etc/sing-box/config.json"

create_config() {
    info "生成配置文件: $CONFIG_PATH"

    mkdir -p "$(dirname "$CONFIG_PATH")"

    cat > "$CONFIG_PATH" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT_REALITY,
      "tcp_fast_open": true,
      "users": [
        {
          "uuid": "$UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI_HOST",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI_HOST",
            "server_port": 443
          },
          "private_key": "$REALITY_PK",
          "short_id": ["$REALITY_SID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct-out"
    }
  ]
}
EOF

    sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1 \
       && info "配置文件验证通过" \
       || warn "配置文件验证失败，但继续执行"

    mkdir -p /etc/sing-box
    cat > /etc/sing-box/.config_cache <<CACHEEOF
REALITY_PORT=$PORT_REALITY
REALITY_SNI=$REALITY_SNI_HOST
REALITY_UUID=$UUID
REALITY_PK=$REALITY_PK
REALITY_SID=$REALITY_SID
REALITY_PUB=$REALITY_PUB
CACHEEOF

    info "配置缓存已保存到 /etc/sing-box/.config_cache"
}

create_config

# -----------------------
# 设置服务
setup_service() {
    info "配置系统服务..."

    SB_GOMEMLIMIT="$(calc_gomemlimit)"
    info "Go 堆软上限 GOMEMLIMIT=$SB_GOMEMLIMIT"
    
    if [ "$OS" = "alpine" ]; then
        SERVICE_PATH="/etc/init.d/sing-box"
        
        cat > "$SERVICE_PATH" <<'OPENRC'
#!/sbin/openrc-run

name="sing-box"
description="Sing-box Proxy Server"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"

# 低内存容器：限制 Go 堆，让 GC 更早介入
export GOMEMLIMIT="__GOMEMLIMIT__"
export GOGC=50

# 使用 supervise-daemon 守护进程：崩溃后自动拉起
supervisor="supervise-daemon"
respawn_delay=5
respawn_max=0
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.err"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath --directory --mode 0755 /var/log
    checkpath --directory --mode 0755 /run
}
OPENRC
        
        sed -i "s|__GOMEMLIMIT__|${SB_GOMEMLIMIT}|g" "$SERVICE_PATH"
        chmod +x "$SERVICE_PATH"
        rc-update add sing-box default >/dev/null 2>&1 || warn "添加开机自启失败"
        rc-service sing-box restart || {
            err "服务启动失败"
            tail -20 /var/log/sing-box.err 2>/dev/null || tail -20 /var/log/sing-box.log 2>/dev/null || true
            exit 1
        }
        
        sleep 2
        if rc-service sing-box status >/dev/null 2>&1; then
            info "✅ OpenRC 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
        
    else
        SERVICE_PATH="/etc/systemd/system/sing-box.service"
        
        cat > "$SERVICE_PATH" <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target
Wants=network.target
# 关闭启动频率限制：崩溃循环时也不会永久放弃
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
Environment="GOMEMLIMIT=__GOMEMLIMIT__"
Environment="GOGC=50"
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
# 任何退出都自动重启（含 exit 0）
Restart=always
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SYSTEMD
        
        sed -i "s|__GOMEMLIMIT__|${SB_GOMEMLIMIT}|g" "$SERVICE_PATH"
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box || {
            err "服务启动失败"
            journalctl -u sing-box -n 30 --no-pager
            exit 1
        }
        
        sleep 2
        if systemctl is-active sing-box >/dev/null 2>&1; then
            info "✅ Systemd 服务已启动"
        else
            err "服务状态异常"
            exit 1
        fi
    fi
    
    info "服务配置完成: $SERVICE_PATH"
}

setup_service

# -----------------------
# 获取公网 IP
get_public_ip() {
    local ip=""
    for url in \
        "https://api.ipify.org" \
        "https://ipinfo.io/ip" \
        "https://ifconfig.me" \
        "https://icanhazip.com" \
        "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

PUB_IP=$(get_public_ip || echo "YOUR_SERVER_IP")
if [ "$PUB_IP" = "YOUR_SERVER_IP" ]; then
    warn "无法获取公网 IP，请手动替换"
else
    info "检测到公网 IP: $PUB_IP"
fi

# -----------------------
# 生成链接
generate_uris() {
    local host="$PUB_IP"

    echo "=== VLESS Reality ==="
    echo "vless://${UUID}@${host}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI_HOST}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${suffix}"
}

# -----------------------
# 最终输出
echo ""
echo "=========================================="
info "🎉 Sing-box VLESS Reality 部署完成！"
echo "=========================================="
echo ""
info "📋 配置信息："
echo "   Reality 端口: $PORT_REALITY"
echo "   UUID: $UUID"
echo "   SNI: $REALITY_SNI_HOST"
echo "   服务器: $PUB_IP"
echo ""
info "📂 文件位置："
echo "   配置: $CONFIG_PATH"
echo "   服务: $SERVICE_PATH"
echo ""
info "🔗 客户端链接："
generate_uris | while IFS= read -r line; do
    echo "   $line"
done
echo ""
info "📧 管理命令："
if [ "$OS" = "alpine" ]; then
    echo "   启动: rc-service sing-box start"
    echo "   停止: rc-service sing-box stop"
    echo "   重启: rc-service sing-box restart"
    echo "   状态: rc-service sing-box status"
    echo "   日志: tail -f /var/log/sing-box.log"
else
    echo "   启动: systemctl start sing-box"
    echo "   停止: systemctl stop sing-box"
    echo "   重启: systemctl restart sing-box"
    echo "   状态: systemctl status sing-box"
    echo "   日志: journalctl -u sing-box -f"
fi
echo ""
echo "=========================================="
# -----------------------
# Create `sb` management script at /usr/local/bin/sb

SB_PATH="/usr/local/bin/sb"

info "正在创建 sb 管理脚本: $SB_PATH"

cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# sb 管理面板（无 python3，使用 jq）
# 兼容: alpine / debian / redhat
# 依赖: jq, curl, openssl 或 /dev/urandom
# -----------------------

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_PATH="${CONFIG_PATH:-/etc/sing-box/config.json}"
URI_PATH="${URI_PATH:-/etc/sing-box/uris.txt}"
REALITY_PUB_FILE="${REALITY_PUB_FILE:-/etc/sing-box/.reality_pub}"
RELAY_REALITY_PUB_FILE="${RELAY_REALITY_PUB_FILE:-/etc/sing-box/.relay_reality_pub}"
RELAY_NAME_FILE="${RELAY_NAME_FILE:-/etc/sing-box/.relay_name}"
RELAY_CACHE_FILE="${RELAY_CACHE_FILE:-/etc/sing-box/.relay_cache}"
RELAY_TARGET_URI_FILE="${RELAY_TARGET_URI_FILE:-/etc/sing-box/.relay_target_uri}"
SERVICE_NAME="${SERVICE_NAME:-sing-box}"
BIN_PATH="${BIN_PATH:-/usr/bin/sing-box}"
SB_BIN_PATH="$BIN_PATH"

# --- 低内存友好的 sing-box 二进制安装（与主脚本同逻辑）---
sb_detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  SB_ARCH="amd64" ;;
        aarch64|arm64) SB_ARCH="arm64" ;;
        armv7l|armv7)  SB_ARCH="armv7" ;;
        armv6l)        SB_ARCH="armv6" ;;
        s390x)         SB_ARCH="s390x" ;;
        riscv64)       SB_ARCH="riscv64" ;;
        *) err "不支持的 CPU 架构: $(uname -m)"; return 1 ;;
    esac
    return 0
}

sb_latest_version() {
    local v=""
    v=$(curl -fsSL --retry 2 --retry-delay 2 --max-time 20 \
        https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null \
        | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//') || true
    if [ -z "$v" ]; then
        v=$(curl -fsSLI -o /dev/null -w '%{url_effective}' --max-time 20 \
            https://github.com/SagerNet/sing-box/releases/latest 2>/dev/null \
            | sed 's#.*/tag/v##') || true
    fi
    echo "$v"
}

# 挑一个"真磁盘"上的临时目录。
# 关键：/tmp 在很多小容器里是 tmpfs（内存盘），往里解压 ~80MB 的 sing-box
# 二进制等于直接吃掉内存，会再次触发 OOM killer。同时做空间预检。
sb_workdir() {
    local d fstype avail
    for d in "${SB_TMPDIR:-}" /var/tmp /tmp /root .; do
        [ -z "$d" ] && continue
        [ -d "$d" ] || continue
        fstype=$(stat -f -c %T "$d" 2>/dev/null || echo unknown)
        case "$fstype" in
            tmpfs|ramfs) continue ;;
        esac
        avail=$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}')
        if [ -n "$avail" ] && [ "$avail" -ge 204800 ] 2>/dev/null; then
            echo "$d"; return 0
        fi
    done
    return 1
}

# 判断本机 libc：Alpine 是 musl，官方 linux-<arch> 包是动态链接 glibc 的，
# 在 musl 上会报 "cannot execute: required file not found"，必须用 -musl 包。
sb_detect_libc() {
    if [ -f /etc/alpine-release ]; then echo musl; return 0; fi
    if ldd --version 2>&1 | head -n1 | grep -qi musl; then echo musl; return 0; fi
    if ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; then echo musl; return 0; fi
    echo glibc
}

# 尝试安装某一个 libc 变体；$1 为资产后缀（"" 或 "-musl"）
sb_try_install() {
    local suffix="$1" tmpd pkg url bin
    pkg="sing-box-${SB_VER}-linux-${SB_ARCH}${suffix}"
    url="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${pkg}.tar.gz"

    tmpd=$(mktemp -d "$SB_WORKDIR/singbox.XXXXXX") || return 1
    if ! curl -fL --retry 3 --retry-delay 2 -o "$tmpd/sb.tar.gz" "$url"; then
        warn "下载失败: ${pkg}.tar.gz"; rm -rf "$tmpd"; return 1
    fi
    if ! tar -xzf "$tmpd/sb.tar.gz" -C "$tmpd"; then
        warn "解压失败: ${pkg}.tar.gz（磁盘空间不足？）"; rm -rf "$tmpd"; return 1
    fi
    bin=$(find "$tmpd" -type f -name sing-box | head -n1)
    if [ -z "$bin" ]; then
        warn "${pkg} 内未找到 sing-box"; rm -rf "$tmpd"; return 1
    fi

    # 关键一步：先在临时目录里真的跑一次，确认这个变体能在本机执行，
    # 再往 /usr/bin 放。否则会装上一个跑不起来的二进制，
    # 直到后面调用 sing-box 时才炸，报错还指向别的行号。
    chmod +x "$bin"
    if ! "$bin" version >/dev/null 2>&1; then
        warn "${pkg} 在本机无法执行（libc 不匹配），尝试其他变体"
        rm -rf "$tmpd"; return 1
    fi

    if ! install -m 0755 "$bin" "${SB_BIN_PATH}.new"; then
        warn "写入 ${SB_BIN_PATH}.new 失败"; rm -rf "$tmpd"; return 1
    fi
    if ! mv -f "${SB_BIN_PATH}.new" "$SB_BIN_PATH"; then
        warn "替换 $SB_BIN_PATH 失败"; rm -rf "$tmpd"; return 1
    fi
    rm -rf "$tmpd"
    info "使用变体: ${pkg}"
    return 0
}

fetch_singbox_binary() {
    sb_detect_arch || return 1

    SB_VER="${SINGBOX_VERSION:-}"
    if [ -z "$SB_VER" ]; then
        SB_VER="$(sb_latest_version)"
    fi
    case "$SB_VER" in
        ""|*[!0-9.]*)
            err "无法确定 sing-box 版本号（GitHub 不可达或被限流）"
            err "可手动指定后重跑：SINGBOX_VERSION=1.14.0 sb"
            return 1
            ;;
    esac

    SB_WORKDIR="$(sb_workdir)" || {
        err "找不到可用的解压目录：需要 ≥200MB 空闲磁盘，且不能是 tmpfs 内存盘"
        err "sing-box 二进制解压后约 80MB。先看 df -h，或指定 SB_TMPDIR=/path"
        return 1
    }

    local libc
    libc="$(sb_detect_libc)"
    info "准备安装 sing-box v${SB_VER} (linux-${SB_ARCH}, libc=${libc})"
    info "解压目录: $SB_WORKDIR ($(df -Pk "$SB_WORKDIR" | awk 'NR==2{printf "%d MB 可用", $4/1024}'))"

    # musl 机器优先拿 -musl（静态链接）；glibc 机器优先拿默认包。
    # 任一失败自动回退到另一个，两个都不行才报错。
    if [ "$libc" = "musl" ]; then
        sb_try_install "-musl" || sb_try_install "" || {
            err "sing-box 安装失败：musl 与 glibc 两个变体都装不上"
            return 1
        }
    else
        sb_try_install "" || sb_try_install "-musl" || {
            err "sing-box 安装失败：glibc 与 musl 两个变体都装不上"
            return 1
        }
    fi

    if [ ! -e /usr/local/bin/sing-box ]; then
        ln -sf "$SB_BIN_PATH" /usr/local/bin/sing-box 2>/dev/null || true
    fi
    info "已安装: $("$SB_BIN_PATH" version | head -n1)"
    return 0
}

# detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID="${ID:-}"
        ID_LIKE="${ID_LIKE:-}"
    else
        ID=""
        ID_LIKE=""
    fi

    if echo "$ID $ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$ID $ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$ID $ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}

detect_os

# service helpers
service_start() {
    if [ "${SB_SKIP_SERVICE:-0}" = "1" ]; then
        info "SB_SKIP_SERVICE=1，跳过启动服务"
        return 0
    fi
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" start || return $?
    else
        systemctl start "$SERVICE_NAME" || return $?
    fi
}
service_stop() {
    if [ "${SB_SKIP_SERVICE:-0}" = "1" ]; then
        info "SB_SKIP_SERVICE=1，跳过停止服务"
        return 0
    fi
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" stop || return $?
    else
        systemctl stop "$SERVICE_NAME" || return $?
    fi
}
service_restart() {
    if [ "${SB_SKIP_SERVICE:-0}" = "1" ]; then
        info "SB_SKIP_SERVICE=1，跳过重启服务"
        return 0
    fi
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" restart || return $?
    else
        systemctl restart "$SERVICE_NAME" || return $?
    fi
}
service_status() {
    if [ "${SB_SKIP_SERVICE:-0}" = "1" ]; then
        info "SB_SKIP_SERVICE=1，跳过查看服务状态"
        return 0
    fi
    if [ "$OS" = "alpine" ]; then
        rc-service "$SERVICE_NAME" status || return $?
    else
        systemctl status "$SERVICE_NAME" --no-pager || return $?
    fi
}

# Safe random
rand_b64() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 16 | tr -d '\n\r'
    else
        head -c 16 /dev/urandom | base64 | tr -d '\n\r'
    fi
}

# URL-encode minimal (for SS userinfo like "method:password")
# encode only a small set of characters common in userinfo
url_encode_min() {
    local s="$1"
    printf "%s" "$s" | sed -e 's/%/%25/g' \
                             -e 's/:/%3A/g' \
                             -e 's/+/%2B/g' \
                             -e 's/\//%2F/g' \
                             -e 's/=/\%3D/g'
}

url_decode() {
    local s="${1//+/ }"
    printf '%b' "${s//%/\\x}" 2>/dev/null || printf "%s" "$1"
}

random_port() {
    shuf -i 10000-60000 -n 1 2>/dev/null || echo $((RANDOM % 50001 + 10000))
}

valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

query_param() {
    local query="$1"
    local key="$2"
    local pair k v
    IFS='&' read -r -a pairs <<< "$query"
    for pair in "${pairs[@]}"; do
        [ -z "$pair" ] && continue
        k="${pair%%=*}"
        v=""
        if [[ "$pair" == *=* ]]; then
            v="${pair#*=}"
        fi
        if [ "$k" = "$key" ]; then
            url_decode "$v"
            return 0
        fi
    done
    return 1
}

parse_vless_uri() {
    local uri="$1"
    local body no_fragment fragment userinfo after_at authority query target_type

    if [[ ! "$uri" =~ ^vless:// ]]; then
        err "只支持 vless:// 链接"
        return 1
    fi

    body="${uri#vless://}"
    no_fragment="${body%%#*}"
    fragment=""
    if [[ "$body" == *#* ]]; then
        fragment="${body#*#}"
    fi

    userinfo="${no_fragment%%@*}"
    after_at="${no_fragment#*@}"
    if [ "$after_at" = "$no_fragment" ] || [ -z "$userinfo" ]; then
        err "VLESS 链接缺少 UUID 或 @"
        return 1
    fi

    authority="${after_at%%\?*}"
    query=""
    if [[ "$after_at" == *\?* ]]; then
        query="${after_at#*\?}"
    fi

    if [[ "$authority" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        TARGET_SERVER="${BASH_REMATCH[1]}"
        TARGET_PORT="${BASH_REMATCH[2]}"
    else
        TARGET_SERVER="${authority%:*}"
        TARGET_PORT="${authority##*:}"
    fi

    if [ "$TARGET_SERVER" = "$authority" ] || [ -z "$TARGET_SERVER" ] || ! valid_port "$TARGET_PORT"; then
        err "VLESS 链接里的服务器地址或端口无效"
        return 1
    fi

    TARGET_URI="$uri"
    TARGET_UUID="$userinfo"
    TARGET_REMARK="$(url_decode "$fragment")"
    TARGET_QUERY="$query"
    TARGET_SECURITY="$(query_param "$query" security || true)"
    TARGET_FLOW="$(query_param "$query" flow || true)"
    TARGET_SNI="$(query_param "$query" sni || true)"
    TARGET_FP="$(query_param "$query" fp || true)"
    TARGET_PBK="$(query_param "$query" pbk || true)"
    TARGET_SID="$(query_param "$query" sid || true)"
    target_type="$(query_param "$query" type || true)"

    [ -z "$TARGET_SECURITY" ] && TARGET_SECURITY="reality"
    [ -z "$TARGET_SNI" ] && TARGET_SNI="$TARGET_SERVER"
    [ -z "$TARGET_FP" ] && TARGET_FP="chrome"

    if [ "$TARGET_SECURITY" != "reality" ]; then
        err "目前只支持 VLESS Reality 目标链接，当前 security=$TARGET_SECURITY"
        return 1
    fi
    if [ -n "$target_type" ] && [ "$target_type" != "tcp" ]; then
        err "目前只支持 Reality TCP 目标链接，当前 type=$target_type"
        return 1
    fi
    if [ -z "$TARGET_PBK" ]; then
        err "目标 VLESS Reality 链接缺少 pbk 参数"
        return 1
    fi
}

generate_reality_material() {
    local keys
    RELAY_UUID=$(cat /proc/sys/kernel/random/uuid)
    keys=$(sing-box generate reality-keypair)
    RELAY_PRIVATE_KEY=$(echo "$keys" | awk '/PrivateKey:/ {print $2}' | tr -d '\r')
    RELAY_PUBLIC_KEY=$(echo "$keys" | awk '/PublicKey:/ {print $2}' | tr -d '\r')
    RELAY_SHORT_ID=$(sing-box generate rand 8 --hex)

    if [ -z "$RELAY_PRIVATE_KEY" ] || [ -z "$RELAY_PUBLIC_KEY" ] || [ -z "$RELAY_SHORT_ID" ]; then
        err "生成 Reality 密钥失败"
        return 1
    fi
}


# read JSON fields from config using jq
read_config_fields() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    # VLESS / Reality
    REALITY_PORT=$(jq -r '.inbounds[] | select(.type=="vless" and ((.tag // "vless-in")=="vless-in")) | .listen_port // empty' "$CONFIG_PATH" | head -n1 || true)
    REALITY_UUID=$(jq -r '.inbounds[] | select(.type=="vless" and ((.tag // "vless-in")=="vless-in")) | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1 || true)
    REALITY_PK=$(jq -r '.inbounds[] | select(.type=="vless" and ((.tag // "vless-in")=="vless-in")) | .tls.reality.private_key // empty' "$CONFIG_PATH" | head -n1 || true)
    REALITY_SID=$(jq -r '.inbounds[] | select(.type=="vless" and ((.tag // "vless-in")=="vless-in")) | .tls.reality.short_id[0] // empty' "$CONFIG_PATH" | head -n1 || true)
    REALITY_SNI=$(jq -r '.inbounds[] | select(.type=="vless" and ((.tag // "vless-in")=="vless-in")) | .tls.server_name // "addons.mozilla.org"' "$CONFIG_PATH" | head -n1 || true)

    # fallback defaults
    REALITY_PORT="${REALITY_PORT:-}"
    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
    REALITY_UUID="${REALITY_UUID:-}"
    REALITY_PK="${REALITY_PK:-}"
    REALITY_SID="${REALITY_SID:-}"
}

read_relay_fields() {
    if [ ! -f "$CONFIG_PATH" ]; then
        return 1
    fi

    RELAY_PORT=$(jq -r '.inbounds[]? | select(.tag=="vless-relay-in") | .listen_port // empty' "$CONFIG_PATH" | head -n1 || true)
    RELAY_UUID=$(jq -r '.inbounds[]? | select(.tag=="vless-relay-in") | .users[0].uuid // empty' "$CONFIG_PATH" | head -n1 || true)
    RELAY_SNI=$(jq -r '.inbounds[]? | select(.tag=="vless-relay-in") | .tls.server_name // .tls.reality.handshake.server // "addons.mozilla.org"' "$CONFIG_PATH" | head -n1 || true)
    RELAY_SHORT_ID=$(jq -r '.inbounds[]? | select(.tag=="vless-relay-in") | .tls.reality.short_id[0] // empty' "$CONFIG_PATH" | head -n1 || true)
    RELAY_TARGET_SERVER=$(jq -r '.outbounds[]? | select(.tag=="vless-relay-out") | .server // empty' "$CONFIG_PATH" | head -n1 || true)
    RELAY_TARGET_PORT=$(jq -r '.outbounds[]? | select(.tag=="vless-relay-out") | .server_port // empty' "$CONFIG_PATH" | head -n1 || true)
    RELAY_TARGET_UUID=$(jq -r '.outbounds[]? | select(.tag=="vless-relay-out") | .uuid // empty' "$CONFIG_PATH" | head -n1 || true)
    RELAY_TARGET_SNI=$(jq -r '.outbounds[]? | select(.tag=="vless-relay-out") | .tls.server_name // empty' "$CONFIG_PATH" | head -n1 || true)

    [ -n "$RELAY_PORT" ] && [ -n "$RELAY_UUID" ] && [ -n "$RELAY_TARGET_SERVER" ] && [ -n "$RELAY_TARGET_PORT" ]
}

# get public IP (tries multiple endpoints)
get_public_ip() {
    local ip=""
    for url in "https://api.ipify.org" "https://ipinfo.io/ip" "https://ifconfig.me" "https://icanhazip.com" "https://ipecho.net/plain"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        # 必须校验：接口挂掉/被劫持时会返回 HTML 或错误文本，
        # 不校验就会把整段报错拼进 vless:// 链接里
        if [ -n "$ip" ] && printf '%s' "$ip" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

# generate and save URIs
generate_and_save_uris() {
    read_config_fields || return 1

    PUBLIC_IP=$(get_public_ip || true)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"
    
    # 读取文件内容作为节点后缀
    node_suffix=$(cat /root/node_names.txt 2>/dev/null || true)

    # reality pubkey read file or from config (fallback)
    if [ -f "$REALITY_PUB_FILE" ]; then
        REALITY_PUB=$(cat "$REALITY_PUB_FILE")
    else
        # try to extract pub from config if stored there
        REALITY_PUB=$(jq -r '.inbounds[] | select(.type=="vless") | .tls.reality.public_key // empty' "$CONFIG_PATH" | head -n1 || true)
        REALITY_PUB="${REALITY_PUB:-UNKNOWN}"
    fi

    reality_uri="vless://${REALITY_UUID}@${PUBLIC_IP}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#reality${node_suffix}"

    relay_uri=""
    if read_relay_fields >/dev/null 2>&1; then
        relay_name=$(cat "$RELAY_NAME_FILE" 2>/dev/null || echo "relay")
        RELAY_PUBLIC_KEY=$(cat "$RELAY_REALITY_PUB_FILE" 2>/dev/null || true)
        if [ -n "$RELAY_PUBLIC_KEY" ]; then
            relay_uri="vless://${RELAY_UUID}@${PUBLIC_IP}:${RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RELAY_SNI}&fp=chrome&pbk=${RELAY_PUBLIC_KEY}&sid=${RELAY_SHORT_ID}#${relay_name}"
        fi
    fi

    {
        if [ -n "$REALITY_PORT" ] && [ -n "$REALITY_UUID" ] && [ -n "$REALITY_SID" ]; then
            echo "=== VLESS Reality ==="
            echo "$reality_uri"
        fi
        if [ -n "$relay_uri" ]; then
            echo ""
            echo "=== VLESS Reality 中转 ==="
            echo "$relay_uri"
        fi
    } > "$URI_PATH"

    info "URI 已写入: $URI_PATH"
}

# view URIs (regenerate first)
action_view_uri() {
    info "正在生成并显示 URI..."
    generate_and_save_uris || { err "生成 URI 失败"; return 1; }
    echo ""
    sed -n '1,200p' "$URI_PATH" || true
}

# view config path
action_view_config() {
    echo "$CONFIG_PATH"
}

# edit config: use EDITOR or fallback
action_edit_config() {
    if [ ! -f "$CONFIG_PATH" ]; then
        err "配置文件不存在: $CONFIG_PATH"
        return 1
    fi

    if command -v nano >/dev/null 2>&1; then
        ${EDITOR:-nano} "$CONFIG_PATH"
    else
        ${EDITOR:-vi} "$CONFIG_PATH"
    fi

    # check with sing-box if available
    if command -v sing-box >/dev/null 2>&1; then
        if sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
            info "配置校验通过，尝试重启服务"
            service_restart || warn "重启失败"
            generate_and_save_uris || true
        else
            warn "配置校验失败，服务未重启"
        fi
    else
        warn "未检测到 sing-box，可跳过校验"
    fi
}

# Generic JSON updater helper using jq
# args: jq_filter tempfile
json_update() {
    local filter="$1"
    local tmp="${CONFIG_PATH}.tmp"
    jq "$filter" "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"
}

# Reset Reality based on current config
action_reset_reality() {
    read_config_fields || return 1
    if [ -z "$REALITY_PORT" ]; then
        err "当前配置中未找到原始 Reality 入站(vless-in)"
        return 1
    fi

    read -p "输入新的 Reality 端口（回车保持 $REALITY_PORT）: " new_reality_port
    [ -z "$new_reality_port" ] && new_reality_port="$REALITY_PORT"
    if ! valid_port "$new_reality_port"; then
        err "端口无效: $new_reality_port"
        return 1
    fi

    read -p "输入新的 Reality UUID（回车随机生成）: " new_reality_uuid
    [ -z "$new_reality_uuid" ] && new_reality_uuid=$(cat /proc/sys/kernel/random/uuid)

    info "正在停止服务..."
    service_stop || warn "停止服务失败"

    cp "$CONFIG_PATH" "${CONFIG_PATH}.bak"

    jq --argjson port "$new_reality_port" --arg uuid "$new_reality_uuid" '
    .inbounds |= map(
        if .type=="vless" and ((.tag // "vless-in")=="vless-in") then
            .listen_port = $port |
            (.users[0].uuid) = $uuid
        else .
        end
    )
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    info "已更新 Reality 端口($new_reality_port)与 UUID(隐藏)，正在启动服务..."
    service_start || warn "启动服务失败"
    sleep 1
    generate_and_save_uris || warn "生成 URI 失败"
}

build_relay_jq_filter() {
    cat <<'JQ'
def clean_rules:
  [ .[]? | select(((.inbound // "") != "vless-relay-in") and ((.inbound // []) != ["vless-relay-in"]) and ((.outbound // "") != "vless-relay-out")) ];
def relay_in:
  {
    "type": "vless",
    "tag": "vless-relay-in",
    "listen": "::",
    "listen_port": $listen_port,
    "tcp_fast_open": true,
    "users": [
      {
        "uuid": $relay_uuid,
        "flow": "xtls-rprx-vision"
      }
    ],
    "tls": {
      "enabled": true,
      "server_name": $relay_sni,
      "reality": {
        "enabled": true,
        "handshake": {
          "server": $relay_sni,
          "server_port": 443
        },
        "private_key": $relay_private_key,
        "short_id": [
          $relay_short_id
        ]
      }
    }
  };
def relay_out:
  ({
    "type": "vless",
    "tag": "vless-relay-out",
    "server": $target_server,
    "server_port": $target_port,
    "uuid": $target_uuid,
    "tcp_fast_open": true,
    "tls": {
      "enabled": true,
      "server_name": $target_sni,
      "utls": {
        "enabled": true,
        "fingerprint": $target_fp
      },
      "reality": {
        "enabled": true,
        "public_key": $target_pbk,
        "short_id": $target_sid
      }
    }
  } + if $target_flow == "" then {} else {"flow": $target_flow} end);
(.inbounds //= []) |
(.outbounds //= []) |
(.route //= {}) |
(.route.rules = ((.route.rules // []) | clean_rules)) |
(.inbounds = ((.inbounds // []) | map(select(.tag != "vless-relay-in")) + [relay_in])) |
(.outbounds = ((.outbounds // []) | map(select(.tag != "vless-relay-out")) + [relay_out])) |
(.route.rules = ([{"inbound": "vless-relay-in", "outbound": "vless-relay-out"}] + (.route.rules // [])))
JQ
}

write_relay_cache() {
    mkdir -p "$(dirname "$CONFIG_PATH")"
    echo -n "$RELAY_PUBLIC_KEY" > "$RELAY_REALITY_PUB_FILE"
    echo -n "$TARGET_URI" > "$RELAY_TARGET_URI_FILE"
    echo -n "$RELAY_NAME" > "$RELAY_NAME_FILE"
    cat > "$RELAY_CACHE_FILE" <<EOF
RELAY_PORT=$RELAY_PORT
RELAY_UUID=$RELAY_UUID
RELAY_SNI=$RELAY_SNI
RELAY_SHORT_ID=$RELAY_SHORT_ID
RELAY_PUBLIC_KEY=$RELAY_PUBLIC_KEY
TARGET_SERVER=$TARGET_SERVER
TARGET_PORT=$TARGET_PORT
TARGET_SNI=$TARGET_SNI
TARGET_UUID=$TARGET_UUID
TARGET_REMARK=$TARGET_REMARK
EOF
}

action_setup_vless_relay() {
    if ! command -v jq >/dev/null 2>&1; then
        err "缺少 jq，无法安全修改 JSON 配置"
        return 1
    fi
    if ! command -v sing-box >/dev/null 2>&1; then
        err "未检测到 sing-box，请先完成安装"
        return 1
    fi
    if [ ! -f "$CONFIG_PATH" ]; then
        err "未找到配置文件: $CONFIG_PATH"
        return 1
    fi

    echo ""
    read -r -p "请输入目标机器 VLESS Reality 链接: " target_uri
    parse_vless_uri "$target_uri" || return 1

    read -r -p "请输入本机中转监听端口（留空随机 10000-60000）: " relay_port
    [ -z "$relay_port" ] && relay_port=$(random_port)
    if ! valid_port "$relay_port"; then
        err "端口无效: $relay_port"
        return 1
    fi

    read -r -p "请输入中转节点名称（留空 relay）: " relay_name
    [ -z "$relay_name" ] && relay_name="relay"

    read -r -p "请输入中转入口 Reality SNI（留空 addons.mozilla.org）: " relay_sni
    [ -z "$relay_sni" ] && relay_sni="addons.mozilla.org"

    RELAY_PORT="$relay_port"
    RELAY_NAME="$relay_name"
    RELAY_SNI="$relay_sni"
    generate_reality_material || return 1

    local backup_path
    backup_path="${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$backup_path"

    local filter tmp
    filter="$(build_relay_jq_filter)"
    tmp="${CONFIG_PATH}.tmp"
    jq \
      --argjson listen_port "$RELAY_PORT" \
      --arg relay_uuid "$RELAY_UUID" \
      --arg relay_private_key "$RELAY_PRIVATE_KEY" \
      --arg relay_short_id "$RELAY_SHORT_ID" \
      --arg relay_sni "$RELAY_SNI" \
      --arg target_server "$TARGET_SERVER" \
      --argjson target_port "$TARGET_PORT" \
      --arg target_uuid "$TARGET_UUID" \
      --arg target_flow "$TARGET_FLOW" \
      --arg target_sni "$TARGET_SNI" \
      --arg target_fp "$TARGET_FP" \
      --arg target_pbk "$TARGET_PBK" \
      --arg target_sid "$TARGET_SID" \
      "$filter" "$CONFIG_PATH" > "$tmp" && mv "$tmp" "$CONFIG_PATH"

    if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "新中转配置校验失败，已保留备份，请检查目标链接"
        sing-box check -c "$CONFIG_PATH" || true
        cp "$backup_path" "$CONFIG_PATH"
        warn "已恢复原配置: $CONFIG_PATH"
        return 1
    fi

    if ! service_restart; then
        err "服务重启失败，正在恢复原配置"
        cp "$backup_path" "$CONFIG_PATH"
        service_restart || true
        return 1
    fi
    write_relay_cache
    generate_and_save_uris || warn "生成 URI 失败"

    info "VLESS Reality 中转已搭建"
    echo ""
    action_show_vless_relay
}

action_show_vless_relay() {
    if ! read_relay_fields >/dev/null 2>&1; then
        err "当前配置中未找到 VLESS Reality 中转"
        return 1
    fi

    PUBLIC_IP=$(get_public_ip || true)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="YOUR_SERVER_IP"
    RELAY_PUBLIC_KEY=$(cat "$RELAY_REALITY_PUB_FILE" 2>/dev/null || true)
    RELAY_NAME=$(cat "$RELAY_NAME_FILE" 2>/dev/null || echo "relay")

    echo "=== VLESS Reality 中转 ==="
    echo "监听端口: $RELAY_PORT"
    echo "目标落地: ${RELAY_TARGET_SERVER}:${RELAY_TARGET_PORT}"
    echo "目标 SNI: ${RELAY_TARGET_SNI:-unknown}"
    if [ -f "$RELAY_TARGET_URI_FILE" ]; then
        echo "目标链接: $(cat "$RELAY_TARGET_URI_FILE")"
    fi
    if [ -n "$RELAY_PUBLIC_KEY" ]; then
        echo ""
        echo "客户端连接中转机使用："
        echo "vless://${RELAY_UUID}@${PUBLIC_IP}:${RELAY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${RELAY_SNI}&fp=chrome&pbk=${RELAY_PUBLIC_KEY}&sid=${RELAY_SHORT_ID}#${RELAY_NAME}"
    else
        warn "未找到中转入口 public key 文件: $RELAY_REALITY_PUB_FILE"
    fi
}

action_reset_vless_relay() {
    if ! read_relay_fields >/dev/null 2>&1; then
        err "当前配置中未找到 VLESS Reality 中转，请先搭建"
        return 1
    fi

    read -r -p "输入新的中转监听端口（回车保持 $RELAY_PORT）: " new_port
    [ -z "$new_port" ] && new_port="$RELAY_PORT"
    if ! valid_port "$new_port"; then
        err "端口无效: $new_port"
        return 1
    fi

    read -r -p "是否重新生成中转 UUID/Reality 密钥？(y/N): " regen
    local backup_path
    backup_path="${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CONFIG_PATH" "$backup_path"

    if [[ "$regen" =~ ^[Yy]$ ]]; then
        generate_reality_material || return 1
        jq \
          --argjson port "$new_port" \
          --arg uuid "$RELAY_UUID" \
          --arg private_key "$RELAY_PRIVATE_KEY" \
          --arg sid "$RELAY_SHORT_ID" '
          .inbounds |= map(
            if .tag=="vless-relay-in" then
              .listen_port = $port |
              (.users[0].uuid) = $uuid |
              (.tls.reality.private_key) = $private_key |
              (.tls.reality.short_id) = [$sid]
            else .
            end
          )
        ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    else
        jq --argjson port "$new_port" '
          .inbounds |= map(
            if .tag=="vless-relay-in" then
              .listen_port = $port
            else .
            end
          )
        ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
    fi

    if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "配置校验失败，服务未重启"
        sing-box check -c "$CONFIG_PATH" || true
        cp "$backup_path" "$CONFIG_PATH"
        warn "已恢复原配置: $CONFIG_PATH"
        return 1
    fi

    if ! service_restart; then
        err "服务重启失败，正在恢复原配置"
        cp "$backup_path" "$CONFIG_PATH"
        service_restart || true
        return 1
    fi
    if [[ "$regen" =~ ^[Yy]$ ]]; then
        echo -n "$RELAY_PUBLIC_KEY" > "$RELAY_REALITY_PUB_FILE"
    fi
    generate_and_save_uris || warn "生成 URI 失败"
    action_show_vless_relay
}

action_disable_vless_relay() {
    if ! read_relay_fields >/dev/null 2>&1; then
        warn "当前配置中没有 VLESS Reality 中转"
        return 0
    fi

    read -r -p "确认关闭并移除 VLESS Reality 中转？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "已取消"
        return 0
    fi

    local backup_path
    local cache_backup_dir
    backup_path="${CONFIG_PATH}.bak-$(date +%Y%m%d-%H%M%S)"
    cache_backup_dir="$(mktemp -d)"
    cp "$CONFIG_PATH" "$backup_path"
    cp "$RELAY_REALITY_PUB_FILE" "$cache_backup_dir/relay_reality_pub" 2>/dev/null || true
    cp "$RELAY_NAME_FILE" "$cache_backup_dir/relay_name" 2>/dev/null || true
    cp "$RELAY_CACHE_FILE" "$cache_backup_dir/relay_cache" 2>/dev/null || true
    cp "$RELAY_TARGET_URI_FILE" "$cache_backup_dir/relay_target_uri" 2>/dev/null || true
    jq '
      .inbounds = ((.inbounds // []) | map(select(.tag != "vless-relay-in"))) |
      .outbounds = ((.outbounds // []) | map(select(.tag != "vless-relay-out"))) |
      if .route and .route.rules then
        .route.rules = (.route.rules | map(select(((.inbound // "") != "vless-relay-in") and ((.inbound // []) != ["vless-relay-in"]) and ((.outbound // "") != "vless-relay-out"))))
      else .
      end
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

    if ! sing-box check -c "$CONFIG_PATH" >/dev/null 2>&1; then
        err "移除后配置校验失败，服务未重启"
        sing-box check -c "$CONFIG_PATH" || true
        cp "$backup_path" "$CONFIG_PATH"
        warn "已恢复原配置: $CONFIG_PATH"
        return 1
    fi

    if ! service_restart; then
        err "服务重启失败，正在恢复原配置"
        cp "$backup_path" "$CONFIG_PATH"
        cp "$cache_backup_dir/relay_reality_pub" "$RELAY_REALITY_PUB_FILE" 2>/dev/null || true
        cp "$cache_backup_dir/relay_name" "$RELAY_NAME_FILE" 2>/dev/null || true
        cp "$cache_backup_dir/relay_cache" "$RELAY_CACHE_FILE" 2>/dev/null || true
        cp "$cache_backup_dir/relay_target_uri" "$RELAY_TARGET_URI_FILE" 2>/dev/null || true
        service_restart || true
        rm -rf "$cache_backup_dir"
        return 1
    fi
    rm -f "$RELAY_REALITY_PUB_FILE" "$RELAY_NAME_FILE" "$RELAY_CACHE_FILE" "$RELAY_TARGET_URI_FILE"
    rm -rf "$cache_backup_dir"
    generate_and_save_uris || true
    info "VLESS Reality 中转已关闭"
}

# Update sing-box
action_update() {
    info "开始更新 sing-box..."
    fetch_singbox_binary || { err "更新失败"; return 1; }

    info "更新完成，尝试重启服务..."
    if command -v sing-box >/dev/null 2>&1; then
        NEW_VER=$(sing-box version 2>/dev/null | head -n1 || echo "unknown")
        info "当前 sing-box 版本: $NEW_VER"
        service_restart || warn "重启失败"
    else
        warn "更新后未检测到 sing-box 可执行文件"
    fi
}

# Uninstall sing-box
action_uninstall() {
    info "正在卸载 sing-box..."
    service_stop || true
    if [ "$OS" = "alpine" ]; then
        rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
        [ -f "/etc/init.d/$SERVICE_NAME" ] && rm -f "/etc/init.d/$SERVICE_NAME"
    else
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        [ -f "/etc/systemd/system/$SERVICE_NAME.service" ] && rm -f "/etc/systemd/system/$SERVICE_NAME.service"
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    rm -rf /etc/sing-box /var/log/sing-box* /usr/local/bin/sb "$BIN_PATH" >/dev/null 2>&1 || true
    rm -f /root/node_names.txt >/dev/null 2>&1 || true
    info "卸载完成"
}

# Main menu
while true; do
    cat <<'MENU'

==========================
 Sing-box 管理面板 (sb) — VLESS/Reality
==========================
1) 查看节点链接
2) 查看配置文件路径
3) 编辑配置文件
4) 重置 Reality 端口/UUID
--------------------------
5) 启动服务
6) 停止服务
7) 重启服务
8) 查看状态
9) 更新 sing-box
--------------------------
10) 搭建/更新 VLESS Reality 中转
11) 查看 VLESS Reality 中转
12) 重置 VLESS Reality 中转入口
13) 关闭 VLESS Reality 中转
--------------------------
14) 卸载 sing-box
0) 退出
==========================
MENU

    read -p "请输入选项: " opt
    case "${opt:-}" in
        1) action_view_uri || true ;;
        2) action_view_config ;;
        3) action_edit_config || true ;;
        4) action_reset_reality || true ;;
        5) service_start && info "已发送启动命令" || true ;;
        6) service_stop && info "已发送停止命令" || true ;;
        7) service_restart && info "已发送重启命令" || true ;;
        8) service_status || true ;;
        9) action_update || true ;;
        10) action_setup_vless_relay || true ;;
        11) action_show_vless_relay || true ;;
        12) action_reset_vless_relay || true ;;
        13) action_disable_vless_relay || true ;;
        14) action_uninstall; exit 0 ;;
        0) exit 0 ;;
        *) warn "无效选项" ;;
    esac

    echo ""
done
SB_SCRIPT

chmod +x "$SB_PATH" || warn "无法设置 $SB_PATH 为可执行"

info "sb 已创建：可输入 sb 运行管理面板"

# end of script
