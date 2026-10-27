# ==============================================================================
# WinPass Admin Suite v2.0 — Нативный графический интерфейс для среды WinPE
# Построен на System.Windows.Forms + System.Drawing (WinPE-NetFx совместимый,
# не требует DirectX / DWM, работает прямо с загрузочного ISO-образа WinPE)
# ==============================================================================

$ErrorActionPreference = 'Stop'

# Гарантируем режим STA
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $psExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    exit
}

$script:AppRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:AppRoot)) {
    $script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

foreach ($modFile in @('LocalAccounts.ps1', 'SavedCredentials.ps1', 'OfflineWinPE.ps1', 'PasswordPolicy.ps1', 'ReportExporter.ps1')) {
    $modPath = Join-Path (Join-Path $script:AppRoot 'modules') $modFile
    if (Test-Path $modPath) { . $modPath }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Цветовая палитра Dark Admin Theme
$cBgMain    = [System.Drawing.Color]::FromArgb(15, 23, 42)
$cBgCard    = [System.Drawing.Color]::FromArgb(30, 41, 59)
$cAccent    = [System.Drawing.Color]::FromArgb(2, 132, 199)
$cSuccess   = [System.Drawing.Color]::FromArgb(5, 150, 105)
$cWarning   = [System.Drawing.Color]::FromArgb(217, 119, 6)
$cSecondary = [System.Drawing.Color]::FromArgb(51, 65, 85)
$cTextLight = [System.Drawing.Color]::FromArgb(248, 250, 252)
$cTextMuted = [System.Drawing.Color]::FromArgb(148, 163, 184)

$fontTitle  = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$fontSub    = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
$fontNorm   = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Regular)
$fontBtn    = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$fontMono   = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)

function New-StyledButton {
    param(
        [string]$Text,
        [int]$X, [int]$Y, [int]$W, [int]$H = 36,
        [System.Drawing.Color]$BackColor = $cAccent
    )
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size = New-Object System.Drawing.Size($W, $H)
    $btn.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = $BackColor
    $btn.ForeColor = $cTextLight
    $btn.Font = $fontBtn
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $btn
}

function New-StyledGrid {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $dgv = New-Object System.Windows.Forms.DataGridView
    $dgv.Location = New-Object System.Drawing.Point($X, $Y)
    $dgv.Size = New-Object System.Drawing.Size($W, $H)
    $dgv.BackgroundColor = $cBgMain
    $dgv.ForeColor = $cTextLight
    $dgv.GridColor = $cSecondary
    $dgv.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $dgv.EnableHeadersVisualStyles = $false
    $dgv.ColumnHeadersDefaultCellStyle.BackColor = $cBgCard
    $dgv.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
    $dgv.ColumnHeadersDefaultCellStyle.Font = $fontBtn
    $dgv.ColumnHeadersHeight = 32
    $dgv.DefaultCellStyle.BackColor = $cBgCard
    $dgv.DefaultCellStyle.ForeColor = $cTextLight
    $dgv.DefaultCellStyle.SelectionBackColor = $cAccent
    $dgv.DefaultCellStyle.SelectionForeColor = $cTextLight
    $dgv.DefaultCellStyle.Font = $fontNorm
    $dgv.RowHeadersVisible = $false
    $dgv.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $dgv.MultiSelect = $false
    $dgv.ReadOnly = $true
    $dgv.AllowUserToAddRows = $false
    $dgv.AllowUserToDeleteRows = $false
    $dgv.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    return $dgv
}

# Главное окно
$form = New-Object System.Windows.Forms.Form
$form.Text = "WinPass Admin Suite v2.0 — Среда восстановления паролей Windows & WinPE"
$form.Size = New-Object System.Drawing.Size(1120, 740)
$form.MinimumSize = New-Object System.Drawing.Size(980, 660)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $cBgMain
$form.ForeColor = $cTextLight
$form.Font = $fontNorm

# Верхняя шапка
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlHeader.Height = 64
$pnlHeader.BackColor = $cBgCard
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "🔑 WinPass Admin Suite v2.0 (WinPE & Offline SAM Recovery Edition)"
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
$lblTitle.Location = New-Object System.Drawing.Point(18, 8)
$lblTitle.AutoSize = $true
$pnlHeader.Controls.Add($lblTitle)

