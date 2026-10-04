#!/bin/sh
# ysp-proxy 安装脚本
#
# 用法：sudo ./install.sh
# 说明：仅支持使用 systemd 的 Linux 系统，支持 armv7l（硬浮点）与 aarch64。
#       全程交互式配置；重复执行即为原地升级，会保留已有配置并自动备份。
set -eu

INSTALL_DIR=/opt/ysp-proxy
CONFIG_FILE=/etc/ysp-proxy.conf
SERVICE_FILE=/etc/systemd/system/ysp-proxy.service
SERVICE_NAME=ysp-proxy
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

usage() {
    cat <<'EOF'
用法：sudo ./install.sh

全程交互。若 /etc/ysp-proxy.conf 已存在，将使用现有配置作为默认值。
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少必要命令: $1"
}

detect_arch() {
    case "$(uname -m)" in
        armv7l|armv7)
            ARCH=armv7
            BINARY=ysp-proxy-linux-armv7
            ;;
        aarch64|arm64)
            ARCH=arm64
            BINARY=ysp-proxy-linux-arm64
            ;;
        *)
            fail "不支持的系统架构：$(uname -m)；仅支持 armv7l、aarch64"
            ;;
    esac
}

verify_package() {
    for file in "$BINARY" cmg-native libopenh264.so.8 native-src/cmg_native.cpp SHA256SUMS.txt; do
        [ -e "$SCRIPT_DIR/$file" ] || fail "安装包不完整，缺少文件：$file"
    done
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$SCRIPT_DIR" && sha256sum -c SHA256SUMS.txt >/dev/null) || fail "安装包 SHA256 校验失败"
    else
        echo "警告：未找到 sha256sum，已跳过安装包校验" >&2
    fi
}

extract_universal_package() {
    [ -d "$SCRIPT_DIR/packages" ] || return 0

    package=$(find "$SCRIPT_DIR/packages" -maxdepth 1 -type f -name "*-linux-$ARCH.tar.gz" | head -n 1)
    [ -n "$package" ] || fail "未找到适用于该架构的子安装包 $ARCH"
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$SCRIPT_DIR" && sha256sum -c SHA256SUMS.txt >/dev/null) || fail "通用安装包 SHA256 校验失败"
    fi

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT INT TERM
    tar -xzf "$package" -C "$work"
    package_root=$(find "$work" -maxdepth 1 -type d -name 'ysp-proxy-*' | head -n 1)
    [ -n "$package_root" ] || fail "未能定位解压后的安装包目录"
    sh "$package_root/install.sh"
    status=$?
    rm -rf "$work"
    trap - EXIT INT TERM
    exit "$status"
}

port_in_use() {
    port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"
        return $?
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$port$"
        return $?
    fi
    return 1
}

detect_lan_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip route get 1.1.1.1 2>/dev/null | awk '
            { for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit } }
        '
        return
    fi
    if command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

prompt_port() {
    while :; do
        printf 'HTTP 监听端口 [%s]: ' "${YSP_PORT:-8090}"
        IFS= read -r answer || fail "输入被中断"
        value=${answer:-${YSP_PORT:-8090}}
        case "$value" in
            ''|*[!0-9]*) echo "请输入数字。"; continue ;;
        esac
        if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
            echo "端口必须在 1 到 65535 之间。"
            continue
        fi
        if port_in_use "$value"; then
            if [ "$service_was_active" = 1 ] && [ "$value" = "${YSP_PORT:-}" ]; then
                YSP_PORT=$value
                return
            fi
            echo "端口 $value 已被占用。"
            continue
        fi
        YSP_PORT=$value
        return
    done
}

prompt_url() {
    default_ip=$(detect_lan_ip)
    default_url=${YSP_PUBLIC_BASE_URL:-}
    if [ -z "$default_url" ] && [ -n "$default_ip" ]; then
        default_url="http://$default_ip:$YSP_PORT"
    fi
    while :; do
        printf '公网访问地址 [%s]: ' "$default_url"
        IFS= read -r answer || fail "输入被中断"
        value=${answer:-$default_url}
        case "$value" in
            http://*|https://*) ;;
            *) echo "URL 必须以 http:// 或 https:// 开头。"; continue ;;
        esac
        YSP_PUBLIC_BASE_URL=${value%/}
        return
    done
}

