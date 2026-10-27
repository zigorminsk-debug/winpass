@echo off
chcp 65001 >nul
title WinPass Admin Suite - Консоль восстановления WinPE / WinRE
color 1F

set "SCRIPT_DIR=%~dp0"

:MAIN_MENU
cls
echo ============================================================================
echo        WINPASS ADMIN SUITE v2.0 — РЕЖИМ ВОССТАНОВЛЕНИЯ WINPE / WINRE
echo ============================================================================
echo.
echo  Обнаруженные разделы с установленной ОС Windows:
for %%D in (C D E F G H I J K L M N O P Q R S T U V W Y Z) do (
    if exist "%%D:\Windows\System32\config\SAM" (
        echo    [*] Диск %%D:\  -- Найдена ОС Windows [%%D:\Windows]
    )
)
echo.
echo ----------------------------------------------------------------------------
echo  Выберите действие:
echo    [1] Запустить графический интерфейс WinPass-GUI (PowerShell + WPF)
echo    [2] Установить перехват 5x SHIFT (sethc.exe) + скопировать WinPass на диск ОС
echo    [3] Восстановить оригинальные системные файлы (sethc.exe / utilman.exe)
echo    [4] Сбросить забытый ПИН-код Windows Hello (очистка контейнера Ngc)
echo    [5] Открыть командную строку администратора (cmd.exe)
echo    [0] Выход / Перезагрузка ПК
echo ============================================================================
echo.
set /p CHOICE="Ваш выбор [0-5]: "

if "%CHOICE%"=="1" goto RUN_GUI
if "%CHOICE%"=="2" goto INSTALL_BYPASS
if "%CHOICE%"=="3" goto RESTORE_BYPASS
if "%CHOICE%"=="4" goto RESET_PIN
if "%CHOICE%"=="5" (start cmd.exe & goto MAIN_MENU)
if "%CHOICE%"=="0" exit /b 0
goto MAIN_MENU

:RUN_GUI
echo.
echo [*] Запуск графического интерфейса WinPass-GUI.ps1...
if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -NoElevate -File "%SCRIPT_DIR%WinPass-GUI.ps1"
) else (
    echo [!] В этом минимальном образе WinRE компонент PowerShell/WPF отключен.
    echo [!] Используйте пункт [2], чтобы активировать запуск WinPass-GUI на экране входа Windows!
)
pause
goto MAIN_MENU

:INSTALL_BYPASS
echo.
set /p TARGET_DRV="Введите букву диска с установленной Windows (например C): "
set "TARGET_DRV=%TARGET_DRV:~0,1%"
if not exist "%TARGET_DRV%:\Windows\System32\sethc.exe" (
    echo [ОШИБКА] На диске %TARGET_DRV%: не найден файл Windows\System32\sethc.exe!
    pause
    goto MAIN_MENU
)

echo [*] Получение прав на %TARGET_DRV%:\Windows\System32\sethc.exe...
takeown /f "%TARGET_DRV%:\Windows\System32\sethc.exe" >nul 2>&1
icacls "%TARGET_DRV%:\Windows\System32\sethc.exe" /grant "*S-1-5-32-544:F" >nul 2>&1

if not exist "%TARGET_DRV%:\Windows\System32\sethc.exe.winpass.bak" (
    copy /y "%TARGET_DRV%:\Windows\System32\sethc.exe" "%TARGET_DRV%:\Windows\System32\sethc.exe.winpass.bak" >nul
    echo [OK] Создана резервная копия: sethc.exe.winpass.bak
)

copy /y "%TARGET_DRV%:\Windows\System32\cmd.exe" "%TARGET_DRV%:\Windows\System32\sethc.exe" >nul
echo [OK] Перехват 5x SHIFT (sethc.exe -> cmd.exe) установлен!