$isWinPE = Test-IsWinPEEnvironment
$modeLabel = if ($isWinPE) { "Среда: Загрузочный образ WinPE (Offline SYSTEM)" } else { "Среда: Запущенная ОС Windows ($env:COMPUTERNAME)" }
$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "$modeLabel  |  Оператор: $env:USERNAME  |  Выберите диск с Windows и пользователя для сброса пароля"
$lblSub.ForeColor = $cTextMuted
$lblSub.Location = New-Object System.Drawing.Point(20, 36)
$lblSub.AutoSize = $true
$pnlHeader.Controls.Add($lblSub)

# Нижняя строка состояния
$pnlStatus = New-Object System.Windows.Forms.Panel
$pnlStatus.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlStatus.Height = 34
$pnlStatus.BackColor = $cBgCard
$form.Controls.Add($pnlStatus)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Готово к работе."
$lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(110, 231, 183)
$lblStatus.Location = New-Object System.Drawing.Point(16, 8)
$lblStatus.AutoSize = $true
$pnlStatus.Controls.Add($lblStatus)

function Set-WinPEStatus([string]$msg, [bool]$isError = $false) {
    $lblStatus.Text = $msg
    $lblStatus.ForeColor = if ($isError) { [System.Drawing.Color]::FromArgb(252, 165, 165) } else { [System.Drawing.Color]::FromArgb(110, 231, 183) }
}

# Основной TabControl
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(14, 74)
$tabs.Size = New-Object System.Drawing.Size(1076, 584)
$tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$tabs.Font = $fontSub
$form.Controls.Add($tabs)

# ==============================================================================
# ВКЛАДКА 1: ОФЛАЙН-СБРОС ПАРОЛЕЙ В КУСТЕ РЕЕСТРА SAM (ОСНОВНОЙ РЕЖИМ WINPE)
# ==============================================================================
$tabSam = New-Object System.Windows.Forms.TabPage("1. Офлайн-сброс паролей (Реестр SAM)")
$tabSam.BackColor = $cBgMain
$tabs.TabPages.Add($tabSam)

$lblDrives = New-Object System.Windows.Forms.Label
$lblDrives.Text = "Шаг 1. Обнаруженные разделы с установленной ОС Windows:"
$lblDrives.ForeColor = $cTextLight
$lblDrives.Location = New-Object System.Drawing.Point(14, 12)
$lblDrives.AutoSize = $true
$tabSam.Controls.Add($lblDrives)

$btnScanDrives = New-StyledButton -Text "🔄 Обновить список дисков" -X 830 -Y 6 -W 220 -H 32 -BackColor $cAccent
$tabSam.Controls.Add($btnScanDrives)

$gridDrives = New-StyledGrid -X 14 -Y 42 -W 1036 -H 130
$tabSam.Controls.Add($gridDrives)

$lblSamUsers = New-Object System.Windows.Forms.Label
$lblSamUsers.Text = "Шаг 2. Учетные записи пользователей в кусте Windows\System32\config\SAM выбранного диска:"
$lblSamUsers.ForeColor = $cTextLight
$lblSamUsers.Location = New-Object System.Drawing.Point(14, 184)
$lblSamUsers.AutoSize = $true
$tabSam.Controls.Add($lblSamUsers)

$btnLoadSam = New-StyledButton -Text "📂 Загрузить пользователей SAM" -X 790 -Y 178 -W 260 -H 32 -BackColor $cSecondary
$tabSam.Controls.Add($btnLoadSam)

$gridSamUsers = New-StyledGrid -X 14 -Y 216 -W 1036 -H 235
$tabSam.Controls.Add($gridSamUsers)

# Панель кнопок офлайн-действий с выбранным пользователем SAM
$btnClearPassSam = New-StyledButton -Text "🔑 Сбросить пароль на ПУСТОЙ + Разблокировать УЗ" -X 14 -Y 464 -W 370 -H 42 -BackColor $cSuccess
$tabSam.Controls.Add($btnClearPassSam)

