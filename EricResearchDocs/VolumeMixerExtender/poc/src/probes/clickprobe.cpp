// clickprobe.cpp -- 一次性探针：被注入按钮点出来的子进程，到底收到了什么？
//
// 为什么需要它：`winver.exe` 只能证明"按钮能拉起一个裸 exe"。
// 而项目主程序入口的真实形态是"exe + 参数"，并且子进程会继承 ShellHost 的当前目录 ——
// 后者是个隐患：如果主程序按相对路径找配置/资源，它会在 System32 里找。
//
// 本程序把自己收到的完整命令行、argv、以及当前目录写到一个文件里，然后立刻退出。
// 落盘位置写死在 %TEMP%\vmext-clickprobe.txt。

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdio.h>

int wmain(int argc, wchar_t** argv)
{
    wchar_t out[MAX_PATH] = {};
    DWORD n = GetTempPathW(MAX_PATH, out);
    if (n == 0 || n + 32 >= MAX_PATH) return 1;
    lstrcatW(out, L"vmext-clickprobe.txt");

    wchar_t cwd[MAX_PATH] = {};
    GetCurrentDirectoryW(MAX_PATH, cwd);

    HANDLE h = CreateFileW(out, GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                           CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return 2;

    char buf[4096];
    int len = 0;

    len += sprintf_s(buf + len, sizeof(buf) - len, "GetCommandLineW = %ls\r\n", GetCommandLineW());
    len += sprintf_s(buf + len, sizeof(buf) - len, "argc            = %d\r\n", argc);
    for (int i = 0; i < argc; ++i)
        len += sprintf_s(buf + len, sizeof(buf) - len, "  argv[%d]       = [%ls]\r\n", i, argv[i]);
    len += sprintf_s(buf + len, sizeof(buf) - len, "GetCurrentDirectoryW = %ls\r\n", cwd);
    len += sprintf_s(buf + len, sizeof(buf) - len, "parent pid      = %lu\r\n", GetCurrentProcessId());

    DWORD wrote = 0;
    WriteFile(h, buf, (DWORD)len, &wrote, nullptr);
    CloseHandle(h);
    return 0;
}