echo [*] Копирование WinPass Admin Suite в %TARGET_DRV%:\WinPass-Admin...
if not exist "%TARGET_DRV%:\WinPass-Admin\modules" mkdir "%TARGET_DRV%:\WinPass-Admin\modules"
if not exist "%TARGET_DRV%:\WinPass-Admin\ui" mkdir "%TARGET_DRV%:\WinPass-Admin\ui"
if not exist "%TARGET_DRV%:\WinPass-Admin\logs" mkdir "%TARGET_DRV%:\WinPass-Admin\logs"
copy /y "%SCRIPT_DIR%WinPass-GUI.ps1" "%TARGET_DRV%:\WinPass-Admin\" >nul
copy /y "%SCRIPT_DIR%Run-WinPass.bat" "%TARGET_DRV%:\WinPass-Admin\" >nul
copy /y "%SCRIPT_DIR%Start-WinPE.cmd" "%TARGET_DRV%:\WinPass-Admin\" >nul
copy /y "%SCRIPT_DIR%modules\*.ps1" "%TARGET_DRV%:\WinPass-Admin\modules\" >nul
copy /y "%SCRIPT_DIR%ui\*.xaml" "%TARGET_DRV%:\WinPass-Admin\ui\" >nul

echo.
echo ============================================================================
echo  ГОТОВО! Инструкция для сброса пароля:
echo  1. Перезагрузите компьютер в обычный режим Windows.
echo  2. На экране входа в систему нажмите клавишу SHIFT 5 раз подряд.
echo  3. В открывшемся окне выполните: C:\WinPass-Admin\Run-WinPass.bat
echo  4. После сброса пароля нажмите «Восстановить оригинальные системные файлы».
echo ============================================================================
pause
goto MAIN_MENU

:RESTORE_BYPASS
echo.
set /p TARGET_DRV="Введите букву диска с установленной Windows (например C): "
set "TARGET_DRV=%TARGET_DRV:~0,1%"
if exist "%TARGET_DRV%:\Windows\System32\sethc.exe.winpass.bak" (
    takeown /f "%TARGET_DRV%:\Windows\System32\sethc.exe" >nul 2>&1
    icacls "%TARGET_DRV%:\Windows\System32\sethc.exe" /grant "*S-1-5-32-544:F" >nul 2>&1
    copy /y "%TARGET_DRV%:\Windows\System32\sethc.exe.winpass.bak" "%TARGET_DRV%:\Windows\System32\sethc.exe" >nul
    del /f /q "%TARGET_DRV%:\Windows\System32\sethc.exe.winpass.bak" >nul
    echo [OK] Файл sethc.exe восстановлен в исходное состояние!
) else (
    echo [i] Резервная копия sethc.exe.winpass.bak не найдена.
)
if exist "%TARGET_DRV%:\Windows\System32\utilman.exe.winpass.bak" (
    takeown /f "%TARGET_DRV%:\Windows\System32\utilman.exe" >nul 2>&1
    icacls "%TARGET_DRV%:\Windows\System32\utilman.exe" /grant "*S-1-5-32-544:F" >nul 2>&1
    copy /y "%TARGET_DRV%:\Windows\System32\utilman.exe.winpass.bak" "%TARGET_DRV%:\Windows\System32\utilman.exe" >nul
    del /f /q "%TARGET_DRV%:\Windows\System32\utilman.exe.winpass.bak" >nul
    echo [OK] Файл utilman.exe восстановлен в исходное состояние!
)
pause
goto MAIN_MENU

:RESET_PIN
echo.
set /p TARGET_DRV="Введите букву диска с установленной Windows (например C): "
set "TARGET_DRV=%TARGET_DRV:~0,1%"
set "NGC_DIR=%TARGET_DRV%:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
if not exist "%NGC_DIR%" (
    echo [i] Папка ПИН-кода (%NGC_DIR%) не найдена или уже очищена.
    pause
    goto MAIN_MENU
)
echo [*] Получение прав и сброс контейнера ПИН-кода Windows Hello...
takeown /f "%NGC_DIR%" /r /d y >nul 2>&1
icacls "%NGC_DIR%" /grant "*S-1-5-32-544:F" /t /c /q >nul 2>&1
if exist "%NGC_DIR%.winpass.bak" rd /s /q "%NGC_DIR%.winpass.bak"
move /y "%NGC_DIR%" "%NGC_DIR%.winpass.bak" >nul
mkdir "%NGC_DIR%" >nul
echo [OK] Контейнер ПИН-кода сброшен (копия в Ngc.winpass.bak). Теперь доступен вход по паролю!
pause
goto MAIN_MENU
