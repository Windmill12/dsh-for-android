/*
 * jsrun —— 把「用 node 跑某个 JS 入口」包装成一个真正可执行的命令。
 *
 * 为什么需要它：
 *   Android 的 app 私有目录（/data/user/0/<pkg>/files/）**禁止 exec**（W^X）。
 *   实测在 app 域里执行 files/bin/xxx.sh 会得到
 *   `/system/bin/sh: bad interpreter: Permission denied`（exit 126）。
 *   只有 nativeLibraryDir（/data/app/~~xxx/<pkg>-yyy==/lib/<abi>/）里的文件能执行。
 *
 *   于是像 `pnpm` 这种「node + JS 入口」的命令就没法做成包装脚本。而有些工具
 *   （比如 dsh-market）是按 PATH 去找 `pnpm` 可执行文件的，找不到就报
 *   「需要先配置 pnpm 环境」。
 *
 *   这个启动器就是那个可执行文件：它被安装成 libpnpm.so，再在 files/bin/ 里
 *   做一个同名符号链接 `pnpm` —— 符号链接指向 nativeLibraryDir，所以能执行。
 *   它自己再 execve 到 node + JS 入口，把参数原样透传。
 *
 * 路径从哪来：
 *   - node：/proc/self/exe 解析出的 nativeLibraryDir 里的 libnode.so（同目录兄弟）
 *   - JS 入口：先读环境变量，取不到再用编译期写死的默认值
 *     （环境变量名和默认值由构建脚本用 -D 指定，见 build-jsrun-android.sh）
 *
 * 编译期宏：
 *   JSRUN_NAME           仅用于报错信息，如 "pnpm"
 *   JSRUN_ENTRY_ENV      环境变量名，如 "ANDROIDDSH_PNPM_ENTRY"
 *   JSRUN_ENTRY_DEFAULT  环境变量缺席时的兜底入口路径
 *   JSRUN_EXTRA_1/2      自动前置的固定参数（如 pnpx 的 "dlx"），可为空
 */
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef JSRUN_NAME
#define JSRUN_NAME "jsrun"
#endif
#ifndef JSRUN_ENTRY_ENV
#define JSRUN_ENTRY_ENV ""
#endif
#ifndef JSRUN_ENTRY_DEFAULT
#define JSRUN_ENTRY_DEFAULT ""
#endif
#ifndef JSRUN_EXTRA_1
#define JSRUN_EXTRA_1 ""
#endif
#ifndef JSRUN_EXTRA_2
#define JSRUN_EXTRA_2 ""
#endif

int main(int argc, char **argv) {
    char exe[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n <= 0) {
        fprintf(stderr, "%s: readlink /proc/self/exe failed: %s\n", JSRUN_NAME, strerror(errno));
        return 127;
    }
    exe[n] = '\0';

    /* 砍掉文件名，留下 nativeLibraryDir（/proc/self/exe 已经把符号链接解析掉了） */
    char *slash = strrchr(exe, '/');
    if (slash == NULL) {
        fprintf(stderr, "%s: unexpected executable path: %s\n", JSRUN_NAME, exe);
        return 127;
    }
    *slash = '\0';

    char node[PATH_MAX];
    int written = snprintf(node, sizeof(node), "%s/libnode.so", exe);
    if (written <= 0 || (size_t)written >= sizeof(node)) {
        fprintf(stderr, "%s: node path too long\n", JSRUN_NAME);
        return 127;
    }

    const char *entry = NULL;
    if (JSRUN_ENTRY_ENV[0] != '\0') entry = getenv(JSRUN_ENTRY_ENV);
    if (entry == NULL || entry[0] == '\0') entry = JSRUN_ENTRY_DEFAULT;
    if (entry[0] == '\0') {
        fprintf(stderr, "%s: no JS entry configured (set %s)\n", JSRUN_NAME, JSRUN_ENTRY_ENV);
        return 127;
    }

    /* argv = [node, entry, <extra...>, <原始参数...>, NULL] */
    const char *extra[2];
    int extra_count = 0;
    if (JSRUN_EXTRA_1[0] != '\0') extra[extra_count++] = JSRUN_EXTRA_1;
    if (JSRUN_EXTRA_2[0] != '\0') extra[extra_count++] = JSRUN_EXTRA_2;

    char **args = calloc((size_t)argc + (size_t)extra_count + 2, sizeof(char *));
    if (args == NULL) {
        fprintf(stderr, "%s: out of memory\n", JSRUN_NAME);
        return 127;
    }
    int at = 0;
    args[at++] = node;
    args[at++] = (char *)entry;
    for (int i = 0; i < extra_count; i++) args[at++] = (char *)extra[i];
    for (int i = 1; i < argc; i++) args[at++] = argv[i];
    args[at] = NULL;

    execv(node, args);

    /* execv 只在失败时返回 */
    fprintf(stderr, "%s: exec %s failed: %s\n", JSRUN_NAME, node, strerror(errno));
    return 127;
}
