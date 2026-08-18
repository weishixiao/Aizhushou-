#!/var/jb/opt/procursus/bin/sh
# RootService 一键启动脚本（加固版）
# 在 NewTerm 中执行: /var/mobile/start_root_service.sh
#
# 特性：
# - 自动切换 root
# - nohup 后台守护：关闭 NewTerm 后服务继续运行
# - 幂等：已在运行则提示 PID，不重复启动
# - 运行日志写入 /var/mobile/root_service.log
# - 安全加固：必须提供 AIREVERSE_SERVICE_SECRET，否则拒绝启动

# 密钥来源：优先取传入的环境变量，其次取固定的受保护配置文件。
# 注意：不把密钥写死在脚本里；配置文件权限收紧为 0600 且仅 root 可读。
SECRET_SOURCE="${AIREVERSE_SERVICE_SECRET:-}"
SECRET_FILE="/var/mobile/.aireverse_service_secret"

if [ -z "$SECRET_SOURCE" ] && [ -r "$SECRET_FILE" ]; then
    SECRET_SOURCE=$(cat "$SECRET_FILE" 2>/dev/null | tr -d '\n')
fi

# 未设置密钥时：降级为兼容无鉴权模式启动（服务端此时不要求握手）。
# 生产环境强烈建议设置密钥以启用鉴权。
if [ -z "$SECRET_SOURCE" ]; then
    echo "==> 警告：未提供共享密钥，将以无鉴权兼容模式启动。"
    echo "    生产环境请设置环境变量 AIREVERSE_SERVICE_SECRET，或写入只读配置文件："
    echo "      echo 'your-strong-secret' > $SECRET_FILE && chmod 600 $SECRET_FILE"
fi

# 检查 Procursus shell 环境
if [ ! -x /var/jb/opt/procursus/bin/sh ]; then
    echo "未找到 /var/jb/opt/procursus/bin/sh，请确认已安装 Procursus 引导。"
    exit 1
fi

# 切换到 root
if [ "$(id -u)" != "0" ]; then
    echo "==> 切换到 root..."
    exec su root -c "$0"
fi

SERVICE=/var/mobile/root_service
PIDFILE=/var/mobile/root_service.pid
LOGFILE=/var/mobile/root_service.log

# 已运行则直接提示退出（幂等）
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "RootService 已在运行 (PID $OLD_PID)"
        exit 0
    fi
    rm -f "$PIDFILE"
fi

if [ ! -x "$SERVICE" ]; then
    echo "未找到可执行文件 $SERVICE，请先在 App 内完成 RootService 安装。"
    exit 1
fi

echo "==> 启动 RootService (root 身份，后台守护)..."
echo "    EUID: $(id -u)"

# 注入 ElleKit（RootHide / Relaxin 必备）
export DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/ellekit/ellekit.dylib
# 传递共享密钥（进程级环境变量，不落到日志/磁盘）
export AIREVERSE_SERVICE_SECRET="$SECRET_SOURCE"

# 后台启动并脱离会话，NewTerm 关闭后服务继续运行
if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$SERVICE" >"$LOGFILE" 2>&1 &
else
    nohup "$SERVICE" >"$LOGFILE" 2>&1 &
fi
SVC_PID=$!
echo "$SVC_PID" > "$PIDFILE"
echo "    PID: $SVC_PID (日志: $LOGFILE)"

sleep 1
if kill -0 "$SVC_PID" 2>/dev/null; then
    echo "==> 启动成功，RootService 正在后台运行。"
else
    echo "==> 启动失败，请查看日志 $LOGFILE"
    rm -f "$PIDFILE"
    exit 1
fi