prompt_int() {
    label=$1
    default_value=$2
    min_value=$3
    max_value=$4
    while :; do
        printf '%s [%s]: ' "$label" "$default_value" >&2
        IFS= read -r answer || fail "输入被中断"
        value=${answer:-$default_value}
        case "$value" in
            ''|*[!0-9]*) echo "请输入数字。"; continue ;;
        esac
        if [ "$value" -lt "$min_value" ] || [ "$value" -gt "$max_value" ]; then
            echo "数值必须在 $min_value 到 $max_value 之间。"
            continue
        fi
        printf '%s' "$value"
        return
    done
}

prompt_bool() {
    label=$1
    default_value=$2
    while :; do
        printf '%s [%s]: ' "$label" "$default_value" >&2
        IFS= read -r answer || fail "输入被中断"
        value=${answer:-$default_value}
        case "$value" in
            0|1) printf '%s' "$value"; return ;;
            *) echo "请输入 0 或 1。" ;;
        esac
    done
}

prompt_text() {
    label=$1
    default_value=$2
    printf '%s [%s]: ' "$label" "$default_value" >&2
    IFS= read -r answer || fail "输入被中断"
    printf '%s' "${answer:-$default_value}"
}

portable_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 "$@"
    else
        "$@"
    fi
}

helper_works() {
    helper=$1
    output=$(printf '%s\n' '{"id":1,"op":"close"}' | portable_timeout "$helper" 2>/dev/null || true)
    printf '%s\n' "$output" | grep -q '"op":"ready"'
    ready=$?
    printf '%s\n' "$output" | grep -q '"op":"close"'
    closed=$?
    [ "$ready" -eq 0 ] && [ "$closed" -eq 0 ]
}

shared_library_works() {
    library=$1
    command -v ldd >/dev/null 2>&1 || return 0
    ldd "$library" >/dev/null 2>&1
}

find_system_openh264() {
    command -v ldconfig >/dev/null 2>&1 || return 1
    for name in libopenh264.so.8 libopenh264.so.7 libopenh264.so.6 libopenh264.so.5 libopenh264.so; do
        path=$(ldconfig -p 2>/dev/null | awk -v name="$name" '$1 == name { print $NF; exit }')
        if [ -n "$path" ] && [ -e "$path" ]; then
            printf '%s' "$path"
            return 0
        fi
    done
    return 1
}

ensure_build_tools() {
    if command -v gcc >/dev/null 2>&1 && command -v g++ >/dev/null 2>&1 && command -v make >/dev/null 2>&1; then
        return
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        fail "从源码编译需要 gcc、g++ 与 make，但当前系统没有 apt-get 可用"
    fi
    printf '是否使用 apt-get 安装 gcc、g++ 与 make？[y/N]: '
    IFS= read -r answer || fail "输入被中断"
    case "$answer" in
        y|Y|yes|YES) ;;
        *) fail "从源码编译需要编译工具" ;;
    esac
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y gcc g++ make ca-certificates
}

fetch_url() {
    url=$1
    if command -v curl >/dev/null 2>&1; then
        curl -fsS --max-time 5 "$url" >/dev/null
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -O /dev/null "$url"
        return $?
    fi
    return 2
}

