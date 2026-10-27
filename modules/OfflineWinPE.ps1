# ==============================================================================
# WinPass Admin Suite - Модуль работы в среде WinPE и офлайн-восстановления ОС
# Прямое редактирование F и V структур офлайн-реестра SAM (сброс пароля и
# разблокировка), управление перехватом sethc.exe / utilman.exe, сброс PIN-кода
# Windows Hello (NGC), офлайн-чтение AutoLogon/Wi-Fi и экспорт на USB
# ==============================================================================

function Test-IsWinPEEnvironment {
    <#
    .SYNOPSIS
        Определяет, запущена ли программа в среде восстановления Windows PE / WinRE.
    #>
    $miniNt = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT'
    $isXDrive = ($env:SystemDrive -eq 'X:')
    return ($miniNt -or $isXDrive)
}

function Get-WinPassOfflineWindowsInstallations {
    <#
    .SYNOPSIS
        Сканирует все подключенные диски на наличие установленных копий Windows
        и проверяет статус файлов специальных возможностей (sethc.exe / utilman.exe).
    #>
    $installs = New-Object System.Collections.Generic.List[PSCustomObject]

    $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue
    foreach ($d in $drives) {
        $root = $d.Root
        if ([string]::IsNullOrEmpty($root)) { continue }

        $samPath     = Join-Path $root 'Windows\System32\config\SAM'
        $softPath    = Join-Path $root 'Windows\System32\config\SOFTWARE'
        $sethcPath   = Join-Path $root 'Windows\System32\sethc.exe'
        $utilmanPath = Join-Path $root 'Windows\System32\utilman.exe'
        $sethcBak    = Join-Path $root 'Windows\System32\sethc.exe.winpass.bak'
        $utilmanBak  = Join-Path $root 'Windows\System32\utilman.exe.winpass.bak'
        $samBak      = Join-Path $root 'Windows\System32\config\SAM.winpass.bak'
        $ngcPath     = Join-Path $root 'Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc'

        if (Test-Path $samPath) {
            $isCurrentOs = ($root.TrimEnd('\').ToUpper() -eq $env:SystemDrive.TrimEnd('\').ToUpper()) -and (-not (Test-IsWinPEEnvironment))
            $hasSethcBypass   = Test-Path $sethcBak
            $hasUtilmanBypass = Test-Path $utilmanBak
            $hasSamBackup     = Test-Path $samBak
            $hasNgc           = Test-Path $ngcPath

            $bypassStatus = if ($hasSethcBypass -and $hasUtilmanBypass) {
                'Активен (sethc + utilman)'
            }
            elseif ($hasSethcBypass) {
                'Активен (sethc.exe / 5x Shift)'
            }
            elseif ($hasUtilmanBypass) {
                'Активен (utilman.exe)'
            }
            else {
                'Штатный режим (оригинал)'
            }

            $installs.Add([PSCustomObject]@{
                DriveRoot        = $root
                DriveLetter      = $root.TrimEnd('\')
                SamPath          = $samPath
                SoftwarePath     = $softPath
                SethcPath        = $sethcPath
                UtilmanPath      = $utilmanPath
                IsCurrentLiveOS  = $isCurrentOs
                ModeText         = if ($isCurrentOs) { 'Запущенная ОС (Online)' } else { 'Офлайн-система (Offline)' }
                BypassActive     = ($hasSethcBypass -or $hasUtilmanBypass)
                BypassStatusText = $bypassStatus
                HasSamBackup     = $hasSamBackup
                HasPinNgc        = $hasNgc
            })
        }
    }

    return $installs
}

function Get-WinPassOfflineSamUsers {
    <#
    .SYNOPSIS
        Подключает офлайн-куст реестра SAM выбранной Windows, считывает список локальных
        пользователей и разбирает бинарные структуры F и V (RID, статус пароля, блокировка, отключена ли УЗ).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamHivePath
    )

    if (-not (Test-Path $SamHivePath)) {
        throw "Файл куста реестра SAM не найден: $SamHivePath"
    }

    $mountKey = 'HKLM\WINPASS_OFFLINE_SAM'
    $psMountPath = 'HKLM:\WINPASS_OFFLINE_SAM'
    $usersResult = New-Object System.Collections.Generic.List[PSCustomObject]

    # Выгружаем куст, если он остался подключенным с прошлого раза
    $null = & reg.exe unload $mountKey 2>&1

    $loadOut = & reg.exe load $mountKey "$SamHivePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось загрузить куст SAM ($SamHivePath). Если это текущая запущенная ОС, используйте вкладку 'Локальные пользователи' или загрузитесь с образа WinPass WinPE ISO. Детали: $($loadOut -join ' ')"
    }

    try {
        $usersKeyPath = "$psMountPath\SAM\Domains\Account\Users"
        $namesKeyPath = "$usersKeyPath\Names"

        if (-not (Test-Path $namesKeyPath)) {
            throw "Структура SAM\Domains\Account\Users\Names недоступна. Запустите программу от имени Администратора / SYSTEM."
        }

        # Сопоставляем RID из веток 0000* и имена пользователей
        $ridToFBytes = @{}
        $ridSubkeys = Get-ChildItem -Path $usersKeyPath -ErrorAction Stop | Where-Object { $_.PSChildName -match '^[0-9A-Fa-f]{8}$' }

        foreach ($rk in $ridSubkeys) {
            $ridHex = $rk.PSChildName.ToUpper()
            $ridInt = [Convert]::ToUInt32($ridHex, 16)
            $props = Get-ItemProperty -Path $rk.PSPath -ErrorAction SilentlyContinue
            if ($props -and $props.F) {
                $ridToFBytes[$ridInt] = @{
                    RidHex = $ridHex
                    FBytes = [byte[]]$props.F
                    VBytes = [byte[]]$props.V
                }
            }
        }

        $nameSubkeys = Get-ChildItem -Path $namesKeyPath -ErrorAction Stop
        foreach ($nk in $nameSubkeys) {
            $userName = $nk.PSChildName
            $matchedRid = $null

            # Поиск имени пользователя в UTF-16LE внутри V-структуры
            $nameBytes = [System.Text.Encoding]::Unicode.GetBytes($userName)
            foreach ($ridKey in $ridToFBytes.Keys) {
                $vBytes = $ridToFBytes[$ridKey].VBytes
                if ($vBytes -and $vBytes.Length -ge 0xCC) {
                    $nameOffset = [BitConverter]::ToInt32($vBytes, 0x0C) + 0xCC
                    $nameLen    = [BitConverter]::ToInt32($vBytes, 0x10)
                    if ($nameLen -eq $nameBytes.Length -and ($nameOffset + $nameLen) -le $vBytes.Length) {
                        $extractedName = [System.Text.Encoding]::Unicode.GetString($vBytes, $nameOffset, $nameLen)
                        if ($extractedName -eq $userName) {
                            $matchedRid = $ridKey
                            break
                        }
                    }
                }
            }

            if ($null -ne $matchedRid -and $ridToFBytes.ContainsKey($matchedRid)) {
                $entry  = $ridToFBytes[$matchedRid]
                $fBytes = $entry.FBytes
                $vBytes = $entry.VBytes
                $ridHex = $entry.RidHex

                # В структуре F по смещению 0x38 (56) находятся 16-битные флаги ACB_*
                $acbFlags = [BitConverter]::ToUInt16($fBytes, 0x38)
                # По смещению 0x42 (66) находится счетчик неверных попыток ввода пароля
                $failedCount = [BitConverter]::ToUInt16($fBytes, 0x42)

                # В структуре V по смещению 0xAC (172) находится длина NTLM-хэша пароля
                $ntlmHashLen = 0
                if ($vBytes -and $vBytes.Length -ge 0xB0) {
                    $ntlmHashLen = [BitConverter]::ToInt32($vBytes, 0xAC)
                }

                $isDisabled = [bool]($acbFlags -band 0x0001)
                $isLocked   = [bool]($acbFlags -band 0x0010)
                $pwNotReq   = [bool]($acbFlags -band 0x0004)
                $hasPass    = ($ntlmHashLen -gt 4)

                $usersResult.Add([PSCustomObject]@{
                    UserName            = $userName
                    RID                 = $matchedRid
                    RIDHex              = $ridHex
                    Enabled             = (-not $isDisabled)
                    StatusText          = if ($isDisabled) { 'Отключена (0x0001)' } else { 'Активна' }
                    PasswordStateText   = if ($hasPass) { 'Установлен пароль' } else { 'Пустой (без пароля)' }
                    HasPasswordHash     = $hasPass
                    LockedOut           = $isLocked
                    LockedText          = if ($isLocked) { 'Заблокирована (0x0010)' } else { 'Норма' }
                    PasswordNotRequired = $pwNotReq
                    FailedLogonCount    = $failedCount
                    ACBFlagsHex         = ('0x{0:X4}' -f $acbFlags)
                })
            }
        }
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 200
        $null = & reg.exe unload $mountKey 2>&1
    }

    return $usersResult
}

function Unlock-WinPassOfflineSamUser {
    <#
    .SYNOPSIS
        Разблокирует и включает выбранную учетную запись напрямую в офлайн-кусте реестра SAM
        путем снятия флагов ACB_DISABLED (0x0001) и ACB_AUTOLOCK (0x0010) в бинарной структуре F,
        а также обнуления счетчика неудачных попыток входа.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamHivePath,

        [Parameter(Mandatory = $true)]
        [string]$RIDHex,

        [switch]$AllowBlankPassword
    )

    if (-not (Test-Path $SamHivePath)) {
        throw "Файл куста реестра SAM не найден: $SamHivePath"
    }

    # Создаем резервную копию куста SAM перед модификацией
    $backupPath = "$SamHivePath.winpass.bak"
    if (-not (Test-Path $backupPath)) {
        Copy-Item -Path $SamHivePath -Destination $backupPath -Force
    }

    $mountKey = 'HKLM\WINPASS_OFFLINE_SAM'
    $psMountPath = 'HKLM:\WINPASS_OFFLINE_SAM'
    $null = & reg.exe unload $mountKey 2>&1

    $loadOut = & reg.exe load $mountKey "$SamHivePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось подключить куст SAM: $($loadOut -join ' ')"
    }

    try {
        $cleanRidHex = $RIDHex.Trim().ToUpper()
        $userRegPath = "$psMountPath\SAM\Domains\Account\Users\$cleanRidHex"
        if (-not (Test-Path $userRegPath)) {
            throw "Ветка пользователя с RID $cleanRidHex не найдена в кусте SAM."
        }

        $props = Get-ItemProperty -Path $userRegPath -Name 'F' -ErrorAction Stop
        [byte[]]$fBytes = $props.F

        if ($fBytes.Length -lt 0x48) {
            throw "Некорректная длина структуры F ($($fBytes.Length) байт)."
        }

        $acbFlags = [BitConverter]::ToUInt16($fBytes, 0x38)
        # Снимаем бит 0x0001 (ACB_DISABLED) и бит 0x0010 (ACB_AUTOLOCK)
        $newFlags = [uint16]($acbFlags -band (-bnot 0x0001) -band (-bnot 0x0010))
        if ($AllowBlankPassword) {
            $newFlags = [uint16]($newFlags -bor 0x0004) # ACB_PWNOTREQ
        }

        $flagBytes = [BitConverter]::GetBytes($newFlags)
        $fBytes[0x38] = $flagBytes[0]
        $fBytes[0x39] = $flagBytes[1]

        # Сбрасываем FailedPasswordCount (смещение 0x42, 2 байта)
        $fBytes[0x42] = 0
        $fBytes[0x43] = 0

        Set-ItemProperty -Path $userRegPath -Name 'F' -Value $fBytes -Type Binary -ErrorAction Stop
        return "Учетная запись (RID $cleanRidHex) успешно активирована и разблокирована в офлайн-кусте SAM. Резервная копия сохранена в $backupPath."
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 250
        $null = & reg.exe unload $mountKey 2>&1
    }
}