$btnUnlockOnlySam = New-StyledButton -Text "🔓 Только включить и разблокировать УЗ" -X 394 -Y 464 -W 280 -H 42 -BackColor $cAccent
$tabSam.Controls.Add($btnUnlockOnlySam)

$btnEnableAdmin500 = New-StyledButton -Text "⚡ Активировать Админа (RID 500)" -X 684 -Y 464 -W 210 -H 42 -BackColor $cWarning
$tabSam.Controls.Add($btnEnableAdmin500)

$btnRestoreSamBak = New-StyledButton -Text "↩️ Откат SAM (.bak)" -X 904 -Y 464 -W 146 -H 42 -BackColor $cSecondary
$tabSam.Controls.Add($btnRestoreSamBak)

$lblSamHint = New-Object System.Windows.Forms.Label
$lblSamHint.Text = "Примечание: Перед любой модификацией автоматически создается резервная копия SAM.winpass.bak. После сброса пароля перезагрузите ПК."
$lblSamHint.ForeColor = $cTextMuted
$lblSamHint.Font = $fontNorm
$lblSamHint.Location = New-Object System.Drawing.Point(14, 514)
$lblSamHint.AutoSize = $true
$tabSam.Controls.Add($lblSamHint)

# ==============================================================================
# ВКЛАДКА 2: ПЕРЕХВАТ 5x SHIFT (SETHC), СБРОС ПИН-КОДА И ОФЛАЙН AUTOLOGON
# ==============================================================================
$tabOfflineTools = New-Object System.Windows.Forms.TabPage("2. Перехват 5x SHIFT / Сброс ПИН-кода")
$tabOfflineTools.BackColor = $cBgMain
$tabs.TabPages.Add($tabOfflineTools)

$lblBypassTitle = New-Object System.Windows.Forms.Label
$lblBypassTitle.Text = "Установка перехвата специальных возможностей (sethc.exe / utilman.exe) на выбранном диске"
$lblBypassTitle.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
$lblBypassTitle.Location = New-Object System.Drawing.Point(20, 20)
$lblBypassTitle.AutoSize = $true
$tabOfflineTools.Controls.Add($lblBypassTitle)

$lblBypassDesc = New-Object System.Windows.Forms.Label
$lblBypassDesc.Text = "Позволяет на экране входа обычной Windows нажать 5 раз клавишу SHIFT, чтобы открыть консоль SYSTEM и запустить WinPass-GUI.`r`nЭтот метод рекомендуется для учетных записей Microsoft Account и сохранения зашифрованных файлов EFS/DPAPI."
$lblBypassDesc.ForeColor = $cTextMuted
$lblBypassDesc.Font = $fontNorm
$lblBypassDesc.Location = New-Object System.Drawing.Point(20, 48)
$lblBypassDesc.Size = New-Object System.Drawing.Size(980, 44)
$tabOfflineTools.Controls.Add($lblBypassDesc)

$btnInstallSethc = New-StyledButton -Text "⚡ Установить перехват 5x SHIFT (sethc.exe) + скопировать WinPass на диск" -X 20 -Y 100 -W 520 -H 42 -BackColor $cWarning
$tabOfflineTools.Controls.Add($btnInstallSethc)

$btnRestoreSethc = New-StyledButton -Text "🛡️ Восстановить оригинальные sethc.exe и utilman.exe (.bak)" -X 555 -Y 100 -W 440 -H 42 -BackColor $cSuccess
$tabOfflineTools.Controls.Add($btnRestoreSethc)

$lblPinTitle = New-Object System.Windows.Forms.Label
$lblPinTitle.Text = "Сброс забытого или поврежденного ПИН-кода Windows Hello (контейнер Ngc)"
$lblPinTitle.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
$lblPinTitle.Location = New-Object System.Drawing.Point(20, 170)
$lblPinTitle.AutoSize = $true
$tabOfflineTools.Controls.Add($lblPinTitle)

$btnResetPinNgc = New-StyledButton -Text "🧹 Очистить контейнер ПИН-кода Windows Hello (с сохранением резервной копии Ngc.winpass.bak)" -X 20 -Y 204 -W 680 -H 42 -BackColor $cAccent
$tabOfflineTools.Controls.Add($btnResetPinNgc)

