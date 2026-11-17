# Super Mario Bros. Wonder PC Recompiler for Windows (driven by Switch2Recomp)
# Uses bundled PC-only SwitchGamesRecomp (src/wonder) + Windows toolchain,
# building ONLY the native Windows PC target (no PS4 / OpenOrbis / .pkg, no external download).
param(
    [string]$Nup = "",
    [string]$Dir = "",
    [string]$ShortcutName = "Super Mario Bros. Wonder",
    [string]$IconPath = "",
    [string]$LauncherUiPath = "",
    [switch]$NoDesktopShortcut
)
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
function Say($msg) { Write-Host "[SMW-PC] $msg" -ForegroundColor Cyan }

if (-not [Environment]::Is64BitOperatingSystem) { Say "64-bit Windows required"; exit 1 }
if (-not $Nup -or -not (Test-Path -LiteralPath $Nup)) { Say "no such file: $Nup"; exit 1 }
if (-not $Dir) {
    $Dir = Join-Path $env:LOCALAPPDATA "Switch2Recomp\Super Mario Bros. Wonder"
}
$Dir = [System.IO.Path]::GetFullPath($Dir)
New-Item -ItemType Directory -Force -Path $Dir | Out-Null
Say "installing into $Dir"

$source = $PSScriptRoot
$globalMsysInstaller = Join-Path $source "..\..\install_msys2.ps1"
if (-not (Test-Path -LiteralPath "C:\msys64\clang64\bin\clang.exe") -or -not (Test-Path -LiteralPath "C:\msys64\clang64\bin\clang++.exe") -or -not (Test-Path -LiteralPath "C:\msys64\clang64\include\SDL3\SDL.h")) {
    if (Test-Path -LiteralPath $globalMsysInstaller) {
        & $globalMsysInstaller -Msys "C:\msys64"
        if ($LASTEXITCODE -ne 0) {
            Say "MSYS2 installation cancelled or failed; stopping recompilation."
            exit 1
        }
    }
}
$bundleRoot = Join-Path $source "bundle"
$builderRoot = Join-Path $Dir "_builder"
$wonderSrc = Join-Path $builderRoot "src\wonder"
$readyMarker = Join-Path $builderRoot "ready.txt"
$workDir = Join-Path $Dir "_work"
$dataRoot = Join-Path $Dir "data"

# ---- 1. Stage bundled src/wonder into _builder (tools run directly from bundled tools/) ----
if (-not (Test-Path -LiteralPath $readyMarker) -or -not (Test-Path -LiteralPath $wonderSrc)) {
    $srcWonder = Join-Path $bundleRoot "src\wonder"
    if (-not (Test-Path -LiteralPath $srcWonder)) {
        Say "error: bundled src/wonder missing: $srcWonder"
        exit 1
    }
    Say "staging bundled src/wonder into _builder..."
    New-Item -ItemType Directory -Force -Path (Join-Path $builderRoot "src") | Out-Null
    if (Test-Path -LiteralPath $wonderSrc) { Remove-Item -Recurse -Force $wonderSrc }
    Copy-Item -LiteralPath $srcWonder -Destination $wonderSrc -Recurse -Force
    "ok" | Set-Content -Encoding ASCII $readyMarker
} elseif (-not (Test-Path -LiteralPath (Join-Path $wonderSrc "games\wonder\game.cpp"))) {
    $srcGames = Join-Path $bundleRoot "src\wonder\games"
    if (Test-Path -LiteralPath $srcGames) {
        Copy-Item -LiteralPath $srcGames -Destination (Join-Path $wonderSrc "games") -Recurse -Force
    }
}

$toolsDir = Join-Path $bundleRoot "tools"
$pyExe = Join-Path $toolsDir "python\python.exe"
$cmakeExe = Join-Path $toolsDir "cmake\bin\cmake.exe"
$ninjaExe = Join-Path $toolsDir "cmake\bin\ninja.exe"
$dotnetExe = Join-Path $toolsDir "dotnet\dotnet.exe"
$harnessDll = Join-Path $toolsDir "harness\spirv_harness.dll"
$vkSdkDir = Join-Path $toolsDir "sdk\Vulkan-Headers"

