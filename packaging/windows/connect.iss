#ifndef BundleDir
  #error BundleDir must point to the complete Windows Connect release bundle
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif
[Setup]
AppId={{9A4E7B21-3C14-4F8B-9D62-5E1A8C3D4F10}
AppName=Syntila Connect
AppVersion={#AppVersion}
AppPublisher=Syntila
VersionInfoVersion={#AppVersion}
VersionInfoProductName=Syntila Connect
VersionInfoCompany=Syntila
DefaultDirName={localappdata}\Programs\Syntila\Connect
DefaultGroupName=Syntila
PrivilegesRequired=lowest
MinVersion=10.0.17763
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Syntila-Connect-{#AppVersion}-windows-x64-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
CloseApplications=no
RestartApplications=no
#if FileExists(BundleDir + "\Syntila Connect.exe")
UninstallDisplayIcon={app}\Syntila Connect.exe
#else
UninstallDisplayIcon={app}\syntila-connect.exe
#endif
SetupLogging=yes

[InstallDelete]
Type: files; Name: "{app}\syntila_connect_gui.exe"
Type: files; Name: "{app}\engine\syntila-worker.exe"

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

#if FileExists(BundleDir + "\Syntila Connect.exe")
[Icons]
Name: "{group}\Syntila Connect"; Filename: "{app}\Syntila Connect.exe"; WorkingDir: "{app}"
#endif

[Code]
// Never force-close Connect or Worker Engine processes during an assignment.
function ConnectRunning(): Boolean;
var Locator, Services, Processes: Variant;
begin
  Result := True;
  try
    Locator := CreateOleObject('WbemScripting.SWbemLocator');
    Services := Locator.ConnectServer('', 'root\CIMV2');
    Processes := Services.ExecQuery('SELECT ProcessId FROM Win32_Process WHERE Name = ''syntila-connect.exe'' OR Name = ''syntila-worker.exe'' OR Name = ''Syntila Connect.exe'' OR Name = ''syntila_connect_gui.exe''');
    Result := Processes.Count > 0;
  except
    // If process inspection fails, preserve the existing installation.
    Result := True;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if ConnectRunning() then
    Result := 'Stop Syntila Connect and close any running Workers before installing. Your data will be preserved.';
end;

function InitializeUninstall(): Boolean;
begin
  Result := not ConnectRunning();
  if not Result then
    SuppressibleMsgBox('Stop Syntila Connect and close any running Workers before uninstalling. Your data will be preserved.', mbError, MB_OK, IDOK);
end;
