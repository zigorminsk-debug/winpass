@echo off
chcp 65001 >nul
title WinPass Admin Suite - Launcher

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%WinPass-GUI.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERROR] Файл "%PS_SCRIPT%" не найден!
    pause
    exit /b 1
)

:: Проверка среды WinPE (ключ реестра MiniNT)
reg query "HKLM\SYSTEM\CurrentControlSet\Control\MiniNT" >nul 2>&1
if %errorlevel% equ 0 (
    echo [WinPE] Обнаружена среда восстановления Windows PE / WinRE. Запуск GUI...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoElevate -File "%PS_SCRIPT%"
    exit /b 0
)

:: Проверка наличия прав Администратора
net session >nul 2>&1
if %errorlevel% equ 0 (
    echo [OK] Запуск WinPass Admin Suite с правами Администратора...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -NoElevate -File "%PS_SCRIPT%"
) else (
    echo [UAC] Запрос повышения привилегий до Администратора...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -ExecutionPolicy Bypass -STA -NoElevate -File ""%PS_SCRIPT%""' -Verb RunAs"
)
exit /b 0