function Clear-WinPassOfflineSamPassword {
    <#
    .SYNOPSIS
        Офлайн-сброс пароля пользователя на ПУСТОЙ пароль напрямую в кусте реестра SAM (из WinPE).
        Обнуляет длины LM и NTLM хэшей в структуре V (смещения 0xA0 и 0xAC), снимает блокировку
        и отключение учетной записи в структуре F (0x0001, 0x0010) и устанавливает флаг ACB_PWNOTREQ (0x0004).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamHivePath,

        [Parameter(Mandatory = $true)]
        [string]$RIDHex
    )

    if (-not (Test-Path $SamHivePath)) {
        throw "Файл куста реестра SAM не найден: $SamHivePath"
    }

    # Сохраняем полную резервную копию файла куста SAM перед изменениями
    $backupPath = "$SamHivePath.winpass.bak"
    if (-not (Test-Path $backupPath)) {
        Copy-Item -Path $SamHivePath -Destination $backupPath -Force
    }

    $mountKey = 'HKLM\WINPASS_OFFLINE_SAM'
    $psMountPath = 'HKLM:\WINPASS_OFFLINE_SAM'
    $null = & reg.exe unload $mountKey 2>&1

    $loadOut = & reg.exe load $mountKey "$SamHivePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось подключить куст SAM: $($loadOut -join ' ')"
    }

    try {
        $cleanRidHex = $RIDHex.Trim().ToUpper()
        $userRegPath = "$psMountPath\SAM\Domains\Account\Users\$cleanRidHex"
        if (-not (Test-Path $userRegPath)) {
            throw "Ветка пользователя с RID $cleanRidHex не найдена в кусте SAM."
        }

        $props = Get-ItemProperty -Path $userRegPath -ErrorAction Stop
        [byte[]]$fBytes = $props.F
        [byte[]]$vBytes = $props.V

        if ($fBytes.Length -lt 0x48 -or $vBytes.Length -lt 0xCC) {
            throw "Некорректный формат структур F или V пользователя $cleanRidHex."
        }

        # Сохраняем резервные копии структур F и V внутри ветки пользователя
        if (-not $props.PSObject.Properties['F_winpass_bak']) {
            Set-ItemProperty -Path $userRegPath -Name 'F_winpass_bak' -Value $fBytes -Type Binary -ErrorAction SilentlyContinue
        }
        if (-not $props.PSObject.Properties['V_winpass_bak']) {
            Set-ItemProperty -Path $userRegPath -Name 'V_winpass_bak' -Value $vBytes -Type Binary -ErrorAction SilentlyContinue
        }

        # 1. В структуре V обнуляем длину LM-хэша (0xA0), NTLM-хэша (0xAC) и истории паролей (0xB8, 0xC4)
        foreach ($lenOffset in @(0xA0, 0xAC, 0xB8, 0xC4)) {
            $vBytes[$lenOffset]     = 0
            $vBytes[$lenOffset + 1] = 0
            $vBytes[$lenOffset + 2] = 0
            $vBytes[$lenOffset + 3] = 0
        }

        # 2. В структуре F активируем УЗ, снимаем блокировку и разрешаем пустой пароль (ACB_PWNOTREQ = 0x0004)
        $acbFlags = [BitConverter]::ToUInt16($fBytes, 0x38)
        $newFlags = [uint16](($acbFlags -band (-bnot 0x0001) -band (-bnot 0x0010)) -bor 0x0004)
        $flagBytes = [BitConverter]::GetBytes($newFlags)
        $fBytes[0x38] = $flagBytes[0]
        $fBytes[0x39] = $flagBytes[1]

        # Обнуляем счетчик неверных попыток входа (0x42)
        $fBytes[0x42] = 0
        $fBytes[0x43] = 0

        Set-ItemProperty -Path $userRegPath -Name 'V' -Value $vBytes -Type Binary -ErrorAction Stop
        Set-ItemProperty -Path $userRegPath -Name 'F' -Value $fBytes -Type Binary -ErrorAction Stop

        return "Пароль пользователя (RID $cleanRidHex) в офлайн-кусте SAM успешно сброшен на ПУСТОЙ (вход без пароля), учетная запись включена и разблокирована! Резервная копия: $backupPath"
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 250
        $null = & reg.exe unload $mountKey 2>&1
    }
}

