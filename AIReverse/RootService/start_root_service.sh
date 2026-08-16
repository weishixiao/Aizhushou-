#!/var/jb/opt/procursus/bin/sh
# RootService 一键启动脚本
# 在 NewTerm 中执行: /var/mobile/start_root_service.sh
#
# 注意：
# - 保持 NewTerm 后台运行，关闭则服务终止
# - ElleKit 注入环境变量必不可少（RootHide 环境必须）

# 切换到 root
if [ "$(id -u)" != "0" ]; then
    echo "==> 切换到 root..."
    exec su root -c "$0"
fi

echo "==> 启动 RootService (root身份)..."
echo "    PID: $$"
echo "    EUID: $(id -u)"

# 注入 ElleKit（RootHide 必备）
export DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/ellekit/ellekit.dylib

# 启动服务
/var/mobile/root_service