foreach ($req in @($wonderSrc, $pyExe, $cmakeExe, $ninjaExe, $dotnetExe, $harnessDll, $vkSdkDir)) {
    if (-not (Test-Path -LiteralPath $req)) {
        Say "error: required component missing: $req"
        exit 1
    }
}

$env:PYTHONUTF8 = "1"
$env:PYTHONUNBUFFERED = "1"
$env:DOTNET_ROOT = Join-Path $toolsDir "dotnet"
$env:DOTNET_CLI_TELEMETRY_OPTOUT = "1"
$env:DOTNET_NOLOGO = "1"
$env:DOTNET_SYSTEM_GLOBALIZATION_INVARIANT = "1"

# ---- 2. Extract ExeFS and RomFS (base 1.0.0) from .nup ----
$exefsDir = Join-Path $workDir "exefs"
$romfsDir = Join-Path $dataRoot "extract\romfs"
if (-not (Test-Path -LiteralPath (Join-Path $exefsDir "main")) -or -not (Test-Path -LiteralPath $romfsDir)) {
    Say "extracting ExeFS and RomFS (base 1.0.0) from .nup..."
    $extractPy = Join-Path $source "extract_nup.py"
    & $pyExe $extractPy --nup $Nup --exefs $exefsDir --romfs $romfsDir
    if ($LASTEXITCODE -ne 0) { Say "nup extraction failed"; exit 1 }
}

# ---- 3. Decompress NSOs to analysis/*.bin ----
$analysisDir = Join-Path $dataRoot "analysis"
New-Item -ItemType Directory -Force -Path $analysisDir | Out-Null
$nso2bin = Join-Path $wonderSrc "tools\nso2bin.py"
foreach ($mod in @("main", "sdk")) {
    $binOut = Join-Path $analysisDir "$mod.bin"
    if (-not (Test-Path -LiteralPath $binOut)) {
        Say "generating analysis/$mod.bin..."
        & $pyExe $nso2bin (Join-Path $exefsDir $mod) $binOut
        if ($LASTEXITCODE -ne 0) { Say "nso2bin failed for $mod"; exit 1 }
    }
}