function Restore-WinPassOfflineSamBackup {
    <#
    .SYNOPSIS
        Восстанавливает оригинальный файл куста реестра SAM из резервной копии SAM.winpass.bak.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamHivePath
    )

    $backupPath = "$SamHivePath.winpass.bak"
    if (-not (Test-Path $backupPath)) {
        throw "Резервная копия куста SAM не найдена: $backupPath"
    }

    $null = & reg.exe unload 'HKLM\WINPASS_OFFLINE_SAM' 2>&1
    Copy-Item -Path $backupPath -Destination $SamHivePath -Force -ErrorAction Stop
    return "Оригинальный куст реестра SAM успешно восстановлен из резервной копии: $backupPath"
}

function Get-WinPassOfflineAutoLogon {
    <#
    .SYNOPSIS
        Читает настройки Winlogon AutoAdminLogon и сохраненный DefaultPassword из офлайн-куста SOFTWARE.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SoftwareHivePath
    )

    if (-not (Test-Path $SoftwareHivePath)) {
        throw "Файл куста SOFTWARE не найден: $SoftwareHivePath"
    }

    $mountKey = 'HKLM\WINPASS_OFFLINE_SOFT'
    $psMountPath = 'HKLM:\WINPASS_OFFLINE_SOFT'
    $null = & reg.exe unload $mountKey 2>&1

    $loadOut = & reg.exe load $mountKey "$SoftwareHivePath" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось подключить куст SOFTWARE: $($loadOut -join ' ')"
    }

    try {
        $winlogonPath = "$psMountPath\Microsoft\Windows NT\CurrentVersion\Winlogon"
        $props = Get-ItemProperty -Path $winlogonPath -ErrorAction Stop
        return [PSCustomObject]@{
            AutoAdminLogon    = [string]$props.AutoAdminLogon
            DefaultUserName   = [string]$props.DefaultUserName
            DefaultDomainName = [string]$props.DefaultDomainName
            DefaultPassword   = if ([string]::IsNullOrEmpty($props.DefaultPassword)) { '[Не сохранен в открытом виде]' } else { [string]$props.DefaultPassword }
        }
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 200
        $null = & reg.exe unload $mountKey 2>&1
    }
}

