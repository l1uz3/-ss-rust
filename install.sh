#!/bin/bash

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 用户或 sudo 运行此脚本。"
    exit 1
fi

CONFIG_FILE="/etc/shadowsocks-rust/config.json"
BIN_FILE="/usr/local/bin/ssserver"
CLI_FILE="/usr/local/bin/ss"

# 检测系统与服务管理器
check_sys() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        echo "无法识别当前系统！"
        exit 1
    fi

    if [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    else
        INIT_SYSTEM="openrc"
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64)
            TARGET_ARCH="x86_64-unknown-linux-musl"
            ;;
        aarch64|arm64)
            TARGET_ARCH="aarch64-unknown-linux-musl"
            ;;
        *)
            echo "暂不支持的 CPU 架构: $ARCH (仅支持 x86_64, aarch64)"
            exit 1
            ;;
    esac
}

# 安装依赖
install_dependencies() {
    echo "正在安装基础依赖..."
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        apt-get update -y && apt-get install -y curl tar jq openssl
    else
        apk update && apk add curl tar jq openssl libgcc
    fi
}

# 安装 SS-Rust
install_ss() {
    check_sys
    install_dependencies

    echo ""
    echo "========================================="
    echo "         开始安装 Shadowsocks-Rust       "
    echo "========================================="

    # 1. 配置端口
    DEFAULT_PORT=$((RANDOM % 55535 + 10000))
    read -rp "请输入监听端口 [默认: $DEFAULT_PORT]: " PORT
    PORT=${PORT:-$DEFAULT_PORT}

    # 2. 加密方式选择
    echo ""
    echo "请选择加密方式:"
    echo "  1) 2022-blake3-aes-128-gcm (推荐，性能优)"
    echo "  2) 2022-blake3-aes-256-gcm (推荐，高强度)"
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

    # 3. 生成合规密钥（彻底解决 status 70 报错）
    if [ "$KEY_LEN" -gt 0 ]; then
        AUTO_KEY=$(openssl rand "$KEY_LEN" | base64 | tr -d '\n')
        read -rp "请输入密码 (Base64编码，需为 $KEY_LEN 字节) [回车自动生成]: " PASSWORD
        PASSWORD=${PASSWORD:-$AUTO_KEY}
    else
        AUTO_PASS=$(openssl rand -base64 16 | tr -d '\n')
        read -rp "请输入密码 [回车自动生成: $AUTO_PASS]: " PASSWORD
        PASSWORD=${PASSWORD:-$AUTO_PASS}
    fi

    # 4. 获取最新 Release 并下载
    echo "正在查询 shadowsocks-rust 最新发布版本..."
    LATEST_TAG=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r '.tag_name')
    if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
        echo "获取最新版本失败，使用稳定回退版本 v1.21.2"
        LATEST_TAG="v1.21.2"
    fi

    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_TAG}/shadowsocks-${LATEST_TAG}.${TARGET_ARCH}.tar.xz"
    echo "下载地址: $DOWNLOAD_URL"

    TMP_DIR=$(mktemp -d)
    curl -sL "$DOWNLOAD_URL" | tar -xJ -C "$TMP_DIR"
    install -m 755 "$TMP_DIR/ssserver" "$BIN_FILE"
    rm -rf "$TMP_DIR"

    # 5. 写入配置
    mkdir -p /etc/shadowsocks-rust
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

    # 6. 配置守护服务
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        cat > /etc/systemd/system/ss-server.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=32768
ExecStart=/usr/local/bin/ssserver -c /etc/shadowsocks-rust/config.json
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ss-server >/dev/null 2>&1
        systemctl restart ss-server
    else
        cat > /etc/init.d/ss-server <<'EOF'
#!/sbin/openrc-run

name="ss-server"
description="Shadowsocks-Rust Server"
command="/usr/local/bin/ssserver"
command_args="-c /etc/shadowsocks-rust/config.json"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"

depend() {
    need net
}
EOF
        chmod +x /etc/init.d/ss-server
        rc-update add ss-server default >/dev/null 2>&1
        rc-service ss-server restart
    fi

    # 7. 安装自身为全局命令 /usr/local/bin/ss
    cp "$0" "$CLI_FILE" 2>/dev/null || curl -sL https://raw.githubusercontent.com/l1uz3/-ss-rust/main/install.sh -o "$CLI_FILE"
    chmod +x "$CLI_FILE"

    echo ""
    echo "Shadowsocks-Rust 安装完成并已成功启动！"
    view_node
}

