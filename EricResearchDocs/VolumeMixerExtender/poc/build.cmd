@echo off
rem build.cmd -- build the PoC (injector.exe + vcxmix.dll).
rem cl.exe / cmake.exe are NOT on PATH on this machine, so we call vcvars64.bat
rem inside this same cmd process (PATH/LIB/INCLUDE only persist within one process).

setlocal
set "SRC=%~dp0"
set "S=%~dp0src\"
set "VS18=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
set "VS22=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

if exist "%VS18%" (set "VCVARS=%VS18%") else (set "VCVARS=%VS22%")
if not exist "%VCVARS%" (
    echo [!] vcvars64.bat not found
    exit /b 1
)
echo [*] vcvars: %VCVARS%
call "%VCVARS%" >nul
if errorlevel 1 (
    echo [!] vcvars64.bat failed
    exit /b 1
)

pushd "%SRC%"

echo.
echo [*] building injector.exe
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W3 /DUNICODE /D_UNICODE "%S%injector.cpp" /link /out:injector.exe
if errorlevel 1 goto :fail

echo.
echo [*] building vcxmix.dll
set "CPPWINRT=%WindowsSdkDir%Include\%WindowsSDKVersion%cppwinrt"
if not exist "%CPPWINRT%\winrt\base.h" set "CPPWINRT=C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\cppwinrt"
if not exist "%CPPWINRT%\winrt\base.h" (
    echo [!] cppwinrt headers not found -- is the Windows SDK installed?
    goto :fail
)
echo [*] cppwinrt: %CPPWINRT%
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /LD /W3 /DUNICODE /D_UNICODE /I"%CPPWINRT%" "%S%vcxmix.cpp" /link /out:vcxmix.dll /DLL WindowsApp.lib
if errorlevel 1 goto :fail

for %%f in (vcxmix.ini vcxlaunch.ini vcxtap.ini) do if not exist "%%f" (
    echo [!] %%f 缺失 -- 它由 git 跟踪，请用 git 恢复，不要让它被自动生成
    echo     ^(自动生成的是 ANSI，而 ANSI 配置会被静默读错: docs\verified-after-injection\09-ini-encoding.md^)
)

echo.
echo [*] building vcxlaunch.dll  (calls InitializeXamlDiagnosticsEx in-process)
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /LD /W3 /DUNICODE /D_UNICODE "%S%vcxlaunch.cpp" /link /out:vcxlaunch.dll /DLL ole32.lib
if errorlevel 1 goto :fail

echo.
echo [*] building vcxtap.dll  (the XAML diagnostics TAP / COM in-proc server)
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /LD /W3 /DUNICODE /D_UNICODE /I"%CPPWINRT%" "%S%vcxtap.cpp" /link /out:vcxtap.dll /DLL WindowsApp.lib ole32.lib /EXPORT:DllGetClassObject /EXPORT:DllCanUnloadNow
if errorlevel 1 goto :fail

echo.
echo [*] building the probes  (re-run them to re-check the conclusions in docs\verified-after-injection\06-09)
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W3 /DUNICODE /D_UNICODE "%S%probes\clickprobe.cpp" /link /out:clickprobe.exe
if errorlevel 1 goto :fail
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W3 /DUNICODE /D_UNICODE "%S%probes\lnkprobe.cpp" /link /out:lnkprobe.exe
if errorlevel 1 goto :fail
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W3 /DUNICODE /D_UNICODE "%S%probes\initest.cpp" /link /out:initest.exe
if errorlevel 1 goto :fail
cl /nologo /std:c++17 /utf-8 /EHsc /O2 /MT /W3 /DUNICODE /D_UNICODE "%S%probes\pipeserver.cpp" /link /out:pipeserver.exe
if errorlevel 1 goto :fail

popd
echo.
echo [+] build OK
exit /b 0

:fail
popd
echo.
echo [!] build FAILED
exit /b 1
