# ==============================================================================
# WinPass Admin Suite - Модуль управления локальными учетными записями Windows
# Поддерживает Get-LocalUser / Set-LocalUser, ADSI (WinNT://) и net.exe
# Работает на русских и английских версиях Windows 10 / 11 / Server / WinPE
# ==============================================================================

# Постоянные флаги ADSI UserFlags
$script:ADS_UF_ACCOUNTDISABLE     = 0x0002
$script:ADS_UF_LOCKOUT            = 0x0010
$script:ADS_UF_PASSWD_NOTREQD     = 0x0020
$script:ADS_UF_PASSWD_CANT_CHANGE = 0x0040
$script:ADS_UF_DONT_EXPIRE_PASSWD = 0x10000
$script:ADS_UF_PASSWORD_EXPIRED   = 0x800000

function Test-IsAdministrator {
    <#
    .SYNOPSIS
        Проверяет, запущен ли текущий процесс с правами Администратора или SYSTEM.
    #>
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Resolve-WellKnownGroupName {
    <#
    .SYNOPSIS
        Возвращает локализованное имя локальной группы по её стандартному SID.
        Например: S-1-5-32-544 -> "Администраторы" (RU) или "Administrators" (EN).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SidString
    )
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($SidString)
        $ntAccount = $sid.Translate([System.Security.Principal.NTAccount])
        $fullName = $ntAccount.Value
        if ($fullName -match '\\(.+)$') {
            return $Matches[1]
        }
        return $fullName
    }
    catch {
        switch ($SidString) {
            'S-1-5-32-544' { return 'Administrators' }
            'S-1-5-32-545' { return 'Users' }
            'S-1-5-32-555' { return 'Remote Desktop Users' }
            default        { return $SidString }
        }
    }
}

function Get-LocalAdminGroupMembers {
    <#
    .SYNOPSIS
        Возвращает список имен пользователей, входящих в локальную группу Администраторы (S-1-5-32-544).
    #>
    $members = @()
    $adminGroupName = Resolve-WellKnownGroupName -SidString 'S-1-5-32-544'

    if (Get-Command Get-LocalGroupMember -ErrorAction SilentlyContinue) {
        try {
            $rawMembers = Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop
            foreach ($m in $rawMembers) {
                $shortName = $m.Name
                if ($shortName -match '\\(.+)$') { $shortName = $Matches[1] }
                $members += $shortName
            }
            return $members
        }
        catch { }
    }

    try {
        $adsiGroup = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroupName,group"
        foreach ($member in $adsiGroup.Invoke('Members')) {
            $memberName = $member.GetType().InvokeMember('Name', 'GetProperty', $null, $member, $null)
            if ($memberName) {
                $members += $memberName
            }
        }
    }
    catch { }

    return $members
}

