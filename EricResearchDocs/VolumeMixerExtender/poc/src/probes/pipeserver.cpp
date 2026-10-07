// pipeserver.cpp -- 命名管道**服务端**探针，用来验 T3（action=pipe 全链路）。
//
// 它按交付文档 §2.4 的约定实现服务端：
//   * 字节模式 + '\n' 分行（不用消息模式）
//   * PIPE_ACCESS_INBOUND（TAP 只写，服务端只读）
//   * ★ 处理那个经典坑：ConnectNamedPipe 返回 FALSE 且 GetLastError()==ERROR_PIPE_CONNECTED
//     表示"客户端在 CreateNamedPipe 与 ConnectNamedPipe 之间已经连上了"，**这是成功**，
//     不是失败。漏掉它就会间歇性丢点击。
//
// 用法:
//   pipeserver.exe <pipeName> [expectedCount] [timeoutSeconds] [outFile] [race]
//     第 5 个参数给 "race" 时，会在 CreateNamedPipe **之后**先睡 3 秒再 ConnectNamedPipe ——
//     这是为了**确定性地触发**那个竞态：客户端在这 3 秒内连上来，于是 ConnectNamedPipe
//     返回 FALSE + ERROR_PIPE_CONNECTED（这正是要验的点）。
// 退出码: 0 = 收齐 expectedCount 条; 2 = 超时; 1 = 出错
//
// 这是**产品侧 App 的原型**：产品里这段会跑在托盘程序里，收到报文后决定做什么。

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void Out(const char* fmt, ...)
{
    char b[2048];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf_s(b, sizeof(b), _TRUNCATE, fmt, ap);
    va_end(ap);
    fputs(b, stdout);
    fflush(stdout);
}

int main(int argc, char** argv)
{
    if (argc < 2) {
        Out("usage: pipeserver.exe <pipeName> [expectedCount] [timeoutSeconds] [outFile]\n");
        return 1;
    }
    const wchar_t* nameRaw = nullptr;
    wchar_t name[512] = {};
    {
        // argv[1] -> wide（用系统 ACP 就够：管道名是 ASCII）
        MultiByteToWideChar(CP_ACP, 0, argv[1], -1, name, 512);
        nameRaw = name;
    }
    const int expected   = (argc >= 3) ? atoi(argv[2]) : 1;
    const int timeoutSec = (argc >= 4) ? atoi(argv[3]) : 20;
    const char* outPath  = (argc >= 5) ? argv[4] : nullptr;
    const bool  raceMode = (argc >= 6 && _stricmp(argv[5], "race") == 0);

    HANDLE h = CreateNamedPipeW(
        nameRaw,
        PIPE_ACCESS_INBOUND,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
        PIPE_UNLIMITED_INSTANCES,
        4096, 4096, 0, nullptr);

    if (h == INVALID_HANDLE_VALUE) {
        Out("SERVER: CreateNamedPipeW FAILED err=%lu\n", GetLastError());
        return 1;
    }
    Out("SERVER: listening on %ls (expected=%d, timeout=%ds%s)\n",
        nameRaw, expected, timeoutSec, raceMode ? ", RACE MODE" : "");

    if (raceMode) {
        // ★ 关键：CreateNamedPipe 已经建好了实例，但**先不 Connect**。
        //   客户端会在这段窗口里连上来；之后 ConnectNamedPipe 就会返回
        //   FALSE + ERROR_PIPE_CONNECTED —— 这正是要验的代码路径。
        Out("SERVER: (race) CreateNamedPipe 已建实例，等 3s 让客户端先连上…\n");
        Sleep(3000);
    }

    FILE* fout = nullptr;
    if (outPath) {
        fopen_s(&fout, outPath, "wb");
        if (fout) { fputs("\xEF\xBB\xBF", fout); fflush(fout); }   // UTF-8 BOM，方便记事本看
    }

    int got = 0;
    const DWORD start = GetTickCount();

    while (got < expected) {
        if ((GetTickCount() - start) > (DWORD)timeoutSec * 1000) {
            Out("SERVER: TIMEOUT after %ds, got %d/%d\n", timeoutSec, got, expected);
            if (fout) fclose(fout);
            CloseHandle(h);
            return 2;
        }

        // ★ 这一行就是那个坑：FALSE + ERROR_PIPE_CONNECTED 必须当成成功。
        //   ★★ 实测补充：还有第二种合法结果 —— ERROR_NO_DATA(232)，表示"客户端连上又关掉了"。
        //      客户端（TAP）写完 32 字节就 CloseHandle，如果这发生在服务端调用 ConnectNamedPipe
        //      之前，就会命中 232。此时**不该当致命错误退出**，而应该仍然试着读一遍缓冲，
        //      读不到再 Disconnect + 重新 arm。
        BOOL connected = ConnectNamedPipe(h, nullptr);
        if (!connected) {
            const DWORD e = GetLastError();
            if (e == ERROR_PIPE_CONNECTED) {
                Out("SERVER: (ConnectNamedPipe FALSE + ERROR_PIPE_CONNECTED(110) -> 视为已连接)\n");
                connected = TRUE;
            } else if (e == ERROR_NO_DATA) {
                Out("SERVER: (ConnectNamedPipe FALSE + ERROR_NO_DATA(232) -> 客户端连上又断开了；试着读缓冲)\n");
                connected = TRUE;                   // 继续往下，看数据还在不在
            } else {
                Out("SERVER: ConnectNamedPipe FAILED err=%lu\n", e);
                if (fout) fclose(fout);
                CloseHandle(h);
                return 1;
            }
        }

        // 收这一连接上的所有数据，按 '\n' 切行
        char buf[4096];
        char line[4096];
        int  lineLen = 0;
        for (;;) {
            DWORD read = 0;
            if (!ReadFile(h, buf, sizeof(buf), &read, nullptr)) {
                Out("SERVER: ReadFile err=%lu（客户端关闭通常也会走到这里）\n", GetLastError());
                break;
            }
            if (read == 0) break;                    // 客户端关掉了
            for (DWORD i = 0; i < read; ++i) {
                if (buf[i] == '\n') {
                    line[lineLen] = 0;
                    Out("SERVER: RECV: [%s]\n", line);
                    if (fout) { fprintf(fout, "%s\n", line); fflush(fout); }
                    ++got; lineLen = 0;
                } else if (lineLen < (int)sizeof(line) - 1) {
                    line[lineLen++] = buf[i];
                }
            }
        }

        DisconnectNamedPipe(h);
    }

    Out("SERVER: OK -- 收到 %d 条，退出\n", got);
    if (fout) fclose(fout);
    CloseHandle(h);
    return 0;
}
