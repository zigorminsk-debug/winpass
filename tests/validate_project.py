#!/usr/bin/env python3
"""
Автоматическая проверка целостности, кодировок Windows (UTF-8 BOM для PS 5.1,
UTF-8 без BOM + CRLF для .bat/.cmd), валидности WPF XAML и привязок элементов UI.
"""

import os
import re
import sys
import xml.etree.ElementTree as ET

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

PS1_FILES = [
    "WinPass-GUI.ps1",
    "WinPass-WinPE-GUI.ps1",
    "winpe/Build-WinPassWinPE.ps1",
    "modules/LocalAccounts.ps1",
    "modules/SavedCredentials.ps1",
    "modules/OfflineWinPE.ps1",
    "modules/PasswordPolicy.ps1",
    "modules/ReportExporter.ps1",
]

BAT_FILES = [
    "Run-WinPass.bat",
    "Start-WinPE.cmd",
]

XAML_FILE = "ui/MainWindow.xaml"


def normalize_encodings():
    """Приводит .ps1 к UTF-8 с BOM + CRLF (требование Windows PowerShell 5.1 для кириллицы),
    а .bat/.cmd — к UTF-8 без BOM + CRLF (требование cmd.exe)."""
    for rel in PS1_FILES:
        path = os.path.join(ROOT, rel)
        with open(path, "rb") as f:
            raw = f.read()
        if raw.startswith(b"\xef\xbb\xbf"):
            raw = raw[3:]
        text = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
        text_crlf = text.replace("\n", "\r\n")
        with open(path, "wb") as f:
            f.write(b"\xef\xbb\xbf" + text_crlf.encode("utf-8"))

    for rel in BAT_FILES:
        path = os.path.join(ROOT, rel)
        with open(path, "rb") as f:
            raw = f.read()
        if raw.startswith(b"\xef\xbb\xbf"):
            raw = raw[3:]
        text = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
        text_crlf = text.replace("\n", "\r\n")
        with open(path, "wb") as f:
            f.write(text_crlf.encode("utf-8"))


def verify_xaml_and_bindings():
    xaml_path = os.path.join(ROOT, XAML_FILE)
    tree = ET.parse(xaml_path)
    root = tree.getroot()

    ns_x = "{http://schemas.microsoft.com/winfx/2006/xaml}"
    xaml_names = set()
    xaml_keys = set()
    static_refs = set()

    for elem in root.iter():
        name_attr = elem.attrib.get(f"{ns_x}Name") or elem.attrib.get("Name")
        if name_attr:
            xaml_names.add(name_attr)
        key_attr = elem.attrib.get(f"{ns_x}Key")
        if key_attr:
            xaml_keys.add(key_attr)
        for val in elem.attrib.values():
            for match in re.findall(r"\{StaticResource\s+([^\}]+)\}", val):
                static_refs.add(match.strip())

    missing_keys = static_refs - xaml_keys
    assert not missing_keys, f"Не найдены StaticResource ключи в XAML: {missing_keys}"

    gui_path = os.path.join(ROOT, "WinPass-GUI.ps1")
    with open(gui_path, "r", encoding="utf-8-sig") as f:
        gui_code = f.read()

    ui_refs = set(re.findall(r"\$ui\['([^']+)'\]", gui_code))
    assert len(ui_refs) > 40, f"Слишком мало привязок UI: {len(ui_refs)}"

    missing_in_xaml = ui_refs - xaml_names
    assert not missing_in_xaml, f"Элементы из WinPass-GUI.ps1 отсутствуют в MainWindow.xaml: {missing_in_xaml}"

    print(f"[OK] XAML валиден: {len(xaml_names)} именованных контролов, {len(xaml_keys)} стилей, все {len(ui_refs)} привязок совпадают.")


def verify_powershell_functions():
    defined_funcs = set()
    for rel in PS1_FILES:
        path = os.path.join(ROOT, rel)
        with open(path, "r", encoding="utf-8-sig") as f:
            content = f.read()
        for m in re.findall(r"function\s+([A-Za-z0-9_-]+)", content):
            defined_funcs.add(m)

    expected_funcs = {
        "Test-IsAdministrator",
        "Resolve-WellKnownGroupName",
        "Get-WinPassLocalUsers",
        "Reset-WinPassUserPassword",
        "Set-WinPassAccountState",
        "Set-WinPassAdminMembership",
        "Enable-WinPassBuiltInAdmin",
        "New-WinPassEmergencyAdmin",
        "New-WinPassRandomPassword",
        "Get-PasswordStrengthInfo",
        "Get-WinPassWifiPasswords",
        "Get-WinPassSavedCredentials",
        "Get-WinPassAutoLogonInfo",
        "Set-WinPassAutoLogon",
        "Test-IsWinPEEnvironment",
        "Get-WinPassOfflineWindowsInstallations",
        "Get-WinPassOfflineSamUsers",
        "Unlock-WinPassOfflineSamUser",
        "Clear-WinPassOfflineSamPassword",
        "Restore-WinPassOfflineSamBackup",
        "Get-WinPassOfflineAutoLogon",
        "Install-WinPassStickyKeysBypass",
        "Restore-WinPassStickyKeysBypass",
        "Reset-WinPassOfflinePinNgc",
        "Export-WinPassPortableUsb",
        "Get-WinPassPasswordPolicy",
        "Set-WinPassPasswordPolicy",
        "Write-WinPassAuditLog",
        "Get-WinPassAuditLog",
        "Export-WinPassHtmlReport",
        "Export-WinPassUserHandoverCard",
    }

    missing_funcs = expected_funcs - defined_funcs
    assert not missing_funcs, f"Отсутствуют обязательные функции: {missing_funcs}"
    print(f"[OK] Проверено {len(defined_funcs)} функций PowerShell во всех модулях.")


def verify_encodings():
    for rel in PS1_FILES:
        path = os.path.join(ROOT, rel)
        with open(path, "rb") as f:
            raw = f.read()
        assert raw.startswith(b"\xef\xbb\xbf"), f"Файл {rel} должен иметь UTF-8 BOM для совместимости с Windows PowerShell 5.1!"
        assert b"\r\n" in raw, f"Файл {rel} должен иметь окончания строк CRLF!"

    for rel in BAT_FILES:
        path = os.path.join(ROOT, rel)
        with open(path, "rb") as f:
            raw = f.read()
        assert not raw.startswith(b"\xef\xbb\xbf"), f"Файл {rel} НЕ должен иметь BOM в первой строке для cmd.exe!"
        assert raw.startswith(b"@echo off\r\n"), f"Файл {rel} должен начинаться с @echo off\\r\\n!"

    print("[OK] Кодировки всех .ps1 (UTF-8 BOM + CRLF) и .bat/.cmd (UTF-8 без BOM + CRLF) проверены.")


if __name__ == "__main__":
    try:
        normalize_encodings()
        verify_encodings()
        verify_xaml_and_bindings()
        verify_powershell_functions()
        print("[SUCCESS] Все проверки проекта WinPass Admin Suite пройдены успешно!")
    except Exception as exc:
        print(f"::error title=ValidateProjectError::{exc}")
        raise
