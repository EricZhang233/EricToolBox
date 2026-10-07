// initest.cpp -- T2: GetPrivateProfileStringW 到底怎么解 INI 文件的编码？
//
// 为什么要单独测：产品的按钮文字是中文（"音量合成器"），而 INI 是**两个二进制之间**的接口
//   （App 写 / TAP 读）。如果编码假设不一致，结果不是"读不到"而是**静默读到乱码** —— 更难查。
//
// 方法：同一份内容用 5 种编码各写一个文件，再用 GetPrivateProfileStringW 读回来，
//   把读到的**码点**以 \uXXXX 打印（⛔ 不能用 %ls 打印中文：控制台/重定向会再乱一次，
//   那就分不清是"API 读错"还是"日志打错"）。同时区分两种失败：
//     ① 键都没找到（返回默认值）  ② 找到了但内容是乱码（静默损坏，最危险）
//
// 用法: initest.exe <输出目录>

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdio.h>
#include <string>

// 期望值：音量合成器测试
static const wchar_t kExpected[] = L"\u97F3\u91CF\u5408\u6210\u5668\u6D4B\u8BD5";
static const wchar_t kSentinel[] = L"<KEY-NOT-FOUND>";

static std::string Utf8(const std::wstring& w)
{
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

// 宽串 -> 纯 ASCII 的 "\uXXXX" 形式（日志里永远不要出现原始中文）
static std::string Escapes(const std::wstring& w)
{
    std::string out;
    char b[16];
    for (size_t i = 0; i < w.size(); ++i) {
        unsigned int c = (unsigned int)(unsigned short)w[i];
        if (c >= 0x20 && c < 0x7F) { out.push_back((char)c); }
        else { sprintf_s(b, "\\u%04X", c); out += b; }
    }
    return out;
}

// 宽串 -> UTF-16LE 字节（低字节在前）。★ 这里必须是真正的 UTF-16LE 编码：
// 曾经写成 "push((char)wchar); push(0);" —— 那把高位字节写死成 0，非 ASCII 全坏，测出来是假结果。
static std::string ToUtf16LeBytes(const std::wstring& w)
{
    std::string b;
    for (size_t j = 0; j < w.size(); ++j) {
        const unsigned short u = (unsigned short)w[j];
        b.push_back((char)(u & 0xFF));
        b.push_back((char)((u >> 8) & 0xFF));
    }
    return b;
}

// 打印前若干字节的 hex —— 让这个测试能自证"我写进去的字节确实是我以为的那些"
static void DumpBytes(const std::string& b, size_t maxBytes)
{
    std::string line = "      hex[:";
    char t[8];
    sprintf_s(t, "%llu] = ", (unsigned long long)b.size());
    line += t;
    for (size_t i = 0; i < b.size() && i < maxBytes; ++i) {
        sprintf_s(t, "%02X ", (unsigned char)b[i]);
        line += t;
    }
    if (b.size() > maxBytes) line += "…";
    printf("%s\n", line.c_str());
}

// 把一段字节写进文件（逐字节控制，不经任何"编码转换"）
static bool WriteBytes(const std::wstring& path, const std::string& bytes)
{
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD wrote = 0;
    BOOL ok = WriteFile(h, bytes.data(), (DWORD)bytes.size(), &wrote, nullptr);
    CloseHandle(h);
    return ok && wrote == bytes.size();
}

struct Case { const char* name; const char* note; };

int main(int argc, char** argv)
{
    wchar_t dir[MAX_PATH] = {};
    if (argc >= 2) {
        MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, dir, MAX_PATH);
    } else {
        GetTempPathW(MAX_PATH, dir);
    }
    if (dir[wcslen(dir) - 1] == L'\\') dir[wcslen(dir) - 1] = 0;

    const UINT acp = GetACP();
    printf("系统 ACP = %u (936=GBK)\n", acp);
    printf("期望值码点 = %s\n\n", Escapes(kExpected).c_str());

    // 五种编码，字节全部手工构造
    const char* names[] = {
        "utf16le-bom",   "utf16le-nobom",  "utf8-bom",  "utf8-nobom",  "ansi-acp"
    };
    const char* notes[] = {
        "UTF-16LE + BOM（文档推荐）",
        "UTF-16LE 无 BOM",
        "UTF-8 + BOM",
        "UTF-8 无 BOM（C# File.WriteAllText 默认风格）",
        "系统 ACP 编码（本机 = GBK）"
    };

    int pass = 0, mojibake = 0, notfound = 0;

    for (int i = 0; i < 5; ++i) {
        std::string bytes;

        // 内容："[t]\r\nk=<中文>\r\n"，按目标编码生成
        std::string ascii1 = "[t]\r\nk=";
        std::string ascii2 = "\r\n";

        if (i == 0 || i == 1) {                       // UTF-16LE（真正的 UTF-16LE 编码）
            if (i == 0) { bytes.push_back((char)0xFF); bytes.push_back((char)0xFE); }   // BOM
            bytes += ToUtf16LeBytes(std::wstring(L"[t]\r\nk=") + kExpected + L"\r\n");
        } else if (i == 2 || i == 3) {                // UTF-8
            if (i == 2) { bytes.push_back((char)0xEF); bytes.push_back((char)0xBB); bytes.push_back((char)0xBF); }
            bytes += ascii1;
            bytes += Utf8(kExpected);
            bytes += ascii2;
        } else {                                      // 系统 ACP
            bytes += ascii1;
            {
                int n = WideCharToMultiByte(acp, 0, kExpected, (int)wcslen(kExpected), nullptr, 0, nullptr, nullptr);
                std::string s(n, 0);
                WideCharToMultiByte(acp, 0, kExpected, (int)wcslen(kExpected), &s[0], n, nullptr, nullptr);
                bytes += s;
            }
            bytes += ascii2;
        }

        wchar_t path[MAX_PATH];
        swprintf_s(path, L"%s\\initest-%hs.ini", dir, names[i]);
        DeleteFileW(path);
        if (!WriteBytes(path, bytes)) {
            printf("[%d] %-14s 写文件失败\n", i, names[i]);
            continue;
        }

        wchar_t buf[512] = {};
        DWORD n = GetPrivateProfileStringW(L"t", L"k", kSentinel, buf, 512, path);

        const bool isDefault = (wcscmp(buf, kSentinel) == 0);
        const bool same      = (wcscmp(buf, kExpected) == 0);

        printf("[%d] %-14s %s\n", i, names[i], notes[i]);
        printf("      文件字节数 = %llu\n", (unsigned long long)bytes.size());
        DumpBytes(bytes, 26);
        printf("      读回长度   = %lu\n", (unsigned long)n);
        printf("      读回码点   = %s\n", Escapes(buf).c_str());
        if (same) {
            printf("      => ✅ 正确\n");
            ++pass;
        } else if (isDefault) {
            printf("      => ❌ 键都没找到（连节名/key 都解错了；返回的是缺省值）\n");
            ++notfound;
        } else {
            printf("      => ❌❌ 找到了但**内容是乱码**（静默损坏 —— 最危险的一种）\n");
            ++mojibake;
        }
        printf("\n");
    }

    printf("===== 汇总 =====\n");
    printf("正确 = %d / 5      内容乱码 = %d      键找不到 = %d\n", pass, mojibake, notfound);
    printf("\n结论要点：\n");
    printf("  * 只有 UTF-16LE+BOM 是**与系统 ACP 无关**的安全选择。\n");
    printf("  * 'ansi-acp' 在本机通过，只因本机 ACP=936；换到 ACP 非 936 的机器上就会乱码。\n");
    printf("  * UTF-8（带不带 BOM）在 GetPrivateProfileStringW 下不可靠 —— 见上面的实际结果。\n");

    // ------------------------------------------------------------------
    // 第二轮：写侧。C++ 轨道的 Ini::Write 若直接委托 WritePrivateProfileStringW，
    // **在全新文件上会创建 ANSI 文件**（文档常见坑）—— 那样本机看着正常，
    // 换到 ACP 非 936 的机器就乱码。这一轮把它的真实行为量出来。
    // ------------------------------------------------------------------
    printf("\n########## 第二轮：WritePrivateProfileStringW 写出来的文件是什么编码 ##########\n\n");

    // A) 全新文件（不存在）
    {
        wchar_t p[MAX_PATH];
        swprintf_s(p, L"%s\\wtest-fresh.ini", dir);
        DeleteFileW(p);
        BOOL ok = WritePrivateProfileStringW(L"t", L"k", kExpected, p);
        printf("[A] 对**全新文件**调 WritePrivateProfileStringW  ok=%d\n", ok);

        HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            char head[32] = {};
            DWORD rd = 0;
            ReadFile(h, head, 32, &rd, nullptr);
            CloseHandle(h);
            std::string s(head, rd);
            DumpBytes(s, 24);
            if (rd >= 2 && (unsigned char)head[0] == 0xFF && (unsigned char)head[1] == 0xFE) {
                printf("      => 文件是 UTF-16LE（有 BOM）\n");
            } else {
                printf("      => ⚠️ 文件**没有** UTF-16 BOM => 被写成 ANSI（本机 GBK）\n");
                printf("         本机能读对只因 ACP=936；换机器/换系统区域设置就会乱码\n");
            }
        }
        wchar_t buf[512] = {};
        GetPrivateProfileStringW(L"t", L"k", kSentinel, buf, 512, p);
        printf("      读回码点 = %s  => %s\n\n", Escapes(buf).c_str(),
               wcscmp(buf, kExpected) == 0 ? "✅ 正确" : "❌ 不对");
    }

    // B) 先手写一个 UTF-16LE+BOM 文件，再用 W 写第二个键 —— 会不会保持 UTF-16LE？
    {
        wchar_t p[MAX_PATH];
        swprintf_s(p, L"%s\\wtest-existing.ini", dir);
        DeleteFileW(p);
        std::string bytes;
        bytes.push_back((char)0xFF); bytes.push_back((char)0xFE);
        bytes += ToUtf16LeBytes(std::wstring(L"[t]\r\nk1=") + kExpected + L"\r\n");
        WriteBytes(p, bytes);

        BOOL ok = WritePrivateProfileStringW(L"t", L"k2", kExpected, p);
        printf("[B] 对**已存在的 UTF-16LE+BOM 文件**再写一个键  ok=%d\n", ok);

        HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, 0, nullptr);
        if (h != INVALID_HANDLE_VALUE) {
            char head[32] = {};
            DWORD rd = 0;
            ReadFile(h, head, 32, &rd, nullptr);
            CloseHandle(h);
            std::string s(head, rd);
            DumpBytes(s, 24);
            if (rd >= 2 && (unsigned char)head[0] == 0xFF && (unsigned char)head[1] == 0xFE) {
                printf("      => 仍是 UTF-16LE（BOM 保留）✅\n");
            } else {
                printf("      => ⚠️ BOM 没了，文件被转成了 ANSI\n");
            }
        }
        wchar_t b1[512] = {}, b2[512] = {};
        GetPrivateProfileStringW(L"t", L"k1", kSentinel, b1, 512, p);
        GetPrivateProfileStringW(L"t", L"k2", kSentinel, b2, 512, p);
        printf("      k1 读回 = %s\n", Escapes(b1).c_str());
        printf("      k2 读回 = %s\n", Escapes(b2).c_str());
        printf("      => %s\n", (wcscmp(b1, kExpected) == 0 && wcscmp(b2, kExpected) == 0) ? "✅ 两个键都对" : "❌ 有问题");
    }

    printf("\n===== T2 结论 =====\n");
    printf("  读侧：**只有 UTF-16LE + BOM** 稳定（与 ACP 无关）。\n");
    printf("  写侧：见上面 [A]/[B] 的实际行为 —— 这正是 C++ 轨道 Ini::Write 必须自己写字节、\n");
    printf("        不能裸委托 WritePrivateProfileStringW 的原因。\n");
    return 0;
}
