# ==============================================================================
# WinPass Admin Suite v2.0 — Главное приложение (PowerShell + WPF GUI)
# Комплексный инструмент системного администратора для восстановления и сброса
# паролей пользователей Windows, извлечения паролей Wi-Fi/Vault и работы в WinPE
# ==============================================================================

param(
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'

# 1. Гарантируем запуск в режиме Single-Threaded Apartment (STA), необходимом для WPF
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $psExe = (Get-Process -Id $PID).Path
    $argList = "-NoProfile -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`""
    if ($NoElevate) { $argList += " -NoElevate" }
    Start-Process -FilePath $psExe -ArgumentList $argList
    exit
}

# 2. Загрузка модулей приложения
$script:AppRoot = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:AppRoot)) {
    $script:AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
}

$moduleFiles = @(
    'LocalAccounts.ps1',
    'SavedCredentials.ps1',
    'OfflineWinPE.ps1',
    'PasswordPolicy.ps1',
    'ReportExporter.ps1'
)

foreach ($modFile in $moduleFiles) {
    $modPath = Join-Path (Join-Path $script:AppRoot 'modules') $modFile
    if (-not (Test-Path $modPath)) {
        throw "Не найден обязательный модуль: $modPath"
    }
    . $modPath
}

# 3. Проверка прав Администратора и авто-запрос UAC (если не в среде WinPE)
$script:IsAdmin = Test-IsAdministrator
$script:IsWinPE = Test-IsWinPEEnvironment

