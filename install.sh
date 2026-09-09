#!/bin/bash
set -e

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 用户或 sudo 运行此脚本。"
    exit 1
fi

# 检查系统类型与架构
OS=""
INIT_SYSTEM=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
fi

case "$OS" in
    ubuntu|debian)
        INIT_SYSTEM="systemd"
        apt-get update -y && apt-get install -y curl tar jq openssl qrencode
        ;;
    alpine)
        INIT_SYSTEM="openrc"
        apk update && apk add curl tar jq openssl libgcc qrencode
        ;;
    *)
        echo "不支持的系统: $OS (仅支持 Debian, Ubuntu, Alpine)"
        exit 1
        ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)
        TARGET_ARCH="x86_64-unknown-linux-musl"
        ;;
    aarch64|arm64)
        TARGET_ARCH="aarch64-unknown-linux-musl"
        ;;
    *)
        echo "不支持的CPU架构: $ARCH (仅支持 x86_64, aarch64)"
        exit 1
        ;;
esac

echo "========================================="
echo "       Shadowsocks-Rust 一键安装脚本     "
echo "========================================="

# 端口配置
DEFAULT_PORT=$((RANDOM % 55535 + 10000))
read -rp "请输入监听端口 [默认: $DEFAULT_PORT]: " PORT
PORT=${PORT:-$DEFAULT_PORT}

# 加密方式选择
echo "请选择加密方式:"
echo "  1) 2022-blake3-aes-128-gcm (推荐，低开销)"
echo "  2) 2022-blake3-aes-256-gcm (推荐，高安全)"
echo "  3) 2022-blake3-chacha20-poly1305"
echo "  4) aes-256-gcm (传统兼容)"
echo "  5) chacha20-ietf-poly1305 (传统兼容)"
read -rp "输入选项 [1-5，默认 1]: " METHOD_CHOICE

case "$METHOD_CHOICE" in
    2)
        METHOD="2022-blake3-aes-256-gcm"
        KEY_LEN=32
        ;;
    3)
        METHOD="2022-blake3-chacha20-poly1305"
        KEY_LEN=32
        ;;
    4)
        METHOD="aes-256-gcm"
        KEY_LEN=0
        ;;
    5)
        METHOD="chacha20-ietf-poly1305"
        KEY_LEN=0
        ;;
    *)
        METHOD="2022-blake3-aes-128-gcm"
        KEY_LEN=16
        ;;
esac

# 密码生成 / 输入
if [ "$KEY_LEN" -gt 0 ]; then
    AUTO_KEY=$(openssl rand -base64 "$KEY_LEN")
    read -rp "请输入密码 (Base64格式 $KEY_LEN 字节) [直接回车自动生成]: " PASSWORD
    PASSWORD=${PASSWORD:-$AUTO_KEY}
else
    AUTO_PASS=$(openssl rand -base64 16)
    read -rp "请输入密码 [直接回车自动生成: $AUTO_PASS]: " PASSWORD
    PASSWORD=${PASSWORD:-$AUTO_PASS}
fi

# 获取最新 release 版本
echo "正在获取 shadowsocks-rust 最新版本..."
LATEST_TAG=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r '.tag_name')
if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
    echo "获取最新版本失败，回退至稳定版 v1.21.2"
    LATEST_TAG="v1.21.2"
fi

DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_TAG}/shadowsocks-${LATEST_TAG}.${TARGET_ARCH}.tar.xz"

# 下载并解压
echo "正在下载: $DOWNLOAD_URL"
TMP_DIR=$(mktemp -d)
curl -sL "$DOWNLOAD_URL" | tar -xJ -C "$TMP_DIR"
install -m 755 "$TMP_DIR/ssserver" /usr/local/bin/ssserver
rm -rf "$TMP_DIR"

# 写入配置文件
mkdir -p /etc/shadowsocks-rust
CONFIG_FILE="/etc/shadowsocks-rust/config.json"
cat > "$CONFIG_FILE" <<EOF
{
    "server": "0.0.0.0",
    "server_port": $PORT,
    "password": "$PASSWORD",
    "method": "$METHOD",
    "timeout": 300,
    "mode": "tcp_and_udp"
}
EOF

# 守护进程与服务管理 (服务名改为 ss)
if [ "$INIT_SYSTEM" = "systemd" ]; then
    cat > /etc/systemd/system/ss.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ss
    systemctl restart ss
elif [ "$INIT_SYSTEM" = "openrc" ]; then
    cat > /etc/init.d/ss <<'EOF'
#!/sbin/openrc-run

name="ss"
description="Shadowsocks-Rust Server"
command="/usr/local/bin/ssserver"
command_args="-c /etc/shadowsocks-rust/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
    chmod +x /etc/init.d/ss
    rc-update add ss default
    rc-service ss restart
fi

# 创建极简管理脚本 /usr/local/bin/ss
cat > /usr/local/bin/ss <<'EOF'
#!/bin/sh
ACTION=$1
INIT="systemd"
[ ! -f /run/systemd/system ] && INIT="openrc"

case "$ACTION" in
    start)
        [ "$INIT" = "systemd" ] && systemctl start ss || rc-service ss start
        ;;
    stop)
        [ "$INIT" = "systemd" ] && systemctl stop ss || rc-service ss stop
        ;;
    restart)
        [ "$INIT" = "systemd" ] && systemctl restart ss || rc-service ss restart
        ;;
    status)
        [ "$INIT" = "systemd" ] && systemctl status ss || rc-service ss status
        ;;
    log)
        [ "$INIT" = "systemd" ] && journalctl -u ss -f || tail -f /var/log/messages
        ;;
    config)
        vi /etc/shadowsocks-rust/config.json
        ;;
    *)
        echo "使用方法: ss {start|stop|restart|status|log|config}"
        ;;
esac
EOF
chmod +x /usr/local/bin/ss

# 获取公网 IP
SERVER_IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://icanhazip.com || echo "YOUR_SERVER_IP")

# 生成 ss:// 链接 (SIP002 格式)
RAW_USERINFO="${METHOD}:${PASSWORD}"
BASE64_USERINFO=$(echo -n "$RAW_USERINFO" | base64 | tr -d '\n' | tr '/+' '_-' | tr -d '=')
SS_LINK="ss://${BASE64_USERINFO}@${SERVER_IP}:${PORT}#SS-Rust"

echo ""
echo "========================================="
echo "        Shadowsocks-Rust 安装成功        "
echo "========================================="
echo "服务器 IP:   $SERVER_IP"
echo "服务端口:    $PORT"
echo "加密方式:    $METHOD"
echo "连接密码:    $PASSWORD"
echo "配置文件:    $CONFIG_FILE"
echo "-----------------------------------------"
echo "快捷管理命令 (全系统通用):"
echo "  ss status   - 查看运行状态"
echo "  ss restart  - 重启服务"
echo "  ss start    - 启动服务"
echo "  ss stop     - 停止服务"
echo "  ss log      - 实时日志"
echo "  ss config   - 修改配置文件"
echo "-----------------------------------------"
echo "节点链接 (SIP002):"
echo "$SS_LINK"
echo "========================================="