$lblOfflineAutoTitle = New-Object System.Windows.Forms.Label
$lblOfflineAutoTitle.Text = "Извлечение сохраненного пароля Winlogon AutoAdminLogon из офлайн-реестра SOFTWARE:"
$lblOfflineAutoTitle.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
$lblOfflineAutoTitle.Location = New-Object System.Drawing.Point(20, 274)
$lblOfflineAutoTitle.AutoSize = $true
$tabOfflineTools.Controls.Add($lblOfflineAutoTitle)

$btnReadOfflineAutoLogon = New-StyledButton -Text "🔍 Прочитать Winlogon DefaultPassword выбранного диска" -X 20 -Y 306 -W 430 -H 38 -BackColor $cSecondary
$tabOfflineTools.Controls.Add($btnReadOfflineAutoLogon)

$txtOfflineAutoResult = New-Object System.Windows.Forms.TextBox
$txtOfflineAutoResult.Multiline = $true
$txtOfflineAutoResult.ReadOnly = $true
$txtOfflineAutoResult.BackColor = $cBgCard
$txtOfflineAutoResult.ForeColor = $cTextLight
$txtOfflineAutoResult.Font = $fontMono
$txtOfflineAutoResult.Location = New-Object System.Drawing.Point(20, 354)
$txtOfflineAutoResult.Size = New-Object System.Drawing.Size(975, 140)
$tabOfflineTools.Controls.Add($txtOfflineAutoResult)

# ==============================================================================
# ВКЛАДКА 3: СЕРВИСНЫЕ ИНСТРУМЕНТЫ WINPE И УПРАВЛЕНИЕ ПИТАНИЕМ
# ==============================================================================
$tabUtilities = New-Object System.Windows.Forms.TabPage("3. Системные утилиты WinPE и Перезагрузка")
$tabUtilities.BackColor = $cBgMain
$tabs.TabPages.Add($tabUtilities)

$btnOpenCmd = New-StyledButton -Text "💻 Командная строка (cmd.exe)" -X 24 -Y 28 -W 310 -H 46 -BackColor $cSecondary
$tabUtilities.Controls.Add($btnOpenCmd)

$btnOpenRegedit = New-StyledButton -Text "🗂️ Редактор реестра (regedit.exe)" -X 354 -Y 28 -W 310 -H 46 -BackColor $cSecondary
$tabUtilities.Controls.Add($btnOpenRegedit)

$btnOpenNotepad = New-StyledButton -Text "📝 Блокнот (notepad.exe)" -X 684 -Y 28 -W 310 -H 46 -BackColor $cSecondary
$tabUtilities.Controls.Add($btnOpenNotepad)

$btnOpenTaskmgr = New-StyledButton -Text "📊 Диспетчер задач (taskmgr.exe)" -X 24 -Y 90 -W 310 -H 46 -BackColor $cSecondary
$tabUtilities.Controls.Add($btnOpenTaskmgr)

$btnRebootPc = New-StyledButton -Text "🔄 Перезагрузить компьютер (Reboot)" -X 354 -Y 90 -W 310 -H 46 -BackColor $cAccent
$tabUtilities.Controls.Add($btnRebootPc)

$btnShutdownPc = New-StyledButton -Text "⏻ Выключить компьютер (Shutdown)" -X 684 -Y 90 -W 310 -H 46 -BackColor $cWarning
$tabUtilities.Controls.Add($btnShutdownPc)

# ==============================================================================
# Логика работы таблиц и обработчики событий
# ==============================================================================
$script:WinInstalls = @()
$script:SamUsersList = @()

