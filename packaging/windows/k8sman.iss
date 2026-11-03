; Inno Setup script for the k8sman Windows installer (Inno Setup 6.3+).
;
; Per-user install into %LOCALAPPDATA%\Programs\k8sman: no admin rights, a
; Start menu shortcut and an uninstaller (Settings > Apps). The app's own
; settings (%USERPROFILE%\.config\k8sman) are kept on uninstall.
;
; Built by .github/workflows/windows.yml:
;   iscc /DAppVersion=0.1.0 /DAppSourceDir=<Release dir> /DAppOutputDir=<dist> packaging\windows\k8sman.iss
; Paths default to the `flutter build windows --release` output and dist\.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef AppSourceDir
  #define AppSourceDir "..\..\frontend\build\windows\x64\runner\Release"
#endif
#ifndef AppOutputDir
  #define AppOutputDir "..\..\dist"
#endif
; "0.2.0-rc.1" -> "0.2.0": the file version must be numeric.
#define NumericVersion Copy(AppVersion, 1, Pos("-", AppVersion + "-") - 1)

[Setup]
; Never change AppId: it ties upgrades and the uninstaller together.
AppId={{6ED524D2-2922-40DE-9FE8-AB60738E3E4F}
AppName=k8sman
AppVersion={#AppVersion}
AppVerName=k8sman {#AppVersion}
AppPublisher=The k8sman authors
AppPublisherURL=https://github.com/matty234/k8sman
AppSupportURL=https://github.com/matty234/k8sman/issues
AppUpdatesURL=https://github.com/matty234/k8sman/releases
AppCopyright=Copyright (C) 2026 The k8sman authors
VersionInfoVersion={#NumericVersion}
DefaultDirName={localappdata}\Programs\k8sman
DefaultGroupName=k8sman
DisableProgramGroupPage=yes
DisableDirPage=auto
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#AppOutputDir}
OutputBaseFilename=k8sman-{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\frontend\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\k8sman.exe
UninstallDisplayName=k8sman
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Upgrades close a running k8sman (and its backend) first.
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#AppSourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
; Assets from an older version (the bundle is replaced wholesale).
Type: filesandordirs; Name: "{app}\data"

[Icons]
Name: "{autoprograms}\k8sman"; Filename: "{app}\k8sman.exe"
Name: "{autodesktop}\k8sman"; Filename: "{app}\k8sman.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\k8sman.exe"; Description: "{cm:LaunchProgram,k8sman}"; Flags: nowait postinstall skipifsilent
