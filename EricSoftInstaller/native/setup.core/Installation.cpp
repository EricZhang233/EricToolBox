#include "Installation.h"
#include <shlobj.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <propkey.h>
#include <propvarutil.h>
#include <sddl.h>
#include <tlhelp32.h>
#include <bcrypt.h>
#include <fstream>
#include <sstream>
#include <set>
#include <algorithm>
#include <memory>

namespace setup {
std::wstring Wide(const std::string& value) {
    if (value.empty()) return {};
    int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
    Check(length > 0, "UTF8");
    std::wstring result(length, 0);
    Check(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length) != 0, "UTF8");
    return result;
}
std::string Utf8(const std::wstring& value) {
    if (value.empty()) return {};
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    Check(length > 0, "UTF16");
    std::string result(length, 0);
    Check(WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), result.data(), length, nullptr, nullptr) != 0, "UTF16");
    return result;
}
void Check(bool result, const char* operation) {
    if (!result) throw std::runtime_error(std::string(operation) + " (" + std::to_string(GetLastError()) + ")");
}
std::array<unsigned char, 32> Sha256(HANDLE file) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    Check(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) == 0, "SHA256Provider");
    BCRYPT_HASH_HANDLE hash = nullptr;
    try {
        Check(BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) == 0, "SHA256Create");
        unsigned char buffer[65536]{};
        DWORD read = 0;
        do {
            Check(ReadFile(file, buffer, sizeof(buffer), &read, nullptr) != 0, "ReadSHA256Input");
            if (read) Check(BCryptHashData(hash, buffer, read, 0) == 0, "SHA256Data");
        } while (read);
        std::array<unsigned char, 32> result{};
        Check(BCryptFinishHash(hash, result.data(), static_cast<ULONG>(result.size()), 0) == 0, "SHA256Finish");
        BCryptDestroyHash(hash);
        BCryptCloseAlgorithmProvider(algorithm, 0);
        return result;
    } catch (...) {
        if (hash) BCryptDestroyHash(hash);
        BCryptCloseAlgorithmProvider(algorithm, 0);
        throw;
    }
}
bool VerifySha256(HANDLE file, std::wstring_view digest) {
    constexpr std::wstring_view prefix = L"sha256:";
    if (digest.size() >= prefix.size() && _wcsnicmp(digest.data(), prefix.data(), prefix.size()) == 0)
        digest.remove_prefix(prefix.size());
    std::array<unsigned char, 32> expected{};
    if (digest.size() != expected.size() * 2) return false;
    auto hex = [](wchar_t digit) {
        if (digit >= L'0' && digit <= L'9') return digit - L'0';
        if (digit >= L'a' && digit <= L'f') return digit - L'a' + 10;
        if (digit >= L'A' && digit <= L'F') return digit - L'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < expected.size(); ++i) {
        int high = hex(digest[2 * i]), low = hex(digest[2 * i + 1]);
        if (high < 0 || low < 0) return false;
        expected[i] = static_cast<unsigned char>((high << 4) | low);
    }
    return Sha256(file) == expected;
}
DirectoryLease::DirectoryLease(const fs::path& root) {
    installation.value = CreateFileW((root / L"._install_lock").c_str(), GENERIC_READ | GENERIC_WRITE | DELETE, 0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
    Check(installation.value != INVALID_HANDLE_VALUE, "InstallationInProgress");
    update.value = CreateFileW((root / L"._update_lock").c_str(), GENERIC_READ | GENERIC_WRITE | DELETE, 0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr);
    Check(update.value != INVALID_HANDLE_VALUE, "UpdateInProgress");
}
ProductLease::ProductLease(const std::wstring& owner) {
    std::wstring product = WindowClass;
    CharUpperBuffW(product.data(), static_cast<DWORD>(product.size()));
    auto name = L"Global\\EricSoftInstaller." + product + (MachineInstall ? L".Machine" : L".User." + owner);
    mutex.value = CreateMutexW(nullptr, FALSE, name.c_str());
    DWORD error = GetLastError();
    if (!mutex.value || error == ERROR_ALREADY_EXISTS) throw std::runtime_error("INSTALLATION_IN_PROGRESS");
}
std::vector<unsigned char> Resource(int id) {
    HRSRC entry = FindResourceW(nullptr, MAKEINTRESOURCEW(id), RT_RCDATA);
    Check(entry != nullptr, "FindResource");
    DWORD size = SizeofResource(nullptr, entry);
    auto data = static_cast<const unsigned char*>(LockResource(LoadResource(nullptr, entry)));
    Check(data != nullptr && size > 0, "LoadResource");
    return { data, data + size };
}
std::wstring Text(const std::string& key) {
    static const wchar_t* language = [] {
        wchar_t locale[LOCALE_NAME_MAX_LENGTH]{};
        LCIDToLocaleName(MAKELCID(GetUserDefaultUILanguage(), SORT_DEFAULT), locale, LOCALE_NAME_MAX_LENGTH, 0);
        std::wstring selected(locale);
        auto base = selected.substr(0, selected.find(L'-'));
        const wchar_t* related = nullptr;
        const wchar_t* fallback = L"en";
        for (const auto* candidate : TextLanguages) {
            if (_wcsicmp(candidate, locale) == 0) return candidate;
            if (_wcsicmp(candidate, L"en") == 0) fallback = candidate;
            std::wstring supported(candidate);
            if (!base.empty() && !related && _wcsicmp(supported.substr(0, supported.find(L'-')).c_str(), base.c_str()) == 0)
                related = candidate;
        }
        return related ? related : fallback;
    }();
    for (const auto& entry : Translations)
        if (key == entry.key && _wcsicmp(language, entry.language) == 0) return entry.value;
    return {};
}
std::wstring LabeledText(const std::string& key, const std::wstring& value) {
    auto label = Text(key);
    if (label.empty() || value.empty()) return {};
    return label + L": " + value;
}
fs::path TemporaryDirectory() {
    wchar_t path[32768]{};
    DWORD length = GetTempPathW(static_cast<DWORD>(std::size(path)), path);
    Check(length > 0 && length < std::size(path), "GetTempPath");
    return fs::path(path) / TempSubdirectory;
}
std::wstring Self() {
    std::wstring path(32768, 0);
    DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
    Check(length > 0 && length < path.size(), "GetModuleFileName");
    path.resize(length);
    return path;
}
std::wstring Sid() {
    Handle token;
    Check(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value) != 0, "OpenProcessToken");
    DWORD length = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &length);
    std::vector<unsigned char> data(length);
    Check(GetTokenInformation(token.value, TokenUser, data.data(), length, &length) != 0, "GetTokenInformation");
    LPWSTR sid = nullptr;
    Check(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &sid) != 0, "ConvertSidToStringSid");
    std::wstring result(sid);
    LocalFree(sid);
    return result;
}
std::wstring Guid() {
    GUID guid{};
    Check(SUCCEEDED(CoCreateGuid(&guid)), "CoCreateGuid");
    wchar_t buffer[40]{};
    Check(StringFromGUID2(guid, buffer, 40) > 0, "StringFromGUID2");
    std::wstring result;
    for (wchar_t c : std::wstring(buffer)) if (c != L'{' && c != L'}' && c != L'-') result += c;
    return result;
}
std::wstring Folder(REFKNOWNFOLDERID id, DWORD flags) {
    PWSTR path = nullptr;
    Check(SUCCEEDED(SHGetKnownFolderPath(id, flags, nullptr, &path)), "SHGetKnownFolderPath");
    std::wstring result(path);
    CoTaskMemFree(path);
    return result;
}
std::wstring DefaultInstallDirectory() {
    auto base = Folder(MachineInstall ? FOLDERID_ProgramFiles : FOLDERID_LocalAppData);
    return (fs::path(base) / DefaultInstallSubdirectory).wstring();
}
static bool Same(const fs::path& first, const fs::path& second) { return _wcsicmp(first.c_str(), second.c_str()) == 0; }
fs::path Owned(const fs::path& root, const std::wstring& relative) {
    if (relative.empty() || relative.find_first_of(L":\r\n\t") != std::wstring::npos) throw std::runtime_error("INVALID_OWNED_PATH");
    fs::path path(relative);
    if (path.is_absolute() || path.has_root_path()) throw std::runtime_error("INVALID_OWNED_PATH");
    for (const auto& part : path) {
        std::wstring name = part.wstring();
        if (name == L".." || name == L"." || name.empty() || name.back() == L'.' || name.back() == L' ' || name.find_first_of(L"<>\"|?*") != std::wstring::npos) throw std::runtime_error("INVALID_OWNED_PATH");
    }
    std::wstring top = path.begin()->wstring();
    if (std::ranges::any_of(ProtectedPaths, [&](const auto* name) { return _wcsicmp(top.c_str(), name) == 0; })) throw std::runtime_error("USER_DATA_PATH");
    fs::path full = (root / path).lexically_normal();
    for (auto current = full; current.wstring().size() >= root.wstring().size(); current = current.parent_path()) {
        DWORD attributes = GetFileAttributesW(current.c_str());
        if (attributes != INVALID_FILE_ATTRIBUTES && (attributes & FILE_ATTRIBUTE_REPARSE_POINT)) throw std::runtime_error("REPARSE_POINT");
        if (current == root || current == current.parent_path()) break;
    }
    return full;
}
static fs::path ExpandedPath(const std::wstring& value) {
    std::wstring expanded(32768, 0);
    DWORD length = ExpandEnvironmentStringsW(value.c_str(), expanded.data(), static_cast<DWORD>(expanded.size()));
    Check(length > 1 && length <= expanded.size(), "ExpandEnvironmentStrings");
    expanded.resize(length - 1);
    fs::path root = fs::absolute(expanded).lexically_normal();
    while (root != root.root_path() && root.filename().empty()) root = root.parent_path();
    return root;
}
std::wstring Destination(const std::wstring& value) {
    auto root = ExpandedPath(value);
    if (!Same(root.filename(), InstallDirectoryName) && !Same(root, ExpandedPath(DefaultInstallDirectory())))
        root /= InstallDirectoryName;
    return ValidateRoot(root.wstring());
}
std::wstring ValidateRoot(const std::wstring& value) {
    auto root = ExpandedPath(value);
    if (root == root.root_path()) throw std::runtime_error(Utf8(Text("Installer_InvalidDirectory")));
    for (const auto& id : { FOLDERID_Profile, FOLDERID_LocalAppData, FOLDERID_RoamingAppData, FOLDERID_ProgramData, FOLDERID_Desktop, FOLDERID_Programs, FOLDERID_ProgramFiles, FOLDERID_ProgramFilesX86 })
        if (Same(root, Folder(id))) throw std::runtime_error(Utf8(Text("Installer_InvalidDirectory")));
    if (MachineInstall && (Same(root, Folder(FOLDERID_PublicDesktop, KF_FLAG_DONT_VERIFY)) ||
        Same(root, Folder(FOLDERID_CommonPrograms, KF_FLAG_DONT_VERIFY))))
        throw std::runtime_error(Utf8(Text("Installer_InvalidDirectory")));
    auto windows = Folder(FOLDERID_Windows);
    if (Same(root, windows) || _wcsnicmp(root.c_str(), (windows + L"\\").c_str(), windows.size() + 1) == 0) throw std::runtime_error(Utf8(Text("Installer_InvalidDirectory")));
    Owned(root, MainExecutable);
    return root.wstring();
}
std::vector<std::wstring> ReadLines(const fs::path& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("READ_MANIFEST_FAILED");
    std::vector<std::wstring> result;
    for (std::string line; std::getline(input, line);) { if (!line.empty() && line.back() == '\r') line.pop_back(); if (!line.empty()) result.push_back(Wide(line)); }
    if (input.bad()) throw std::runtime_error("READ_MANIFEST_FAILED");
    return result;
}
void WriteLines(const fs::path& path, const std::vector<std::wstring>& lines) {
    Handle output(CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr));
    Check(output.value != INVALID_HANDLE_VALUE, "CreateFile");
    for (const auto& line : lines) {
        auto bytes = Utf8(line) + "\n";
        DWORD written = 0;
        Check(WriteFile(output.value, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) != 0 && written == bytes.size(), "WriteFile");
    }
    Check(FlushFileBuffers(output.value) != 0, "FlushFileBuffers");
}
void Log(const std::wstring& message) noexcept {
    try {
        auto folder = TemporaryDirectory() / L"setup";
        fs::create_directories(folder);
        std::ofstream output(folder / (std::to_wstring(GetCurrentProcessId()) + L".log"), std::ios::app | std::ios::binary);
        SYSTEMTIME time{};
        GetSystemTime(&time);
        output << time.wYear << '-' << time.wMonth << '-' << time.wDay << ' ' << time.wHour << ':' << time.wMinute << ':' << time.wSecond << "Z " << Utf8(message) << '\n';
    } catch (...) {}
}
std::wstring Quote(const std::wstring& value) {
    std::wstring result = L"\"";
    size_t slashes = 0;
    for (wchar_t c : value) {
        if (c == L'\\') { ++slashes; continue; }
        result.append(slashes * (c == L'"' ? 2 : 1), L'\\');
        slashes = 0;
        if (c == L'"') result += L'\\';
        result += c;
    }
    result.append(slashes * 2, L'\\');
    return result + L'"';
}
fs::path UninstallDataDirectory(const Options& options) {
    auto path = options.dataDirectory ? *options.dataDirectory : fs::path(Folder(FOLDERID_ProgramData)) / DataSubdirectory;
    if (path.empty() || !path.is_absolute()) throw std::runtime_error("UNINSTALL_INVALID_DATA_DIRECTORY");
    path = path.lexically_normal().make_preferred();
    while (path != path.root_path() && path.filename().empty()) path = path.parent_path();
    return path;
}
Options Parse(bool setupMode, bool& quiet) {
    int count = 0;
    LPWSTR* values = CommandLineToArgvW(GetCommandLineW(), &count);
    Check(values != nullptr, "CommandLineToArgv");
    std::unique_ptr<LPWSTR, decltype(&LocalFree)> arguments(values, LocalFree);
    for (int i = 1; i < count; ++i) {
        std::wstring_view key(values[i]);
        if (key == L"--quiet" || key == L"--stage" || (setupMode && key == L"--update")) quiet = true;
    }
    Options result;
    result.owner = Sid();
    std::set<std::wstring> seen;
    for (int i = 1; i < count; ++i) {
        std::wstring key(values[i]);
        if (!seen.insert(key).second) throw std::runtime_error(Utf8(Text("Installer_InvalidArguments")));
        if (setupMode && key == L"--sha256") {
            result.expectedSha256 = i + 1 < count && !std::wstring_view(values[i + 1]).starts_with(L"--") ? values[++i] : L"";
            continue;
        }
        if (key == L"--directory" || key == L"--owner-sid" || key == L"--parent" || key == L"--cancel-file") {
            if (++i >= count) throw std::runtime_error(Utf8(Text("Installer_InvalidArguments")));
            if (key == L"--directory") result.root = values[i];
            else if (key == L"--owner-sid") result.owner = values[i];
            else if (key == L"--cancel-file") result.cancelFile = values[i];
            else result.parent = std::stoul(values[i]);
        } else if (key == L"--quiet") result.quiet = true;
        else if (!setupMode && (key == L"--keep-data" || key == L"--remove-data")) {
            if (result.dataChoice) throw std::runtime_error(Utf8(Text("Installer_InvalidArguments")));
            result.keepData = key == L"--keep-data";
            result.dataChoice = true;
        }
        else if (setupMode && key == L"--update") result.update = true;
        else if (setupMode && key == L"--stage") result.stage = true;
        else if (!setupMode && key == L"--worker") result.worker = true;
        else if (setupMode && key == L"--no-desktop") result.desktop = false;
        else if (setupMode && key == L"--desktop") result.desktop = true;
        else if (setupMode && key == L"--no-start-menu") result.menu = false;
        else if (setupMode && key == L"--start-menu") result.menu = true;
        else if (setupMode && key == L"--extract") result.extract = true;
        else if (key == L"--help") result.help = true;
        else throw std::runtime_error(Utf8(Text("Installer_InvalidArguments")));
    }
    if (result.extract && result.update) throw std::runtime_error(Utf8(Text("Installer_InvalidArguments")));
    quiet = result.quiet || result.update || result.stage;
    PSID parsed = nullptr;
    Check(ConvertStringSidToSidW(result.owner.c_str(), &parsed) != 0, "OwnerSid");
    LocalFree(parsed);
    return result;
}
void CheckCancelled(const Options& options) {
    if ((options.cancellation && options.cancellation->load()) || (!options.cancelFile.empty() && fs::exists(options.cancelFile))) throw std::runtime_error("INSTALL_CANCELLED");
}
static std::wstring UserPath(const std::wstring& owner, const wchar_t* path, HKEY& hive) {
    if (owner == Sid()) { hive = HKEY_CURRENT_USER; return path; }
    hive = HKEY_USERS;
    return owner + L"\\" + path;
}
static constexpr REGSAM RegistrationView = MachineInstall ? KEY_WOW64_64KEY : 0;
static std::wstring RegistrationPath(const std::wstring& owner, const wchar_t* path, HKEY& hive) {
    if (!MachineInstall) return UserPath(owner, path, hive);
    hive = HKEY_LOCAL_MACHINE;
    return path;
}
static void DeleteRegistrationTree(HKEY hive, const std::wstring& path) {
    if (!MachineInstall) {
        Check(RegDeleteTreeW(hive, path.c_str()) == ERROR_SUCCESS, "RegDeleteTree");
        return;
    }
    auto separator = path.find_last_of(L'\\');
    Key parent;
    Check(RegOpenKeyExW(hive, path.substr(0, separator).c_str(), 0,
        KEY_READ | KEY_WRITE | DELETE | RegistrationView, &parent.value) == ERROR_SUCCESS, "OpenRegistrationParent");
    Check(RegDeleteTreeW(parent.value, path.c_str() + separator + 1) == ERROR_SUCCESS, "RegDeleteTree");
}
static std::wstring Get(HKEY key, const wchar_t* name) {
    DWORD type = 0, bytes = 0;
    if (RegQueryValueExW(key, name, nullptr, &type, nullptr, &bytes) != ERROR_SUCCESS || type != REG_SZ || bytes < 2 || bytes > 65536) return {};
    std::wstring value(bytes / 2, 0);
    if (RegQueryValueExW(key, name, nullptr, &type, reinterpret_cast<BYTE*>(value.data()), &bytes) != ERROR_SUCCESS) return {};
    while (!value.empty() && value.back() == 0) value.pop_back();
    return value;
}
static bool IsDisplayVersion(const std::wstring& version) {
    size_t parts = 1, digits = 0;
    int value = 0;
    for (wchar_t character : version) {
        if (character == L'.' && digits > 0) {
            ++parts;
            digits = 0;
            value = 0;
        } else {
            if (character < L'0' || character > L'9' || ++digits > 5) return false;
            value = value * 10 + character - L'0';
            if (value > 65535) return false;
        }
    }
    return digits > 0 && (parts == 3 || parts == 4);
}
Record ReadRegistration(const std::wstring& owner) {
    HKEY hive;
    auto path = RegistrationPath(owner, UninstallKey, hive);
    Key key;
    LSTATUS opened = RegOpenKeyExW(hive, path.c_str(), 0, KEY_READ | RegistrationView, &key.value);
    if (opened == ERROR_FILE_NOT_FOUND || opened == ERROR_PATH_NOT_FOUND) return {};
    Check(opened == ERROR_SUCCESS, "RegOpenKeyEx");
    Record record;
    record.owner = owner;
    record.root = Get(key.value, L"InstallLocation");
    record.id = Get(key.value, L"InstallId");
    if (record.id.size() != 32 || record.id.find_first_not_of(L"0123456789abcdefABCDEF") != std::wstring::npos ||
        (!MachineInstall && Get(key.value, L"OwnerSid") != owner) || record.root.empty()) return {};
    record.desktop = Get(key.value, L"DesktopShortcut");
    record.menu = Get(key.value, L"StartMenuShortcut");
    record.version = Get(key.value, L"DisplayVersion");
    if (!IsDisplayVersion(record.version)) record.version.clear();
    record.date = Get(key.value, L"InstallDate");
    DWORD bytes = sizeof(record.size);
    RegGetValueW(key.value, nullptr, L"EstimatedSize", RRF_RT_REG_DWORD, nullptr, &record.size, &bytes);
    Key startup;
    auto startupPath = RegistrationPath(owner, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", hive);
    if (RegOpenKeyExW(hive, startupPath.c_str(), 0, KEY_READ | RegistrationView, &startup.value) == ERROR_SUCCESS) {
        auto command = Get(startup.value, StartupValueName);
        auto prefix = Quote((fs::path(record.root) / MainExecutable).wstring());
        if (_wcsnicmp(command.c_str(), prefix.c_str(), prefix.size()) == 0) record.startup = command;
    }
    return record;
}
Record Find(const std::wstring& root, const std::wstring& owner) {
    auto record = ReadRegistration(owner);
    if (!record || !Same(fs::absolute(record.root).lexically_normal(), fs::absolute(root).lexically_normal()) || !fs::is_regular_file(fs::path(root) / UninstallerName) || !fs::is_regular_file(fs::path(root) / MainExecutable)) return {};
    return record;
}
Record RegisteredInstallation(const std::wstring& owner) {
    auto record = ReadRegistration(owner);
    if (!record) return {};
    try { return Find(record.root, owner); }
    catch (const fs::filesystem_error&) { Log(L"Ignored invalid installation path in registry"); return {}; }
}
ShortcutLocations InstallShortcuts(const Options& options) {
    if (options.shortcuts) return *options.shortcuts;
    if (MachineInstall) return {
        (fs::path(Folder(FOLDERID_PublicDesktop, KF_FLAG_DONT_VERIFY)) / ShortcutFile).wstring(),
        (fs::path(Folder(FOLDERID_CommonPrograms, KF_FLAG_DONT_VERIFY)) / ShortcutFile).wstring()
    };
    if (options.owner == Sid()) return {
        (fs::path(Folder(FOLDERID_Desktop, KF_FLAG_DONT_VERIFY)) / ShortcutFile).wstring(),
        (fs::path(Folder(FOLDERID_Programs, KF_FLAG_DONT_VERIFY)) / ShortcutFile).wstring()
    };
    HKEY hive;
    auto path = UserPath(options.owner, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders", hive);
    Key key;
    Check(RegOpenKeyExW(hive, path.c_str(), 0, KEY_READ, &key.value) == ERROR_SUCCESS, "OpenUserShellFolders");
    auto desktop = Get(key.value, L"Desktop"), menu = Get(key.value, L"Programs");
    if (!fs::path(desktop).is_absolute() || !fs::path(menu).is_absolute()) throw std::runtime_error("INSTALL_SHORTCUT_FOLDER_MISSING");
    return {(fs::path(desktop) / ShortcutFile).wstring(), (fs::path(menu) / ShortcutFile).wstring()};
}
Record SelectInstallation(Options& options) {
    auto installed = RegisteredInstallation(options.owner);
    options.extract = false;
    options.update = static_cast<bool>(installed);
    if (installed) {
        options.root = installed.root;
        options.desktop = fs::is_regular_file(InstallShortcuts(options).desktop);
        options.menu = DefaultStartMenuShortcut || !installed.menu.empty();
    }
    return installed;
}
std::wstring UpgradeSummary(const Record& installed, const std::wstring& target) {
    if (installed.version.empty()) return LabeledText("Installer_Version", target);
    if (target.empty()) return LabeledText("Installer_InstalledVersion", installed.version);
    return installed.version + L" → " + target;
}
static void Set(HKEY key, const wchar_t* name, const std::wstring& value) {
    Check(RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()), static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS, "RegSetValueEx");
}
static void Number(HKEY key, const wchar_t* name, DWORD value) {
    Check(RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS, "RegSetValueEx");
}
void WriteRegistration(const Record& record) {
    HKEY hive;
    auto path = RegistrationPath(record.owner, UninstallKey, hive);
    Key key;
    Check(RegCreateKeyExW(hive, path.c_str(), 0, nullptr, 0, KEY_WRITE | RegistrationView, nullptr, &key.value, nullptr) == ERROR_SUCCESS, "RegCreateKeyEx");
    auto executable = (fs::path(record.root) / MainExecutable).wstring();
    auto uninstall = Quote((fs::path(record.root) / UninstallerName).wstring());
    if (!MachineInstall) uninstall += L" --owner-sid " + Quote(record.owner);
    Set(key.value, L"DisplayName", Product);
    Set(key.value, L"DisplayVersion", record.version);
    Set(key.value, L"Publisher", Publisher);
    Set(key.value, L"InstallLocation", record.root);
    Set(key.value, L"DisplayIcon", Quote(executable) + L",0");
    Set(key.value, L"UninstallString", uninstall);
    Set(key.value, L"QuietUninstallString", uninstall + (DefaultKeepData ? L" --quiet --keep-data" : L" --quiet --remove-data"));
    Set(key.value, L"InstallDate", record.date);
    Number(key.value, L"EstimatedSize", record.size);
    Number(key.value, L"NoModify", 1);
    Number(key.value, L"NoRepair", 1);
    Set(key.value, L"InstallId", record.id);
    if (!MachineInstall) Set(key.value, L"OwnerSid", record.owner);
    Set(key.value, L"DesktopShortcut", record.desktop);
    Set(key.value, L"StartMenuShortcut", record.menu);
    Key app;
    path = RegistrationPath(record.owner, AppPathKey, hive);
    Check(RegCreateKeyExW(hive, path.c_str(), 0, nullptr, 0, KEY_WRITE | RegistrationView, nullptr, &app.value, nullptr) == ERROR_SUCCESS, "RegCreateKeyEx");
    Set(app.value, nullptr, executable);
}
void RestoreRegistration(const Record& record) {
    WriteRegistration(record);
    if (!record.startup.empty()) {
        HKEY hive;
        Key startup;
        auto path = RegistrationPath(record.owner, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", hive);
        Check(RegCreateKeyExW(hive, path.c_str(), 0, nullptr, 0, KEY_WRITE | RegistrationView, nullptr, &startup.value, nullptr) == ERROR_SUCCESS, "CreateStartupRegistration");
        Set(startup.value, StartupValueName, record.startup);
    }
}
void RemoveRegistration(const Record& record) {
    auto existing = ReadRegistration(record.owner);
    if (!existing || existing.id != record.id || !Same(existing.root, record.root)) throw std::runtime_error("INSTALL_ID_MISMATCH");
    HKEY hive;
    auto path = RegistrationPath(record.owner, UninstallKey, hive);
    DeleteRegistrationTree(hive, path);
    path = RegistrationPath(record.owner, AppPathKey, hive);
    Key app;
    if (RegOpenKeyExW(hive, path.c_str(), 0, KEY_READ | RegistrationView, &app.value) == ERROR_SUCCESS && Same(Get(app.value, nullptr), fs::path(record.root) / MainExecutable)) {
        RegCloseKey(app.value); app.value = nullptr;
        DeleteRegistrationTree(hive, path);
    }
    path = RegistrationPath(record.owner, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", hive);
    Key startup;
    if (RegOpenKeyExW(hive, path.c_str(), 0, KEY_READ | KEY_WRITE | RegistrationView, &startup.value) == ERROR_SUCCESS) {
        auto command = Get(startup.value, StartupValueName);
        auto prefix = Quote((fs::path(record.root) / MainExecutable).wstring());
        if (_wcsnicmp(command.c_str(), prefix.c_str(), prefix.size()) == 0) RegDeleteValueW(startup.value, StartupValueName);
    }
}
void Shortcut(const std::wstring& executable, const std::wstring& destination) {
    IShellLinkW* raw = nullptr;
    Check(SUCCEEDED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&raw))), "CoCreateInstance");
    std::unique_ptr<IShellLinkW, void(*)(IShellLinkW*)> link(raw, [](auto p) { p->Release(); });
    Check(SUCCEEDED(link->SetPath(executable.c_str())), "SetPath");
    Check(SUCCEEDED(link->SetWorkingDirectory(fs::path(executable).parent_path().c_str())), "SetWorkingDirectory");
    Check(SUCCEEDED(link->SetDescription(Product)), "SetDescription");
    IPropertyStore* properties = nullptr;
    Check(SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&properties))), "IPropertyStore");
    std::unique_ptr<IPropertyStore, void(*)(IPropertyStore*)> store(properties, [](auto p) { p->Release(); });
    PROPVARIANT identifier{};
    Check(SUCCEEDED(InitPropVariantFromString(AppUserModelId, &identifier)), "InitPropVariant");
    HRESULT result = store->SetValue(PKEY_AppUserModel_ID, identifier);
    PropVariantClear(&identifier);
    Check(SUCCEEDED(result) && SUCCEEDED(store->Commit()), "SetAppId");
    IPersistFile* persisted = nullptr;
    Check(SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&persisted))), "IPersistFile");
    std::unique_ptr<IPersistFile, void(*)(IPersistFile*)> file(persisted, [](auto p) { p->Release(); });
    fs::create_directories(fs::path(destination).parent_path());
    auto temporary = destination + L"." + Guid() + L".lnk";
    try {
        Check(SUCCEEDED(file->Save(temporary.c_str(), TRUE)), "SaveShortcut");
        Check(MoveFileExW(temporary.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0, "MoveShortcut");
    } catch (...) { DeleteFileW(temporary.c_str()); throw; }
}
bool ShortcutTargets(const std::wstring& destination, const std::wstring& executable) {
    try {
        IShellLinkW* raw = nullptr;
        Check(SUCCEEDED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&raw))), "CoCreateInstance");
        std::unique_ptr<IShellLinkW, void(*)(IShellLinkW*)> link(raw, [](auto p) { p->Release(); });
        IPersistFile* persisted = nullptr;
        Check(SUCCEEDED(link->QueryInterface(IID_PPV_ARGS(&persisted))), "IPersistFile");
        std::unique_ptr<IPersistFile, void(*)(IPersistFile*)> file(persisted, [](auto p) { p->Release(); });
        Check(SUCCEEDED(file->Load(destination.c_str(), STGM_READ)), "LoadShortcut");
        wchar_t target[32768]{};
        Check(SUCCEEDED(link->GetPath(target, 32768, nullptr, SLGP_RAWPATH)), "GetShortcutPath");
        return Same(target, executable);
    } catch (...) { return false; }
}
bool CanWrite(const fs::path& root) {
    auto existing = root;
    while (!fs::exists(existing) && existing != existing.parent_path()) existing = existing.parent_path();
    auto path = existing / (L".setup-probe-" + Guid());
    Handle probe(CreateFileW(path.c_str(), GENERIC_WRITE | DELETE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE, nullptr));
    return probe.value != INVALID_HANDLE_VALUE;
}
DWORD Run(const std::wstring& executable, const std::wstring& arguments, bool elevate, bool wait) {
    HANDLE process = nullptr;
    if (elevate) {
        SHELLEXECUTEINFOW start{ sizeof(start) };
        start.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC;
        start.lpVerb = L"runas";
        start.lpFile = executable.c_str();
        start.lpParameters = arguments.c_str();
        start.nShow = SW_HIDE;
        Check(ShellExecuteExW(&start) != 0, "ShellExecuteEx");
        process = start.hProcess;
    } else {
        std::wstring command = Quote(executable) + L" " + arguments;
        STARTUPINFOW startup{ sizeof(startup) };
        PROCESS_INFORMATION information{};
        Check(CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, fs::path(executable).parent_path().c_str(), &startup, &information) != 0, "CreateProcess");
        CloseHandle(information.hThread);
        process = information.hProcess;
    }
    Handle child(process);
    Check(process != nullptr, "ChildProcess");
    if (!wait) return 0;
    Check(WaitForSingleObject(process, INFINITE) == WAIT_OBJECT_0, "WaitForSingleObject");
    DWORD exitCode = 1;
    Check(GetExitCodeProcess(process, &exitCode) != 0, "GetExitCodeProcess");
    return exitCode;
}
void CloseApplication(const std::wstring& root) {
    Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
    Check(snapshot.value != INVALID_HANDLE_VALUE, "ProcessSnapshot");
    PROCESSENTRY32W entry{ sizeof(entry) };
    for (BOOL more = Process32FirstW(snapshot.value, &entry); more; more = Process32NextW(snapshot.value, &entry)) {
        bool companion = std::ranges::any_of(CompanionExecutables, [&](const auto* name) { return _wcsicmp(entry.szExeFile, name) == 0; });
        if (!companion && _wcsicmp(entry.szExeFile, MainExecutable) != 0) continue;
        Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, entry.th32ProcessID));
        if (process.value == nullptr) continue;
        wchar_t executable[32768]{};
        DWORD size = 32768;
        if (!QueryFullProcessImageNameW(process.value, 0, executable, &size) || !Same(executable, fs::path(root) / entry.szExeFile)) continue;
        if (companion) {
            if (WaitForSingleObject(process.value, 15000) != WAIT_OBJECT_0) throw std::runtime_error(Utf8(Text("Installer_CloseApplication")));
            continue;
        }
        if (*ShutdownPipeName) {
            auto pipePath = std::wstring(L"\\\\.\\pipe\\") + ShutdownPipeName;
            WaitNamedPipeW(pipePath.c_str(), 500);
            Handle pipe(CreateFileW(pipePath.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr));
            ULONG owner = 0;
            if (pipe.value != INVALID_HANDLE_VALUE && GetNamedPipeServerProcessId(pipe.value, &owner) && owner == entry.th32ProcessID) {
                DWORD written = 0;
                WriteFile(pipe.value, ShutdownPipeCommand, static_cast<DWORD>(std::char_traits<char>::length(ShutdownPipeCommand)), &written, nullptr);
                FlushFileBuffers(pipe.value);
            }
        }
        EnumWindows([](HWND window, LPARAM id) -> BOOL { DWORD pid = 0; GetWindowThreadProcessId(window, &pid); if (pid == static_cast<DWORD>(id)) PostMessageW(window, WM_CLOSE, 0, 0); return TRUE; }, static_cast<LPARAM>(entry.th32ProcessID));
        if (WaitForSingleObject(process.value, 10000) != WAIT_OBJECT_0) throw std::runtime_error(Utf8(Text("Installer_CloseApplication")));
    }
}
}