function Get-WinPassLocalUsers {
    <#
    .SYNOPSIS
        Получает полный список локальных учетных записей ПК с подробными свойствами.
        Использует Get-LocalUser с автоматическим переключением на ADSI при отсутствии модуля.
    #>
    param(
        [switch]$OnlyEnabled
    )

    $adminMembers = Get-LocalAdminGroupMembers
    $usersList = New-Object System.Collections.Generic.List[PSCustomObject]

    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
        try {
            $localUsers = Get-LocalUser -ErrorAction Stop
            foreach ($u in $localUsers) {
                if ($OnlyEnabled -and (-not $u.Enabled)) { continue }

                $isLocked = $false
                try {
                    $adsi = [ADSI]"WinNT://$env:COMPUTERNAME/$($u.Name),user"
                    if ($adsi.UserFlags.Value -band $script:ADS_UF_LOCKOUT) {
                        $isLocked = $true
                    }
                    if ($adsi.Properties['IsAccountLocked'] -and $adsi.Properties['IsAccountLocked'].Value) {
                        $isLocked = $true
                    }
                }
                catch { }

                $isAdmin = $adminMembers -contains $u.Name
                $isBuiltInAdmin = ($u.SID.Value -like 'S-1-5-21-*-500')
                $neverExpires = ($null -eq $u.PasswordExpires)

                $lastLogonStr = if ($u.LastLogon) { $u.LastLogon.ToString('dd.MM.yyyy HH:mm') } else { 'Никогда' }
                $passLastSetStr = if ($u.PasswordLastSet) { $u.PasswordLastSet.ToString('dd.MM.yyyy HH:mm') } else { 'Не задан' }

                $usersList.Add([PSCustomObject]@{
                    Name                 = $u.Name
                    FullName             = [string]$u.FullName
                    Description          = [string]$u.Description
                    Enabled              = [bool]$u.Enabled
                    StatusText           = if ($u.Enabled) { 'Активна' } else { 'Отключена' }
                    LockedOut            = [bool]$isLocked
                    LockedText           = if ($isLocked) { 'Заблокирована' } else { 'Норма' }
                    IsAdmin              = [bool]$isAdmin
                    RoleText             = if ($isBuiltInAdmin) { 'Встроенный Админ' } elseif ($isAdmin) { 'Администратор' } else { 'Пользователь' }
                    IsBuiltInAdmin       = [bool]$isBuiltInAdmin
                    PasswordRequired     = [bool]$u.PasswordRequired
                    PasswordNeverExpires = [bool]$neverExpires
                    UserMayChangePass    = [bool]$u.UserMayChangePassword
                    LastLogon            = $lastLogonStr
                    PasswordLastSet      = $passLastSetStr
                    SID                  = [string]$u.SID.Value
                    PrincipalSource      = [string]$u.PrincipalSource
                })
            }
            return $usersList
        }
        catch { }
    }

    # Fallback через ADSI (WinNT://) для сред без Microsoft.PowerShell.LocalAccounts
    try {
        $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
        $computer.Children | Where-Object { $_.SchemaClassName -eq 'User' } | ForEach-Object {
            $u = $_
            $name = [string]$u.Name.Value
            $flags = [int]$u.UserFlags.Value
            $enabled = -not [bool]($flags -band $script:ADS_UF_ACCOUNTDISABLE)
            if ($OnlyEnabled -and (-not $enabled)) { return }

            $locked = [bool]($flags -band $script:ADS_UF_LOCKOUT)
            $neverExpires = [bool]($flags -band $script:ADS_UF_DONT_EXPIRE_PASSWD)
            $passRequired = -not [bool]($flags -band $script:ADS_UF_PASSWD_NOTREQD)
            $userMayChange = -not [bool]($flags -band $script:ADS_UF_PASSWD_CANT_CHANGE)

            $sidStr = ''
            try {
                $sidBytes = $u.ObjectSid.Value
                $sidObj = New-Object System.Security.Principal.SecurityIdentifier($sidBytes, 0)
                $sidStr = $sidObj.Value
            }
            catch { }

            $isBuiltInAdmin = ($sidStr -like 'S-1-5-21-*-500')
            $isAdmin = ($adminMembers -contains $name) -or $isBuiltInAdmin

            $lastLogonStr = 'Н/Д'
            try {
                if ($u.Properties['LastLogin'].Value) {
                    $lastLogonStr = ([datetime]$u.Properties['LastLogin'].Value).ToString('dd.MM.yyyy HH:mm')
                }
            }
            catch { }

            $usersList.Add([PSCustomObject]@{
                Name                 = $name
                FullName             = [string]$u.FullName.Value
                Description          = [string]$u.Description.Value
                Enabled              = $enabled
                StatusText           = if ($enabled) { 'Активна' } else { 'Отключена' }
                LockedOut            = $locked
                LockedText           = if ($locked) { 'Заблокирована' } else { 'Норма' }
                IsAdmin              = $isAdmin
                RoleText             = if ($isBuiltInAdmin) { 'Встроенный Админ' } elseif ($isAdmin) { 'Администратор' } else { 'Пользователь' }
                IsBuiltInAdmin       = $isBuiltInAdmin
                PasswordRequired     = $passRequired
                PasswordNeverExpires = $neverExpires
                UserMayChangePass    = $userMayChange
                LastLogon            = $lastLogonStr
                PasswordLastSet      = 'Н/Д'
                SID                  = $sidStr
                PrincipalSource      = 'Local (ADSI)'
            })
        }
    }
    catch {
        throw "Не удалось получить список локальных пользователей: $($_.Exception.Message)"
    }

    return $usersList
}

