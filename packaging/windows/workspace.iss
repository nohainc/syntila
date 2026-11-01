#ifndef BundleDir
  #error BundleDir must point to the complete Windows release bundle
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
[Setup]
AppId={{77334D81-D586-4FF6-BC89-CB844B9A9D37}
AppName=Syntila Workspace
AppVersion={#AppVersion}
AppPublisher=Syntila
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Syntila Workspace
VersionInfoCompany=Syntila
DefaultDirName={localappdata}\Programs\Syntila\Workspace
DefaultGroupName=Syntila
PrivilegesRequired=lowest
MinVersion=10.0.17763
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Syntila-Workspace-{#AppVersion}-windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
CloseApplications=no
RestartApplications=no
#if FileExists(BundleDir + "\gui\syntila-workspace-gui.exe")
UninstallDisplayIcon={app}\gui\syntila-workspace-gui.exe
#else
UninstallDisplayIcon={app}\syntila.exe
#endif
SetupLogging=yes
#ifdef SignInstaller
; Signs Setup.exe and the embedded uninstaller with the "syntila" sign tool
; passed by scripts/package-workspace-windows.ps1 -Sign.
SignTool=syntila
SignedUninstaller=yes
#endif

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

#if FileExists(BundleDir + "\gui\syntila-workspace-gui.exe")
[Icons]
Name: "{group}\Syntila Workspace"; Filename: "{app}\gui\syntila-workspace-gui.exe"; WorkingDir: "{app}"
#endif

[Code]
// Never force-close the service or provider processes during an assignment.
function WorkspaceRunning(): Boolean;
var Locator, Services, Processes: Variant;
begin
  Result := True;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('', 'root\CIMV2');
    Processes := Services.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name = ''syntila.exe'' OR Name = ''syntila-service.exe'' OR Name = ''syntila-workspace-gui.exe''');
    Result := Processes.Count > 0;
  except
    // If process inspection fails, preserve the existing installation.
    Result := True;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if WorkspaceRunning() then
    Result := 'Stop the Workspace Service and close Syntila Workspace before installing. Your data will be preserved.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := not WorkspaceRunning();
  if not Result then
    SuppressibleMsgBox('Stop the Workspace Service and close Syntila Workspace before uninstalling. Your data will be preserved.', mbError, MB_OK, IDOK);
end;