if ((-not $script:IsAdmin) -and (-not $script:IsWinPE) -and (-not $NoElevate)) {
    try {
        $psExe = (Get-Process -Id $PID).Path
        $argList = "-NoProfile -ExecutionPolicy Bypass -STA -NoElevate -File `"$PSCommandPath`""
        Start-Process -FilePath $psExe -ArgumentList $argList -Verb RunAs
        exit
    }
    catch {
        # Если пользователь отменил запрос UAC, продолжаем запуск в режиме чтения с предупреждением
    }
}

# 4. Загрузка сборок WPF (или автоматическое переключение на WinForms GUI в среде WinPE)
$wpfLoaded = $false
if (-not $script:IsWinPE) {
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        Add-Type -AssemblyName WindowsBase -ErrorAction Stop
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $wpfLoaded = $true
    }
    catch {
        $wpfLoaded = $false
    }
}

if (-not $wpfLoaded) {
    $winpeGuiPath = Join-Path $script:AppRoot 'WinPass-WinPE-GUI.ps1'
    if (Test-Path $winpeGuiPath) {
        & $winpeGuiPath
        exit 0
    }
}

# 5. Загрузка XAML-интерфейса
$xamlPath = Join-Path (Join-Path $script:AppRoot 'ui') 'MainWindow.xaml'
if (-not (Test-Path $xamlPath)) {
    [System.Windows.MessageBox]::Show(
        "Не найден файл разметки интерфейса: $xamlPath",
        "Ошибка запуска WinPass Admin Suite",
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null
    exit 1
}

$xamlContent = [System.IO.File]::ReadAllText($xamlPath, [System.Text.Encoding]::UTF8)
$xmlReader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader($xamlContent)))
$script:Window = [System.Windows.Markup.XamlReader]::Load($xmlReader)

# 6. Привязка всех элементов управления WPF
$ui = @{}
$controlNames = @(
    'TxtSystemSummary', 'BadgeAdminMode', 'TxtAdminMode', 'BadgeEnvironment', 'TxtEnvironment',
    'BtnQuickExportHtml', 'MainTabControl', 'TxtStatusBar',
    'TxtSearchUser', 'ChkOnlyEnabledUsers', 'BtnRefreshUsers', 'GridLocalUsers',
    'BtnEnableUser', 'BtnDisableUser', 'BtnUnlockUser', 'BtnAddAdminGroup', 'BtnRemoveAdminGroup', 'BtnActivateBuiltInAdmin',
    'TxtSelectedUserHeader', 'TxtSelectedUserSid', 'TxtNewPassword', 'BtnGeneratePass', 'BtnCopyNewPass', 'TxtPasswordStrength',
    'TxtGenLengthVal', 'SliderPassLength', 'ChkGenUpper', 'ChkGenLower', 'ChkGenDigits', 'ChkGenSpecial',
    'ChkPassNeverExpires', 'ChkMustChangeNextLogon', 'ChkUnlockOnReset',
    'BtnApplyNewPassword', 'BtnSetBlankPassword', 'BtnSaveHandoverCard',
    'TxtEmergencyAdminName', 'TxtEmergencyAdminPass', 'BtnCreateEmergencyAdmin',
    'BtnRefreshWifi', 'BtnCopyWifiPass', 'BtnExportWifiCsv', 'GridWifiPasswords', 'TxtWifiSummary',
    'BtnRefreshCreds', 'BtnCopyCredPass', 'GridSavedCredentials',
    'TxtAutoLogonState', 'TxtAutoLogonCurrentUser', 'TxtAutoLogonCurrentPass', 'BtnReadAutoLogon',
    'TxtAutoLogonUser', 'TxtAutoLogonPass', 'BtnEnableAutoLogon', 'BtnDisableAutoLogon',
    'BtnScanOfflineDrives', 'GridOfflineInstallations',
    'BtnLoadOfflineSam', 'BtnClearOfflineSamPassword', 'BtnUnlockOfflineSamUser', 'GridOfflineSamUsers',
    'BtnInstallSethcBypass', 'BtnInstallUtilmanBypass', 'BtnRestoreOfflineBypass',
    'BtnResetOfflinePin', 'TxtUsbTargetPath', 'BtnExportPortableUsb',
    'TxtPolicyMinLen', 'TxtPolicyMaxAge', 'TxtPolicyLockout', 'ChkPolicyComplexity',
    'BtnRefreshPolicy', 'BtnApplyPolicy',
    'BtnPresetHomeRelaxed', 'BtnPresetStandardWin', 'BtnPresetEnterprise',
    'BtnExportFullHtmlReport', 'BtnOpenLogsFolder', 'GridAuditLog'
)

foreach ($name in $controlNames) {
    $ctrl = $script:Window.FindName($name)
    if ($null -eq $ctrl) {
        throw "Элемент управления '$name' не найден в XAML!"
    }
    $ui[$name] = $ctrl
}

# Путь к файлу журнала аудита
$script:LogFile = Join-Path (Join-Path $script:AppRoot 'logs') 'winpass_audit.log'
$script:AllLoadedUsers = @()
$script:CachedWifiList = @()
$script:CachedCredList = @()

# ==============================================================================
# Вспомогательные функции обновления UI и логирования
# ==============================================================================
function Set-AppStatus {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO',
        [string]$AuditAction = ''
    )

    $ui['TxtStatusBar'].Text = $Message
    $brushConv = New-Object System.Windows.Media.BrushConverter
    switch ($Level) {
        'SUCCESS' { $ui['TxtStatusBar'].Foreground = $brushConv.ConvertFromString('#6EE7B7') }
        'WARNING' { $ui['TxtStatusBar'].Foreground = $brushConv.ConvertFromString('#FCD34D') }
        'ERROR'   { $ui['TxtStatusBar'].Foreground = $brushConv.ConvertFromString('#FCA5A5') }
        default   { $ui['TxtStatusBar'].Foreground = $brushConv.ConvertFromString('#CBD5E1') }
    }

    if (-not [string]::IsNullOrEmpty($AuditAction)) {
        $null = Write-WinPassAuditLog -Action $AuditAction -Details $Message -Level $Level -LogFilePath $script:LogFile
        $ui['GridAuditLog'].ItemsSource = $null
        $ui['GridAuditLog'].ItemsSource = @(Get-WinPassAuditLog)
    }
}

function Update-HeaderSummary {
    $osCaption = 'Microsoft Windows'
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($os) {
            $osCaption = "$($os.Caption) (Build $($os.BuildNumber))"
        }
    }
    catch { }

    $ui['TxtSystemSummary'].Text = "ПК: $env:COMPUTERNAME  •  Оператор: $env:USERDOMAIN\$env:USERNAME  •  ОС: $osCaption"

    $brushConv = New-Object System.Windows.Media.BrushConverter
    if ($script:IsAdmin) {
        $ui['TxtAdminMode'].Text = 'Права: Администратор'
        $ui['BadgeAdminMode'].Background = $brushConv.ConvertFromString('#065F46')
        $ui['TxtAdminMode'].Foreground = $brushConv.ConvertFromString('#6EE7B7')
    }
    else {
        $ui['TxtAdminMode'].Text = 'Права: Ограниченные (Без UAC)'
        $ui['BadgeAdminMode'].Background = $brushConv.ConvertFromString('#7F1D1D')
        $ui['TxtAdminMode'].Foreground = $brushConv.ConvertFromString('#FCA5A5')
    }

    if ($script:IsWinPE) {
        $ui['TxtEnvironment'].Text = 'Среда: WinPE / WinRE (Офлайн)'
        $ui['BadgeEnvironment'].Background = $brushConv.ConvertFromString('#78350F')
        $ui['TxtEnvironment'].Foreground = $brushConv.ConvertFromString('#FDE68A')
    }
    else {
        $ui['TxtEnvironment'].Text = 'Режим: Запущенная ОС (Online)'
    }
}

# ==============================================================================
# ВКЛАДКА 1: Управление локальными пользователями и сброс паролей
# ==============================================================================
function Refresh-UsersTable {
    try {
        $onlyEnabled = ($ui['ChkOnlyEnabledUsers'].IsChecked -eq $true)
        $script:AllLoadedUsers = @(Get-WinPassLocalUsers -OnlyEnabled:$onlyEnabled)
        Apply-UserSearchFilter
        Set-AppStatus -Message "Загружено учетных записей пользователей: $($script:AllLoadedUsers.Count)" -Level 'INFO'
    }
    catch {
        Set-AppStatus -Message "Ошибка чтения пользователей: $($_.Exception.Message)" -Level 'ERROR' -AuditAction 'Чтение пользователей'
    }
}

function Apply-UserSearchFilter {
    $query = $ui['TxtSearchUser'].Text.Trim()
    if ([string]::IsNullOrEmpty($query)) {
        $filtered = $script:AllLoadedUsers
    }
    else {
        $filtered = @($script:AllLoadedUsers | Where-Object {
            ($_.Name -match [regex]::Escape($query)) -or
            ($_.FullName -match [regex]::Escape($query)) -or
            ($_.Description -match [regex]::Escape($query)) -or
            ($_.RoleText -match [regex]::Escape($query))
        })
    }
    $ui['GridLocalUsers'].ItemsSource = $null
    $ui['GridLocalUsers'].ItemsSource = $filtered
    if ($filtered.Count -gt 0 -and $null -eq $ui['GridLocalUsers'].SelectedItem) {
        $ui['GridLocalUsers'].SelectedIndex = 0
    }
}

function Get-SelectedLocalUser {
    $sel = $ui['GridLocalUsers'].SelectedItem
    if ($null -eq $sel) {
        [System.Windows.MessageBox]::Show(
            "Пожалуйста, выберите пользователя в таблице слева.",
            "Пользователь не выбран",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Warning
        ) | Out-Null
        return $null
    }
    return $sel
}

$ui['GridLocalUsers'].Add_SelectionChanged({
    $sel = $ui['GridLocalUsers'].SelectedItem
    if ($null -ne $sel) {
        $ui['TxtSelectedUserHeader'].Text = "Выбран пользователь: $($sel.Name) ($($sel.RoleText))"
        $ui['TxtSelectedUserSid'].Text = "SID: $($sel.SID)  |  Статус: $($sel.StatusText)"
        $ui['ChkPassNeverExpires'].IsChecked = [bool]$sel.PasswordNeverExpires
        $ui['TxtAutoLogonUser'].Text = $sel.Name
    }
})

$ui['TxtSearchUser'].Add_TextChanged({ Apply-UserSearchFilter })
$ui['ChkOnlyEnabledUsers'].Add_Click({ Refresh-UsersTable })
$ui['BtnRefreshUsers'].Add_Click({ Refresh-UsersTable })

$ui['SliderPassLength'].Add_ValueChanged({
    $len = [int]$ui['SliderPassLength'].Value
    if ($ui['TxtGenLengthVal']) {
        $ui['TxtGenLengthVal'].Text = "$len символов"
    }
})

$ui['TxtNewPassword'].Add_TextChanged({
    $info = Get-PasswordStrengthInfo -Password $ui['TxtNewPassword'].Text
    $ui['TxtPasswordStrength'].Text = "Надежность: $($info.Label) ($($info.Score)%)"
    $brushConv = New-Object System.Windows.Media.BrushConverter
    $ui['TxtPasswordStrength'].Foreground = $brushConv.ConvertFromString($info.Color)
})

$ui['BtnGeneratePass'].Add_Click({
    $len = [int]$ui['SliderPassLength'].Value
    $pass = New-WinPassRandomPassword `
        -Length $len `
        -IncludeUpper ($ui['ChkGenUpper'].IsChecked -eq $true) `
        -IncludeLower ($ui['ChkGenLower'].IsChecked -eq $true) `
        -IncludeDigits ($ui['ChkGenDigits'].IsChecked -eq $true) `
        -IncludeSpecial ($ui['ChkGenSpecial'].IsChecked -eq $true)
    $ui['TxtNewPassword'].Text = $pass
    Set-AppStatus -Message "Сгенерирован новый криптостойкий пароль длиной $len символов." -Level 'INFO'
})