function Install-WinPassStickyKeysBypass {
    <#
    .SYNOPSIS
        Устанавливает подмену sethc.exe (залипание клавиш - 5x Shift) или utilman.exe (специальные возможности)
        на cmd.exe на выбранном диске с Windows для вызова консоли SYSTEM на экране входа.
        Автоматически сохраняет оригинальный файл в *.winpass.bak.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveRoot,

        [ValidateSet('sethc.exe', 'utilman.exe')]
        [string]$TargetBinary = 'sethc.exe'
    )

    $sys32 = Join-Path $DriveRoot 'Windows\System32'
    $targetPath = Join-Path $sys32 $TargetBinary
    $backupPath = Join-Path $sys32 "$TargetBinary.winpass.bak"
    $cmdPath    = Join-Path $sys32 'cmd.exe'

    if (-not (Test-Path $targetPath)) {
        throw "Системный файл не найден: $targetPath"
    }
    if (-not (Test-Path $cmdPath)) {
        throw "Файл cmd.exe не найден: $cmdPath"
    }

    # Получаем владение файлом и права для группы Администраторы (*S-1-5-32-544 работает на любом языке ОС)
    $null = & takeown.exe /f "$targetPath" 2>&1
    $null = & icacls.exe "$targetPath" /grant "*S-1-5-32-544:F" 2>&1

    # Сохраняем резервную копию только если она еще не создана, чтобы не перезаписать оригинал
    if (-not (Test-Path $backupPath)) {
        Copy-Item -Path $targetPath -Destination $backupPath -Force -ErrorAction Stop
    }

    Copy-Item -Path $cmdPath -Destination $targetPath -Force -ErrorAction Stop

    $hotkeyHint = if ($TargetBinary -eq 'sethc.exe') {
        'нажмите клавишу SHIFT 5 раз подряд'
    }
    else {
        'нажмите кнопку «Специальные возможности» в правом нижнем углу'
    }

    return "Офлайн-перехват ($TargetBinary) успешно установлен на диске $DriveRoot! Загрузите обычную Windows и на экране входа $hotkeyHint — откроется командная строка SYSTEM, откуда можно запустить WinPass-GUI.ps1 или команду net user."
}