# ---- 4. Extract Maxwell shaders and translate to SPIR-V ----
$spirvDir = Join-Path $dataRoot "spirv"
$spirvDone = Join-Path $spirvDir ".done"
if (-not (Test-Path -LiteralPath $spirvDone)) {
    Say "extracting Maxwell shaders..."
    $shadersExt = Join-Path $wonderSrc "private\wonder\shaders_extracted"
    if (Test-Path -LiteralPath $shadersExt) { Remove-Item -Recurse -Force $shadersExt }
    New-Item -ItemType Directory -Force -Path $shadersExt | Out-Null

    $containersPy = Join-Path $wonderSrc "tools\maxwell\containers.py"
    $exefsShadersPy = Join-Path $wonderSrc "tools\maxwell\exefs_shaders.py"

    $jobs = @(
        @("uber", "Shader\SecredUber.Product.100.product.Nin_NX_NVN.bfsha.zs"),
        @("secred", "Shader\Secred.Nin_NX_NVN.release.sarc.zs"),
        @("agl", "Lib\agl\agl_resource.Nin_NX_NVN.release.sarc.zs"),
        @("gsys", "Lib\gsys\gsys_resource.Nin_NX_NVN.release.sarc.zs")
    )
    $effectDir = Join-Path $romfsDir "Effect"
    if (Test-Path -LiteralPath $effectDir) {
        Get-ChildItem -LiteralPath $effectDir -Filter "*.Nin_NX_NVN.esetb.byml.zs" | Sort-Object Name | ForEach-Object {
            $base = $_.Name -replace "\.Nin_NX_NVN\.esetb\.byml\.zs$", ""
            $jobs += ,@("effect_$base", "Effect\$($_.Name)")
        }
    }
    Push-Location $wonderSrc
    foreach ($j in $jobs) {
        $srcFile = Join-Path $romfsDir $j[1]
        if (Test-Path -LiteralPath $srcFile) {
            & $pyExe $containersPy $srcFile --extract (Join-Path $shadersExt $j[0]) --unique | Out-Null
            if ($LASTEXITCODE -ne 0) { Pop-Location; Say "shader extract failed for $($j[0])"; exit 1 }
        }
    }
    $layoutDir = Join-Path $romfsDir "Layout"
    if (Test-Path -LiteralPath $layoutDir) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        Get-ChildItem -LiteralPath $layoutDir -Filter "*.Nin_NX_NVN.blarc.zs" | Sort-Object Name | ForEach-Object {
            $base = $_.Name -replace "\.Nin_NX_NVN\.blarc\.zs$", ""
            $d = Join-Path $shadersExt "layout_$base"
            & $pyExe $containersPy $_.FullName --extract $d --unique *> $null
            if (Test-Path -LiteralPath $d) {
                $nonManifest = Get-ChildItem -LiteralPath $d | Where-Object { $_.Name -ne "manifest.tsv" }
                if (-not $nonManifest) { Remove-Item -Recurse -Force $d }
            }
        }
        $ErrorActionPreference = $prevEap
    }
    & $pyExe $exefsShadersPy (Join-Path $analysisDir "main.bin") --extract (Join-Path $shadersExt "exefs")
    if ($LASTEXITCODE -ne 0) { Pop-Location; Say "exefs_shaders failed"; exit 1 }

    Say "translating shaders to SPIR-V..."
    if (Test-Path -LiteralPath $spirvDir) { Remove-Item -Recurse -Force $spirvDir }
    New-Item -ItemType Directory -Force -Path $spirvDir | Out-Null
    $shaderJobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, 6))
    $shaderDirs = @(Get-ChildItem -LiteralPath $shadersExt -Directory | Sort-Object Name)
    if ($shaderDirs.Count -eq 0) {
        & $dotnetExe $harnessDll --batch $shadersExt --out $spirvDir --jobs $shaderJobs --no-val
        $rc = $LASTEXITCODE
    } else {
        $rc = 0
        foreach ($sd in $shaderDirs) {
            & $dotnetExe $harnessDll --batch $sd.FullName --out $spirvDir --jobs $shaderJobs --no-val
            if ($LASTEXITCODE -ne 0) {
                $rc = $LASTEXITCODE
                break
            }
        }
    }
    Pop-Location
    if ($rc -ne 0) { Say "spirv_harness failed"; exit 1 }
    "ok" | Set-Content -Encoding ASCII $spirvDone
}

# ---- 5. Generate button font ----
$fontsDir = Join-Path $dataRoot "fonts"
New-Item -ItemType Directory -Force -Path $fontsDir | Out-Null
$fontOut = Join-Path $fontsDir "shared_5.ttf"
$makeFont = Join-Path $wonderSrc "tools\fonts\make_button_font.py"
$arialFont = "C:\Windows\Fonts\arial.ttf"
if ((Test-Path -LiteralPath $makeFont) -and (Test-Path -LiteralPath $arialFont) -and -not (Test-Path -LiteralPath $fontOut)) {
    Say "generating button font (shared_5.ttf)..."
    & $pyExe $makeFont --base $arialFont --out $fontOut
    if ($LASTEXITCODE -ne 0) { Say "warning: make_button_font.py failed (continuing)" }
}