function Reset-WinPassUserPassword {
    <#
    .SYNOPSIS
        Сбрасывает или устанавливает новый пароль для локального пользователя Windows.
        Поддерживает установку пустого пароля, разблокировку, включение УЗ и настройку срока действия.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [AllowEmptyString()]
        [string]$NewPassword = '',

        [bool]$PasswordNeverExpires = $true,
        [bool]$MustChangeAtNextLogon = $false,
        [bool]$UnlockAndEnable = $true
    )

    $steps = New-Object System.Collections.Generic.List[string]

    # 1. Если задается пустой пароль, снимаем флаг обязательности пароля
    if ([string]::IsNullOrEmpty($NewPassword)) {
        try {
            $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$UserName,user"
            $flags = [int]$adsiUser.UserFlags.Value
            $flags = $flags -bor $script:ADS_UF_PASSWD_NOTREQD
            $adsiUser.Put('UserFlags', $flags)
            $adsiUser.CommitChanges()
            $steps.Add("Снят флаг обязательности пароля (PASSWD_NOTREQD)")
        }
        catch { }
    }

    # 2. Установка нового пароля (основной метод Set-LocalUser + fallback ADSI + fallback net user)
    $passwordSetSuccess = $false
    $lastError = $null

    if (Get-Command Set-LocalUser -ErrorAction SilentlyContinue) {
        try {
            if ([string]::IsNullOrEmpty($NewPassword)) {
                $securePass = New-Object System.Security.SecureString
            }
            else {
                $securePass = ConvertTo-SecureString -String $NewPassword -AsPlainText -Force
            }
            Set-LocalUser -Name $UserName -Password $securePass -ErrorAction Stop
            $passwordSetSuccess = $true
            $steps.Add("Пароль успешно изменен через Set-LocalUser")
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    if (-not $passwordSetSuccess) {
        try {
            $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$UserName,user"
            $adsiUser.Invoke('SetPassword', $NewPassword)
            $adsiUser.CommitChanges()
            $passwordSetSuccess = $true
            $steps.Add("Пароль успешно изменен через ADSI WinNT")
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    if (-not $passwordSetSuccess) {
        $netOut = & net.exe user $UserName $NewPassword 2>&1
        if ($LASTEXITCODE -eq 0) {
            $passwordSetSuccess = $true
            $steps.Add("Пароль успешно изменен через net.exe user")
        }
        else {
            throw "Ошибка смены пароля для '$UserName': $lastError | $($netOut -join ' ')"
        }
    }

    # 3. Разблокировка и включение учетной записи при необходимости
    if ($UnlockAndEnable) {
        try {
            if (Get-Command Enable-LocalUser -ErrorAction SilentlyContinue) {
                Enable-LocalUser -Name $UserName -ErrorAction SilentlyContinue
            }
            if (Get-Command Unlock-LocalUser -ErrorAction SilentlyContinue) {
                Unlock-LocalUser -Name $UserName -ErrorAction SilentlyContinue
            }
        }
        catch { }

        try {
            $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$UserName,user"
            $flags = [int]$adsiUser.UserFlags.Value
            $flags = $flags -band (-bnot $script:ADS_UF_ACCOUNTDISABLE)
            $flags = $flags -band (-bnot $script:ADS_UF_LOCKOUT)
            $adsiUser.Put('UserFlags', $flags)
            if ($adsiUser.Properties['IsAccountLocked']) {
                $adsiUser.Put('IsAccountLocked', $false)
            }
            $adsiUser.CommitChanges()
            $steps.Add("Учетная запись активирована и разблокирована")
        }
        catch { }
    }

    # 4. Настройка срока действия пароля и смены при следующем входе
    try {
        $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$UserName,user"
        $flags = [int]$adsiUser.UserFlags.Value

        if ($MustChangeAtNextLogon) {
            # Если требуется смена пароля при входе, флаг PasswordNeverExpires должен быть снят
            $flags = $flags -band (-bnot $script:ADS_UF_DONT_EXPIRE_PASSWD)
            $flags = $flags -band (-bnot $script:ADS_UF_PASSWD_CANT_CHANGE)
            $adsiUser.Put('UserFlags', $flags)
            $adsiUser.Put('PasswordExpired', 1)
            $adsiUser.CommitChanges()
            $steps.Add("Установлено требование смены пароля при следующем входе")
        }
        elseif ($PasswordNeverExpires) {
            $flags = $flags -bor $script:ADS_UF_DONT_EXPIRE_PASSWD
            $adsiUser.Put('UserFlags', $flags)
            $adsiUser.Put('PasswordExpired', 0)
            $adsiUser.CommitChanges()
            $steps.Add("Установлен бессрочный срок действия пароля (PasswordNeverExpires)")
        }
        else {
            $flags = $flags -band (-bnot $script:ADS_UF_DONT_EXPIRE_PASSWD)
            $adsiUser.Put('UserFlags', $flags)
            $adsiUser.Put('PasswordExpired', 0)
            $adsiUser.CommitChanges()
        }
    }
    catch {
        $steps.Add("Предупреждение при установке флагов пароля: $($_.Exception.Message)")
    }

    return [PSCustomObject]@{
        Success  = $true
        UserName = $UserName
        Message  = ($steps -join '; ')
    }
}

function Set-WinPassAccountState {
    <#
    .SYNOPSIS
        Включает, отключает или разблокирует локальную учетную запись пользователя.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Enable', 'Disable', 'Unlock')]
        [string]$Action
    )

    $adsiUser = [ADSI]"WinNT://$env:COMPUTERNAME/$UserName,user"
    $flags = [int]$adsiUser.UserFlags.Value

    switch ($Action) {
        'Enable' {
            if (Get-Command Enable-LocalUser -ErrorAction SilentlyContinue) {
                Enable-LocalUser -Name $UserName -ErrorAction SilentlyContinue
            }
            $flags = $flags -band (-bnot $script:ADS_UF_ACCOUNTDISABLE)
            $adsiUser.Put('UserFlags', $flags)
            $adsiUser.CommitChanges()
            return "Учетная запись '$UserName' успешно включена."
        }
        'Disable' {
            if (Get-Command Disable-LocalUser -ErrorAction SilentlyContinue) {
                Disable-LocalUser -Name $UserName -ErrorAction SilentlyContinue
            }
            $flags = $flags -bor $script:ADS_UF_ACCOUNTDISABLE
            $adsiUser.Put('UserFlags', $flags)
            $adsiUser.CommitChanges()
            return "Учетная запись '$UserName' отключена."
        }
        'Unlock' {
            if (Get-Command Unlock-LocalUser -ErrorAction SilentlyContinue) {
                Unlock-LocalUser -Name $UserName -ErrorAction SilentlyContinue
            }
            $flags = $flags -band (-bnot $script:ADS_UF_LOCKOUT)
            $adsiUser.Put('UserFlags', $flags)
            if ($adsiUser.Properties['IsAccountLocked']) {
                $adsiUser.Put('IsAccountLocked', $false)
            }
            $adsiUser.CommitChanges()
            return "Учетная запись '$UserName' успешно разблокирована."
        }
    }
}

function Set-WinPassAdminMembership {
    <#
    .SYNOPSIS
        Добавляет или удаляет пользователя из локальной группы Администраторы (по SID S-1-5-32-544).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Add', 'Remove')]
        [string]$Operation
    )

    $adminGroupName = Resolve-WellKnownGroupName -SidString 'S-1-5-32-544'

    if ($Operation -eq 'Add') {
        if (Get-Command Add-LocalGroupMember -ErrorAction SilentlyContinue) {
            try {
                Add-LocalGroupMember -SID 'S-1-5-32-544' -Member $UserName -ErrorAction Stop
                return "Пользователь '$UserName' добавлен в группу '$adminGroupName'."
            }
            catch {
                if ($_.Exception.Message -match '1378|already a member|уже является') {
                    return "Пользователь '$UserName' уже состоит в группе '$adminGroupName'."
                }
            }
        }
        $adsiGroup = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroupName,group"
        $adsiGroup.Invoke('Add', "WinNT://$env:COMPUTERNAME/$UserName,user")
        return "Пользователь '$UserName' добавлен в группу '$adminGroupName' (ADSI)."
    }
    else {
        if (Get-Command Remove-LocalGroupMember -ErrorAction SilentlyContinue) {
            try {
                Remove-LocalGroupMember -SID 'S-1-5-32-544' -Member $UserName -ErrorAction Stop
                return "Пользователь '$UserName' удален из группы '$adminGroupName'."
            }
            catch { }
        }
        $adsiGroup = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroupName,group"
        $adsiGroup.Invoke('Remove', "WinNT://$env:COMPUTERNAME/$UserName,user")
        return "Пользователь '$UserName' удален из группы '$adminGroupName' (ADSI)."
    }
}

function Enable-WinPassBuiltInAdmin {
    <#
    .SYNOPSIS
        Находит встроенную учетную запись Администратора по SID S-1-5-21-*-500 (независимо от языка ОС),
        активирует её и при необходимости устанавливает новый пароль.
    #>
    param(
        [AllowEmptyString()]
        [string]$NewPassword = ''
    )

    $users = Get-WinPassLocalUsers
    $builtIn = $users | Where-Object { $_.IsBuiltInAdmin -eq $true } | Select-Object -First 1

    if (-not $builtIn) {
        throw "Не удалось обнаружить встроенную учетную запись Администратора (RID 500)."
    }

    $adminName = $builtIn.Name
    $null = Set-WinPassAccountState -UserName $adminName -Action 'Enable'
    $null = Set-WinPassAccountState -UserName $adminName -Action 'Unlock'

    if (-not [string]::IsNullOrEmpty($NewPassword)) {
        $null = Reset-WinPassUserPassword -UserName $adminName -NewPassword $NewPassword -PasswordNeverExpires $true -MustChangeAtNextLogon $false -UnlockAndEnable $true
        return "Встроенный администратор '$adminName' (RID 500) активирован, установлен новый пароль."
    }

    return "Встроенный администратор '$adminName' (RID 500) успешно активирован и разблокирован."
}

function New-WinPassEmergencyAdmin {
    <#
    .SYNOPSIS
        Создает резервную учетную запись локального администратора и добавляет её в группы Administrators и Users.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [string]$FullName = 'Emergency System Administrator',
        [string]$Description = 'Резервная учетная запись администратора (создана WinPass Admin Suite)'
    )

    $created = $false
    if (Get-Command New-LocalUser -ErrorAction SilentlyContinue) {
        try {
            $securePass = ConvertTo-SecureString -String $Password -AsPlainText -Force
            $null = New-LocalUser -Name $UserName -Password $securePass -FullName $FullName -Description $Description -PasswordNeverExpires -ErrorAction Stop
            $created = $true
        }
        catch { }
    }

    if (-not $created) {
        $computer = [ADSI]"WinNT://$env:COMPUTERNAME,computer"
        $newUser = $computer.Create('User', $UserName)
        $newUser.Invoke('SetPassword', $Password)
        $newUser.Put('FullName', $FullName)
        $newUser.Put('Description', $Description)
        $newUser.Put('UserFlags', $script:ADS_UF_DONT_EXPIRE_PASSWD)
        $newUser.CommitChanges()
    }

    $usersGroupName = Resolve-WellKnownGroupName -SidString 'S-1-5-32-545'
    try {
        if (Get-Command Add-LocalGroupMember -ErrorAction SilentlyContinue) {
            Add-LocalGroupMember -SID 'S-1-5-32-545' -Member $UserName -ErrorAction SilentlyContinue
        }
        else {
            $uGroup = [ADSI]"WinNT://$env:COMPUTERNAME/$usersGroupName,group"
            $uGroup.Invoke('Add', "WinNT://$env:COMPUTERNAME/$UserName,user")
        }
    }
    catch { }

    $null = Set-WinPassAdminMembership -UserName $UserName -Operation 'Add'
    return "Резервный администратор '$UserName' успешно создан и добавлен в группу локальных администраторов."
}

