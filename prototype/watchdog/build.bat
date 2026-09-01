@echo off
rem ===========================================================================
rem  build.bat -- MSVC build for the LuaJIT watchdog prototype (Windows x64).
rem
rem  MUST be run from a "x64 Native Tools Command Prompt for VS" (so cl.exe,
rem  lib.exe, link.exe are on PATH). Requires git on PATH.
rem
rem  Produces TWO harness binaries so you can measure the CHECKHOOK tax:
rem     harness_checkhook.exe  -> LuaJIT built WITH  LUAJIT_ENABLE_CHECKHOOK
rem     harness_stock.exe      -> LuaJIT built WITHOUT it (soft hook cannot
rem                               interrupt a live trace -- the failure case)
rem  Both link a STATIC LuaJIT v2.1 at a pinned commit, with GC64 (x64
rem  default) left ON and LUA52COMPAT enabled.
rem ===========================================================================
setlocal enabledelayedexpansion

rem --- pinned LuaJIT v2.1 commit (tip of v2.1 as of 2026-08-19) ---
set LJ_COMMIT=1ee778a4e37122d8ca7d5733c590a47dafd6b15c
set LJ_REPO=https://github.com/LuaJIT/LuaJIT.git

where cl >nul 2>nul || (echo [!] cl.exe not found. Run from a VS x64 Native Tools prompt. & exit /b 1)
where git >nul 2>nul || (echo [!] git not found on PATH. & exit /b 1)

rem --- 1. fetch LuaJIT at the pinned commit -------------------------------
if not exist luajit (
  echo [*] cloning LuaJIT ...
  git clone %LJ_REPO% luajit || exit /b 1
)
pushd luajit
git fetch --all --tags >nul 2>nul
git checkout %LJ_COMMIT% || (echo [!] checkout failed & popd & exit /b 1)
popd

rem --- 2. make two patched copies of msvcbuild.bat that inject XCFLAGS -----
rem  msvcbuild.bat has no XCFLAGS hook, so we append the defines to its
rem  LJCOMPILE line (this is exactly what its own 'lua52compat' arg does).
powershell -NoProfile -Command ^
  "(Get-Content luajit\src\msvcbuild.bat) -replace '(@set LJCOMPILE=cl[^\r\n]*)', '$1 /DLUAJIT_ENABLE_LUA52COMPAT /DLUAJIT_ENABLE_CHECKHOOK' | Set-Content luajit\src\msvcbuild_checkhook.bat" || exit /b 1
powershell -NoProfile -Command ^
  "(Get-Content luajit\src\msvcbuild.bat) -replace '(@set LJCOMPILE=cl[^\r\n]*)', '$1 /DLUAJIT_ENABLE_LUA52COMPAT' | Set-Content luajit\src\msvcbuild_stock.bat" || exit /b 1

rem --- 3. build the CHECKHOOK static lib ----------------------------------
echo [*] building LuaJIT static lib WITH CHECKHOOK ...
pushd luajit\src
del *.obj *.lib >nul 2>nul
call msvcbuild_checkhook.bat static || (echo [!] checkhook build failed & popd & exit /b 1)
copy /y lua51.lib ..\..\lua51_checkhook.lib >nul
popd

rem --- 4. build the stock static lib --------------------------------------
echo [*] building LuaJIT static lib WITHOUT CHECKHOOK (stock) ...
pushd luajit\src
del *.obj *.lib >nul 2>nul
call msvcbuild_stock.bat static || (echo [!] stock build failed & popd & exit /b 1)
copy /y lua51.lib ..\..\lua51_stock.lib >nul
popd

rem --- 5. compile the harness against each lib ----------------------------
rem  No explicit /MD or /MT: match msvcbuild's static default CRT exactly.
echo [*] compiling harness_checkhook.exe ...
cl /nologo /O2 /W3 /I luajit\src /Foharness_ch.obj /Feharness_checkhook.exe harness.c lua51_checkhook.lib || exit /b 1
echo [*] compiling harness_stock.exe ...
cl /nologo /O2 /W3 /I luajit\src /Foharness_st.obj /Feharness_stock.exe    harness.c lua51_stock.lib    || exit /b 1

del *.obj >nul 2>nul
echo.
echo [+] done.
echo     harness_checkhook.exe  (LUAJIT_ENABLE_CHECKHOOK, the design)
echo     harness_stock.exe      (no CHECKHOOK, the evasion baseline)
echo.
echo  try:
echo     harness_checkhook.exe --expect interrupt scripts\attack_tight_loop.lua
echo     harness_stock.exe     --expect hard      scripts\attack_tight_loop.lua
endlocal