function Update-DrivesGrid {
    try {
        $script:WinInstalls = @(Get-WinPassOfflineWindowsInstallations)
        $dt = New-Object System.Data.DataTable
        [void]$dt.Columns.Add("Диск")
        [void]$dt.Columns.Add("Режим ОС")
        [void]$dt.Columns.Add("Статус sethc/utilman")
        [void]$dt.Columns.Add("Бэкап SAM")
        [void]$dt.Columns.Add("Путь к файлу SAM")

        foreach ($w in $script:WinInstalls) {
            $samBakTxt = if ($w.HasSamBackup) { "Есть (.winpass.bak)" } else { "Нет" }
            [void]$dt.Rows.Add($w.DriveLetter, $w.ModeText, $w.BypassStatusText, $samBakTxt, $w.SamPath)
        }
        $gridDrives.DataSource = $dt
        Set-WinPEStatus "Найдено установленных копий Windows: $($script:WinInstalls.Count)"

        if ($script:WinInstalls.Count -gt 0) {
            Update-SamUsersGrid -Index 0
        }
    }
    catch {
        Set-WinPEStatus "Ошибка поиска дисков: $($_.Exception.Message)" $true
    }
}

function Get-CurrentSelectedInstall {
    if ($script:WinInstalls.Count -eq 0) { return $null }
    $idx = if ($gridDrives.CurrentRow) { $gridDrives.CurrentRow.Index } else { 0 }
    if ($idx -ge 0 -and $idx -lt $script:WinInstalls.Count) {
        return $script:WinInstalls[$idx]
    }
    return $script:WinInstalls[0]
}

function Update-SamUsersGrid([int]$Index = -1) {
    $inst = if ($Index -ge 0 -and $Index -lt $script:WinInstalls.Count) { $script:WinInstalls[$Index] } else { Get-CurrentSelectedInstall }
    if ($null -eq $inst) { return }

    try {
        $script:SamUsersList = @(Get-WinPassOfflineSamUsers -SamHivePath $inst.SamPath)
        $dt = New-Object System.Data.DataTable
        [void]$dt.Columns.Add("Имя пользователя")
        [void]$dt.Columns.Add("RID")
        [void]$dt.Columns.Add("RID (Hex)")
        [void]$dt.Columns.Add("Статус УЗ")
        [void]$dt.Columns.Add("Состояние пароля в SAM")
        [void]$dt.Columns.Add("Блокировка")
        [void]$dt.Columns.Add("Ошибок входа")
        [void]$dt.Columns.Add("Флаги ACB")

        foreach ($u in $script:SamUsersList) {
            [void]$dt.Rows.Add($u.UserName, $u.RID, $u.RIDHex, $u.StatusText, $u.PasswordStateText, $u.LockedText, $u.FailedLogonCount, $u.ACBFlagsHex)
        }
        $gridSamUsers.DataSource = $dt
        Set-WinPEStatus "Из куста $($inst.SamPath) загружено пользователей: $($script:SamUsersList.Count)"
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
    }
}

function Get-CurrentSelectedSamUser {
    if ($script:SamUsersList.Count -eq 0 -or $null -eq $gridSamUsers.CurrentRow) {
        [System.Windows.Forms.MessageBox]::Show("Выберите пользователя в таблице учетных записей SAM.", "Внимание", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return $null
    }
    $idx = $gridSamUsers.CurrentRow.Index
    if ($idx -ge 0 -and $idx -lt $script:SamUsersList.Count) {
        return $script:SamUsersList[$idx]
    }
    return $null
}

$btnScanDrives.Add_Click({ Update-DrivesGrid })
$btnLoadSam.Add_Click({ Update-SamUsersGrid })

$btnClearPassSam.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    $u = Get-CurrentSelectedSamUser; if ($null -eq $u) { return }

    $ans = [System.Windows.Forms.MessageBox]::Show(
        "Сбросить пароль пользователя '$($u.UserName)' (RID $($u.RID)) на ПУСТОЙ (вход без пароля) и разблокировать учетную запись на диске $($inst.DriveLetter)?",
        "Подтверждение офлайн-сброса пароля в SAM",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        $msg = Clear-WinPassOfflineSamPassword -SamHivePath $inst.SamPath -RIDHex $u.RIDHex
        Set-WinPEStatus $msg
        Update-DrivesGrid
        Update-SamUsersGrid
        [System.Windows.Forms.MessageBox]::Show($msg, "Пароль успешно сброшен", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Ошибка", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnUnlockOnlySam.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    $u = Get-CurrentSelectedSamUser; if ($null -eq $u) { return }

    try {
        $msg = Unlock-WinPassOfflineSamUser -SamHivePath $inst.SamPath -RIDHex $u.RIDHex
        Set-WinPEStatus $msg
        Update-SamUsersGrid
        [System.Windows.Forms.MessageBox]::Show($msg, "Учетная запись разблокирована", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
    }
})

$btnEnableAdmin500.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    try {
        $msg = Clear-WinPassOfflineSamPassword -SamHivePath $inst.SamPath -RIDHex '000001F4'
        Set-WinPEStatus $msg
        Update-SamUsersGrid
        [System.Windows.Forms.MessageBox]::Show("Встроенный Администратор (RID 500 / 000001F4) активирован, разблокирован, пароль сброшен на пустой!`n`n$msg", "Администратор активирован", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
    }
})

$btnRestoreSamBak.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    try {
        $msg = Restore-WinPassOfflineSamBackup -SamHivePath $inst.SamPath
        Set-WinPEStatus $msg
        Update-DrivesGrid
        Update-SamUsersGrid
        [System.Windows.Forms.MessageBox]::Show($msg, "Откат SAM выполнен", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Ошибка", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
})

$btnInstallSethc.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    try {
        $msg1 = Install-WinPassStickyKeysBypass -DriveRoot $inst.DriveRoot -TargetBinary 'sethc.exe'
        $msg2 = Export-WinPassPortableUsb -SourceRoot $script:AppRoot -DestinationFolder $inst.DriveRoot
        Set-WinPEStatus "$msg1 | $msg2"
        Update-DrivesGrid
        [System.Windows.Forms.MessageBox]::Show("$msg1`n`n$msg2", "Готово", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
    }
})