rollback() {
    echo "==> 安装失败，正在回滚" >&2
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    for name in "$BINARY" cmg-native libopenh264.so.8; do
        if [ -f "$BACKUP_DIR/$name" ]; then
            install -m 0755 "$BACKUP_DIR/$name" "$INSTALL_DIR/$name"
        else
            rm -f "$INSTALL_DIR/$name"
        fi
    done
    if [ -f "$BACKUP_DIR/ysp-proxy.service" ]; then
        install -m 0644 "$BACKUP_DIR/ysp-proxy.service" "$SERVICE_FILE"
    else
        rm -f "$SERVICE_FILE"
    fi
    if [ -f "$BACKUP_DIR/ysp-proxy.conf" ]; then
        install -m 0644 "$BACKUP_DIR/ysp-proxy.conf" "$CONFIG_FILE"
    else
        rm -f "$CONFIG_FILE"
    fi
    systemctl daemon-reload 2>/dev/null || true
    if [ -f "$SERVICE_FILE" ]; then
        systemctl enable --now "$SERVICE_NAME" 2>/dev/null || true
    else
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    fi
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi
[ "$#" -eq 0 ] || fail "install.sh 为交互式安装，不接受任何参数"

detect_arch
extract_universal_package
verify_package

# 部分打包环境（例如 Windows 上的 tar）不会保留 POSIX 执行位，这里补齐；
# 否则内置 helper 会被误判为不可用，回退脚本还会报 Permission denied。
for _f in "$SCRIPT_DIR/cmg-native" "$SCRIPT_DIR/build-fallback-native.sh" "$SCRIPT_DIR/build-fallback-openh264.sh"; do
    [ -f "$_f" ] && chmod 0755 "$_f" 2>/dev/null || true
done

[ "$(id -u)" -eq 0 ] || fail "请使用 root 权限运行此安装脚本（例如：sudo ./install.sh）"
need_command systemctl
need_command tar
[ -d /run/systemd/system ] || fail "此安装程序需要 systemd"
need_command install
need_command awk
need_command grep

if command -v df >/dev/null 2>&1; then
    available_kb=$(df -Pk /opt 2>/dev/null | awk 'NR == 2 {print $4}')
    if [ -n "$available_kb" ] && [ "$available_kb" -lt 102400 ]; then
        fail "/opt 下至少需要 100 MB 可用磁盘空间"
    fi
fi

if [ -r "$CONFIG_FILE" ]; then
    # 该文件由安装脚本维护，仅包含简单的 KEY=VALUE 项。
    . "$CONFIG_FILE"
fi
YSP_PORT=${YSP_PORT:-8090}
YSP_DECODER_LANES=${YSP_DECODER_LANES:-3}
YSP_PREFETCH=${YSP_PREFETCH:-0}
YSP_ANOMALY=${YSP_ANOMALY:-1}
YSP_EPG_CACHE=${YSP_EPG_CACHE:-$INSTALL_DIR/data/epg.xml.gz}
YSP_MEMORY_MAX=${YSP_MEMORY_MAX:-512M}

service_was_active=0
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    service_was_active=1
fi

echo "==> 开始配置"
prompt_port
prompt_url
prompt_int '解码并发数（1-8）' "$YSP_DECODER_LANES" 1 8 > /tmp/ysp-answer.$$
YSP_DECODER_LANES=$(cat /tmp/ysp-answer.$$)
prompt_bool '启用分片预取（0=关闭，1=开启）' "$YSP_PREFETCH" > /tmp/ysp-answer.$$
YSP_PREFETCH=$(cat /tmp/ysp-answer.$$)
prompt_bool '启用异常日志（0=关闭，1=开启）' "$YSP_ANOMALY" > /tmp/ysp-answer.$$
YSP_ANOMALY=$(cat /tmp/ysp-answer.$$)
YSP_EPG_CACHE=$(prompt_text 'EPG 缓存路径' "$YSP_EPG_CACHE")
YSP_MEMORY_MAX=$(prompt_text 'systemd MemoryMax' "$YSP_MEMORY_MAX")
rm -f /tmp/ysp-answer.$$

case "$YSP_MEMORY_MAX" in
    *[!0-9BbIiKkMmGgTtPp]*) fail "MemoryMax 格式无效：$YSP_MEMORY_MAX（例如 512M、512MiB、1G、200MB）" ;;
    *[!0-9]*) ;;
    *) fail "MemoryMax 必须带单位：$YSP_MEMORY_MAX 不带单位时 systemd 会当成字节数（200 = 200 字节），进程会立刻被 OOM 杀掉。请输入 200M、512M 或 1G。" ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

echo "==> 正在准备运行时依赖..."
if [ -x "$SCRIPT_DIR/cmg-native" ] && helper_works "$SCRIPT_DIR/cmg-native"; then
    helper_source=$SCRIPT_DIR/cmg-native
else
    echo "当前系统无法直接使用内置 cmg-native，将从源码重新编译。"
    ensure_build_tools
    "$SCRIPT_DIR/build-fallback-native.sh" "$work/cmg-native"
    helper_source=$work/cmg-native
fi

if shared_library_works "$SCRIPT_DIR/libopenh264.so.8"; then
    openh264_source=$SCRIPT_DIR/libopenh264.so.8
elif system_openh264=$(find_system_openh264); then
    openh264_source=$system_openh264
else
    echo "当前系统无法直接使用内置 OpenH264，将从源码重新编译。"
    ensure_build_tools
    # 源码包不再随安装包分发，缺失时由回退脚本按需下载到本地。
    "$SCRIPT_DIR/build-fallback-openh264.sh" \
        "$work/openh264-2.6.0.tar.gz" \
        "$work/libopenh264.so.8"
    openh264_source=$work/libopenh264.so.8
fi

# 备份现有程序、service 与配置，失败时用于回滚。
BACKUP_DIR="$INSTALL_DIR/backups/$(date -u +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for file in "$BINARY" cmg-native libopenh264.so.8; do
    if [ -f "$INSTALL_DIR/$file" ]; then
        cp -a "$INSTALL_DIR/$file" "$BACKUP_DIR/$file"
    fi
