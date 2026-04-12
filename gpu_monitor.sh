#!/bin/bash

# GPU自动监控脚本 - VastAI 功耗上报
# 一条命令安装: curl -fsSL https://raw.githubusercontent.com/chenshaoquan/chaojinbidggbpujk/main/gpu_monitor.sh | sudo bash -s -- http://你的服务器:端口
# 或者下载后运行: ./gpu_monitor.sh http://你的服务器:端口

# ========================================
# 配置
# ========================================
API_BASE_URL="${1:-${API_BASE_URL:-}}"
MACHINE_ID_FILE="/root/machine_id.txt"
MONITOR_INTERVAL=10
TIMEOUT_DURATION=5
SERVICE_NAME="gpu-power-monitor"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/gpu_monitor.sh"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ========================================
# 获取 machine_id
# ========================================
extract_latest_machine_id() {
    grep -hE 'machine_id=[0-9]+' /var/lib/vastai_kaalia/kaalia*.log* 2>/dev/null \
      | sed -n 's/.*\[\([0-9-]\+ [0-9:.]\+\)\].*machine_id=\([0-9]\+\).*/\1|\2/p' \
      | sort \
      | tail -n 1 \
      | cut -d'|' -f2
}

get_machine_id() {
    # 从 kaalia 日志中按时间提取最新 machine_id
    local mid
    mid=$(extract_latest_machine_id)
    
    # 只有获取到非空有效值时才更新文件
    if [ -n "$mid" ] && [[ "$mid" =~ ^[0-9]+$ ]]; then
        echo "$mid" > "$MACHINE_ID_FILE"
        MACHINE_ID="$mid"
        return 0
    elif [ -f "$MACHINE_ID_FILE" ] && [ -s "$MACHINE_ID_FILE" ]; then
        # 日志中没有获取到，使用已缓存的值（不覆盖）
        MACHINE_ID=$(cat "$MACHINE_ID_FILE" | tr -d '[:space:]')
        [ -n "$MACHINE_ID" ] && return 0
    fi
    return 1
}

# ========================================
# GPU 监控
# ========================================
get_gpu_info() {
    GPU_COUNT=$(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1)
    [ -z "$GPU_COUNT" ] || [ "$GPU_COUNT" -eq 0 ] && return 1
    
    local temps=($(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null))
    local temp_sum=0 temp_count=0
    for t in "${temps[@]}"; do
        [[ "$t" =~ ^[0-9]+$ ]] && { temp_sum=$((temp_sum + t)); temp_count=$((temp_count + 1)); }
    done
    GPU_TEMP=$((temp_count > 0 ? temp_sum / temp_count : 0))
    
    local powers=($(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | sed 's/[^0-9.]/ /g'))
    local power_sum=0
    for p in "${powers[@]}"; do
        [[ "$p" =~ ^[0-9.]+$ ]] && power_sum=$(awk "BEGIN {print $power_sum + $p}")
    done
    GPU_POWER=$(printf "%.1f" "$power_sum")
    
    local utils=($(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sed 's/[^0-9.]/ /g'))
    local util_sum=0 util_count=0
    for u in "${utils[@]}"; do
        [[ "$u" =~ ^[0-9.]+$ ]] && { util_sum=$(awk "BEGIN {print $util_sum + $u}"); util_count=$((util_count + 1)); }
    done
    GPU_UTIL=$(printf "%.1f" "$(awk "BEGIN {print ($util_count > 0) ? ($util_sum / $util_count) : 0}")")
    
    return 0
}

send_data() {
    curl -s -X POST "${API_BASE_URL}/api/monitor/data/${MACHINE_ID}" \
      -H "Content-Type: application/json" \
      -d "{\"gpu_temperature\": ${GPU_TEMP}, \"gpu_power_usage\": ${GPU_POWER}, \"gpu_utilization\": ${GPU_UTIL}}" \
      -w "%{http_code}" -o /dev/null 2>/dev/null
}

