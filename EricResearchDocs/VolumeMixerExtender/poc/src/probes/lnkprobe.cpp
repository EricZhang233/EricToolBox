// lnkprobe.cpp -- 一次性探针：CreateProcessW 能不能直接跑 .lnk 快捷方式？
//
// 为什么要问这个：产品的 entry1.action=exec 是"TAP 直接 CreateProcessW(command)"。
// 用户直觉上会想把命令配成"某个快捷方式"（桌面/开始菜单里的 .lnk）。
// 如果 CreateProcessW 不解析 .lnk，那么配置里写 .lnk 就会静默失败 —— 这是必须提前知道的事。
//
// 用法: lnkprobe.exe "<lnk 路径>" "<exe 路径>"

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdio.h>

// 与 vcxtap.cpp 的 RunWinver() 同一套写法：命令行必须放在**可写**缓冲里
static void TryRun(const char* label, const char* cmdline)
{
    char buf[2048];
    lstrcpynA(buf, cmdline, sizeof(buf));

    STARTUPINFOA si = {};
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi = {};

    printf("--- %s ---\n", label);
    printf("    cmdline: %s\n", buf);

    BOOL ok = CreateProcessA(
        nullptr,            // lpApplicationName = NULL：从命令行推断可执行文件
        buf,                // ★ 必须可写
        nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi);

    if (ok) {
        printf("    => OK   pid=%lu\n", pi.dwProcessId);
        WaitForSingleObject(pi.hProcess, 5000);
        CloseHandle(pi.hThread);
        CloseHandle(pi.hProcess);
    } else {
        DWORD e = GetLastError();
        printf("    => FAILED  GetLastError=%lu\n", e);
        if (e == ERROR_BAD_EXE_FORMAT) printf("       (ERROR_BAD_EXE_FORMAT：不是可执行文件映像)\n");
        if (e == ERROR_FILE_NOT_FOUND) printf("       (ERROR_FILE_NOT_FOUND)\n");
        if (e == ERROR_PATH_NOT_FOUND) printf("       (ERROR_PATH_NOT_FOUND)\n");
    }
    printf("\n");
}

int main(int argc, char** argv)
{
    if (argc < 3) {
        printf("usage: lnkprobe.exe <lnk path> <exe path>\n");
        return 2;
    }

    char quotedLnk[2600];
    char quotedExe[2600];
    char exeWithArgs[2600];

    sprintf_s(quotedLnk, sizeof(quotedLnk), "\"%s\"", argv[1]);
    sprintf_s(quotedExe, sizeof(quotedExe), "\"%s\"", argv[2]);
    // 对照：exe + 参数（cmd.exe /c exit，进程自己退出，不用善后）
    sprintf_s(exeWithArgs, sizeof(exeWithArgs), "\"%s\" /c exit", argv[2]);

    // 第 3 个参数（可选）用来**只跑**其中一例：因为 clickprobe.exe 的报告文件会被后一次覆盖，
    // 想确认"某一例到底启动了哪个 exe"就必须把用例拆开跑。
    //   argv[3] = "d" -> 只跑 D    "e" -> 只跑 E    缺省 -> 全跑
    const char* only = (argc >= 4) ? argv[3] : "";
    const bool all   = (only[0] == 0);

    if (all || only[0] == 'a') TryRun("A. 直接跑 .lnk（产品里把 exec 配成快捷方式就是这个场景）", quotedLnk);
    if (all || only[0] == 'b') TryRun("B. 对照：直接跑 .exe（已知可行）", quotedExe);
    if (all || only[0] == 'c') TryRun("C. 对照：.exe + 参数", exeWithArgs);
    // D/E：路径**含空格**时，引号是不是必须的？产品里安装路径含空格很常见
    //      （argv[2]=含空格的 exe 路径时才有意义）
    if (all || only[0] == 'd') TryRun("D. ★ 路径含空格**不加引号**（产品若直接拼裸路径就是这样）", argv[2]);
    if (all || only[0] == 'e') TryRun("E. ★ 路径含空格**加引号**（正确写法）", quotedExe);

    printf("结论：A 行 FAILED ⇒ 配置里不能写 .lnk；\n");
    printf("      D 行会启动**哪个** exe 才是关键 —— 单独跑 -d 看 clickprobe 报告里的 argv[0]。\n");
    return 0;
}
