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

[Files]
Source: "{#Stage}\nightfall-meteor.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\ncnn.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#Stage}\share\nightfall-meteor\models\zipdepth_wide_512x288.ncnn.param"; DestDir: "{app}\share\nightfall-meteor\models"; Flags: ignoreversion
Source: "{#Stage}\share\nightfall-meteor\models\zipdepth_wide_512x288.ncnn.bin"; DestDir: "{app}\share\nightfall-meteor\models"; Flags: ignoreversion
Source: "{#Stage}\share\doc\nightfall-meteor\LICENSE"; DestDir: "{app}\share\doc\nightfall-meteor"; Flags: ignoreversion
Source: "{#Stage}\share\doc\nightfall-meteor\THIRD_PARTY_NOTICES.txt"; DestDir: "{app}\share\doc\nightfall-meteor"; Flags: ignoreversion

[Icons]
Name: "{group}\Nightfall Meteor"; Filename: "{app}\nightfall-meteor.exe"; WorkingDir: "{app}"
Name: "{group}\Uninstall Nightfall Meteor"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Nightfall Meteor"; Filename: "{app}\nightfall-meteor.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\nightfall-meteor.exe"; Description: "Launch Nightfall Meteor"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  RunKey, Command, InstalledCommand: String;
begin
  if CurUninstallStep <> usUninstall then Exit;
  RunKey := 'Software\Microsoft\Windows\CurrentVersion\Run';
  InstalledCommand := '"' + ExpandConstant('{app}\nightfall-meteor.exe') + '"';
  if RegQueryStringValue(HKCU, RunKey, 'Nightfall Meteor', Command) and
     (CompareText(Command, InstalledCommand) = 0) then
    RegDeleteValue(HKCU, RunKey, 'Nightfall Meteor');
end;
