; Per-user installer (no admin prompt): installs to %LOCALAPPDATA%\Programs\MC Download Manager.
; Built by scripts\build.ps1, which passes AppVersion and SourceDir.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\publish"
#endif

[Setup]
AppId={{6F1C2D7E-8B6A-4E8C-9C5B-3D2A7F1E4B90}
AppName=MC Download Manager
AppVersion={#AppVersion}
AppPublisher=MC Download Manager
DefaultDirName={localappdata}\Programs\MC Download Manager
DefaultGroupName=MC Download Manager
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputBaseFilename=MC-Download-Manager-{#AppVersion}-setup
SetupIconFile=..\src\Resources\app.ico
UninstallDisplayIcon={app}\MCDownloadManager.exe
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
CloseApplications=force

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "tr"; MessagesFile: "compiler:Languages\Turkish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\MC Download Manager"; Filename: "{app}\MCDownloadManager.exe"
Name: "{autodesktop}\MC Download Manager"; Filename: "{app}\MCDownloadManager.exe"; Tasks: desktopicon

[Registry]
; Written by the app at runtime; removed on uninstall.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "MC Download Manager"; ValueType: none; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Google\Chrome\NativeMessagingHosts\com.mesutcevik.mcdownloadmanager"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Microsoft\Edge\NativeMessagingHosts\com.mesutcevik.mcdownloadmanager"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.mesutcevik.mcdownloadmanager"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Chromium\NativeMessagingHosts\com.mesutcevik.mcdownloadmanager"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Mozilla\NativeMessagingHosts\com.mesutcevik.mcdownloadmanager"; Flags: uninsdeletekey

[Run]
Filename: "{app}\MCDownloadManager.exe"; Description: "{cm:LaunchProgram,MC Download Manager}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/IM MCDownloadManager.exe /F"; Flags: runhidden; RunOnceId: "StopApp"
