/**
 * RootService — 无 UI 后台 root 权限服务
 *
 * 架构：iOS17 RootHide/Relaxin 双进程方案
 *   - 主 App（mobile）：正常桌面打开，显示 UI
 *   - RootService（root）：独立二进制，NewTerm 手动启动
 *   - 通信：UNIX 本地域 Socket
 *
 * 编译（Mac 交叉编译 arm64）：
 *   clang -arch arm64 root_service.c -o root_service -O2
 *
 * 部署到手机：
 *   scp root_service root@手机IP:/var/mobile/
 *   ssh root@手机IP chmod +x /var/mobile/root_service
 *
 * 启动（NewTerm）：
 *   su root
 *   export DYLD_INSERT_LIBRARIES=/var/jb/usr/lib/ellekit/ellekit.dylib
 *   /var/mobile/root_service
 *
 * 注意：保持 NewTerm 后台运行，关闭则服务终止。
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>

#define SOCKET_PATH "/var/mobile/Library/aireverse_service.sock"
#define BUF_SIZE 65536
#define MAX_CLIENTS 10

static int server_fd;
static volatile int running = 1;

// 清理退出
void sig_handler(int sig) {
    running = 0;
    close(server_fd);
    unlink(SOCKET_PATH);
    printf("\n[RootService] 已关闭\n");
    exit(0);
}

// 执行 shell 命令并返回结果
char* exec_cmd(const char *cmd) {
    static char result[BUF_SIZE];
    result[0] = '\0';
    FILE *pipe = popen(cmd, "r");
    if (!pipe) {
        snprintf(result, BUF_SIZE, "ERROR: 命令执行失败");
        return result;
    }
    size_t n = fread(result, 1, BUF_SIZE - 1, pipe);
    result[n] = '\0';
    pclose(pipe);
    return result;
}

// 处理客户端请求
void handle_client(int client_fd) {
    char buffer[BUF_SIZE];
    ssize_t n = read(client_fd, buffer, sizeof(buffer) - 1);
    if (n <= 0) {
        close(client_fd);
        return;
    }
    buffer[n] = '\0';

    // 去除末尾换行
    char *nl = strchr(buffer, '\n');
    if (nl) *nl = '\0';

    printf("[RootService] 收到指令: %s\n", buffer);

    char reply[BUF_SIZE];
    reply[0] = '\0';

    // 解析指令并分发
    if (strcmp(buffer, "CMD_PING") == 0) {
        // 心跳检测
        snprintf(reply, BUF_SIZE, "PONG");
    }
    else if (strcmp(buffer, "CMD_LIST_APPS") == 0) {
        // 枚举所有第三方 App 进程
        char *out = exec_cmd("ps -e -o pid,comm 2>/dev/null | grep -v '^ *PID' | head -100");
        snprintf(reply, BUF_SIZE, "进程列表:\n%s", out);
    }
    else if (strcmp(buffer, "CMD_ROOT_INFO") == 0) {
        // 返回 root 身份和环境信息
        char *id = exec_cmd("whoami 2>/dev/null");
        char *euid = exec_cmd("echo euid=$(id -u) 2>/dev/null");
        char *jb = exec_cmd("ls /var/jb 2>/dev/null | head -5");
        snprintf(reply, BUF_SIZE, "身份: %s\n%s\n/var/jb 内容:\n%s", id, euid, jb);
    }
    else if (strncmp(buffer, "CMD_SHELL ", 10) == 0) {
        // 执行任意 shell 命令
        char *cmd = buffer + 10;
        char *out = exec_cmd(cmd);
        snprintf(reply, BUF_SIZE, "%s", out);
    }
    else if (strncmp(buffer, "CMD_FRIDA ", 10) == 0) {
        // Frida 操作（需要安装 rootless 版 frida-server）
        char *args = buffer + 10;
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
            "/var/jb/opt/procursus/bin/sh -c 'frida %s 2>&1'",
            args);
        char *out = exec_cmd(cmd);
        snprintf(reply, BUF_SIZE, "%s", out);
    }
    else if (strncmp(buffer, "CMD_INJECT ", 11) == 0) {
        // 注入 dylib 到目标 App
        // 格式: CMD_INJECT bundle_id|dylib_path
        char *args = buffer + 11;
        char cmd[512];
        snprintf(cmd, sizeof(cmd),
            "/var/jb/opt/procursus/bin/sh -c '"
            "BUNDLE_ID=$(echo \"%s\" | cut -d\"|\" -f1); "
            "DYLIB=$(echo \"%s\" | cut -d\"|\" -f2); "
            "echo \"注入 $BUNDLE_ID <- $DYLIB\"; "
            "insert_dylib --inplace \"$DYLIB\" \"/var/containers/Bundle/Application/$(echo $BUNDLE_ID)/*.app/*\" 2>&1 || "
            "echo \"注入失败\"'",
            args, args);
        char *out = exec_cmd(cmd);
        snprintf(reply, BUF_SIZE, "%s", out);
    }
    else {
        // 未知指令，尝试作为 shell 命令执行
        char *out = exec_cmd(buffer);
        snprintf(reply, BUF_SIZE, "%s", out);
    }

    // 返回结果
    write(client_fd, reply, strlen(reply));
    close(client_fd);
}

int main() {
    struct sockaddr_un addr;

    // 信号处理
    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    // 清理旧 socket
    unlink(SOCKET_PATH);

    // 创建 socket
    server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd == -1) {
        perror("创建 socket 失败");
        return 1;
    }

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strcpy(addr.sun_path, SOCKET_PATH);

    // 绑定
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("绑定失败");
        close(server_fd);
        unlink(SOCKET_PATH);
        return 1;
    }

    // 权限：允许 mobile 用户连接
    chmod(SOCKET_PATH, 0777);

    // 监听
    if (listen(server_fd, MAX_CLIENTS) < 0) {
        perror("监听失败");
        close(server_fd);
        unlink(SOCKET_PATH);
        return 1;
    }

    printf("========================================\n");
    printf("  RootService 已启动\n");
    printf("  Socket: %s\n", SOCKET_PATH);
    printf("  身份: root (euid=%d)\n", geteuid());
    printf("  PID: %d\n", getpid());
    printf("  等待前端 App 连接...\n");
    printf("========================================\n");

    // 主循环
    while (running) {
        struct sockaddr_un client_addr;
        socklen_t client_len = sizeof(client_addr);
        int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
        if (client_fd < 0) {
            if (running) perror("accept 失败");
            continue;
        }
        handle_client(client_fd);
    }

    close(server_fd);
    unlink(SOCKET_PATH);
    return 0;
}