done
[ -f "$SERVICE_FILE" ] && cp -a "$SERVICE_FILE" "$BACKUP_DIR/ysp-proxy.service"
[ -f "$CONFIG_FILE" ] && cp -a "$CONFIG_FILE" "$BACKUP_DIR/ysp-proxy.conf"

# 安装程序、helper 与运行数据到 /opt/ysp-proxy。
echo "==> 正在安装至 $INSTALL_DIR"
mkdir -p "$INSTALL_DIR/data"
chmod 0755 "$INSTALL_DIR" "$INSTALL_DIR/data"

systemctl stop "$SERVICE_NAME" 2>/dev/null || true
install -m 0755 "$SCRIPT_DIR/$BINARY" "$INSTALL_DIR/$BINARY.new"
install -m 0755 "$helper_source" "$INSTALL_DIR/cmg-native.new"
install -m 0755 "$openh264_source" "$INSTALL_DIR/libopenh264.so.8.new"
mv "$INSTALL_DIR/$BINARY.new" "$INSTALL_DIR/$BINARY"
mv "$INSTALL_DIR/cmg-native.new" "$INSTALL_DIR/cmg-native"
mv "$INSTALL_DIR/libopenh264.so.8.new" "$INSTALL_DIR/libopenh264.so.8"
rm -rf "$INSTALL_DIR/native-src"
cp -a "$SCRIPT_DIR/native-src" "$INSTALL_DIR/native-src"

cat > "$work/ysp-proxy.conf" <<EOF
YSP_PORT=$YSP_PORT
YSP_PUBLIC_BASE_URL=$YSP_PUBLIC_BASE_URL
YSP_CMG_BACKEND=native
YSP_CMG_NATIVE=$INSTALL_DIR/cmg-native
YSP_DECODER_LANES=$YSP_DECODER_LANES
YSP_PREFETCH=$YSP_PREFETCH
YSP_ANOMALY=$YSP_ANOMALY
YSP_EPG_CACHE=$YSP_EPG_CACHE
YSP_OPENH264=$INSTALL_DIR/libopenh264.so.8
YSP_MEMORY_MAX=$YSP_MEMORY_MAX
EOF

cat > "$work/ysp-proxy.service" <<EOF
[Unit]
Description=Yangshipin IPTV proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=-$CONFIG_FILE
ExecStart=$INSTALL_DIR/$BINARY -addr 0.0.0.0:$YSP_PORT
MemoryMax=$YSP_MEMORY_MAX
Restart=always
RestartSec=3
LimitNOFILE=4096
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

install -m 0644 "$work/ysp-proxy.conf" "$CONFIG_FILE"
install -m 0644 "$work/ysp-proxy.service" "$SERVICE_FILE"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null
start_time=$(date '+%Y-%m-%d %H:%M:%S')

if ! systemctl start "$SERVICE_NAME"; then
    rollback
    fail "服务启动失败"
fi

# 轮询等待服务就绪，并验证首页与直播地址。
healthy=0
attempt=1
while [ "$attempt" -le 30 ]; do
    if fetch_url "http://127.0.0.1:$YSP_PORT/" && \
       fetch_url "http://127.0.0.1:$YSP_PORT/live/600001859/fhd.m3u8"; then
        healthy=1
        break
    fi
    attempt=$((attempt + 1))
    sleep 1
done

# 确认日志中出现 cmg helper ready 标记。
helper_ready=0
if command -v journalctl >/dev/null 2>&1; then
    if journalctl -u "$SERVICE_NAME" --since "$start_time" --no-pager 2>/dev/null | \
        grep -q 'cmg helper ready'; then
        helper_ready=1
    fi
else
    helper_ready=1
fi

if [ "$healthy" -ne 1 ] || [ "$helper_ready" -ne 1 ]; then
    journalctl -u "$SERVICE_NAME" --no-pager -n 40 2>/dev/null || true
    rollback
    fail "健康检查未通过"
fi

echo
# 输出安装结果与常用命令。
echo "==> 安装成功"
echo "    服务管理：systemctl status $SERVICE_NAME"
echo "    查看日志：journalctl -u $SERVICE_NAME -f"
echo "    网页播放：http://<设备IP>:$YSP_PORT/"
echo "    订阅地址：$YSP_PUBLIC_BASE_URL/yuanzl77"
echo "    备份位置：$BACKUP_DIR"