# ---- 6. Recompile main and sdk NSOs to C++ ----
# Workaround for Python 3.14 adaptive specializer bug in nested range() loop (analysis.py:135)
$analysisPy = Join-Path $wonderSrc "recomp\analysis.py"
if (Test-Path -LiteralPath $analysisPy) {
    $anTxt = Get-Content -LiteralPath $analysisPy -Raw -Encoding UTF8
    if ($anTxt -match "            for a in range\(f\.start, f\.end, 4\):\r?\n                ins = insns\.get\(a\)") {
        $anTxt = $anTxt -replace "(            for a in range\(f\.start, f\.end, 4\):\r?\n)                ins = insns\.get\(a\)", "`$1                try:`n                    ins = insns.get(a)`n                except TypeError:`n                    ins = insns.get(int(a))"
        Set-Content -LiteralPath $analysisPy -Value $anTxt -Encoding UTF8
    }
}
$genDir = Join-Path $workDir "gen"

# Prefer Python 3.13 or 3.12 for recomp (bundled Python 3.14.4 can crash in ctypes.POINTER specializer)
$recompPy = $pyExe
foreach ($ver in @("3.13", "3.12")) {
    $pyLauncher = Get-Command py -ErrorAction SilentlyContinue
    if ($pyLauncher) {
        $cand = & py "-$ver" -c "import sys; print(sys.executable)" 2>$null
        if ($LASTEXITCODE -eq 0 -and $cand -and (Test-Path -LiteralPath $cand.Trim())) {
            $cand = $cand.Trim()
            & $cand -c "import capstone, lz4.block" 2>$null
            if ($LASTEXITCODE -ne 0) {
                Say "installing capstone and lz4 into Python $ver..."
                & $cand -m pip install -q capstone lz4
            }
            & $cand -c "import capstone, lz4.block" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $recompPy = $cand
                Say "using Python $ver for C++ recompilation: $recompPy"
                break
            }
        }
    }
}

Push-Location $wonderSrc
foreach ($entry in @(@("main", "0x4000000000"), @("sdk", "0x4010000000"))) {
    $mod = $entry[0]
    $base = $entry[1]
    $modGen = Join-Path $genDir $mod
    $modDone = Join-Path $modGen ".done"
    if (-not (Test-Path -LiteralPath $modDone)) {
        $recompOk = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            Say "recompiling $mod to C++ (attempt $attempt/3)..."
            if (Test-Path -LiteralPath $modGen) { Remove-Item -Recurse -Force $modGen }
            New-Item -ItemType Directory -Force -Path $modGen | Out-Null
            & $recompPy -B -m recomp (Join-Path $exefsDir $mod) $modGen --name $mod --base $base
            if ($LASTEXITCODE -eq 0) {
                $recompOk = $true
                break
            }
            Say "recompiling $mod failed (exit $LASTEXITCODE), retrying..."
        }
        if (-not $recompOk) { Pop-Location; Say "recompiling $mod failed"; exit 1 }
        "ok" | Set-Content -Encoding ASCII $modDone
    }
}
Pop-Location

# ---- 7. Configure & build native Windows PC executable (wonder.exe) with MSYS2 Clang64 + Ninja ----
$clang64Bin = "C:\msys64\clang64\bin"
$ccExe = Join-Path $clang64Bin "clang.exe"
$cxxExe = Join-Path $clang64Bin "clang++.exe"
if (-not (Test-Path -LiteralPath $ccExe) -or -not (Test-Path -LiteralPath $cxxExe)) {
    Say "error: MSYS2 Clang64 (clang.exe / clang++.exe) not found in $clang64Bin"
    exit 1
}
$env:PATH = "$clang64Bin;$env:PATH"

# MinGW/Clang64 libc++ does not transitively include <cstdlib> in these two files
foreach ($rel in @("runtime\src\hle_hid.cpp", "runtime\src\nvn\nvn_shaders.cpp")) {
    $fp = Join-Path $wonderSrc $rel
    if (Test-Path -LiteralPath $fp) {
        $srcTxt = Get-Content -LiteralPath $fp -Raw -Encoding UTF8
        if ($srcTxt -notmatch "#include\s*<cstdlib>") {
            Set-Content -LiteralPath $fp -Value ("#include <cstdlib>`n" + $srcTxt) -Encoding UTF8
        }
    }
}