$ui['BtnCopyNewPass'].Add_Click({
    $p = $ui['TxtNewPassword'].Text
    if (-not [string]::IsNullOrEmpty($p)) {
        [System.Windows.Clipboard]::SetText($p)
        Set-AppStatus -Message "Пароль скопирован в буфер обмена." -Level 'SUCCESS'
    }
})

# Взаимоисключение флажков PasswordNeverExpires и MustChangeNextLogon
$ui['ChkMustChangeNextLogon'].Add_Click({
    if ($ui['ChkMustChangeNextLogon'].IsChecked -eq $true) {
        $ui['ChkPassNeverExpires'].IsChecked = $false
    }
})
$ui['ChkPassNeverExpires'].Add_Click({
    if ($ui['ChkPassNeverExpires'].IsChecked -eq $true) {
        $ui['ChkMustChangeNextLogon'].IsChecked = $false
    }
})

# Установка нового пароля
$ui['BtnApplyNewPassword'].Add_Click({
    $sel = Get-SelectedLocalUser
    if ($null -eq $sel) { return }

    $newPass = $ui['TxtNewPassword'].Text
    if ([string]::IsNullOrEmpty($newPass)) {
        $ans = [System.Windows.MessageBox]::Show(
            "Поле пароля пустое. Вы хотите установить ПУСТОЙ пароль (вход без пароля) для пользователя '$($sel.Name)'?",
            "Подтверждение пустого пароля",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Question
        )
        if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    }

    try {
        $res = Reset-WinPassUserPassword `
            -UserName $sel.Name `
            -NewPassword $newPass `
            -PasswordNeverExpires ($ui['ChkPassNeverExpires'].IsChecked -eq $true) `
            -MustChangeAtNextLogon ($ui['ChkMustChangeNextLogon'].IsChecked -eq $true) `
            -UnlockAndEnable ($ui['ChkUnlockOnReset'].IsChecked -eq $true)

        Set-AppStatus -Message "Пароль для '$($sel.Name)' успешно установлен: $($res.Message)" -Level 'SUCCESS' -AuditAction "Сброс пароля ($($sel.Name))"
        Refresh-UsersTable
        [System.Windows.MessageBox]::Show(
            "Пароль пользователя '$($sel.Name)' успешно изменен!`n`nПодробности: $($res.Message)",
            "Сброс пароля выполнен",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        ) | Out-Null
    }
    catch {
        Set-AppStatus -Message "Ошибка сброса пароля '$($sel.Name)': $($_.Exception.Message)" -Level 'ERROR' -AuditAction "Ошибка сброса пароля ($($sel.Name))"
        [System.Windows.MessageBox]::Show(
            "Не удалось изменить пароль для '$($sel.Name)':`n$($_.Exception.Message)`n`nСовет: Если пароль не проходит политику сложности, перейдите на вкладку «5. Политики безопасности паролей» и нажмите «Домашний / Сервисный режим».",
            "Ошибка смены пароля",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Error
        ) | Out-Null
    }
})