# ========================================
# 循环监控
# ========================================
monitor_loop() {
    while true; do
        [ -f "$MACHINE_ID_FILE" ] && MACHINE_ID=$(cat "$MACHINE_ID_FILE" | tr -d '[:space:]')
        
        if get_gpu_info; then
            local code=$(send_data)
            local status="OK"
            [ "$GPU_TEMP" -ge 60 ] && status="WARN"
            [ "$GPU_TEMP" -ge 80 ] && status="CRIT"
            
            if [ "$code" == "200" ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') | ID:${MACHINE_ID} | ${GPU_TEMP}°C | ${GPU_POWER}W | ${GPU_UTIL}% | ${status} | OK"
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S') | ID:${MACHINE_ID} | ${GPU_TEMP}°C | ${GPU_POWER}W | ${GPU_UTIL}% | FAIL(${code})"
            fi
        fi
        
        sleep $MONITOR_INTERVAL
    done
}

# ========================================
# 安装为 systemd 服务
# ========================================
install_service() {
    if [ -z "$API_BASE_URL" ]; then
        log_error "请提供 API 地址"
        echo ""
        echo "用法: curl -fsSL <脚本URL> | bash -s -- <API地址>"
        echo "示例: curl -fsSL https://xxx/gpu_monitor.sh | bash -s -- http://server:3000"
        exit 1
    fi
    
    log_info "=========================================="
    log_info "GPU 功耗监控 - 一键安装"
    log_info "=========================================="
    log_info "API 地址: $API_BASE_URL"
    echo ""
    
    # 检查 root
    if [ "$EUID" -ne 0 ]; then
        log_error "需要 root 权限，请使用 sudo 或 root 用户运行"
        exit 1
    fi
    
    # 检查 nvidia-smi
    if ! command -v nvidia-smi &> /dev/null; then
        log_error "nvidia-smi 未找到，请先安装 NVIDIA 驱动"
        exit 1
    fi
    log_success "nvidia-smi 可用"
    
    # 获取 machine_id
    log_info "正在获取 machine_id..."
    if get_machine_id; then
        log_success "machine_id: $MACHINE_ID"
    else
        log_warning "暂未获取到 machine_id，服务启动后会自动重试"
    fi
    
    # 下载脚本到系统目录
    log_info "安装脚本到 $SCRIPT_INSTALL_PATH..."
    
    # 如果是通过 curl | bash 运行，需要保存脚本
    if [ ! -f "$0" ] || [ "$0" == "bash" ]; then
        # 从 stdin 读取脚本内容（已经在内存中执行了）
        # 需要重新下载或使用 heredoc 保存
        cat > "$SCRIPT_INSTALL_PATH" << 'SCRIPT_EOF'
#!/bin/bash
API_BASE_URL="${1:-${API_BASE_URL:-}}"
MACHINE_ID_FILE="/root/machine_id.txt"
MONITOR_INTERVAL=10
TIMEOUT_DURATION=5

extract_latest_machine_id() {
    grep -hE 'machine_id=[0-9]+' /var/lib/vastai_kaalia/kaalia*.log* 2>/dev/null \
      | sed -n 's/.*\[\([0-9-]\+ [0-9:.]\+\)\].*machine_id=\([0-9]\+\).*/\1|\2/p' \
      | sort \
      | tail -n 1 \
      | cut -d'|' -f2
}

get_machine_id() {
    local mid
    mid=$(extract_latest_machine_id)
    # 只有获取到非空有效值时才更新文件
    if [ -n "$mid" ] && [[ "$mid" =~ ^[0-9]+$ ]]; then
        echo "$mid" > "$MACHINE_ID_FILE"
        MACHINE_ID="$mid"
        return 0
    elif [ -f "$MACHINE_ID_FILE" ] && [ -s "$MACHINE_ID_FILE" ]; then
        # 日志中没有获取到，使用已缓存的值（不覆盖）
        MACHINE_ID=$(cat "$MACHINE_ID_FILE" | tr -d '[:space:]')
        [ -n "$MACHINE_ID" ] && return 0
    fi
    return 1
}

get_gpu_info() {
    GPU_COUNT=$(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=count --format=csv,noheader,nounits 2>/dev/null | head -1)
    [ -z "$GPU_COUNT" ] || [ "$GPU_COUNT" -eq 0 ] && return 1
    
    local temps=($(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null))
    local temp_sum=0 temp_count=0
    for t in "${temps[@]}"; do
        [[ "$t" =~ ^[0-9]+$ ]] && { temp_sum=$((temp_sum + t)); temp_count=$((temp_count + 1)); }
    done
    GPU_TEMP=$((temp_count > 0 ? temp_sum / temp_count : 0))
    
    local powers=($(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | sed 's/[^0-9.]/ /g'))
    local power_sum=0
    for p in "${powers[@]}"; do
        [[ "$p" =~ ^[0-9.]+$ ]] && power_sum=$(awk "BEGIN {print $power_sum + $p}")
    done
    GPU_POWER=$(printf "%.1f" "$power_sum")
    
    local utils=($(timeout $TIMEOUT_DURATION nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sed 's/[^0-9.]/ /g'))
    local util_sum=0 util_count=0
    for u in "${utils[@]}"; do
        [[ "$u" =~ ^[0-9.]+$ ]] && { util_sum=$(awk "BEGIN {print $util_sum + $u}"); util_count=$((util_count + 1)); }
    done
    GPU_UTIL=$(printf "%.1f" "$(awk "BEGIN {print ($util_count > 0) ? ($util_sum / $util_count) : 0}")")
    
    return 0
}

send_data() {
    curl -s -X POST "${API_BASE_URL}/api/monitor/data/${MACHINE_ID}" \
      -H "Content-Type: application/json" \
      -d "{\"gpu_temperature\": ${GPU_TEMP}, \"gpu_power_usage\": ${GPU_POWER}, \"gpu_utilization\": ${GPU_UTIL}}" \
      -w "%{http_code}" -o /dev/null 2>/dev/null
}

while true; do
    get_machine_id
    if [ -n "$MACHINE_ID" ] && get_gpu_info; then
        send_data > /dev/null
    fi
    sleep $MONITOR_INTERVAL
done
SCRIPT_EOF
    else
        cp "$0" "$SCRIPT_INSTALL_PATH"
    fi
    chmod +x "$SCRIPT_INSTALL_PATH"
    log_success "脚本已安装"
    
    # 创建 systemd 服务
    log_info "创建 systemd 服务..."
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=GPU Power Monitor Service
After=network.target

[Service]
Type=simple
Environment="API_BASE_URL=${API_BASE_URL}"
ExecStart=${SCRIPT_INSTALL_PATH} ${API_BASE_URL}
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    
    # 创建 machine-id 更新定时器
    log_info "创建 machine-id 自动更新定时器..."
    cat > /etc/systemd/system/machine-id-update.service << 'EOF'
[Unit]
Description=Update machine_id from kaalia logs

[Service]
Type=oneshot
ExecStart=/bin/bash -c "mid=$(grep -hE 'machine_id=[0-9]+' /var/lib/vastai_kaalia/kaalia*.log* 2>/dev/null | sed -n 's/.*\\[\\([0-9-]\\+ [0-9:.]\\+\\)\\].*machine_id=\\([0-9]\\+\\).*/\\1|\\2/p' | sort | tail -n 1 | cut -d'|' -f2); [ -n \"$mid\" ] && echo \"$mid\" > /root/machine_id.txt"
EOF

    cat > /etc/systemd/system/machine-id-update.timer << 'EOF'
[Unit]
Description=Run machine-id-update every 10 minutes

[Timer]
OnBootSec=10s
OnUnitActiveSec=10min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # 启动服务
    systemctl daemon-reload
    systemctl enable --now machine-id-update.timer
    systemctl start machine-id-update.service
    systemctl enable --now "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
    
    echo ""
    log_success "=========================================="
    log_success "安装完成！"
    log_success "=========================================="
    echo ""
    log_info "已安装服务:"
    echo "  - $SERVICE_NAME.service (GPU监控，每10秒上报)"
    echo "  - machine-id-update.timer (每10分钟更新machine_id)"
    echo ""
    log_info "常用命令:"
    echo "  查看状态: systemctl status $SERVICE_NAME"
    echo "  查看日志: journalctl -u $SERVICE_NAME -f"
    echo "  停止服务: systemctl stop $SERVICE_NAME"
    echo "  卸载: systemctl disable --now $SERVICE_NAME machine-id-update.timer"
    echo ""
    log_info "Machine ID: $(cat $MACHINE_ID_FILE 2>/dev/null || echo '等待获取...')"
}

# ========================================
# 卸载
# ========================================
uninstall() {
    log_info "正在卸载..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null
    systemctl disable "$SERVICE_NAME" 2>/dev/null
    systemctl stop machine-id-update.timer 2>/dev/null
    systemctl disable machine-id-update.timer 2>/dev/null
    rm -f "$SERVICE_FILE" /etc/systemd/system/machine-id-update.* "$SCRIPT_INSTALL_PATH"
    systemctl daemon-reload
    log_success "卸载完成"
}

# ========================================
# 入口
# ========================================
case "${1:-}" in
    --uninstall)
        uninstall
        ;;
    --loop)
        monitor_loop
        ;;
    http://*|https://*)
        install_service
        ;;
    *)
        if [ -n "$API_BASE_URL" ]; then
            install_service
        else
            echo "GPU 功耗监控脚本"
            echo ""
            echo "一键安装:"
            echo "  curl -fsSL https://raw.githubusercontent.com/chenshaoquan/chaojinbidggbpujk/main/gpu_monitor.sh | sudo bash -s -- <API地址>"
            echo ""
            echo "示例:"
            echo "  curl -fsSL https://raw.githubusercontent.com/chenshaoquan/chaojinbidggbpujk/main/gpu_monitor.sh | sudo bash -s -- http://server:3000"
            echo ""
            echo "卸载:"
            echo "  sudo $0 --uninstall"
        fi
        ;;
esac
