; Built by tools/build_windows_installer.ps1 from the verified release folder.
; Per-user install. Meteor's models, downloads, key and settings stay in AppData.
#ifndef Stage
  #error Stage must point to the Windows release folder
#endif
#ifndef AppVersion
  #error AppVersion must match Cargo.toml
#endif
#ifndef RepoRoot
  #error RepoRoot must point to the Nightfall repository
#endif
#ifndef Output
  #error Output must point to the installer output folder
#endif

[Setup]
AppId=Nightfall.Meteor
AppName=Nightfall Meteor
AppVersion={#AppVersion}
AppPublisher=Nightfall
AppPublisherURL=https://github.com/tB0nE/nightfall
AppSupportURL=https://github.com/tB0nE/nightfall/issues
DefaultDirName={localappdata}\Programs\Nightfall Meteor
DefaultGroupName=Nightfall Meteor
DisableProgramGroupPage=yes
SetupArchitecture=x64
PrivilegesRequired=lowest
LicenseFile={#RepoRoot}\LICENSE
OutputDir={#Output}
OutputBaseFilename=Nightfall-Meteor-{#AppVersion}-Setup-x64
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\nightfall-meteor.exe
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; Flags: unchecked
Name: "builtinhost"; Description: "Use Meteor's built-in desktop streaming host"
Name: "pcvr"; Description: "Set up PCVR for installed games"

[Files]
Source: "{#Stage}\nightfall-meteor.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\ncnn.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\avcodec-62.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\avutil-60.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\swscale-9.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\swresample-6.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\meteor_vda_vulkan.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\msvcp*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\vcruntime*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\vccorlib*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\concrt*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\vcomp*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\Setup-Meteor.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\Meteor-Cli.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\Pair-Headset.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\Install-SteamVR.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\SteamVR-Driver.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Stage}\share\doc\nightfall-meteor\runtime\*"; DestDir: "{app}\share\doc\nightfall-meteor\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Stage}\share\nightfall-meteor\models\*"; DestDir: "{app}\share\nightfall-meteor\models"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Stage}\share\doc\nightfall-meteor\LICENSE"; DestDir: "{app}\share\doc\nightfall-meteor"; Flags: ignoreversion
Source: "{#Stage}\share\doc\nightfall-meteor\FFmpeg-LICENSE.txt"; DestDir: "{app}\share\doc\nightfall-meteor"; Flags: ignoreversion
Source: "{#Stage}\share\doc\nightfall-meteor\THIRD_PARTY_NOTICES.txt"; DestDir: "{app}\share\doc\nightfall-meteor"; Flags: ignoreversion

[Icons]
Name: "{group}\Nightfall Meteor"; Filename: "{app}\nightfall-meteor.exe"; WorkingDir: "{app}"
Name: "{group}\Pair a Nightfall headset"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\Pair-Headset.ps1"""; WorkingDir: "{app}"
Name: "{group}\Set up Nightfall Meteor"; Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Meteor.ps1"" -EnableHost -EnablePCVR"; WorkingDir: "{app}"
Name: "{group}\Uninstall Nightfall Meteor"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Nightfall Meteor"; Filename: "{app}\nightfall-meteor.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\Setup-Meteor.ps1"" {code:SetupFlags}"; Flags: runhidden waituntilterminated runasoriginaluser; Check: HasSetupTasks
Filename: "{app}\nightfall-meteor.exe"; Description: "Launch Nightfall Meteor"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
function HasSetupTasks: Boolean;
begin
  Result := WizardIsTaskSelected('builtinhost') or WizardIsTaskSelected('pcvr');
end;

function SetupFlags(Param: String): String;
begin
  Result := '';
  if WizardIsTaskSelected('builtinhost') then Result := Result + ' -EnableHost';
  if WizardIsTaskSelected('pcvr') then Result := Result + ' -EnablePCVR';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  RunKey, Command, InstalledCommand: String;
  DriverResult: Integer;
begin
  if CurUninstallStep <> usUninstall then Exit;
  if FileExists(ExpandConstant('{app}\SteamVR-Driver.ps1')) and
     FileExists(ExpandConstant('{localappdata}\Nightfall Meteor\steamvr-driver-registration.json')) then
    Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -File "' + ExpandConstant('{app}\SteamVR-Driver.ps1') + '" -Action Unregister',
      '', SW_HIDE, ewWaitUntilTerminated, DriverResult);
  RunKey := 'Software\Microsoft\Windows\CurrentVersion\Run';
  InstalledCommand := '"' + ExpandConstant('{app}\nightfall-meteor.exe') + '"';
  if RegQueryStringValue(HKCU, RunKey, 'Nightfall Meteor', Command) and
     (CompareText(Command, InstalledCommand) = 0) then
    RegDeleteValue(HKCU, RunKey, 'Nightfall Meteor');
end;