# Сброс на пустой пароль (без пароля)
$ui['BtnSetBlankPassword'].Add_Click({
    $sel = Get-SelectedLocalUser
    if ($null -eq $sel) { return }

    $ans = [System.Windows.MessageBox]::Show(
        "Сбросить пароль пользователя '$($sel.Name)' на ПУСТОЙ (разрешить вход без пароля)?",
        "Сброс пароля",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Warning
    )
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }

    try {
        $ui['TxtNewPassword'].Text = ''
        $res = Reset-WinPassUserPassword `
            -UserName $sel.Name `
            -NewPassword '' `
            -PasswordNeverExpires $true `
            -MustChangeAtNextLogon $false `
            -UnlockAndEnable $true

        Set-AppStatus -Message "Пароль пользователя '$($sel.Name)' успешно сброшен (вход без пароля)." -Level 'SUCCESS' -AuditAction "Сброс на пустой пароль ($($sel.Name))"
        Refresh-UsersTable
    }
    catch {
        Set-AppStatus -Message "Ошибка установки пустого пароля: $($_.Exception.Message)" -Level 'ERROR' -AuditAction "Ошибка пустого пароля ($($sel.Name))"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

# Сохранение карточки-памятки для пользователя
$ui['BtnSaveHandoverCard'].Add_Click({
    $sel = Get-SelectedLocalUser
    if ($null -eq $sel) { return }

    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = "Сохранить карточку доступа пользователя"
    $dlg.Filter = "Текстовый файл (*.txt)|*.txt"
    $dlg.FileName = "Пароль_$($sel.Name)_$($env:COMPUTERNAME).txt"

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $null = Export-WinPassUserHandoverCard `
                -OutputPath $dlg.FileName `
                -UserName $sel.Name `
                -NewPassword $ui['TxtNewPassword'].Text `
                -MustChangeAtLogon ($ui['ChkMustChangeNextLogon'].IsChecked -eq $true)
            Set-AppStatus -Message "Карточка-памятка для '$($sel.Name)' сохранена: $($dlg.FileName)" -Level 'SUCCESS' -AuditAction "Экспорт памятки ($($sel.Name))"
        }
        catch {
            Set-AppStatus -Message "Ошибка сохранения памятки: $($_.Exception.Message)" -Level 'ERROR'
        }
    }
})

# Быстрые кнопки управления статусом и группами
$ui['BtnEnableUser'].Add_Click({
    $sel = Get-SelectedLocalUser; if ($null -eq $sel) { return }
    try {
        $msg = Set-WinPassAccountState -UserName $sel.Name -Action 'Enable'
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Включение УЗ ($($sel.Name))"
        Refresh-UsersTable
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

$ui['BtnDisableUser'].Add_Click({
    $sel = Get-SelectedLocalUser; if ($null -eq $sel) { return }
    try {
        $msg = Set-WinPassAccountState -UserName $sel.Name -Action 'Disable'
        Set-AppStatus -Message $msg -Level 'WARNING' -AuditAction "Отключение УЗ ($($sel.Name))"
        Refresh-UsersTable
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

$ui['BtnUnlockUser'].Add_Click({
    $sel = Get-SelectedLocalUser; if ($null -eq $sel) { return }
    try {
        $msg = Set-WinPassAccountState -UserName $sel.Name -Action 'Unlock'
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Разблокировка УЗ ($($sel.Name))"
        Refresh-UsersTable
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

$ui['BtnAddAdminGroup'].Add_Click({
    $sel = Get-SelectedLocalUser; if ($null -eq $sel) { return }
    try {
        $msg = Set-WinPassAdminMembership -UserName $sel.Name -Operation 'Add'
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Назначение прав Админа ($($sel.Name))"
        Refresh-UsersTable
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

$ui['BtnRemoveAdminGroup'].Add_Click({
    $sel = Get-SelectedLocalUser; if ($null -eq $sel) { return }
    try {
        $msg = Set-WinPassAdminMembership -UserName $sel.Name -Operation 'Remove'
        Set-AppStatus -Message $msg -Level 'WARNING' -AuditAction "Удаление из Админов ($($sel.Name))"
        Refresh-UsersTable
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

$ui['BtnActivateBuiltInAdmin'].Add_Click({
    try {
        $msg = Enable-WinPassBuiltInAdmin -NewPassword $ui['TxtNewPassword'].Text
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction 'Активация встроенного Администратора (RID 500)'
        Refresh-UsersTable
        [System.Windows.MessageBox]::Show($msg, "Встроенный Администратор", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' -AuditAction 'Ошибка активации RID 500'
    }
})

$ui['BtnCreateEmergencyAdmin'].Add_Click({
    $uName = $ui['TxtEmergencyAdminName'].Text.Trim()
    $uPass = $ui['TxtEmergencyAdminPass'].Text
    if ([string]::IsNullOrEmpty($uName)) {
        [System.Windows.MessageBox]::Show("Укажите имя создаваемого администратора.", "Внимание", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }
    try {
        $msg = New-WinPassEmergencyAdmin -UserName $uName -Password $uPass
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Создание резервного админа ($uName)"
        Refresh-UsersTable
        [System.Windows.MessageBox]::Show($msg, "Готово", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message "Ошибка создания администратора: $($_.Exception.Message)" -Level 'ERROR' -AuditAction "Ошибка создания админа ($uName)"
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

# ==============================================================================
# ВКЛАДКА 2: Сохраненные пароли Wi-Fi
# ==============================================================================
$ui['BtnRefreshWifi'].Add_Click({
    try {
        $script:CachedWifiList = @(Get-WinPassWifiPasswords)
        $ui['GridWifiPasswords'].ItemsSource = $null
        $ui['GridWifiPasswords'].ItemsSource = $script:CachedWifiList
        $ui['TxtWifiSummary'].Text = "Найдено сохраненных беспроводных профилей Wi-Fi: $($script:CachedWifiList.Count)"
        Set-AppStatus -Message "Извлечено профилей Wi-Fi: $($script:CachedWifiList.Count)" -Level 'SUCCESS' -AuditAction 'Сканирование паролей Wi-Fi'
    }
    catch {
        Set-AppStatus -Message "Ошибка чтения Wi-Fi профилей: $($_.Exception.Message)" -Level 'ERROR'
    }
})

$ui['BtnCopyWifiPass'].Add_Click({
    $sel = $ui['GridWifiPasswords'].SelectedItem
    if ($null -ne $sel -and (-not [string]::IsNullOrEmpty($sel.Password))) {
        [System.Windows.Clipboard]::SetText($sel.Password)
        Set-AppStatus -Message "Пароль сети Wi-Fi '$($sel.SSID)' скопирован в буфер обмена." -Level 'SUCCESS'
    }
})

$ui['BtnExportWifiCsv'].Add_Click({
    if ($script:CachedWifiList.Count -eq 0) {
        $script:CachedWifiList = @(Get-WinPassWifiPasswords)
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = "Экспорт паролей Wi-Fi в CSV"
    $dlg.Filter = "CSV файл (*.csv)|*.csv"
    $dlg.FileName = "WiFi_Passwords_$($env:COMPUTERNAME).csv"

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:CachedWifiList | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
        Set-AppStatus -Message "Список паролей Wi-Fi экспортирован в $($dlg.FileName)" -Level 'SUCCESS' -AuditAction 'Экспорт Wi-Fi в CSV'
    }
})

# ==============================================================================
# ВКЛАДКА 3: Диспетчер учетных данных Windows (Vault) и AutoLogon
# ==============================================================================
function Refresh-AutoLogonPanel {
    $info = Get-WinPassAutoLogonInfo
    $ui['TxtAutoLogonState'].Text = if ($info.Enabled) { 'Статус AutoLogon: ВКЛЮЧЕН (AutoAdminLogon = 1)' } else { 'Статус AutoLogon: Отключен' }
    $ui['TxtAutoLogonCurrentUser'].Text = "Пользователь в реестре: $(if ($info.DefaultUserName) { "$($info.DefaultDomainName)\$($info.DefaultUserName)" } else { 'Не задан' })"
    $ui['TxtAutoLogonCurrentPass'].Text = "Сохраненный пароль: $($info.DefaultPassword)"
    if ($info.DefaultUserName) {
        $ui['TxtAutoLogonUser'].Text = $info.DefaultUserName
    }
}

$ui['BtnRefreshCreds'].Add_Click({
    try {
        $script:CachedCredList = @(Get-WinPassSavedCredentials)
        $ui['GridSavedCredentials'].ItemsSource = $null
        $ui['GridSavedCredentials'].ItemsSource = $script:CachedCredList
        Refresh-AutoLogonPanel
        Set-AppStatus -Message "Извлечено записей из хранилища Windows Credential Manager / Vault: $($script:CachedCredList.Count)" -Level 'SUCCESS' -AuditAction 'Чтение Credential Manager'
    }
    catch {
        Set-AppStatus -Message "Ошибка чтения хранилища учетных данных: $($_.Exception.Message)" -Level 'ERROR'
    }
})

$ui['BtnCopyCredPass'].Add_Click({
    $sel = $ui['GridSavedCredentials'].SelectedItem
    if ($null -ne $sel -and (-not [string]::IsNullOrEmpty($sel.Password))) {
        [System.Windows.Clipboard]::SetText($sel.Password)
        Set-AppStatus -Message "Секрет для '$($sel.Target)' скопирован в буфер обмена." -Level 'SUCCESS'
    }
})

$ui['BtnReadAutoLogon'].Add_Click({
    Refresh-AutoLogonPanel
    Set-AppStatus -Message "Настройки Winlogon AutoAdminLogon прочитаны из реестра." -Level 'INFO'
})

$ui['BtnEnableAutoLogon'].Add_Click({
    try {
        $msg = Set-WinPassAutoLogon -Enable $true -UserName $ui['TxtAutoLogonUser'].Text.Trim() -Password $ui['TxtAutoLogonPass'].Text
        Refresh-AutoLogonPanel
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction 'Включение AutoLogon'
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
    }
})

$ui['BtnDisableAutoLogon'].Add_Click({
    try {
        $msg = Set-WinPassAutoLogon -Enable $false
        Refresh-AutoLogonPanel
        Set-AppStatus -Message $msg -Level 'WARNING' -AuditAction 'Отключение AutoLogon'
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
    }
})

# ==============================================================================
# ВКЛАДКА 4: Режим WinPE и Офлайн-инструменты восстановления
# ==============================================================================
function Refresh-OfflineInstallations {
    try {
        $installs = @(Get-WinPassOfflineWindowsInstallations)
        $ui['GridOfflineInstallations'].ItemsSource = $null
        $ui['GridOfflineInstallations'].ItemsSource = $installs
        if ($installs.Count -gt 0) {
            $ui['GridOfflineInstallations'].SelectedIndex = 0
        }
        Set-AppStatus -Message "Найдено копий Windows на дисках: $($installs.Count)" -Level 'INFO'
    }
    catch {
        Set-AppStatus -Message "Ошибка поиска дисков Windows: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Get-SelectedOfflineWindows {
    $sel = $ui['GridOfflineInstallations'].SelectedItem
    if ($null -eq $sel) {
        [System.Windows.MessageBox]::Show("Выберите раздел с установленной Windows в верхней таблице.", "Диск не выбран", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return $null
    }
    return $sel
}

$ui['BtnScanOfflineDrives'].Add_Click({ Refresh-OfflineInstallations })

$ui['BtnLoadOfflineSam'].Add_Click({
    $win = Get-SelectedOfflineWindows
    if ($null -eq $win) { return }

    try {
        $samUsers = @(Get-WinPassOfflineSamUsers -SamHivePath $win.SamPath)
        $ui['GridOfflineSamUsers'].ItemsSource = $null
        $ui['GridOfflineSamUsers'].ItemsSource = $samUsers
        Set-AppStatus -Message "Из офлайн-куста SAM ($($win.SamPath)) загружено пользователей: $($samUsers.Count)" -Level 'SUCCESS' -AuditAction "Чтение офлайн SAM ($($win.DriveLetter))"
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'WARNING'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Чтение куста SAM", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
})

$ui['BtnClearOfflineSamPassword'].Add_Click({
    $win = Get-SelectedOfflineWindows
    if ($null -eq $win) { return }

    $samUser = $ui['GridOfflineSamUsers'].SelectedItem
    if ($null -eq $samUser) {
        [System.Windows.MessageBox]::Show("Сначала нажмите «Прочитать SAM» и выберите пользователя в нижней таблице.", "Пользователь SAM не выбран", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    $ans = [System.Windows.MessageBox]::Show(
        "Сбросить пароль пользователя '$($samUser.UserName)' (RID $($samUser.RID)) в офлайн-кусте SAM на ПУСТОЙ (вход без пароля) и разблокировать УЗ?",
        "Подтверждение офлайн-сброса пароля в SAM",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }

    try {
        $msg = Clear-WinPassOfflineSamPassword -SamHivePath $win.SamPath -RIDHex $samUser.RIDHex
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Офлайн-сброс пароля в SAM ($($samUser.UserName))"
        $samUsers = @(Get-WinPassOfflineSamUsers -SamHivePath $win.SamPath)
        $ui['GridOfflineSamUsers'].ItemsSource = $null
        $ui['GridOfflineSamUsers'].ItemsSource = $samUsers
        [System.Windows.MessageBox]::Show($msg, "Пароль в SAM сброшен", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка модификации SAM", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

$ui['BtnUnlockOfflineSamUser'].Add_Click({
    $win = Get-SelectedOfflineWindows
    if ($null -eq $win) { return }

    $samUser = $ui['GridOfflineSamUsers'].SelectedItem
    if ($null -eq $samUser) {
        [System.Windows.MessageBox]::Show("Сначала нажмите «Прочитать куст SAM» и выберите пользователя в нижней таблице.", "Пользователь SAM не выбран", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
        return
    }

    try {
        $msg = Unlock-WinPassOfflineSamUser -SamHivePath $win.SamPath -RIDHex $samUser.RIDHex
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Разблокировка офлайн SAM ($($samUser.UserName))"
        $samUsers = @(Get-WinPassOfflineSamUsers -SamHivePath $win.SamPath)
        $ui['GridOfflineSamUsers'].ItemsSource = $null
        $ui['GridOfflineSamUsers'].ItemsSource = $samUsers
        [System.Windows.MessageBox]::Show($msg, "Успешно", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка модификации SAM", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

$ui['BtnInstallSethcBypass'].Add_Click({
    $win = Get-SelectedOfflineWindows; if ($null -eq $win) { return }
    try {
        $msg = Install-WinPassStickyKeysBypass -DriveRoot $win.DriveRoot -TargetBinary 'sethc.exe'
        Set-AppStatus -Message $msg -Level 'WARNING' -AuditAction "Установка перехвата sethc.exe ($($win.DriveLetter))"
        Refresh-OfflineInstallations
        [System.Windows.MessageBox]::Show($msg, "Перехват 5x SHIFT установлен", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

$ui['BtnInstallUtilmanBypass'].Add_Click({
    $win = Get-SelectedOfflineWindows; if ($null -eq $win) { return }
    try {
        $msg = Install-WinPassStickyKeysBypass -DriveRoot $win.DriveRoot -TargetBinary 'utilman.exe'
        Set-AppStatus -Message $msg -Level 'WARNING' -AuditAction "Установка перехвата utilman.exe ($($win.DriveLetter))"
        Refresh-OfflineInstallations
        [System.Windows.MessageBox]::Show($msg, "Перехват Utilman установлен", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

$ui['BtnRestoreOfflineBypass'].Add_Click({
    $win = Get-SelectedOfflineWindows; if ($null -eq $win) { return }
    try {
        $msg = Restore-WinPassStickyKeysBypass -DriveRoot $win.DriveRoot
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Восстановление sethc/utilman ($($win.DriveLetter))"
        Refresh-OfflineInstallations
        [System.Windows.MessageBox]::Show($msg, "Восстановление завершено", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
    }
})

$ui['BtnResetOfflinePin'].Add_Click({
    $win = Get-SelectedOfflineWindows; if ($null -eq $win) { return }
    $ans = [System.Windows.MessageBox]::Show(
        "Сбросить контейнер ПИН-кода Windows Hello (папка Ngc) на диске $($win.DriveLetter)? Резервная копия будет сохранена в Ngc.winpass.bak.",
        "Сброс ПИН-кода Windows Hello",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }

    try {
        $msg = Reset-WinPassOfflinePinNgc -DriveRoot $win.DriveRoot
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Сброс ПИН-кода NGC ($($win.DriveLetter))"
        [System.Windows.MessageBox]::Show($msg, "ПИН-код сброшен", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка сброса NGC", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

$ui['BtnExportPortableUsb'].Add_Click({
    $targetPath = $ui['TxtUsbTargetPath'].Text.Trim()
    if ([string]::IsNullOrEmpty($targetPath)) { return }
    try {
        $msg = Export-WinPassPortableUsb -SourceRoot $script:AppRoot -DestinationFolder $targetPath
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction "Запись портативного пакета ($targetPath)"
        [System.Windows.MessageBox]::Show($msg, "Экспорт завершен", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
        [System.Windows.MessageBox]::Show($_.Exception.Message, "Ошибка копирования", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error) | Out-Null
    }
})

# ==============================================================================
# ВКЛАДКА 5: Локальные политики паролей
# ==============================================================================
function Refresh-PasswordPolicyUI {
    try {
        $pol = Get-WinPassPasswordPolicy
        $ui['TxtPolicyMinLen'].Text = "$($pol.MinimumPasswordLength)"
        $maxAgeVal = if ($pol.MaximumPasswordAge -lt 0) { 0 } else { $pol.MaximumPasswordAge }
        $ui['TxtPolicyMaxAge'].Text = "$maxAgeVal"
        $ui['TxtPolicyLockout'].Text = "$($pol.LockoutBadCount)"
        $ui['ChkPolicyComplexity'].IsChecked = [bool]$pol.PasswordComplexity
    }
    catch { }
}

$ui['BtnRefreshPolicy'].Add_Click({
    Refresh-PasswordPolicyUI
    Set-AppStatus -Message "Параметры локальной политики паролей обновлены." -Level 'INFO'
})

$ui['BtnApplyPolicy'].Add_Click({
    try {
        $minLen  = [int]$ui['TxtPolicyMinLen'].Text
        $maxAge  = [int]$ui['TxtPolicyMaxAge'].Text
        $lockout = [int]$ui['TxtPolicyLockout'].Text
        $complex = ($ui['ChkPolicyComplexity'].IsChecked -eq $true)

        $msg = Set-WinPassPasswordPolicy -MinPasswordLength $minLen -MaxPasswordAgeDays $maxAge -LockoutThreshold $lockout -RequireComplexity $complex
        Refresh-PasswordPolicyUI
        Set-AppStatus -Message $msg -Level 'SUCCESS' -AuditAction 'Изменение политики паролей'
    }
    catch {
        Set-AppStatus -Message $_.Exception.Message -Level 'ERROR'
    }
})

$ui['BtnPresetHomeRelaxed'].Add_Click({
    try {
        $msg = Set-WinPassPasswordPolicy -MinPasswordLength 0 -MaxPasswordAgeDays 0 -LockoutThreshold 0 -RequireComplexity $false
        Refresh-PasswordPolicyUI
        Set-AppStatus -Message "Применен сервисный режим: разрешены простые и пустые пароли без срока действия." -Level 'SUCCESS' -AuditAction 'Пресет политики: Сервисный режим'
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

$ui['BtnPresetStandardWin'].Add_Click({
    try {
        $msg = Set-WinPassPasswordPolicy -MinPasswordLength 8 -MaxPasswordAgeDays 42 -LockoutThreshold 0 -RequireComplexity $false
        Refresh-PasswordPolicyUI
        Set-AppStatus -Message "Применена стандартная политика Windows (мин. длина 8 символов)." -Level 'SUCCESS' -AuditAction 'Пресет политики: Стандартный'
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

$ui['BtnPresetEnterprise'].Add_Click({
    try {
        $msg = Set-WinPassPasswordPolicy -MinPasswordLength 10 -MaxPasswordAgeDays 90 -LockoutThreshold 5 -RequireComplexity $true
        Refresh-PasswordPolicyUI
        Set-AppStatus -Message "Применена корпоративная политика безопасности паролей." -Level 'SUCCESS' -AuditAction 'Пресет политики: Корпоративный'
    }
    catch { Set-AppStatus -Message $_.Exception.Message -Level 'ERROR' }
})

# ==============================================================================
# ВКЛАДКА 6: Журнал аудита и экспорт HTML-отчетов
# ==============================================================================
function Invoke-FullHtmlReportDialog {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Title = "Сохранить полный HTML-отчет WinPass Admin Suite"
    $dlg.Filter = "HTML-отчет (*.html)|*.html"
    $dlg.FileName = "WinPass_Audit_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmm').html"

    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            if ($script:AllLoadedUsers.Count -eq 0) { $script:AllLoadedUsers = @(Get-WinPassLocalUsers) }
            if ($script:CachedWifiList.Count -eq 0) { $script:CachedWifiList = @(Get-WinPassWifiPasswords) }
            if ($script:CachedCredList.Count -eq 0) { $script:CachedCredList = @(Get-WinPassSavedCredentials) }

            $null = Export-WinPassHtmlReport `
                -OutputPath $dlg.FileName `
                -Users $script:AllLoadedUsers `
                -WifiProfiles $script:CachedWifiList `
                -SavedCredentials $script:CachedCredList `
                -AuditLogs @(Get-WinPassAuditLog)

            Set-AppStatus -Message "Полный HTML-отчет сохранен: $($dlg.FileName)" -Level 'SUCCESS' -AuditAction 'Экспорт полного HTML-отчета'
            Start-Process $dlg.FileName -ErrorAction SilentlyContinue
        }
        catch {
            Set-AppStatus -Message "Ошибка создания отчета: $($_.Exception.Message)" -Level 'ERROR'
        }
    }
}

$ui['BtnQuickExportHtml'].Add_Click({ Invoke-FullHtmlReportDialog })
$ui['BtnExportFullHtmlReport'].Add_Click({ Invoke-FullHtmlReportDialog })

$ui['BtnOpenLogsFolder'].Add_Click({
    $logDir = Split-Path -Parent $script:LogFile
    if (-not (Test-Path $logDir)) {
        $null = New-Item -Path $logDir -ItemType Directory -Force
    }
    Start-Process explorer.exe -ArgumentList "`"$logDir`"" -ErrorAction SilentlyContinue
})

# ==============================================================================
# Первичная инициализация при открытии окна
# ==============================================================================
$script:Window.Add_Loaded({
    Update-HeaderSummary
    Set-AppStatus -Message "Инициализация WinPass Admin Suite завершена." -Level 'INFO' -AuditAction 'Запуск приложения'
    Refresh-UsersTable
    Refresh-AutoLogonPanel
    Refresh-OfflineInstallations
    Refresh-PasswordPolicyUI

    # Генерируем стартовый временный пароль в поле генератора
    $ui['TxtNewPassword'].Text = New-WinPassRandomPassword -Length 12
})

$null = $script:Window.ShowDialog()
