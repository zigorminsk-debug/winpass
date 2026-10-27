# ==============================================================================
# WinPass Admin Suite — Скрипт автоматической сборки загрузочного образа WinPE ISO
# Устанавливает Windows ADK + WinPE Add-on (если не установлены), интегрирует
# пакеты .NET Framework (WinPE-NetFx) и PowerShell (WinPE-PowerShell), встраивает
# WinPass Admin Suite с автозапуском GUI и собирает гибридный BIOS/UEFI ISO.
# ==============================================================================

param(
    [string]$OutputIsoPath = "$PSScriptRoot\..\output\WinPass-WinPE-amd64.iso",
    [string]$WorkDir = "C:\WinPE_WinPass_Build"
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  Сборка загрузочного образа WinPass WinPE ISO (x64 BIOS + UEFI)" -ForegroundColor Cyan
Write-Host "  Корень проекта : $RepoRoot" -ForegroundColor Gray
Write-Host "  Выходной ISO   : $OutputIsoPath" -ForegroundColor Gray
Write-Host "======================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Поиск или автоматическая установка Windows ADK и WinPE Add-on
# ------------------------------------------------------------------------------
$AdkRoot   = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
$WinPERoot = Join-Path $AdkRoot "Windows Preinstallation Environment"
$DeployRoot = Join-Path $AdkRoot "Deployment Tools"

$WinpeWimPath = Join-Path $WinPERoot "amd64\en-us\winpe.wim"
$OscdimgPath  = Join-Path $DeployRoot "amd64\Oscdimg\oscdimg.exe"

if ((-not (Test-Path $WinpeWimPath)) -or (-not (Test-Path $OscdimgPath))) {
    Write-Host "[1/7] Windows ADK / WinPE Add-on не обнаружен. Скачивание и установка..." -ForegroundColor Yellow
    $tempSetupDir = Join-Path $env:TEMP "winpass_adk_setup"
    if (-not (Test-Path $tempSetupDir)) {
        New-Item -Path $tempSetupDir -ItemType Directory -Force | Out-Null
    }

    # Официальные ссылки Microsoft ADK и WinPE Add-on
    $adkUrl      = "https://go.microsoft.com/fwlink/?linkid=2243390"
    $adkWinpeUrl = "https://go.microsoft.com/fwlink/?linkid=2243391"
    $adkExe      = Join-Path $tempSetupDir "adksetup.exe"
    $adkWinpeExe = Join-Path $tempSetupDir "adkwinpesetup.exe"

    if (-not (Test-Path $OscdimgPath)) {
        Write-Host "  -> Скачивание adksetup.exe..."
        Invoke-WebRequest -Uri $adkUrl -OutFile $adkExe -UseBasicParsing
        Write-Host "  -> Установка Deployment Tools (oscdimg, DISM)..."
        $procAdk = Start-Process -FilePath $adkExe -ArgumentList "/quiet /norestart /ceip off /features OptionId.DeploymentTools" -Wait -PassThru
        Write-Host "  -> Код завершения adksetup.exe: $($procAdk.ExitCode)"
    }

    if (-not (Test-Path $WinpeWimPath)) {
        Write-Host "  -> Скачивание adkwinpesetup.exe..."
        Invoke-WebRequest -Uri $adkWinpeUrl -OutFile $adkWinpeExe -UseBasicParsing
        Write-Host "  -> Установка Windows Preinstallation Environment (WinPE Add-on)..."
        $procPe = Start-Process -FilePath $adkWinpeExe -ArgumentList "/quiet /norestart /ceip off /features OptionId.WindowsPreinstallationEnvironment" -Wait -PassThru
        Write-Host "  -> Код завершения adkwinpesetup.exe: $($procPe.ExitCode)"
    }
}

if (-not (Test-Path $WinpeWimPath)) {
    throw "Критическая ошибка: Не найден базовый образ $WinpeWimPath после установки ADK WinPE Add-on!"
}
if (-not (Test-Path $OscdimgPath)) {
    throw "Критическая ошибка: Не найден инструмент сборки ISO $OscdimgPath!"
}

Write-Host "[OK] Инструменты Windows ADK и базовый образ winpe.wim готовы." -ForegroundColor Green

# ------------------------------------------------------------------------------
# 2. Подготовка рабочей директории и базовых медиа-файлов WinPE
# ------------------------------------------------------------------------------
Write-Host "[2/7] Подготовка структуры каталогов WinPE в $WorkDir..." -ForegroundColor Cyan

$MountDir = Join-Path $WorkDir "mount"
$MediaDir = Join-Path $WorkDir "media"

if (Test-Path $WorkDir) {
    & dism.exe /Cleanup-Mountpoints | Out-Null
    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -Path $MountDir -ItemType Directory -Force | Out-Null
New-Item -Path (Join-Path $MediaDir "sources") -ItemType Directory -Force | Out-Null

$AdkMediaSrc = Join-Path $WinPERoot "amd64\Media"
Copy-Item -Path "$AdkMediaSrc\*" -Destination $MediaDir -Recurse -Force

$BootWimPath = Join-Path $MediaDir "sources\boot.wim"
Copy-Item -Path $WinpeWimPath -Destination $BootWimPath -Force
# Снимаем атрибут ReadOnly с boot.wim
Set-ItemProperty -Path $BootWimPath -Name IsReadOnly -Value $false

# ------------------------------------------------------------------------------
# 3. Монтирование образа boot.wim
# ------------------------------------------------------------------------------
Write-Host "[3/7] Монтирование образа boot.wim через DISM..." -ForegroundColor Cyan
& dism.exe /Mount-Image /ImageFile:"$BootWimPath" /Index:1 /MountDir:"$MountDir"
if ($LASTEXITCODE -ne 0) {
    throw "Ошибка монтирования boot.wim (код $LASTEXITCODE)"
}

try {
    # --------------------------------------------------------------------------
    # 4. Интеграция пакетов WinPE (.NET Framework, PowerShell, WMI, StorageWMI)
    # --------------------------------------------------------------------------
    Write-Host "[4/7] Интеграция компонентов .NET Framework и Windows PowerShell в WinPE..." -ForegroundColor Cyan
    $OcDir = Join-Path $WinPERoot "amd64\WinPE_OCs"

    # Строгий порядок установки пакетов согласно документации Microsoft
    $PackagesToInstall = @(
        "WinPE-WMI.cab",
        "en-us\WinPE-WMI_en-us.cab",
        "WinPE-NetFx.cab",
        "en-us\WinPE-NetFx_en-us.cab",
        "WinPE-Scripting.cab",
        "en-us\WinPE-Scripting_en-us.cab",
        "WinPE-PowerShell.cab",
        "en-us\WinPE-PowerShell_en-us.cab",
        "WinPE-StorageWMI.cab",
        "en-us\WinPE-StorageWMI_en-us.cab",
        "WinPE-DismCmdlets.cab",
        "en-us\WinPE-DismCmdlets_en-us.cab"
    )

    foreach ($pkgRel in $PackagesToInstall) {
        $pkgFull = Join-Path $OcDir $pkgRel
        if (Test-Path $pkgFull) {
            Write-Host "  -> Добавление пакета: $pkgRel"
            & dism.exe /Image:"$MountDir" /Add-Package /PackagePath:"$pkgFull" /NoRestart | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Предупреждение DISM при установке пакета $pkgRel (код $LASTEXITCODE)"
            }
        }
    }

    # --------------------------------------------------------------------------
    # 5. Интеграция WinPass Admin Suite внутрь образа (X:\WinPass) и на DVD/USB
    # --------------------------------------------------------------------------
    Write-Host "[5/7] Встраивание WinPass Admin Suite в образ WinPE (X:\WinPass)..." -ForegroundColor Cyan

    foreach ($destBase in @(
        (Join-Path $MountDir "WinPass"),
        (Join-Path $MediaDir "WinPass")
    )) {
        foreach ($sub in @("", "modules", "ui", "logs")) {
            $p = if ($sub) { Join-Path $destBase $sub } else { $destBase }
            New-Item -Path $p -ItemType Directory -Force | Out-Null
        }

        foreach ($f in @("WinPass-GUI.ps1", "WinPass-WinPE-GUI.ps1", "Run-WinPass.bat", "Start-WinPE.cmd", "README.md")) {
            $src = Join-Path $RepoRoot $f
            if (Test-Path $src) {
                Copy-Item -Path $src -Destination $destBase -Force
            }
        }

        Copy-Item -Path (Join-Path $RepoRoot "modules\*.ps1") -Destination (Join-Path $destBase "modules") -Force
        Copy-Item -Path (Join-Path $RepoRoot "ui\*.xaml") -Destination (Join-Path $destBase "ui") -Force
    }

    # Также создаем ярлык запуска в корне диска ISO для запуска прямо из Windows
    $autorunCmd = "@echo off`r`ncd /d `"%~dp0WinPass`"`r`ncall Run-WinPass.bat`r`n"
    [System.IO.File]::WriteAllText((Join-Path $MediaDir "Run-WinPass.cmd"), $autorunCmd, [System.Text.Encoding]::ASCII)

    # Настраиваем политику выполнения PowerShell (ExecutionPolicy = Bypass) в реестре WinPE
    $peSoftHive = Join-Path $MountDir "Windows\System32\config\SOFTWARE"
    & reg.exe load "HKLM\WINPE_BUILD_SOFT" "$peSoftHive" | Out-Null
    try {
        & reg.exe add "HKLM\WINPE_BUILD_SOFT\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Bypass" /f | Out-Null
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\WINPE_BUILD_SOFT" | Out-Null
    }

    # Настраиваем автозапуск графического интерфейса WinPass Admin Suite в X:\Windows\System32\startnet.cmd
    $startnetPath = Join-Path $MountDir "Windows\System32\startnet.cmd"
    $startnetContent = @"
@echo off
wpeinit
chcp 65001 >nul
title WinPass Admin Suite v2.0 - Live WinPE Recovery Environment
color 1F
cls
echo ============================================================================
echo        WINPASS ADMIN SUITE v2.0 — ЗАГРУЗОЧНАЯ СРЕДА ВОССТАНОВЛЕНИЯ WINPE
echo ============================================================================
echo  [*] Инициализация оборудования завершена.
echo  [*] Запуск графического интерфейса восстановления паролей WinPass GUI...
echo ============================================================================
echo.
if exist "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" (
    "X:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -File "X:\WinPass\WinPass-WinPE-GUI.ps1"
)
call "X:\WinPass\Start-WinPE.cmd"
"@
    [System.IO.File]::WriteAllText($startnetPath, $startnetContent, (New-Object System.Text.UTF8Encoding($false)))

    # --------------------------------------------------------------------------
    # 6. Сохранение и размонтирование образа boot.wim
    # --------------------------------------------------------------------------
    Write-Host "[6/7] Сохранение изменений и размонтирование boot.wim..." -ForegroundColor Cyan
    & dism.exe /Unmount-Image /MountDir:"$MountDir" /Commit
    if ($LASTEXITCODE -ne 0) {
        throw "Ошибка при сохранении boot.wim (код $LASTEXITCODE)"
    }
}
catch {
    Write-Host "[!] Ошибка при модификации образа, откат монтирования..." -ForegroundColor Red
    & dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard | Out-Null
    throw
}

# ------------------------------------------------------------------------------
# 7. Сборка загрузочного гибридного ISO-образа (Legacy BIOS + UEFI x64)
# ------------------------------------------------------------------------------
Write-Host "[7/7] Генерация загрузочного ISO-образа через oscdimg.exe..." -ForegroundColor Cyan

$outDir = Split-Path -Parent $OutputIsoPath
if (-not (Test-Path $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

$EtfsBoot = Join-Path $AdkRoot "Deployment Tools\amd64\Oscdimg\etfsboot.com"
$EfiSys   = Join-Path $AdkRoot "Deployment Tools\amd64\Oscdimg\efisys_noprompt.bin"
if (-not (Test-Path $EfiSys)) {
    $EfiSys = Join-Path $AdkRoot "Deployment Tools\amd64\Oscdimg\efisys.bin"
}

$BootDataArg = "2#p0,e,b`"$EtfsBoot`"#pEF,e,b`"$EfiSys`""
& $OscdimgPath -m -o -u2 -udfver102 -l"WINPASS_PE" -bootdata:$BootDataArg "$MediaDir" "$OutputIsoPath"
if ($LASTEXITCODE -ne 0 -or (-not (Test-Path $OutputIsoPath))) {
    throw "Ошибка создания ISO-образа через oscdimg.exe (код $LASTEXITCODE)"
}

$isoFile = Get-Item $OutputIsoPath
$sizeMb  = [Math]::Round($isoFile.Length / 1MB, 2)
$hashObj = Get-FileHash -Path $OutputIsoPath -Algorithm SHA256

$checksumFile = "$OutputIsoPath.sha256.txt"
$checksumLine = "$($hashObj.Hash.ToLower())  $($isoFile.Name) ($sizeMb MB)`r`n"
[System.IO.File]::WriteAllText($checksumFile, $checksumLine, [System.Text.Encoding]::UTF8)

# Очистка временной рабочей папки
Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  [УСПЕШНО] Загрузочный образ WinPE собран!" -ForegroundColor Green
Write-Host "  Файл ISO : $($isoFile.FullName)" -ForegroundColor White
Write-Host "  Размер   : $sizeMb МБ" -ForegroundColor White
Write-Host "  SHA-256  : $($hashObj.Hash)" -ForegroundColor White
Write-Host "======================================================================" -ForegroundColor Green
