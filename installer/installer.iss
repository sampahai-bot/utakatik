#define AppName "PDF Office Converter"
#define AppVersion "1.0.0"
[Setup]
AppId={{6F1D2C8A-3B7E-4C55-9A21-5D0E7A4B9C31}
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\{#AppName}
DefaultGroupName={#AppName}
PrivilegesRequired=lowest
OutputDir=output
OutputBaseFilename=PDF-Office-Converter-Setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
WizardStyle=modern
[Files]
Source: "..\flutter\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\pdf_office_converter.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\pdf_office_converter.exe"; Tasks: desktopicon
[Tasks]
Name: "desktopicon"; Description: "Buat ikon di Desktop"
[Run]
Filename: "{app}\pdf_office_converter.exe"; Description: "Jalankan {#AppName}"; Flags: nowait postinstall skipifsilent