function New-WinPassRandomPassword {
    <#
    .SYNOPSIS
        Генерирует криптографически стойкий пароль заданной длины, гарантированно проходящий политики сложности Windows.
    #>
    param(
        [int]$Length = 12,
        [bool]$IncludeUpper = $true,
        [bool]$IncludeLower = $true,
        [bool]$IncludeDigits = $true,
        [bool]$IncludeSpecial = $true
    )

    if ($Length -lt 6) { $Length = 6 }
    if ($Length -gt 64) { $Length = 64 }

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $digits  = '23456789'
    $special = '!@#$%&*+-=?'

    $pool = ''
    $mandatoryChars = New-Object System.Collections.Generic.List[char]
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    function Get-RandomIndex([int]$Max) {
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $val = [BitConverter]::ToUInt32($bytes, 0)
        return [int]($val % [uint32]$Max)
    }

    if ($IncludeUpper)   { $pool += $upper;   $mandatoryChars.Add($upper[(Get-RandomIndex $upper.Length)]) }
    if ($IncludeLower)   { $pool += $lower;   $mandatoryChars.Add($lower[(Get-RandomIndex $lower.Length)]) }
    if ($IncludeDigits)  { $pool += $digits;  $mandatoryChars.Add($digits[(Get-RandomIndex $digits.Length)]) }
    if ($IncludeSpecial) { $pool += $special; $mandatoryChars.Add($special[(Get-RandomIndex $special.Length)]) }

    if ([string]::IsNullOrEmpty($pool)) {
        $pool = $lower + $digits
        $mandatoryChars.Add($lower[(Get-RandomIndex $lower.Length)])
    }

    while ($mandatoryChars.Count -lt $Length) {
        $mandatoryChars.Add($pool[(Get-RandomIndex $pool.Length)])
    }

    # Перемешивание Фишера-Йетса
    for ($i = $mandatoryChars.Count - 1; $i -gt 0; $i--) {
        $j = Get-RandomIndex ($i + 1)
        $temp = $mandatoryChars[$i]
        $mandatoryChars[$i] = $mandatoryChars[$j]
        $mandatoryChars[$j] = $temp
    }

    $rng.Dispose()
    return -join $mandatoryChars
}