# 查看节点信息
view_node() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "错误: 未检测到配置文件，服务可能未安装！"
        return
    fi

    PORT=$(jq -r '.server_port' "$CONFIG_FILE")
    METHOD=$(jq -r '.method' "$CONFIG_FILE")
    PASSWORD=$(jq -r '.password' "$CONFIG_FILE")

    SERVER_IP=$(curl -s4m 4 https://api.ipify.org || curl -s4m 4 https://icanhazip.com || echo "你的公网IP")

    RAW_USERINFO="${METHOD}:${PASSWORD}"
    BASE64_USERINFO=$(echo -n "$RAW_USERINFO" | base64 | tr -d '\n' | tr '/+' '_-' | tr -d '=')
    SS_LINK="ss://${BASE64_USERINFO}@${SERVER_IP}:${PORT}#SS-Rust"

    echo ""
    echo "========================================="
    echo "             当前节点信息                "
    echo "========================================="
    echo "服务器 IP:   $SERVER_IP"
    echo "端口 (Port): $PORT"
    echo "密码 (Pass): $PASSWORD"
    echo "加密 (Crypt):$METHOD"
    echo "配置文件:    $CONFIG_FILE"
    echo "-----------------------------------------"
    echo "节点链接 (SIP002):"
    echo "$SS_LINK"
    echo "========================================="
    echo "提示: 以后随时在终端输入 ss 即可打开管理面板"
    echo ""
}

# 查看运行状态
view_status() {
    check_sys
    echo "---------------- 服务状态 ----------------"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl status ss-server --no-pager
    else
        rc-service ss-server status
    fi
    echo "------------------------------------------"
}

# 重启服务
restart_service() {
    check_sys
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart ss-server
    else
        rc-service ss-server restart
    fi
    echo "服务已重启！"
}

# 停止服务
stop_service() {
    check_sys
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop ss-server
    else
        rc-service ss-server stop
    fi
    echo "服务已停止！"
}

# 查看日志
view_log() {
    check_sys
    echo "按 Ctrl + C 退出日志查看"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        journalctl -u ss-server -f
    else
        tail -f /var/log/messages
    fi
}

# 卸载 SS-Rust
uninstall_ss() {
    read -rp "确定要彻底卸载 Shadowsocks-Rust 吗？[y/N]: " CONFIRM
    case "$CONFIRM" in
        [yY][eE][sS]|[yY])
            check_sys
            echo "正在卸载..."
            if [ "$INIT_SYSTEM" = "systemd" ]; then
                systemctl stop ss-server >/dev/null 2>&1 || true
                systemctl disable ss-server >/dev/null 2>&1 || true
                rm -f /etc/systemd/system/ss-server.service
                systemctl daemon-reload
            else
                rc-service ss-server stop >/dev/null 2>&1 || true
                rc-update del ss-server default >/dev/null 2>&1 || true
                rm -f /etc/init.d/ss-server
            fi

            rm -f "$BIN_FILE"
            rm -rf /etc/shadowsocks-rust
            rm -f "$CLI_FILE"

            echo "卸载完成！所有相关文件及 ss 管理命令已移除。"
            exit 0
            ;;
        *)
            echo "已取消卸载。"
            ;;
    esac
}

# 交互主菜单
menu() {
    clear
    echo "========================================="
    echo "       Shadowsocks-Rust 管理面板         "
    echo "========================================="
    echo " 1. 安装 / 重新安装 节点"
    echo " 2. 查看 节点配置与链接"
    echo " 3. 卸载 Shadowsocks-Rust"
    echo "-----------------------------------------"
    echo " 4. 查看 运行状态"
    echo " 5. 重启 服务"
    echo " 6. 停止 服务"
    echo " 7. 查看 实时日志"
    echo " 0. 退出"
    echo "========================================="
    read -rp "请输入选项 [0-7]: " num

    case "$num" in
        1) install_ss ;;
        2) view_node ;;
        3) uninstall_ss ;;
        4) view_status ;;
        5) restart_service ;;
        6) stop_service ;;
        7) view_log ;;
        0) exit 0 ;;
        *) echo "无效选项，请输入 0-7" ;;
    esac
}

# 脚本入口
menu
