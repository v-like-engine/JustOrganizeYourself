#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef BundleDirectory
  #error BundleDirectory must point to the self-contained release folder.
#endif
#ifndef OutputDirectory
  #error OutputDirectory is required.
#endif

[Setup]
AppId={{3A52C758-5DEE-4ABD-B0E1-64566DE851B7}
AppName=Just Organize Yourself
AppVersion={#AppVersion}
AppPublisher=Just Organize Yourself
DefaultDirName={localappdata}\Programs\Just Organize Yourself
DefaultGroupName=Just Organize Yourself
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#OutputDirectory}
OutputBaseFilename=JOY-Windows-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\JustOrganizeYourself.exe
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BundleDirectory}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Just Organize Yourself"; Filename: "{app}\JustOrganizeYourself.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Just Organize Yourself"; Filename: "{app}\JustOrganizeYourself.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\JustOrganizeYourself.exe"; Description: "{cm:LaunchProgram,Just Organize Yourself}"; Flags: nowait postinstall skipifsilent
