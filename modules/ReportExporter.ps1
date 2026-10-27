# ==============================================================================
# WinPass Admin Suite - Модуль журналирования и экспорта отчетов
# Формирует журнал аудита администратора, сводные HTML/CSV/JSON отчеты
# и карточку-памятку передачи нового пароля пользователю
# ==============================================================================

$script:AuditLogEntries = New-Object System.Collections.Generic.List[PSCustomObject]

function Write-WinPassAuditLog {
    <#
    .SYNOPSIS
        Записывает событие в журнал в памяти и в файл logs/winpass_audit.log.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Details,

        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO',

        [string]$LogFilePath = ''
    )

    $timestamp = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss')
    $entry = [PSCustomObject]@{
        Timestamp = $timestamp
        Level     = $Level
        Operator  = "$env:USERDOMAIN\$env:USERNAME"
        Computer  = $env:COMPUTERNAME
        Action    = $Action
        Details   = $Details
    }

    $script:AuditLogEntries.Add($entry)

    if (-not [string]::IsNullOrWhiteSpace($LogFilePath)) {
        try {
            $dir = Split-Path -Path $LogFilePath -Parent
            if (-not (Test-Path $dir)) {
                $null = New-Item -Path $dir -ItemType Directory -Force
            }
            $line = "[$timestamp] [$Level] [$($entry.Computer) / $($entry.Operator)] $Action : $Details`r`n"
            [System.IO.File]::AppendAllText($LogFilePath, $line, [System.Text.Encoding]::UTF8)
        }
        catch { }
    }

    return $entry
}

function Get-WinPassAuditLog {
    return $script:AuditLogEntries
}

