#!/bin/bash

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 用户或 sudo 运行此脚本。"
    exit 1
fi

CONFIG_FILE="/etc/shadowsocks-rust/config.json"
BIN_FILE="/usr/local/bin/ssserver"

# 清理旧残留别名，避免误影响系统原生 ss
rm -f /usr/local/bin/ss /usr/local/bin/ssrust
hash -r 2>/dev/null || true

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

install_dependencies() {
    echo "正在安装基础依赖..."
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        apt-get update -y && apt-get install -y curl tar jq openssl
    else
        apk update && apk add curl tar xz jq openssl libgcc
    fi
}

install_ss() {
    check_sys
    install_dependencies

    echo ""
    echo "========================================="
    echo "         开始安装 Shadowsocks-Rust       "
    echo "========================================="

    # 1. 端口配置
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
            AUTO_KEY=$(openssl rand -base64 32)
            ;;
        3)
            METHOD="2022-blake3-chacha20-poly1305"
            AUTO_KEY=$(openssl rand -base64 32)
            ;;
        4)
            METHOD="aes-256-gcm"
            AUTO_KEY=$(openssl rand -base64 16)
            ;;
        5)
            METHOD="chacha20-ietf-poly1305"
            AUTO_KEY=$(openssl rand -base64 16)
            ;;
        *)
            METHOD="2022-blake3-aes-128-gcm"
            AUTO_KEY=$(openssl rand -base64 16)
            ;;
    esac

    # 3. 输入或自动生成密码
    read -rp "请输入密码 [直接回车自动生成合规密钥]: " PASSWORD
    PASSWORD=${PASSWORD:-$AUTO_KEY}

    # 4. 下载对应架构二进制
    echo "正在查询 shadowsocks-rust 最新版本..."
    LATEST_TAG=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest | jq -r '.tag_name')
    if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
        LATEST_TAG="v1.21.2"
    fi

    DOWNLOAD_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST_TAG}/shadowsocks-${LATEST_TAG}.${TARGET_ARCH}.tar.xz"
    echo "正在下载: $DOWNLOAD_URL"

    # 清理残留进程，防止端口冲突
    killall -9 ssserver 2>/dev/null || pkill -9 -f ssserver 2>/dev/null || true

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

    # 6. 配置守护服务 (服务名为 ss-server)
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

    echo ""
    echo "Shadowsocks-Rust 安装完成并已成功启动！"
    view_node
}

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
    echo ""
}

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

restart_service() {
    check_sys
    killall -9 ssserver 2>/dev/null || pkill -9 -f ssserver 2>/dev/null || true
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart ss-server
    else
        rc-service ss-server restart
    fi
    echo "服务已重启！"
}

stop_service() {
    check_sys
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop ss-server
    else
        rc-service ss-server stop
    fi
    killall -9 ssserver 2>/dev/null || pkill -9 -f ssserver 2>/dev/null || true
    echo "服务已停止！"
}

view_log() {
    check_sys
    echo "按 Ctrl + C 退出实时日志查看"
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        journalctl -u ss-server -f
    else
        tail -f /var/log/messages
    fi
}

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

            killall -9 ssserver 2>/dev/null || pkill -9 -f ssserver 2>/dev/null || true
            rm -f "$BIN_FILE"
            rm -rf /etc/shadowsocks-rust
            rm -f /usr/local/bin/ss /usr/local/bin/ssrust
            hash -r 2>/dev/null || true

            echo "卸载完成！所有相关文件已清理。"
            exit 0
            ;;
        *)
            echo "已取消卸载。"
            ;;
    esac
}

# 交互主菜单（循环停留，操作完按回车返回，按 0 退出）
menu() {
    while true; do
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
        echo " 0. 退出面板"
        echo "========================================="
        read -rp "请输入选项 [0-7]: " num

        case "$num" in
            1)
                install_ss
                read -rp "按回车键返回菜单..." _
                ;;
            2)
                view_node
                read -rp "按回车键返回菜单..." _
                ;;
            3)
                uninstall_ss
                read -rp "按回车键返回菜单..." _
                ;;
            4)
                view_status
                read -rp "按回车键返回菜单..." _
                ;;
            5)
                restart_service
                read -rp "按回车键返回菜单..." _
                ;;
            6)
                stop_service
                read -rp "按回车键返回菜单..." _
                ;;
            7)
                view_log
                ;;
            0)
                echo "已退出管理面板。"
                exit 0
                ;;
            *)
                echo "无效选项，请输入 0-7"
                sleep 1
                ;;
        esac
    done
}

# 入口
menu
