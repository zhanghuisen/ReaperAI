#define AppName "ReaperAI"
#define AppVersion "1.0.6"

#ifndef SourceRoot
  #define SourceRoot AddBackslash(SourcePath) + "build\package"
#endif

#ifndef OutputDir
  #define OutputDir AddBackslash(SourcePath) + "output"
#endif

[Setup]
AppId={{2473A7AE-0B0C-4B2C-95CC-6DF75AF0CBF6}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=zhanghuisen
DefaultDirName={localappdata}\Programs\ReaperAI
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=ReaperAI-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
UninstallDisplayName={#AppName}
UninstallDisplayIcon={code:GetReaperExe}
VersionInfoVersion={#AppVersion}
VersionInfoDescription=ReaperAI offline installer
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}

[Languages]
Name: "chinesesimp"; MessagesFile: "ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#SourceRoot}\Scripts\ReaperAI.lua"; DestDir: "{code:GetResourceRoot}\Scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\Scripts\rai_async_pipe.lua"; DestDir: "{code:GetResourceRoot}\Scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\Scripts\ReaperAI_mcp_config.json"; DestDir: "{code:GetResourceRoot}\Scripts"; Flags: ignoreversion
Source: "{#SourceRoot}\Scripts\ReaperAI\*"; DestDir: "{code:GetResourceRoot}\Scripts\ReaperAI"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\MCP_Server\*"; DestDir: "{code:GetResourceRoot}\MCP_Server"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#SourceRoot}\UserPlugins\*"; DestDir: "{code:GetResourceRoot}\UserPlugins"; Flags: ignoreversion recursesubdirs createallsubdirs onlyifdoesntexist
Source: "{#SourceRoot}\README.md"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#SourceRoot}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#SourceRoot}\EULA.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "{#SourceRoot}\安装说明.txt"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Registry]
Root: HKCU; Subkey: "Software\ReaperAI"; ValueType: string; ValueName: "ReaperRoot"; ValueData: "{code:GetSelectedReaperRoot}"; Flags: uninsdeletevalue uninsdeletekeyifempty
Root: HKCU; Subkey: "Software\ReaperAI"; ValueType: string; ValueName: "ResourceRoot"; ValueData: "{code:GetResourceRoot}"; Flags: uninsdeletevalue uninsdeletekeyifempty

[Run]
Filename: "{code:GetReaperExe}"; Description: "启动 REAPER"; Flags: nowait postinstall skipifsilent unchecked

[Code]
const
  ReaperActionLine = 'SCR 4 0 RSb48641b7a2b3105cf6682f5c0ddbf3a29a8d3428 "Custom: ReaperAI.lua" ReaperAI.lua';

var
  ReaperDirPage: TInputDirWizardPage;
  ResourceRoot: String;
  ReadyDetailsAdded: Boolean;
  PreserveUserConfig: Boolean;

function RemoveTrailingSlash(const Value: String): String;
begin
  Result := Value;
  while (Length(Result) > 3) and
    ((Result[Length(Result)] = '\') or (Result[Length(Result)] = '/')) do
  begin
    Delete(Result, Length(Result), 1);
  end;
end;

function ExpandAndNormalizePath(const Value: String): String;
begin
  Result := RemoveTrailingSlash(ExpandConstant(Value));
end;

function ReaperExeIn(const Directory: String): String;
begin
  Result := AddBackslash(Directory) + 'reaper.exe';
end;

function DetectReaperRoot(): String;
var
  Candidate: String;
begin
  Result := '';

  Candidate := ExpandConstant('{param:REAPERDIR|}');
  if Candidate <> '' then
  begin
    Candidate := ExpandAndNormalizePath(Candidate);
    if FileExists(ReaperExeIn(Candidate)) then
    begin
      Result := Candidate;
      Exit;
    end;
  end;

  if RegQueryStringValue(HKCU, 'Software\ReaperAI', 'ReaperRoot', Candidate) then
  begin
    Candidate := ExpandAndNormalizePath(Candidate);
    if FileExists(ReaperExeIn(Candidate)) then
    begin
      Result := Candidate;
      Exit;
    end;
  end;

  Candidate := ExpandAndNormalizePath('{pf}\REAPER (x64)');
  if FileExists(ReaperExeIn(Candidate)) then
  begin
    Result := Candidate;
    Exit;
  end;

  Candidate := ExpandAndNormalizePath('{pf}\REAPER');
  if FileExists(ReaperExeIn(Candidate)) then
  begin
    Result := Candidate;
    Exit;
  end;

  Candidate := ExpandAndNormalizePath('{localappdata}\Programs\REAPER (x64)');
  if FileExists(ReaperExeIn(Candidate)) then
    Result := Candidate;
end;

function ResolveResourceRoot(const ReaperRoot: String): String;
var
  RegistryPath: String;
  OverridePath: String;
begin
  OverridePath := ExpandConstant('{param:RESOURCEDIR|}');
  if OverridePath <> '' then
  begin
    Result := ExpandAndNormalizePath(OverridePath);
    Exit;
  end;

  if FileExists(AddBackslash(ReaperRoot) + 'reaper.ini') then
  begin
    Result := ReaperRoot;
    Exit;
  end;

  if RegQueryStringValue(HKCU, 'Software\REAPER', 'REAPER_PREF_DIR', RegistryPath) and
    (RegistryPath <> '') then
  begin
    Result := ExpandAndNormalizePath(RegistryPath);
    Exit;
  end;

  Result := ExpandAndNormalizePath('{userappdata}\REAPER');
end;

function GetSelectedReaperRoot(Param: String): String;
begin
  if ReaperDirPage <> nil then
    Result := RemoveTrailingSlash(ReaperDirPage.Values[0])
  else
    Result := '';
end;

function GetResourceRoot(Param: String): String;
begin
  if ResourceRoot = '' then
    ResourceRoot := ResolveResourceRoot(GetSelectedReaperRoot(''));
  Result := ResourceRoot;
end;

function GetReaperExe(Param: String): String;
begin
  if ReaperDirPage <> nil then
    Result := ReaperExeIn(GetSelectedReaperRoot(''))
  else
    Result := 'reaper.exe';
end;

function EscapeJson(const Value: String): String;
begin
  Result := Value;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;

function CanWriteDirectory(const Directory: String): Boolean;
var
  TestFile: String;
begin
  Result := False;
  if not ForceDirectories(Directory) then
    Exit;

  TestFile := AddBackslash(Directory) + '.reaperai_install_write_test.tmp';
  if SaveStringToFile(TestFile, 'write test', False) then
  begin
    DeleteFile(TestFile);
    Result := True;
  end;
end;

function ValidateSelection(var ErrorMessage: String): Boolean;
var
  ReaperRoot: String;
begin
  Result := False;
  ReaperRoot := GetSelectedReaperRoot('');
  if not FileExists(ReaperExeIn(ReaperRoot)) then
  begin
    ErrorMessage := '所选目录中没有找到 reaper.exe：' + #13#10 + ReaperRoot;
    Exit;
  end;

  ResourceRoot := ResolveResourceRoot(ReaperRoot);
  if not CanWriteDirectory(ResourceRoot) then
  begin
    ErrorMessage := '无法写入 REAPER 资源目录：' + #13#10 + ResourceRoot + #13#10 +
      '请确认当前账号有写入权限，或重新以管理员身份运行安装器。';
    Exit;
  end;

  Log('Selected REAPER root: ' + ReaperRoot);
  Log('Resolved REAPER resource root: ' + ResourceRoot);
  Result := True;
end;

procedure WriteInitialConfig();
var
  ConfigPath: String;
  ConfigText: String;
  FFmpegPath: String;
begin
  ConfigPath := AddBackslash(ResourceRoot) + 'MCP_Server\config.json';
  if FileExists(ConfigPath) then
  begin
    Log('Preserved existing ' + ConfigPath);
    Exit;
  end;

  FFmpegPath := AddBackslash(ResourceRoot) + 'MCP_Server\ffmpeg\bin\ffmpeg.exe';
  ConfigText :=
    '{' + #13#10 +
    '  "_comment": "ReaperAI MCP Server configuration",' + #13#10 +
    '  "reaper_projects_dir": ".",' + #13#10 +
    '  "reaper_resource_path": "' + EscapeJson(ResourceRoot) + '",' + #13#10 +
    '  "ffmpeg_path": "' + EscapeJson(FFmpegPath) + '",' + #13#10 +
    '  "server": {' + #13#10 +
    '    "host": "127.0.0.1",' + #13#10 +
    '    "port": 8765' + #13#10 +
    '  }' + #13#10 +
    '}' + #13#10;
  if not SaveStringToFile(ConfigPath, ConfigText, False) then
    RaiseException('无法创建配置文件：' + ConfigPath);
  Log('Created ' + ConfigPath);
end;

procedure WriteRuntimePathFiles();
var
  ServerRoot: String;
  PythonPath: String;
  PythonwPath: String;
  FFmpegPath: String;
begin
  ServerRoot := AddBackslash(ResourceRoot) + 'MCP_Server';
  PythonPath := AddBackslash(ServerRoot) + 'python_runtime\python.exe';
  PythonwPath := AddBackslash(ServerRoot) + 'python_runtime\pythonw.exe';
  FFmpegPath := AddBackslash(ServerRoot) + 'ffmpeg\bin\ffmpeg.exe';

  if not SaveStringToFile(AddBackslash(ServerRoot) + 'python_path.txt', PythonPath + #13#10, False) then
    RaiseException('无法写入 python_path.txt');
  if not SaveStringToFile(AddBackslash(ServerRoot) + 'pythonw_path.txt', PythonwPath + #13#10, False) then
    RaiseException('无法写入 pythonw_path.txt');
  if not SaveStringToFile(AddBackslash(ServerRoot) + 'ffmpeg_path.txt', FFmpegPath + #13#10, False) then
    RaiseException('无法写入 ffmpeg_path.txt');
end;

procedure RegisterReaperAction();
var
  KeyboardConfigPath: String;
  ExistingText: AnsiString;
begin
  KeyboardConfigPath := AddBackslash(ResourceRoot) + 'reaper-kb.ini';
  if LoadStringFromFile(KeyboardConfigPath, ExistingText) and
    (Pos('ReaperAI.lua', ExistingText) > 0) then
  begin
    Log('ReaperAI action is already registered.');
    Exit;
  end;

  if not SaveStringToFile(KeyboardConfigPath, ReaperActionLine + #13#10, True) then
    RaiseException('无法注册 ReaperAI 动作：' + KeyboardConfigPath);
  Log('Registered the ReaperAI action in ' + KeyboardConfigPath);
end;

procedure RemoveRegisteredReaperAction();
var
  KeyboardConfigPath: String;
  Lines: TArrayOfString;
  FilteredLines: TArrayOfString;
  I: Integer;
  OutputIndex: Integer;
begin
  if ResourceRoot = '' then
    Exit;

  KeyboardConfigPath := AddBackslash(ResourceRoot) + 'reaper-kb.ini';
  if not LoadStringsFromFile(KeyboardConfigPath, Lines) then
    Exit;

  SetLength(FilteredLines, Length(Lines));
  OutputIndex := 0;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    if Trim(Lines[I]) <> ReaperActionLine then
    begin
      FilteredLines[OutputIndex] := Lines[I];
      OutputIndex := OutputIndex + 1;
    end;
  end;

  if OutputIndex = GetArrayLength(Lines) then
    Exit;

  SetLength(FilteredLines, OutputIndex);
  if SaveStringsToUTF8FileWithoutBOM(KeyboardConfigPath, FilteredLines, False) then
    Log('Removed the ReaperAI action from ' + KeyboardConfigPath)
  else
    Log('Could not remove the ReaperAI action from ' + KeyboardConfigPath);
end;

procedure VerifyRuntime();
var
  PythonPath: String;
  FFmpegPath: String;
  ResultCode: Integer;
begin
  PythonPath := AddBackslash(ResourceRoot) + 'MCP_Server\python_runtime\python.exe';
  if not Exec(PythonPath,
    '-c "import requests, flask, flask_cors, numpy, soundfile, pydub, cffi"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or (ResultCode <> 0) then
  begin
    RaiseException('Python 运行环境自检失败。请查看安装日志，错误代码：' + IntToStr(ResultCode));
  end;

  FFmpegPath := AddBackslash(ResourceRoot) + 'MCP_Server\ffmpeg\bin\ffmpeg.exe';
  if not Exec(FFmpegPath, '-version', '', SW_HIDE, ewWaitUntilTerminated, ResultCode) or
    (ResultCode <> 0) then
  begin
    RaiseException('FFmpeg 自检失败。请查看安装日志，错误代码：' + IntToStr(ResultCode));
  end;
  Log('All bundled runtime dependency checks passed.');
end;

procedure InitializeWizard();
var
  InitialRoot: String;
begin
  ReadyDetailsAdded := False;
  ReaperDirPage := CreateInputDirPage(wpSelectDir,
    '选择 REAPER 安装目录',
    '请选择包含 reaper.exe 的 REAPER 根目录。',
    '支持任意盘符和自定义路径，例如 F:\GANHUO\DAW\Reaper(x64)。安装器会自动识别普通安装或便携安装。',
    False, '选择文件夹');
  ReaperDirPage.Add('REAPER 根目录：');

  InitialRoot := DetectReaperRoot();
  if InitialRoot = '' then
    InitialRoot := ExpandAndNormalizePath('{pf}\REAPER (x64)');
  ReaperDirPage.Values[0] := InitialRoot;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  ErrorMessage: String;
begin
  Result := True;
  if CurPageID <> ReaperDirPage.ID then
    Exit;

  if not ValidateSelection(ErrorMessage) then
  begin
    MsgBox(ErrorMessage, mbError, MB_OK);
    Result := False;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not ValidateSelection(Result) then
    Exit;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpReady) and (ResourceRoot <> '') and not ReadyDetailsAdded then
  begin
    WizardForm.ReadyMemo.Lines.Add('');
    WizardForm.ReadyMemo.Lines.Add('REAPER 根目录：' + GetSelectedReaperRoot(''));
    WizardForm.ReadyMemo.Lines.Add('组件安装目录：' + ResourceRoot);
    ReadyDetailsAdded := True;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    WriteInitialConfig();
    WriteRuntimePathFiles();
    RegisterReaperAction();
    VerifyRuntime();
  end;
end;

function HasUninstallParameter(const ParameterName: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    if CompareText(ParamStr(I), ParameterName) = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure RemoveUserConfiguration();
var
  ServerRoot: String;
begin
  if ResourceRoot = '' then
    Exit;

  ServerRoot := AddBackslash(ResourceRoot) + 'MCP_Server';
  DeleteFile(AddBackslash(ResourceRoot) + 'ReaperAI_config.txt');
  DeleteFile(AddBackslash(ResourceRoot) + 'ReaperAI_elevenlabs_voices.tsv');
  DeleteFile(AddBackslash(ResourceRoot) + 'ReaperAI_doubao_voices.tsv');
  DeleteFile(AddBackslash(ServerRoot) + 'config.json');
  Log('Removed ReaperAI user configuration and voice caches.');
end;

procedure StopMcpServer();
var
  ServerRoot: String;
  PythonwPath: String;
  ShutdownScript: String;
  ResultCode: Integer;
begin
  if ResourceRoot = '' then
    Exit;

  ServerRoot := AddBackslash(ResourceRoot) + 'MCP_Server';
  PythonwPath := AddBackslash(ServerRoot) + 'python_runtime\pythonw.exe';
  ShutdownScript := AddBackslash(ServerRoot) + 'shutdown_http_server.py';
  if not FileExists(PythonwPath) or not FileExists(ShutdownScript) then
    Exit;

  if Exec(PythonwPath, '"' + ShutdownScript + '"', ServerRoot,
    SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Log('MCP shutdown helper exited with code ' + IntToStr(ResultCode))
  else
    Log('Could not start the MCP shutdown helper.');
end;

function InitializeUninstall(): Boolean;
var
  Choice: Integer;
begin
  Result := True;
  if not RegQueryStringValue(HKCU, 'Software\ReaperAI', 'ResourceRoot', ResourceRoot) then
    ResourceRoot := '';

  PreserveUserConfig := True;
  if HasUninstallParameter('/DELETEUSERCONFIG') then
  begin
    PreserveUserConfig := False;
    Log('Silent uninstall requested removal of user configuration.');
  end
  else if not UninstallSilent then
  begin
    Choice := SuppressibleMsgBox(
      '是否保留 ReaperAI 用户配置？' + #13#10 + #13#10 +
      '选择“是”：保留 API Key、模型、音频服务和 MCP 配置，重装后可继续使用。' + #13#10 +
      '选择“否”：卸载时一并删除用户配置和音色缓存。',
      mbConfirmation, MB_YESNO, IDYES);
    PreserveUserConfig := Choice = IDYES;
  end;

  if PreserveUserConfig then
    Log('Uninstall will preserve ReaperAI user configuration.')
  else
    Log('Uninstall will remove ReaperAI user configuration.');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usUninstall) and (ResourceRoot <> '') then
  begin
    StopMcpServer();
    DeleteFile(AddBackslash(ResourceRoot) + 'MCP_Server\python_path.txt');
    DeleteFile(AddBackslash(ResourceRoot) + 'MCP_Server\pythonw_path.txt');
    DeleteFile(AddBackslash(ResourceRoot) + 'MCP_Server\ffmpeg_path.txt');
    RemoveRegisteredReaperAction();
    if not PreserveUserConfig then
      RemoveUserConfiguration();
  end
  else if (CurUninstallStep = usPostUninstall) and
    (ResourceRoot <> '') and not PreserveUserConfig then
  begin
    DelTree(AddBackslash(ResourceRoot) + 'MCP_Server', True, True, True);
  end;
end;