function Restore-WinPassStickyKeysBypass {
    <#
    .SYNOPSIS
        Восстанавливает оригинальные системные файлы sethc.exe и utilman.exe из резервной копии *.winpass.bak.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveRoot
    )

    $sys32 = Join-Path $DriveRoot 'Windows\System32'
    $restored = New-Object System.Collections.Generic.List[string]

    foreach ($bin in @('sethc.exe', 'utilman.exe')) {
        $targetPath = Join-Path $sys32 $bin
        $backupPath = Join-Path $sys32 "$bin.winpass.bak"

        if (Test-Path $backupPath) {
            $null = & takeown.exe /f "$targetPath" 2>&1
            $null = & icacls.exe "$targetPath" /grant "*S-1-5-32-544:F" 2>&1
            Copy-Item -Path $backupPath -Destination $targetPath -Force -ErrorAction Stop
            Remove-Item -Path $backupPath -Force -ErrorAction SilentlyContinue
            $restored.Add($bin)
        }
    }

    if ($restored.Count -eq 0) {
        return "На диске $DriveRoot не обнаружено активных подмен (.winpass.bak). Системные файлы уже находятся в штатном состоянии."
    }

    return "Оригинальные системные файлы ($($restored -join ', ')) на диске $DriveRoot успешно восстановлены из резервной копии!"
}