$btnRestoreSethc.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    try {
        $msg = Restore-WinPassStickyKeysBypass -DriveRoot $inst.DriveRoot
        Set-WinPEStatus $msg
        Update-DrivesGrid
        [System.Windows.Forms.MessageBox]::Show($msg, "Восстановлено", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
    }
})

$btnResetPinNgc.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    try {
        $msg = Reset-WinPassOfflinePinNgc -DriveRoot $inst.DriveRoot
        Set-WinPEStatus $msg
        [System.Windows.Forms.MessageBox]::Show($msg, "Сброс ПИН-кода", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
    catch {
        Set-WinPEStatus $_.Exception.Message $true
    }
})

$btnReadOfflineAutoLogon.Add_Click({
    $inst = Get-CurrentSelectedInstall; if ($null -eq $inst) { return }
    try {
        $info = Get-WinPassOfflineAutoLogon -SoftwareHivePath $inst.SoftwarePath
        $txtOfflineAutoResult.Text = "Диск ОС           : $($inst.DriveLetter)`r`nAutoAdminLogon    : $($info.AutoAdminLogon)`r`nDefaultDomainName : $($info.DefaultDomainName)`r`nDefaultUserName   : $($info.DefaultUserName)`r`nDefaultPassword   : $($info.DefaultPassword)"
        Set-WinPEStatus "Данные Winlogon прочитаны из $($inst.SoftwarePath)"
    }
    catch {
        $txtOfflineAutoResult.Text = "Ошибка: $($_.Exception.Message)"
        Set-WinPEStatus $_.Exception.Message $true
    }
})

$btnOpenCmd.Add_Click({ Start-Process cmd.exe })
$btnOpenRegedit.Add_Click({ Start-Process regedit.exe })
$btnOpenNotepad.Add_Click({ Start-Process notepad.exe })
$btnOpenTaskmgr.Add_Click({ Start-Process taskmgr.exe })

$btnRebootPc.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show("Перезагрузить компьютер сейчас?", "Перезагрузка", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        if (Get-Command wpeutil.exe -ErrorAction SilentlyContinue) { & wpeutil.exe reboot } else { Restart-Computer -Force }
    }
})

$btnShutdownPc.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show("Выключить компьютер сейчас?", "Выключение", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($ans -eq [System.Windows.Forms.DialogResult]::Yes) {
        if (Get-Command wpeutil.exe -ErrorAction SilentlyContinue) { & wpeutil.exe shutdown } else { Stop-Computer -Force }
    }
})

$form.Add_Shown({
    Update-DrivesGrid
})

[void]$form.ShowDialog()
