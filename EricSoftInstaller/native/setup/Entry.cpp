#include "../setup.core/Installation.h"
#include <shellapi.h>
#include <iostream>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    bool quiet = false;
    try {
        setup::Check(SUCCEEDED(initialized), "CoInitializeEx");
#ifdef SETUP_UNINSTALL
        auto options = setup::Parse(false, quiet);
#else
        auto options = setup::Parse(true, quiet);
#endif
        if (options.extract && !setup::AllowExtract)
            throw std::runtime_error(setup::Utf8(setup::Text("Installer_ExtractDisabled")));
        if (options.help) {
            AttachConsole(ATTACH_PARENT_PROCESS);
#ifdef SETUP_UNINSTALL
            std::cout << setup::Utf8(setup::Text("Installer_UninstallHelp")) << std::endl;
#else
            auto help = setup::Text("Installer_Help");
            if (setup::AllowExtract) {
                auto extractHelp = setup::Text("Installer_ExtractHelp");
                if (!help.empty() && !extractHelp.empty()) help += L"\n";
                help += extractHelp;
            }
            std::cout << setup::Utf8(help) << std::endl;
#endif
            CoUninitialize();
            return 0;
        }
#ifdef SETUP_UNINSTALL
        if (quiet && !options.dataChoice) throw std::runtime_error(setup::Utf8(setup::Text("Installer_UninstallDataRequired")));
        if (options.root.empty()) options.root = setup::fs::path(setup::Self()).parent_path().wstring();
        if (!setup::PrepareUninstallWorker(options)) { CoUninitialize(); return 0; }
        int result = 0;
        if (quiet) setup::Uninstall(options);
        else result = setup::Window(options, setup::Uninstall, true);
#else
        auto package = setup::Self();
        setup::Handle packageFile;
        if (options.expectedSha256) {
            packageFile.value = CreateFileW(package.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
            setup::Check(packageFile.value != INVALID_HANDLE_VALUE, "OpenPackageForVerification");
            if (!setup::VerifySha256(packageFile.value, *options.expectedSha256)) {
                setup::Log(L"PACKAGE_SHA256_VERIFICATION_FAILED");
                auto message = setup::Text("Installer_VerificationFailed");
                if (!quiet && !message.empty()) MessageBoxW(nullptr, message.c_str(), setup::Product, MB_OK | MB_ICONERROR);
                CoUninitialize();
                return 2;
            }
        }
        auto current = setup::RegisteredInstallation(options.owner);
        if (options.root.empty()) options.root = current && !options.extract ? current.root : setup::DefaultInstallDirectory();
        if (quiet && !options.update && !options.extract && !options.stage) setup::SelectInstallation(options);
        int result = 0;
        auto operation = [package, quiet](const setup::Options& selected) {
            if (selected.extract) {
                setup::ExtractOnly(selected, package);
                return;
            }
            auto root = setup::Install(selected, package, setup::Resource(102), setup::Version);
            if (quiet && setup::RestartAfterInstall && !selected.stage) {
                auto executable = setup::fs::path(root) / setup::MainExecutable;
                SHELLEXECUTEINFOW start{ sizeof(start) };
                start.fMask = SEE_MASK_FLAG_NO_UI | SEE_MASK_NOASYNC;
                start.lpVerb = L"open";
                start.lpFile = executable.c_str();
                start.lpDirectory = root.c_str();
                start.nShow = SW_SHOWNORMAL;
                if (!ShellExecuteExW(&start)) setup::Log(L"Application restart failed: " + std::to_wstring(GetLastError()));
            }
        };
        if (quiet) operation(options);
        else result = setup::Window(options, operation, false);
#endif
        CoUninitialize();
        return result;
    } catch (const std::exception& error) {
        auto message = setup::Wide(error.what());
        setup::Log(message);
        auto failure = setup::Text("Installer_Failed");
        if (!quiet && !failure.empty()) {
            if (!message.empty()) failure += L"\n" + message;
            MessageBoxW(nullptr, failure.c_str(), setup::Product, MB_OK | MB_ICONERROR);
        }
        if (SUCCEEDED(initialized)) CoUninitialize();
        return 1;
    }
}