function Export-WinPassHtmlReport {
    <#
    .SYNOPSIS
        Генерирует подробный HTML-отчет администратора по учетным записям, Wi-Fi,
        сохраненным паролям и журналу выполненных действий.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [array]$Users = @(),
        [array]$WifiProfiles = @(),
        [array]$SavedCredentials = @(),
        [array]$AuditLogs = @()
    )

    $nowStr = (Get-Date).ToString('dd.MM.yyyy HH:mm:ss')
    $osCaption = 'Windows'
    try {
        $osInfo = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
        if ($osInfo) { $osCaption = "$($osInfo.Caption) (Build $($osInfo.BuildNumber))" }
    }
    catch { }

    $usersRows = foreach ($u in $Users) {
        $statusBadge = if ($u.Enabled) { "<span class='badge ok'>Активна</span>" } else { "<span class='badge off'>Отключена</span>" }
        $lockBadge   = if ($u.LockedOut) { "<span class='badge err'>Заблокирована</span>" } else { "Норма" }
        "<tr><td><b>$([System.Net.WebUtility]::HtmlEncode($u.Name))</b></td><td>$([System.Net.WebUtility]::HtmlEncode($u.FullName))</td><td>$([System.Net.WebUtility]::HtmlEncode($u.RoleText))</td><td>$statusBadge</td><td>$lockBadge</td><td>$([System.Net.WebUtility]::HtmlEncode($u.LastLogon))</td><td><code>$([System.Net.WebUtility]::HtmlEncode($u.SID))</code></td></tr>"
    }

    $wifiRows = foreach ($w in $WifiProfiles) {
        "<tr><td><b>$([System.Net.WebUtility]::HtmlEncode($w.SSID))</b></td><td>$([System.Net.WebUtility]::HtmlEncode($w.Authentication))</td><td>$([System.Net.WebUtility]::HtmlEncode($w.Encryption))</td><td><code>$([System.Net.WebUtility]::HtmlEncode($w.Password))</code></td></tr>"
    }

    $credRows = foreach ($c in $SavedCredentials) {
        "<tr><td>$([System.Net.WebUtility]::HtmlEncode($c.Source))</td><td><b>$([System.Net.WebUtility]::HtmlEncode($c.Target))</b></td><td>$([System.Net.WebUtility]::HtmlEncode($c.UserName))</td><td><code>$([System.Net.WebUtility]::HtmlEncode($c.Password))</code></td><td>$([System.Net.WebUtility]::HtmlEncode($c.Type))</td></tr>"
    }

    $logRows = foreach ($l in $AuditLogs) {
        "<tr><td>$([System.Net.WebUtility]::HtmlEncode($l.Timestamp))</td><td><b>$([System.Net.WebUtility]::HtmlEncode($l.Level))</b></td><td>$([System.Net.WebUtility]::HtmlEncode($l.Action))</td><td>$([System.Net.WebUtility]::HtmlEncode($l.Details))</td></tr>"
    }

    $html = @"
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8" />
<title>Отчет WinPass Admin Suite — $env:COMPUTERNAME</title>
<style>
  body { font-family: 'Segoe UI', Tahoma, sans-serif; background: #0f172a; color: #e2e8f0; margin: 24px; }
  .container { max-width: 1180px; margin: 0 auto; background: #1e293b; padding: 28px; border-radius: 12px; border: 1px solid #334155; }
  h1 { margin-top: 0; color: #38bdf8; font-size: 24px; }
  h2 { color: #94a3b8; border-bottom: 1px solid #334155; padding-bottom: 8px; margin-top: 28px; font-size: 18px; }
  .meta { background: #0f172a; padding: 14px 18px; border-radius: 8px; margin-bottom: 20px; font-size: 14px; color: #cbd5e1; }
  table { width: 100%; border-collapse: collapse; margin-top: 12px; font-size: 13.5px; }
  th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #334155; }
  th { background: #0f172a; color: #38bdf8; font-weight: 600; }
  code { background: #0f172a; padding: 3px 6px; border-radius: 4px; color: #f8fafc; font-family: Consolas, monospace; }
  .badge { padding: 3px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }
  .badge.ok { background: #065f46; color: #6ee7b7; }
  .badge.off { background: #334155; color: #cbd5e1; }
  .badge.err { background: #7f1d1d; color: #fca5a5; }
</style>
</head>
<body>
<div class="container">
  <h1>Отчет аудита и восстановления паролей — WinPass Admin Suite</h1>
  <div class="meta">
    <b>Компьютер:</b> $env:COMPUTERNAME &nbsp;|&nbsp;
    <b>ОС:</b> $osCaption &nbsp;|&nbsp;
    <b>Администратор:</b> $env:USERDOMAIN\$env:USERNAME &nbsp;|&nbsp;
    <b>Дата отчета:</b> $nowStr
  </div>

  <h2>1. Локальные учетные записи ($($Users.Count))</h2>
  <table>
    <thead><tr><th>Логин</th><th>Полное имя</th><th>Роль</th><th>Статус</th><th>Блокировка</th><th>Последний вход</th><th>SID</th></tr></thead>
    <tbody>$($usersRows -join "`r`n")</tbody>
  </table>

  <h2>2. Сохраненные профили и пароли Wi-Fi ($($WifiProfiles.Count))</h2>
  <table>
    <thead><tr><th>Имя сети (SSID)</th><th>Аутентификация</th><th>Шифрование</th><th>Пароль (ключ безопасности)</th></tr></thead>
    <tbody>$($wifiRows -join "`r`n")</tbody>
  </table>

  <h2>3. Диспетчер учетных данных Windows ($($SavedCredentials.Count))</h2>
  <table>
    <thead><tr><th>Хранилище</th><th>Ресурс / Цель</th><th>Имя пользователя</th><th>Пароль / Секрет</th><th>Тип</th></tr></thead>
    <tbody>$($credRows -join "`r`n")</tbody>
  </table>

  <h2>4. Журнал операций администратора ($($AuditLogs.Count))</h2>
  <table>
    <thead><tr><th>Время</th><th>Уровень</th><th>Операция</th><th>Подробности</th></tr></thead>
    <tbody>$($logRows -join "`r`n")</tbody>
  </table>
</div>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($OutputPath, $html, [System.Text.Encoding]::UTF8)
    return $OutputPath
}

function Export-WinPassUserHandoverCard {
    <#
    .SYNOPSIS
        Создает карточку-памятку для пользователя с его логином и новым временным паролем.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [AllowEmptyString()]
        [string]$NewPassword,

        [bool]$MustChangeAtLogon = $false
    )

    $nowStr = (Get-Date).ToString('dd.MM.yyyy HH:mm')
    $passDisplay = if ([string]::IsNullOrEmpty($NewPassword)) { '[Без пароля / Пустой пароль]' } else { $NewPassword }
    $changeHint  = if ($MustChangeAtLogon) { 'Да (потребуется ввести новый личный пароль при первом входе)' } else { 'Нет (пароль постоянный)' }

    $cardText = @"
======================================================================
          КАРТОЧКА ДОСТУПА ПОЛЬЗОВАТЕЛЯ ПК (WINPASS ADMIN)
======================================================================
Дата выдачи       : $nowStr
Имя компьютера    : $env:COMPUTERNAME
Имя пользователя  : $UserName
Новый пароль      : $passDisplay
Смена при входе   : $changeHint
Выдал админ       : $env:USERNAME
----------------------------------------------------------------------
Рекомендация: Храните пароль в надежном месте и не передавайте третьим
лицам. При возникновении вопросов обратитесь к системному администратору.
======================================================================
"@

    [System.IO.File]::WriteAllText($OutputPath, $cardText, [System.Text.Encoding]::UTF8)
    return $OutputPath
}
