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
$ProgressPreference = 'SilentlyContinue'

function Write-StepLog([string]$Title, [string]$Message) {
    Write-Host "[$Title] $Message" -ForegroundColor Cyan
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::notice title=$Title::$Message"
    }
}

try {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Write-StepLog "Init" "Старт сборки загрузочного образа WinPass WinPE ISO (RepoRoot=$RepoRoot)"

    # --------------------------------------------------------------------------
    # 1. Поиск или автоматическая установка Windows ADK и WinPE Add-on
    # --------------------------------------------------------------------------
    $AdkRoot    = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit"
    $WinPERoot  = Join-Path $AdkRoot "Windows Preinstallation Environment"
    $DeployRoot = Join-Path $AdkRoot "Deployment Tools"

    $WinpeWimPath = Join-Path $WinPERoot "amd64\en-us\winpe.wim"
    $OscdimgPath  = Join-Path $DeployRoot "amd64\Oscdimg\oscdimg.exe"

    $tempSetupDir = Join-Path $env:TEMP "winpass_adk_setup"
    New-Item -Path $tempSetupDir -ItemType Directory -Force | Out-Null

    if (-not (Test-Path $OscdimgPath)) {
        Write-StepLog "ADK" "Установка Windows ADK Deployment Tools..."
        $adkExe = Join-Path $tempSetupDir "adksetup.exe"
        & curl.exe -L -s -o "$adkExe" "https://go.microsoft.com/fwlink/?linkid=2196127"
        $pAdk = Start-Process -FilePath $adkExe -ArgumentList "/quiet /norestart /ceip off /features OptionId.DeploymentTools" -Wait -PassThru
        Write-Host "Код завершения adksetup.exe: $($pAdk.ExitCode)"
    }

    if (-not (Test-Path $WinpeWimPath)) {
        # Пробуем официальные инсталляторы WinPE Add-on (Win11 22H2 / Win11 23H2 / Win10 2004)
        $winpeLinks = @(
            "https://go.microsoft.com/fwlink/?linkid=2196224",
            "https://go.microsoft.com/fwlink/?linkid=2243391",
            "https://go.microsoft.com/fwlink/?linkid=2087112"
        )
        foreach ($url in $winpeLinks) {
            if (Test-Path $WinpeWimPath) { break }
            Write-StepLog "WinPE-Addon" "Скачивание и установка WinPE Add-on ($url)..."
            $peExe = Join-Path $tempSetupDir ("adkwinpesetup_" + [Guid]::NewGuid().ToString('N').Substring(0, 6) + ".exe")
            & curl.exe -L -s -o "$peExe" "$url"
            $pPe = Start-Process -FilePath $peExe -ArgumentList "/quiet /norestart /ceip off /features OptionId.WindowsPreinstallationEnvironment" -Wait -PassThru
            Write-Host "Код завершения adkwinpesetup.exe ($url): $($pPe.ExitCode)"
        }
    }

    if (-not (Test-Path $WinpeWimPath)) {
        throw "Не найден базовый образ $WinpeWimPath после установки ADK WinPE Add-on!"
    }
    if (-not (Test-Path $OscdimgPath)) {
        throw "Не найден инструмент сборки ISO $OscdimgPath!"
    }

    Write-StepLog "ADK-Ready" "Инструменты Windows ADK и winpe.wim готовы к сборке."

    # --------------------------------------------------------------------------
    # 2. Подготовка рабочей директории и базовых медиа-файлов WinPE
    # --------------------------------------------------------------------------
    $MountDir = Join-Path $WorkDir "mount"
    $MediaDir = Join-Path $WorkDir "media"

    if (Test-Path $WorkDir) {
        $null = & dism.exe /Cleanup-Mountpoints 2>&1
        Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    New-Item -Path $MountDir -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $MediaDir "sources") -ItemType Directory -Force | Out-Null

    $AdkMediaSrc = Join-Path $WinPERoot "amd64\Media"
    Copy-Item -Path "$AdkMediaSrc\*" -Destination $MediaDir -Recurse -Force

    $BootWimPath = Join-Path $MediaDir "sources\boot.wim"
    Copy-Item -Path $WinpeWimPath -Destination $BootWimPath -Force
    Set-ItemProperty -Path $BootWimPath -Name IsReadOnly -Value $false

    # --------------------------------------------------------------------------
    # 3. Монтирование образа boot.wim
    # --------------------------------------------------------------------------
    Write-StepLog "Mount-WIM" "Монтирование boot.wim в $MountDir..."
    & dism.exe /Mount-Image /ImageFile:"$BootWimPath" /Index:1 /MountDir:"$MountDir"
    if ($LASTEXITCODE -ne 0) {
        throw "Ошибка монтирования boot.wim (код $LASTEXITCODE)"
    }

    try {
        # ----------------------------------------------------------------------
        # 4. Интеграция пакетов WinPE (.NET Framework, PowerShell, WMI, StorageWMI)
        # ----------------------------------------------------------------------
        Write-StepLog "Inject-OCs" "Интеграция пакетов WinPE-WMI, WinPE-NetFx и WinPE-PowerShell..."
        $OcDir = Join-Path $WinPERoot "amd64\WinPE_OCs"

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
                & dism.exe /Image:"$MountDir" /Add-Package /PackagePath:"$pkgFull" /NoRestart
            }
        }

        # ----------------------------------------------------------------------
        # 5. Интеграция WinPass Admin Suite внутрь образа (X:\WinPass) и в корень ISO
        # ----------------------------------------------------------------------
        Write-StepLog "Integrate-WinPass" "Копирование WinPass Admin Suite в X:\WinPass и корень ISO..."

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

        $autorunCmd = "@echo off`r`ncd /d `"%~dp0WinPass`"`r`ncall Run-WinPass.bat`r`n"
        [System.IO.File]::WriteAllText((Join-Path $MediaDir "Run-WinPass.cmd"), $autorunCmd, [System.Text.Encoding]::ASCII)

        # Настраиваем политику выполнения PowerShell (ExecutionPolicy = Bypass) в реестре WinPE
        $peSoftHive = Join-Path $MountDir "Windows\System32\config\SOFTWARE"
        $null = & reg.exe load "HKLM\WINPE_BUILD_SOFT" "$peSoftHive" 2>&1
        try {
            $null = & reg.exe add "HKLM\WINPE_BUILD_SOFT\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v "ExecutionPolicy" /t REG_SZ /d "Bypass" /f 2>&1
        }
        finally {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            Start-Sleep -Milliseconds 300
            $null = & reg.exe unload "HKLM\WINPE_BUILD_SOFT" 2>&1
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

        # ----------------------------------------------------------------------
        # 6. Сохранение и размонтирование образа boot.wim
        # ----------------------------------------------------------------------
        Write-StepLog "Commit-WIM" "Сохранение и размонтирование boot.wim..."
        & dism.exe /Unmount-Image /MountDir:"$MountDir" /Commit
        if ($LASTEXITCODE -ne 0) {
            throw "Ошибка при сохранении boot.wim (код $LASTEXITCODE)"
        }
    }
    catch {
        $null = & dism.exe /Unmount-Image /MountDir:"$MountDir" /Discard 2>&1
        throw
    }

    # --------------------------------------------------------------------------
    # 7. Сборка загрузочного гибридного ISO-образа (Legacy BIOS + UEFI x64)
    # --------------------------------------------------------------------------
    Write-StepLog "Build-ISO" "Генерация загрузочного ISO-образа через oscdimg.exe..."

    $outDir = Split-Path -Parent $OutputIsoPath
    if (-not (Test-Path $outDir)) {
        New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }

    $EtfsBootSrc = Join-Path $DeployRoot "amd64\Oscdimg\etfsboot.com"
    $EfiSysSrc   = Join-Path $DeployRoot "amd64\Oscdimg\efisys_noprompt.bin"
    if (-not (Test-Path $EfiSysSrc)) {
        $EfiSysSrc = Join-Path $DeployRoot "amd64\Oscdimg\efisys.bin"
    }

    # Копируем загрузочные сектора в папку без пробелов в пути (требование синтаксиса -bootdata oscdimg.exe)
    $EtfsBootNoSpace = Join-Path $WorkDir "etfsboot.com"
    $EfiSysNoSpace   = Join-Path $WorkDir "efisys.bin"
    Copy-Item -Path $EtfsBootSrc -Destination $EtfsBootNoSpace -Force
    Copy-Item -Path $EfiSysSrc   -Destination $EfiSysNoSpace   -Force

    $BootDataArg = "2#p0,e,b$EtfsBootNoSpace#pEF,e,b$EfiSysNoSpace"
    & $OscdimgPath -m -o -u2 -udfver102 -lWINPASS_PE "-bootdata:$BootDataArg" "$MediaDir" "$OutputIsoPath"
    if ($LASTEXITCODE -ne 0 -or (-not (Test-Path $OutputIsoPath))) {
        throw "Ошибка создания ISO-образа через oscdimg.exe (код $LASTEXITCODE)"
    }

    $isoFile = Get-Item $OutputIsoPath
    $sizeMb  = [Math]::Round($isoFile.Length / 1MB, 2)
    $hashObj = Get-FileHash -Path $OutputIsoPath -Algorithm SHA256

    $checksumFile = "$OutputIsoPath.sha256.txt"
    $checksumLine = "$($hashObj.Hash.ToLower())  $($isoFile.Name) ($sizeMb MB)`r`n"
    [System.IO.File]::WriteAllText($checksumFile, $checksumLine, [System.Text.Encoding]::UTF8)

    Remove-Item -Path $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-StepLog "Success" "Готовый образ собран: $($isoFile.Name) ($sizeMb MB), SHA256=$($hashObj.Hash)"
}
catch {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        Write-Host "::error title=WinPEBuildError::$($_.Exception.Message)"
    }
    throw
}