function Reset-WinPassOfflinePinNgc {
    <#
    .SYNOPSIS
        Сбрасывает поврежденный или забытый контейнер ПИН-кода Windows Hello (папка Ngc)
        с сохранением резервной копии, позволяя войти по обычному паролю и заново задать ПИН-код.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DriveRoot
    )

    $ngcPath = Join-Path $DriveRoot 'Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc'
    $ngcBak  = Join-Path $DriveRoot 'Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc.winpass.bak'

    if (-not (Test-Path $ngcPath)) {
        return "Папка контейнера ПИН-кода Windows Hello (Ngc) на диске $DriveRoot не найдена или уже очищена."
    }

    $null = & takeown.exe /f "$ngcPath" /r /d y 2>&1
    $null = & icacls.exe "$ngcPath" /grant "*S-1-5-32-544:F" /t /c /q 2>&1

    if (Test-Path $ngcBak) {
        Remove-Item -Path $ngcBak -Recurse -Force -ErrorAction SilentlyContinue
    }

    Move-Item -Path $ngcPath -Destination $ngcBak -Force -ErrorAction Stop
    $null = New-Item -Path $ngcPath -ItemType Directory -Force

    return "Контейнер ПИН-кода Windows Hello (Ngc) на диске $DriveRoot успешно сброшен (резервная копия: Ngc.winpass.bak). Теперь вход возможен по стандартному паролю пользователя."
}

function Export-WinPassPortableUsb {
    <#
    .SYNOPSIS
        Копирует комплект WinPass Admin Suite в выбранную папку или на загрузочную флешку WinPE.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot,

        [Parameter(Mandatory = $true)]
        [string]$DestinationFolder
    )

    $targetDir = Join-Path $DestinationFolder 'WinPass-Admin'
    if (-not (Test-Path $targetDir)) {
        $null = New-Item -Path $targetDir -ItemType Directory -Force -ErrorAction Stop
    }

    foreach ($sub in @('modules', 'ui', 'logs')) {
        $p = Join-Path $targetDir $sub
        if (-not (Test-Path $p)) {
            $null = New-Item -Path $p -ItemType Directory -Force
        }
    }

    foreach ($rootFile in @('WinPass-GUI.ps1', 'WinPass-WinPE-GUI.ps1', 'Run-WinPass.bat', 'Start-WinPE.cmd', 'README.md')) {
        $srcFile = Join-Path $SourceRoot $rootFile
        if (Test-Path $srcFile) {
            Copy-Item -Path $srcFile -Destination $targetDir -Force
        }
    }

    Copy-Item -Path (Join-Path $SourceRoot 'modules\*.ps1') -Destination (Join-Path $targetDir 'modules') -Force
    Copy-Item -Path (Join-Path $SourceRoot 'ui\*.xaml') -Destination (Join-Path $targetDir 'ui') -Force

    return "Портативный пакет WinPass Admin Suite успешно скопирован в: $targetDir"
}
