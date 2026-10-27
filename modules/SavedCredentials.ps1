# ==============================================================================
# WinPass Admin Suite - Модуль восстановления сохраненных паролей
# Wi-Fi (netsh wlan + XML), Windows Credential Manager (P/Invoke CredEnumerate),
# Windows PasswordVault и реестр автологона Winlogon
# ==============================================================================

# Инициализация P/Invoke обертки для чтения Windows Credential Manager (advapi32.dll)
$script:CredManagerCsCode = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace WinPassNative {
    public class CredentialItem {
        public string TargetName { get; set; }
        public string UserName { get; set; }
        public string Password { get; set; }
        public string CredType { get; set; }
        public string Persist { get; set; }
        public string Comment { get; set; }
        public string LastWritten { get; set; }
    }

    public static class CredManagerReader {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL {
            public UInt32 Flags;
            public UInt32 Type;
            public IntPtr TargetName;
            public IntPtr Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public UInt32 CredentialBlobSize;
            public IntPtr CredentialBlob;
            public UInt32 Persist;
            public UInt32 AttributeCount;
            public IntPtr Attributes;
            public IntPtr TargetAlias;
            public IntPtr UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredEnumerateW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredEnumerate(string filter, int flag, out int count, out IntPtr pCredentials);

        [DllImport("advapi32.dll", EntryPoint = "CredFree", SetLastError = true)]
        private static extern void CredFree([In] IntPtr cred);

        public static List<CredentialItem> ReadAllCredentials() {
            var result = new List<CredentialItem>();
            int count = 0;
            IntPtr pCredentials = IntPtr.Zero;

            if (!CredEnumerate(null, 0, out count, out pCredentials)) {
                return result;
            }

            try {
                for (int i = 0; i < count; i++) {
                    IntPtr credPtr = Marshal.ReadIntPtr(pCredentials, i * IntPtr.Size);
                    CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(credPtr, typeof(CREDENTIAL));

                    string target = Marshal.PtrToStringUni(cred.TargetName) ?? "";
                    string user = Marshal.PtrToStringUni(cred.UserName) ?? "";
                    string comment = Marshal.PtrToStringUni(cred.Comment) ?? "";
                    string password = "";

                    if (cred.CredentialBlob != IntPtr.Zero && cred.CredentialBlobSize > 0) {
                        byte[] blob = new byte[cred.CredentialBlobSize];
                        Marshal.Copy(cred.CredentialBlob, blob, 0, (int)cred.CredentialBlobSize);

                        // Определение кодировки: UTF-16LE или UTF-8
                        bool looksUnicode = (blob.Length >= 2 && blob.Length % 2 == 0 && blob[1] == 0);
                        if (looksUnicode) {
                            password = Encoding.Unicode.GetString(blob).TrimEnd('\0');
                        } else {
                            password = Encoding.UTF8.GetString(blob).TrimEnd('\0');
                        }

                        // Проверка на нечитаемые бинарные данные (например, защищенный токен)
                        int nonPrintable = 0;
                        foreach (char c in password) {
                            if (char.IsControl(c) && c != '\r' && c != '\n' && c != '\t') {
                                nonPrintable++;
                            }
                        }
                        if (password.Length > 0 && nonPrintable > password.Length / 3) {
                            password = "[Зашифрованный токен / Бинарный ключ (" + cred.CredentialBlobSize + " байт)]";
                        }
                    } else {
                        password = "[Защищено LSA / Недоступно в открытом виде]";
                    }

                    string typeName = "Generic";
                    switch (cred.Type) {
                        case 1: typeName = "Generic (Общие)"; break;
                        case 2: typeName = "Domain Password (Домен/Сеть)"; break;
                        case 3: typeName = "Domain Certificate (Сертификат)"; break;
                        case 4: typeName = "Domain Visible Password"; break;
                        case 5: typeName = "Generic Certificate"; break;
                        case 6: typeName = "Domain Extended"; break;
                        default: typeName = "Type " + cred.Type; break;
                    }

                    string persistName = "Enterprise";
                    switch (cred.Persist) {
                        case 1: persistName = "Сеанс (Session)"; break;
                        case 2: persistName = "Локальный ПК (Local Machine)"; break;
                        case 3: persistName = "Предприятие (Enterprise)"; break;
                    }

                    string dateStr = "";
                    try {
                        long hFT = (((long)cred.LastWritten.dwHighDateTime) << 32) | ((uint)cred.LastWritten.dwLowDateTime);
                        dateStr = DateTime.FromFileTime(hFT).ToString("dd.MM.yyyy HH:mm");
                    } catch {
                        dateStr = "Н/Д";
                    }

                    result.Add(new CredentialItem {
                        TargetName = target,
                        UserName = user,
                        Password = password,
                        CredType = typeName,
                        Persist = persistName,
                        Comment = comment,
                        LastWritten = dateStr
                    });
                }
            }
            finally {
                if (pCredentials != IntPtr.Zero) {
                    CredFree(pCredentials);
                }
            }
            return result;
        }
    }
}
'@

try {
    if (-not ('WinPassNative.CredManagerReader' -as [type])) {
        Add-Type -TypeDefinition $script:CredManagerCsCode -ErrorAction SilentlyContinue
    }
}
catch { }

function Get-WinPassWifiPasswords {
    <#
    .SYNOPSIS
        Извлекает сохраненные профили Wi-Fi и их пароли в открытом виде.
        Использует экспорт XML через netsh wlan export profile key=clear (не зависит от языка ОС),
        а также резервный парсинг вывода netsh wlan show profile.
    #>
    $wifiList = New-Object System.Collections.Generic.List[PSCustomObject]
    $seenSsids = @{}

    # Метод 1: Экспорт профилей в XML с открытым ключом (100% независимость от языка Windows)
    $tempDir = Join-Path $env:TEMP ("winpass_wifi_" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    try {
        $null = New-Item -Path $tempDir -ItemType Directory -Force -ErrorAction Stop
        $null = & netsh.exe wlan export profile key=clear folder="$tempDir" 2>&1

        $xmlFiles = Get-ChildItem -Path $tempDir -Filter '*.xml' -ErrorAction SilentlyContinue
        foreach ($file in $xmlFiles) {
            try {
                [xml]$xmlDoc = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
                $ssid = $xmlDoc.WLANProfile.SSIDConfig.SSID.name
                if ([string]::IsNullOrWhiteSpace($ssid)) {
                    $ssid = $xmlDoc.WLANProfile.name
                }
                $auth = $xmlDoc.WLANProfile.MSM.security.authEncryption.authentication
                $cipher = $xmlDoc.WLANProfile.MSM.security.authEncryption.encryption
                $keyMat = $xmlDoc.WLANProfile.MSM.security.sharedKey.keyMaterial
                $protected = $xmlDoc.WLANProfile.MSM.security.sharedKey.protected
                $connMode = $xmlDoc.WLANProfile.connectionMode

                $passDisplay = if (-not [string]::IsNullOrEmpty($keyMat)) {
                    if ($protected -eq 'true') {
                        "[Зашифрован DPAPI: $($keyMat.Substring(0, [Math]::Min(16, $keyMat.Length)))...]"
                    }
                    else {
                        [string]$keyMat
                    }
                }
                elseif ($auth -eq 'open') {
                    '[Открытая сеть без пароля]'
                }
                else {
                    '[Ключ отсутствует]'
                }

                $seenSsids[$ssid] = $true
                $wifiList.Add([PSCustomObject]@{
                    SSID           = [string]$ssid
                    Authentication = [string]$auth
                    Encryption     = [string]$cipher
                    Password       = $passDisplay
                    ConnectionMode = [string]$connMode
                    Source         = 'WLAN XML (key=clear)'
                })
            }
            catch { }
        }
    }
    catch { }
    finally {
        if (Test-Path $tempDir) {
            Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Метод 2: Дополнительный парсинг netsh wlan show profiles (на случай если экспорт заблокирован)
    if ($wifiList.Count -eq 0) {
        try {
            $profilesOut = & netsh.exe wlan show profiles 2>&1
            foreach ($line in $profilesOut) {
                if ($line -match '(?:All User Profile|Все профили пользователей)\s*:\s*(.+)$') {
                    $profileName = $Matches[1].Trim()
                    if ([string]::IsNullOrEmpty($profileName) -or $seenSsids.ContainsKey($profileName)) { continue }

                    $detailOut = & netsh.exe wlan show profile name="$profileName" key=clear 2>&1
                    $authVal = 'Н/Д'
                    $cipherVal = 'Н/Д'
                    $keyVal = '[Не найден]'

                    foreach ($dLine in $detailOut) {
                        if ($dLine -match '(?:Authentication|Проверка подлинности)\s*:\s*(.+)$') {
                            $authVal = $Matches[1].Trim()
                        }
                        elseif ($dLine -match '(?:Cipher|Шифрование)\s*:\s*(.+)$') {
                            $cipherVal = $Matches[1].Trim()
                        }
                        elseif ($dLine -match '(?:Key Content|Содержимое ключа)\s*:\s*(.+)$') {
                            $keyVal = $Matches[1].Trim()
                        }
                    }

                    $wifiList.Add([PSCustomObject]@{
                        SSID           = $profileName
                        Authentication = $authVal
                        Encryption     = $cipherVal
                        Password       = $keyVal
                        ConnectionMode = 'auto'
                        Source         = 'netsh wlan'
                    })
                }
            }
        }
        catch { }
    }

    return $wifiList
}

function Get-WinPassSavedCredentials {
    <#
    .SYNOPSIS
        Извлекает сохраненные учетные данные из Диспетчера учетных данных Windows (Credential Manager)
        и Хранилища веб-паролей (Windows.Security.Credentials.PasswordVault).
    #>
    $credList = New-Object System.Collections.Generic.List[PSCustomObject]

    # 1. Чтение через нативный Win32 CredEnumerateW
    try {
        if ('WinPassNative.CredManagerReader' -as [type]) {
            $nativeItems = [WinPassNative.CredManagerReader]::ReadAllCredentials()
            foreach ($item in $nativeItems) {
                $credList.Add([PSCustomObject]@{
                    Source      = 'Credential Manager'
                    Target      = $item.TargetName
                    UserName    = $item.UserName
                    Password    = $item.Password
                    Type        = $item.CredType
                    Persistence = $item.Persist
                    LastUpdated = $item.LastWritten
                })
            }
        }
    }
    catch { }

    # 2. Чтение через Windows.Security.Credentials.PasswordVault (Веб-учетные данные)
    try {
        $null = [Windows.Security.Credentials.PasswordVault, Windows.Security.Credentials, ContentType = WindowsRuntime]
        $vault = New-Object Windows.Security.Credentials.PasswordVault
        $vaultItems = $vault.RetrieveAll()
        foreach ($vItem in $vaultItems) {
            try {
                $vItem.RetrievePassword()
                $credList.Add([PSCustomObject]@{
                    Source      = 'Windows Web Vault'
                    Target      = [string]$vItem.Resource
                    UserName    = [string]$vItem.UserName
                    Password    = [string]$vItem.Password
                    Type        = 'Web Credential'
                    Persistence = 'Local User Vault'
                    LastUpdated = 'Актуально'
                })
            }
            catch { }
        }
    }
    catch { }

    # 3. Если список пуст, пробуем парсинг cmdkey /list
    if ($credList.Count -eq 0) {
        try {
            $cmdkeyOut = & cmdkey.exe /list 2>&1
            $currentTarget = ''
            $currentType = ''
            $currentUser = ''

            foreach ($line in $cmdkeyOut) {
                if ($line -match '(?:Target|Цель):\s*(.+)$') {
                    $currentTarget = $Matches[1].Trim()
                }
                elseif ($line -match '(?:Type|Тип):\s*(.+)$') {
                    $currentType = $Matches[1].Trim()
                }
                elseif ($line -match '(?:User|Пользователь):\s*(.+)$') {
                    $currentUser = $Matches[1].Trim()
                    if (-not [string]::IsNullOrEmpty($currentTarget)) {
                        $credList.Add([PSCustomObject]@{
                            Source      = 'cmdkey'
                            Target      = $currentTarget
                            UserName    = $currentUser
                            Password    = '[Скрыто политикой LSA]'
                            Type        = $currentType
                            Persistence = 'Local'
                            LastUpdated = 'Н/Д'
                        })
                        $currentTarget = ''
                    }
                }
            }
        }
        catch { }
    }

    return $credList
}

function Get-WinPassAutoLogonInfo {
    <#
    .SYNOPSIS
        Проверяет настройки автоматического входа Windows (Winlogon AutoAdminLogon)
        и извлекает сохраненный DefaultPassword, если он присутствует в реестре.
    #>
    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
        $autoLogon = ($props.AutoAdminLogon -eq '1')
        $defUser   = [string]$props.DefaultUserName
        $defDomain = [string]$props.DefaultDomainName
        $defPass   = [string]$props.DefaultPassword

        return [PSCustomObject]@{
            Enabled           = $autoLogon
            DefaultUserName   = $defUser
            DefaultDomainName = $defDomain
            DefaultPassword   = if ([string]::IsNullOrEmpty($defPass)) { '[Не сохранен в открытом виде в реестре]' } else { $defPass }
            RawPassword       = $defPass
        }
    }
    catch {
        return [PSCustomObject]@{
            Enabled           = $false
            DefaultUserName   = ''
            DefaultDomainName = ''
            DefaultPassword   = ''
            RawPassword       = ''
        }
    }
}

function Set-WinPassAutoLogon {
    <#
    .SYNOPSIS
        Настраивает или отключает автоматический вход пользователя при загрузке Windows (AutoAdminLogon).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enable,

        [string]$UserName = '',
        [string]$Password = '',
        [string]$Domain = $env:COMPUTERNAME
    )

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    if ($Enable) {
        if ([string]::IsNullOrWhiteSpace($UserName)) {
            throw "Для включения AutoLogon необходимо указать имя пользователя."
        }
        Set-ItemProperty -Path $regPath -Name 'AutoAdminLogon' -Value '1' -Type String
        Set-ItemProperty -Path $regPath -Name 'DefaultUserName' -Value $UserName -Type String
        Set-ItemProperty -Path $regPath -Name 'DefaultDomainName' -Value $Domain -Type String
        Set-ItemProperty -Path $regPath -Name 'DefaultPassword' -Value $Password -Type String
        Set-ItemProperty -Path $regPath -Name 'ForceAutoLogon' -Value '1' -Type String
        return "Автоматический вход (AutoLogon) включен для пользователя '$UserName'."
    }
    else {
        Set-ItemProperty -Path $regPath -Name 'AutoAdminLogon' -Value '0' -Type String
        Set-ItemProperty -Path $regPath -Name 'ForceAutoLogon' -Value '0' -Type String
        Remove-ItemProperty -Path $regPath -Name 'DefaultPassword' -ErrorAction SilentlyContinue
        return "Автоматический вход (AutoLogon) отключен, сохраненный пароль удален из реестра Winlogon."
    }
}
