# Run only on a disposable Windows CI runner. Uses an isolated application folder.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = Split-Path $PSScriptRoot -Parent
$Installer = @(Get-ChildItem (Join-Path $Root 'dist/connect/installer/*Setup.exe'))
if ($Installer.Count -ne 1) { throw 'Expected exactly one Connect installer.' }
$Target = Join-Path $env:LOCALAPPDATA 'Programs/Syntila/Connect-Installer-Test'
function Run-Setup {
    $Process = Start-Process $Installer[0].FullName -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/DIR=`"$Target`"") -Wait -PassThru
    if ($Process.ExitCode -ne 0) { throw "Setup failed: $($Process.ExitCode)" }
}

# ADR-034 decision 10: per-user install, no administrator rights.
$Script = Get-Content (Join-Path $Root 'packaging/windows/connect.iss') -Raw
if ($Script -notmatch '(?m)^PrivilegesRequired=lowest\s*$') { throw 'Installer must use PrivilegesRequired=lowest.' }
if ($Script -notmatch '(?m)^DefaultDirName=\{localappdata\}\\Programs\\Syntila\\Connect\s*$') { throw 'Default install folder must be %LOCALAPPDATA%\Programs\Syntila\Connect.' }
$Principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
Run-Setup
if (-not (Test-Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{9A4E7B21-3C14-4F8B-9D62-5E1A8C3D4F10}_is1')) {
    throw 'Install did not register a per-user uninstall entry (HKCU).'
}
foreach ($File in @('syntila-connect.exe', 'syntila-worker.exe', 'Syntila Connect.exe')) {
    if ((Get-FileHash (Join-Path $Target $File)).Hash -ne
        (Get-FileHash (Join-Path $Root "dist/connect/windows/release/$File")).Hash) {
        throw "Installed file mismatch: $File"
    }
}
$Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Syntila/Syntila Connect.lnk'
if (-not (Test-Path $Shortcut)) { throw 'Syntila Connect Start menu shortcut is missing.' }

& (Join-Path $Target 'syntila-connect.exe') help | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Installed syntila-connect.exe help failed: $LASTEXITCODE" }

# Simulate files left by the previous bundle layout before upgrading.
New-Item -ItemType Directory -Force (Join-Path $Target 'engine') | Out-Null
Set-Content (Join-Path $Target 'engine/syntila-worker.exe') 'old engine'
Set-Content (Join-Path $Target 'syntila_connect_gui.exe') 'old desktop app'
# Repeat installation to exercise the stable AppId upgrade path.
Run-Setup
foreach ($OldFile in @('engine/syntila-worker.exe', 'syntila_connect_gui.exe')) {
    if (Test-Path (Join-Path $Target $OldFile)) { throw "Upgrade left $OldFile behind." }
}

$Uninstall = Start-Process (Join-Path $Target 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -Wait -PassThru
if ($Uninstall.ExitCode -ne 0) { throw "Uninstall failed: $($Uninstall.ExitCode)" }
foreach ($File in @('syntila-connect.exe', 'Syntila Connect.exe')) {
    if (Test-Path (Join-Path $Target $File)) { throw "Uninstall left $File behind." }
}