function Get-PasswordStrengthInfo {
    <#
    .SYNOPSIS
        Оценивает надежность пароля по шкале от 0 до 100 и возвращает текстовую метку и цвет.
    #>
    param(
        [AllowEmptyString()]
        [string]$Password
    )

    if ([string]::IsNullOrEmpty($Password)) {
        return [PSCustomObject]@{
            Score = 0
            Label = 'Пустой пароль (вход без пароля)'
            Color = '#F59E0B'
        }
    }

    $score = 0
    if ($Password.Length -ge 8)  { $score += 25 }
    if ($Password.Length -ge 12) { $score += 20 }
    if ($Password -cmatch '[A-ZА-ЯЁ]') { $score += 15 }
    if ($Password -cmatch '[a-zа-яё]') { $score += 15 }
    if ($Password -match '\d')         { $score += 15 }
    if ($Password -match '[^a-zA-Zа-яА-ЯёЁ0-9]') { $score += 10 }

    if ($score -lt 40) {
        return [PSCustomObject]@{ Score = $score; Label = 'Слабый пароль'; Color = '#EF4444' }
    }
    elseif ($score -lt 75) {
        return [PSCustomObject]@{ Score = $score; Label = 'Средний пароль'; Color = '#F59E0B' }
    }
    else {
        return [PSCustomObject]@{ Score = $score; Label = 'Надежный пароль (проходит политику сложности)'; Color = '#10B981' }
    }
}
