#define AppName "FaceSwap Studio"
#ifndef AppVersion
#define AppVersion "0.1.0"
#endif
#define AppPublisher "FaceSwap Studio"
#define AppExeName "启动FaceSwap Studio.exe"

[Setup]
AppId={{B19D9CFB-DB06-4DF1-81F1-0E12AA3A7A10}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={code:GetDefaultInstallDir}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
OutputDir=..\dist\installer
OutputBaseFilename=FaceSwapStudioSetup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
PrivilegesRequired=admin
SetupIconFile=..\facefusion.ico
UninstallDisplayIcon={app}\{#AppExeName}

[Files]
Source: "..\build\installer\app\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{commondesktop}\FaceSwap Studio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\facefusion.ico"
Name: "{group}\FaceSwap Studio"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\facefusion.ico"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\repair_runtime.ps1"""; Flags: runhidden waituntilterminated

[Code]
const
  RequiredFreeMB = 12288;

var
  CachedDefaultInstallDir: String;

function HasEnoughSpace(DriveRoot: String): Boolean;
var
  FreeMB: Cardinal;
  TotalMB: Cardinal;
begin
  Result := False;
  if GetSpaceOnDisk(DriveRoot, True, FreeMB, TotalMB) then
    Result := FreeMB >= RequiredFreeMB;
end;

function ResolveBestInstallDrive(): String;
var
  Index: Integer;
  Drive: String;
  DriveRoot: String;
  FreeMB: Cardinal;
  TotalMB: Cardinal;
  BestFreeMB: Cardinal;
begin
  Result := 'D';
  if DirExists('D:\') and HasEnoughSpace('D:\') then
    Exit;

  BestFreeMB := 0;
  Result := '';
  for Index := Ord('C') to Ord('Z') do
  begin
    Drive := Chr(Index);
    if Drive = 'D' then
      Continue;

    DriveRoot := Drive + ':\';
    if not DirExists(DriveRoot) then
      Continue;

    if GetSpaceOnDisk(DriveRoot, True, FreeMB, TotalMB) and (FreeMB >= RequiredFreeMB) then
    begin
      if FreeMB > BestFreeMB then
      begin
        BestFreeMB := FreeMB;
        Result := Drive;
      end;
    end;
  end;

  if Result = '' then
    Result := 'D';
end;

function GetDefaultInstallDir(Param: String): String;
begin
  if CachedDefaultInstallDir = '' then
    CachedDefaultInstallDir := ResolveBestInstallDrive() + ':\Program Files\FaceSwap Studio';
  Result := CachedDefaultInstallDir;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  DriveRoot: String;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    DriveRoot := ExtractFileDrive(WizardDirValue) + '\';
    if not HasEnoughSpace(DriveRoot) then
    begin
      MsgBox('当前安装盘剩余空间不足。请至少预留 12GB，用于软件运行时、核心模型和缓存。', mbError, MB_OK);
      Result := False;
    end;
  end;
end;