# MinGW/Clang64 defines CLOCK_THREAD_CPUTIME_ID -> clock_gettime64 (in winpthread)
$frameStatsPath = Join-Path $wonderSrc "runtime\src\frame_stats.cpp"
if (Test-Path -LiteralPath $frameStatsPath) {
    $fsTxt = Get-Content -LiteralPath $frameStatsPath -Raw -Encoding UTF8
    if ($fsTxt -match "#if defined\(CLOCK_THREAD_CPUTIME_ID\)\r?\n") {
        $fsTxt = $fsTxt -replace "#if defined\(CLOCK_THREAD_CPUTIME_ID\)", "#if defined(CLOCK_THREAD_CPUTIME_ID) && !defined(_WIN32)"
        Set-Content -LiteralPath $frameStatsPath -Value $fsTxt -Encoding UTF8
    }
}

# Confirmation popup when pressing Escape + window icon from game_icon.ico
$platWinPath = Join-Path $wonderSrc "runtime\src\platform_win.cpp"
if (Test-Path -LiteralPath $platWinPath) {
    $pwTxt = Get-Content -LiteralPath $platWinPath -Raw -Encoding UTF8
    if ($pwTxt -notmatch "Voulez-vous vraiment fermer le jeu") {
        $pwTxt = $pwTxt -replace "if \(w == VK_F11\) toggle_fullscreen\(h\);", @"
if (w == VK_F11) toggle_fullscreen(h);
            if (w == VK_ESCAPE && !(l & (1LL << 30))) {
                if (MessageBoxW(h, L"Voulez-vous vraiment fermer le jeu ?", L"Quitter le jeu",
                                MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) == IDYES) {
                    log("window closed by user");
                    ExitProcess(0);
                }
                return 0;
            }
"@
    }
    if ($pwTxt -notmatch "WM_SETICON") {
        $pwTxt = $pwTxt -replace "(if \(const char\* f = std::getenv\(""NX_FULLSCREEN""\);)", @"
    {
        wchar_t exePath[MAX_PATH]{};
        GetModuleFileNameW(nullptr, exePath, MAX_PATH);
        std::wstring dir(exePath);
        auto slash = dir.find_last_of(L"\\/");
        if (slash != std::wstring::npos) dir.resize(slash);
        std::wstring p1 = dir + L"\\game_icon.ico";
        const wchar_t* candidates[] = {L"game_icon.ico", p1.c_str()};
        for (const wchar_t* path : candidates) {
            HICON big = (HICON)LoadImageW(nullptr, path, IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
            HICON small = (HICON)LoadImageW(nullptr, path, IMAGE_ICON, GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), LR_LOADFROMFILE);
            if (big || small) {
                if (big) SendMessageW(g_window, WM_SETICON, ICON_BIG, (LPARAM)big);
                if (small) SendMessageW(g_window, WM_SETICON, ICON_SMALL, (LPARAM)small);
                break;
            }
        }
    }
    `$1
"@
    }
    Set-Content -LiteralPath $platWinPath -Value $pwTxt -Encoding UTF8
}

# MinGW/Clang64 provides libxaudio2_8.a instead of xaudio2.lib
$cmakeFile = Join-Path $wonderSrc "CMakeLists.txt"
$cmakeTxt = Get-Content -LiteralPath $cmakeFile -Raw -Encoding UTF8
if ($cmakeTxt -match "\bxaudio2\b") {
    $cmakeTxt = $cmakeTxt -replace "\bxaudio2\b", "xaudio2_8"
    Set-Content -LiteralPath $cmakeFile -Value $cmakeTxt -Encoding UTF8
}

$buildDir = Join-Path $workDir "build"
$cacheFile = Join-Path $buildDir "CMakeCache.txt"
if (Test-Path -LiteralPath $cacheFile) {
    $cacheTxt = Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8
    if ($cacheTxt -notmatch "clang\+\+\.exe") {
        Remove-Item -Recurse -Force $buildDir
    }
}
New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
$ninjaFwd = $ninjaExe -replace "\\", "/"
$genFwd = $genDir -replace "\\", "/"
$vkFwd = $vkSdkDir -replace "\\", "/"
$srcFwd = $wonderSrc -replace "\\", "/"
$bldFwd = $buildDir -replace "\\", "/"
$ccFwd = $ccExe -replace "\\", "/"
$cxxFwd = $cxxExe -replace "\\", "/"

Say "configuring CMake (Windows PC native, Clang64, NX_PS4=OFF)..."
& $cmakeExe -S $srcFwd -B $bldFwd -G "Ninja" `
    "-DCMAKE_MAKE_PROGRAM=$ninjaFwd" `
    "-DCMAKE_C_COMPILER=$ccFwd" `
    "-DCMAKE_CXX_COMPILER=$cxxFwd" `
    "-DCMAKE_PREFIX_PATH=C:/msys64/clang64" `
    "-DCMAKE_CXX_FLAGS=-Wno-deprecated-declarations" `
    "-DCMAKE_EXE_LINKER_FLAGS=-Wl,--stack,67108864 -Wl,--disable-high-entropy-va -static" `
    "-DCMAKE_BUILD_TYPE=Release" `
    "-DNX_PS4=OFF" `
    "-DNX_GAME=wonder" `
    "-DNX_GEN_DIR=$genFwd" `
    "-DNX_VULKAN_SDK=$vkFwd"
if ($LASTEXITCODE -ne 0) { Say "CMake configure failed"; exit 1 }

$os = Get-CimInstance Win32_OperatingSystem
$freeGb = [Math]::Floor($os.FreePhysicalMemory / 1MB)
$jobs = [Math]::Max(1, [Math]::Min([Environment]::ProcessorCount, [int]([Math]::Max(1, ($freeGb - 2) / 1.5))))
Say "compiling wonder.exe with Ninja (-j$jobs)..."
& $ninjaExe -C $bldFwd wonder "-j$jobs"
if ($LASTEXITCODE -ne 0) { Say "Ninja build failed"; exit 1 }

$builtExe = Join-Path $buildDir "wonder.exe"
if (-not (Test-Path -LiteralPath $builtExe)) {
    Say "error: wonder.exe was not produced in $buildDir"
    exit 1
}
Copy-Item -LiteralPath $builtExe -Destination (Join-Path $Dir "wonder.exe") -Force
foreach ($dll in @("SDL3.dll", "libiconv-2.dll", "libwinpthread-1.dll")) {
    $dllSrc = Join-Path $clang64Bin $dll
    if (Test-Path -LiteralPath $dllSrc) {
        Copy-Item -LiteralPath $dllSrc -Destination (Join-Path $Dir $dll) -Force
    }
}

# ---- 8. Pre-launch UI + icons + shortcuts ----
$iconSrc = $IconPath
if (-not $iconSrc -or -not (Test-Path -LiteralPath $iconSrc)) {
    $iconSrc = Join-Path $source "game_icon.ico"
}
$iconDst = Join-Path $Dir "game_icon.ico"
if (Test-Path -LiteralPath $iconSrc) {
    Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force
}
$pngSrc = Join-Path $source "game_icon.png"
$pngDst = Join-Path $Dir "game_icon.png"
if (Test-Path -LiteralPath $pngSrc) {
    Copy-Item -LiteralPath $pngSrc -Destination $pngDst -Force
}

$launcherUiSrc = $LauncherUiPath
if (-not $launcherUiSrc -or -not (Test-Path -LiteralPath $launcherUiSrc)) {
    $repoRoot = Split-Path (Split-Path $source -Parent) -Parent
    $toolsExe = Join-Path $repoRoot "tools\game_launcher.exe"
    $exeCand = Join-Path $repoRoot "game_launcher.exe"
    if (Test-Path -LiteralPath $toolsExe) { $launcherUiSrc = $toolsExe }
    elseif (Test-Path -LiteralPath $exeCand) { $launcherUiSrc = $exeCand }
    else { $launcherUiSrc = Join-Path $repoRoot "src\game_launcher.py" }
}
$isLauncherExe = $launcherUiSrc -match "\.exe$"
$launcherUiDst = Join-Path $Dir $(if ($isLauncherExe) { "game_launcher.exe" } else { "game_launcher.py" })
if (Test-Path -LiteralPath $launcherUiSrc) {
    Copy-Item -LiteralPath $launcherUiSrc -Destination $launcherUiDst -Force
}

$globalSaveDir = Join-Path (Split-Path $Dir -Parent) "Saves\Super Mario Bros. Wonder"
New-Item -ItemType Directory -Force -Path $globalSaveDir | Out-Null
$localSaveDir = Join-Path $dataRoot "user\save"
if ((Test-Path -LiteralPath $localSaveDir) -and -not (Get-ChildItem -LiteralPath $globalSaveDir -Force | Select-Object -First 1)) {
    Get-ChildItem -LiteralPath $localSaveDir -Force | Copy-Item -Destination $globalSaveDir -Recurse -Force -ErrorAction SilentlyContinue
}

$launchTplPath = Join-Path $source "launch_options_template.json"
$launchConfigPath = Join-Path $Dir "launch_options.json"
if (Test-Path -LiteralPath $launchTplPath) {
    $tpl = Get-Content -LiteralPath $launchTplPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $tpl | Add-Member -NotePropertyName "working_dir" -NotePropertyValue $Dir -Force
    $tpl | Add-Member -NotePropertyName "command" -NotePropertyValue @((Join-Path $Dir "wonder.exe")) -Force
    if ($tpl.env) {
        $tpl.env | Add-Member -NotePropertyName "NX_SAVE_DIR" -NotePropertyValue $globalSaveDir -Force
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($launchConfigPath, ($tpl | ConvertTo-Json -Depth 10), $utf8NoBom)
}

$hostPythonw = $null
$pyCandidates = @(Get-Command pythonw.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source) +
                @(Get-Command python.exe -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
foreach ($cand in $pyCandidates) {
    if ($cand -and ($cand -notmatch "\\msys64\\")) {
        $probeExe = if ($cand -match "pythonw\.exe$") { $cand -replace "pythonw\.exe$", "python.exe" } else { $cand }
        if (Test-Path -LiteralPath $probeExe) {
            & $probeExe -c "import PySide6" 2>$null
            if ($LASTEXITCODE -eq 0) {
                $hostPythonw = $cand
                break
            }
        }
    }
}

$runner = Join-Path $Dir "wonder.cmd"
if ($isLauncherExe -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
@"
@echo off
cd /d "$Dir"
"$launcherUiDst" --config "$launchConfigPath" %*
"@ | Set-Content -Encoding ASCII $runner
} elseif ($hostPythonw -and (Test-Path -LiteralPath $launcherUiDst) -and (Test-Path -LiteralPath $launchConfigPath)) {
@"
@echo off
cd /d "$Dir"
"$hostPythonw" "$launcherUiDst" --config "$launchConfigPath" %*
"@ | Set-Content -Encoding ASCII $runner
} else {
@"
@echo off
cd /d "$Dir"
set "NX_DATA_ROOT=$dataRoot"
set "NX_LOG=$dataRoot\nx.log"
set NX_MEM_LIMIT_GB=8
set NX_GPU=discrete
set NX_LANGUAGE=fr
"$Dir\wonder.exe" %*
"@ | Set-Content -Encoding ASCII $runner
}

$safeShortcutName = ($ShortcutName -replace '[<>:"/\\|?*]+', ' -').Trim()
if (-not $safeShortcutName) { $safeShortcutName = "Super Mario Bros. Wonder" }

$startMenuPrograms = [Environment]::GetFolderPath("Programs")
$shortcutDirs = @((Join-Path $startMenuPrograms $safeShortcutName))
if (-not $NoDesktopShortcut) {
    $shortcutDirs += [Environment]::GetFolderPath("Desktop")
}

$wsh = New-Object -ComObject WScript.Shell
foreach ($sdir in $shortcutDirs) {
    New-Item -ItemType Directory -Force -Path $sdir | Out-Null
    $linkPath = Join-Path $sdir "$safeShortcutName.lnk"
    $link = $wsh.CreateShortcut($linkPath)
    $link.TargetPath = $runner
    $link.WorkingDirectory = $Dir
    $link.Description = "$safeShortcutName - Native PC port"
    if (Test-Path -LiteralPath $iconDst) { $link.IconLocation = "$iconDst,0" }
    $link.Save()
}

# ---- 9. Clean up temporary build & extraction folders ----
Say "cleaning up temporary build files in $Dir..."
foreach ($tmpDir in @($builderRoot, $workDir, (Join-Path $Dir "_extracted"))) {
    if (Test-Path -LiteralPath $tmpDir) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

# ---- 10. Register in Windows Installed Apps + create uninstaller (never deletes the .nup ROM) ----
$uninstKeyName = "Switch2Recomp_" + ($safeShortcutName -replace '[^A-Za-z0-9_-]', '_')
$uninstRegPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstKeyName"
$uninstPs1 = Join-Path $Dir "uninstall.ps1"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "$safeShortcutName.lnk"
$startMenuDir = Join-Path ([Environment]::GetFolderPath("Programs")) $safeShortcutName
$uninstScript = @"
Add-Type -AssemblyName System.Windows.Forms
`$res = [System.Windows.Forms.MessageBox]::Show(
    "Voulez-vous désinstaller $safeShortcutName ?`n`nLe dossier d'installation et les raccourcis seront supprimés.`nVotre fichier ROM (.nup) et vos sauvegardes ne seront PAS supprimés.",
    "Désinstaller $safeShortcutName",
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if (`$res -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }
if (Test-Path -LiteralPath "$desktopLnk") { Remove-Item -LiteralPath "$desktopLnk" -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$startMenuDir") { Remove-Item -LiteralPath "$startMenuDir" -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path -LiteralPath "$uninstRegPath") {
    Remove-Item -LiteralPath "$uninstRegPath" -Recurse -Force -ErrorAction SilentlyContinue
}
Set-Location `$env:TEMP
Start-Process -FilePath "cmd.exe" -ArgumentList "/c timeout /t 1 /nobreak >nul & rmdir /s /q ``"$Dir``"" -WindowStyle Hidden
"@
[System.IO.File]::WriteAllText($uninstPs1, $uninstScript, (New-Object System.Text.UTF8Encoding($true)))

$sizeKb = [int](((Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1KB)
New-Item -Path $uninstRegPath -Force | Out-Null
Set-ItemProperty -Path $uninstRegPath -Name "DisplayName" -Value $safeShortcutName
Set-ItemProperty -Path $uninstRegPath -Name "Publisher" -Value "Switch2Recomp (NUP Studio)"
Set-ItemProperty -Path $uninstRegPath -Name "InstallLocation" -Value $Dir
if (Test-Path -LiteralPath $iconDst) { Set-ItemProperty -Path $uninstRegPath -Name "DisplayIcon" -Value "$iconDst,0" }
$uninstCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uninstPs1`""
Set-ItemProperty -Path $uninstRegPath -Name "UninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "QuietUninstallString" -Value $uninstCmd
Set-ItemProperty -Path $uninstRegPath -Name "NoModify" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "NoRepair" -Value 1 -Type DWord
Set-ItemProperty -Path $uninstRegPath -Name "EstimatedSize" -Value $sizeKb -Type DWord

Say "installed. Start the game from the Start menu or the desktop shortcut."

