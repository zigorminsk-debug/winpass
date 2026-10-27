# ==============================================================================
# WinPass Admin Suite - Модуль управления локальными политиками паролей
# Использует secedit.exe (SECURITYPOLICY) и net.exe accounts (не зависит от языка ОС)
# ==============================================================================

function Get-WinPassPasswordPolicy {
    <#
    .SYNOPSIS
        Считывает текущие локальные политики паролей и блокировки учетных записей Windows.
    #>
    $policy = [PSCustomObject]@{
        MinimumPasswordLength = 0
        MaximumPasswordAge    = 42
        MinimumPasswordAge    = 0
        PasswordHistorySize   = 0
        PasswordComplexity    = $false
        LockoutBadCount       = 0
        LockoutDuration       = 30
        ResetLockoutCount     = 30
    }

    $tempInf = Join-Path $env:TEMP ("winpass_secpol_" + [Guid]::NewGuid().ToString('N').Substring(0, 8) + ".inf")
    try {
        $null = & secedit.exe /export /cfg "$tempInf" /areas SECURITYPOLICY /quiet 2>&1
        if (Test-Path $tempInf) {
            $lines = Get-Content -Path $tempInf -ErrorAction SilentlyContinue
            foreach ($line in $lines) {
                if ($line -match '^\s*MinimumPasswordLength\s*=\s*(\d+)') {
                    $policy.MinimumPasswordLength = [int]$Matches[1]
                }
                elseif ($line -match '^\s*MaximumPasswordAge\s*=\s*(-?\d+)') {
                    $policy.MaximumPasswordAge = [int]$Matches[1]
                }
                elseif ($line -match '^\s*MinimumPasswordAge\s*=\s*(\d+)') {
                    $policy.MinimumPasswordAge = [int]$Matches[1]
                }
                elseif ($line -match '^\s*PasswordHistorySize\s*=\s*(\d+)') {
                    $policy.PasswordHistorySize = [int]$Matches[1]
                }
                elseif ($line -match '^\s*PasswordComplexity\s*=\s*(\d+)') {
                    $policy.PasswordComplexity = ([int]$Matches[1] -eq 1)
                }
                elseif ($line -match '^\s*LockoutBadCount\s*=\s*(\d+)') {
                    $policy.LockoutBadCount = [int]$Matches[1]
                }
                elseif ($line -match '^\s*LockoutDuration\s*=\s*(-?\d+)') {
                    $policy.LockoutDuration = [int]$Matches[1]
                }
                elseif ($line -match '^\s*ResetLockoutCount\s*=\s*(-?\d+)') {
                    $policy.ResetLockoutCount = [int]$Matches[1]
                }
            }
        }
    }
    catch { }
    finally {
        if (Test-Path $tempInf) {
            Remove-Item -Path $tempInf -Force -ErrorAction SilentlyContinue
        }
    }

    return $policy
}

function Set-WinPassPasswordPolicy {
    <#
    .SYNOPSIS
        Применяет новые параметры локальной политики паролей и блокировки через net accounts и secedit.
    #>
    param(
        [int]$MinPasswordLength = 0,
        [int]$MaxPasswordAgeDays = 0,
        [int]$LockoutThreshold = 0,
        [bool]$RequireComplexity = $false
    )

    if ($MinPasswordLength -lt 0)  { $MinPasswordLength = 0 }
    if ($MinPasswordLength -gt 14) { $MinPasswordLength = 14 }

    # 1. Применение параметров через net.exe accounts
    $maxAgeArg = if ($MaxPasswordAgeDays -le 0 -or $MaxPasswordAgeDays -gt 999) { 'UNLIMITED' } else { "$MaxPasswordAgeDays" }
    $null = & net.exe accounts /minpwlen:$MinPasswordLength /maxpwage:$maxAgeArg /minpwage:0 2>&1

    if ($LockoutThreshold -le 0) {
        $null = & net.exe accounts /lockoutthreshold:NEVER 2>&1
    }
    else {
        $null = & net.exe accounts /lockoutthreshold:$LockoutThreshold /lockoutduration:30 /lockoutwindow:30 2>&1
    }

    # 2. Применение PasswordComplexity через secedit.exe
    $tempId  = [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $tempInf = Join-Path $env:TEMP "winpass_apply_$tempId.inf"
    $tempSdb = Join-Path $env:TEMP "winpass_apply_$tempId.sdb"

    try {
        $complexityVal = if ($RequireComplexity) { 1 } else { 0 }
        $maxAgeSecedit = if ($MaxPasswordAgeDays -le 0) { -1 } else { $MaxPasswordAgeDays }
        $lockoutVal    = if ($LockoutThreshold -le 0) { 0 } else { $LockoutThreshold }

        $infContent = @"
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordAge = 0
MaximumPasswordAge = $maxAgeSecedit
MinimumPasswordLength = $MinPasswordLength
PasswordComplexity = $complexityVal
PasswordHistorySize = 0
LockoutBadCount = $lockoutVal
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
        [System.IO.File]::WriteAllText($tempInf, $infContent, [System.Text.Encoding]::Unicode)
        $null = & secedit.exe /configure /db "$tempSdb" /cfg "$tempInf" /areas SECURITYPOLICY /quiet 2>&1
    }
    catch {
        throw "Ошибка применения политики безопасности через secedit: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -Path $tempInf -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempSdb -Force -ErrorAction SilentlyContinue
    }

    $compText = if ($RequireComplexity) { 'Включена' } else { 'Отключена' }
    return "Политика паролей обновлена: мин. длина = $MinPasswordLength, сложность = $compText, порог блокировки = $LockoutThreshold."
}
