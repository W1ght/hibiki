; fushi/windows/installer/fushi.iss
; 由 CI 用 ISCC 编译；AppVersion / SourceDir / OutputDir 由命令行 /D 传入。
; Fushi 改名（Phase 3）：AppId GUID 不变 => 对旧 Hibiki 安装做覆盖升级；
; 升级路径上的旧名残留（hibiki.exe / 快捷方式 / 注册表 ProgID）在本脚本内清理。
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\installer"
#endif

[Setup]
AppId={{8F2C1A3E-7B4D-4E9A-9C21-0A1B2C3D4E5F}}
AppName=Fushi
AppVersion={#AppVersion}
AppPublisher=Fushi
DefaultDirName={localappdata}\Fushi
DefaultGroupName=Fushi
DisableProgramGroupPage=yes
; Fushi 改名：Inno 默认 UsePreviousGroup=yes，升级时从卸载键里读回上一次的
; 「Inno Setup: Icon Group」（旧安装写的是 Hibiki），于是 {group} 解析成
; ...\Programs\Hibiki，新建的 Fushi 快捷方式会落进一个叫 Hibiki 的文件夹里
; （实测用户机器上 Programs\Hibiki 现在是空目录，正是这条路径的产物）。
; 关掉它，强制用 DefaultGroupName=Fushi；遗留的 Programs\Hibiki 在
; CurStepChanged/ssPostInstall 里清理（先删旧 lnk，目录空了才 RemoveDir）。
; DisableProgramGroupPage=yes 意味着用户从来无法自定义组名，所以这里不存在
; 「覆盖用户选择」的风险。
UsePreviousGroup=no
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename=fushi-{#AppVersion}-windows-setup
Compression=lzma2
SolidCompression=yes

; 安装器自己的图标 = app 图标（兔子）。不设的话是 Inno 默认的下载箭头，
; 于是「双击下载来的 setup.exe」和「桌面上的 Fushi」看着毫不相干。
; 这份 ico 由 a32b885d65 换成兔子，7 档尺寸（16~256）齐全，直接可用。
SetupIconFile=..\runner\resources\app_icon.ico
; 控制面板「应用和功能」里的图标同样取 app 自己的，不留 Inno 默认。
UninstallDisplayIcon={app}\fushi.exe

; ── Material Design 3 外观 ────────────────────────────────────────────────
; app 五端统一 MD3，安装器是用户见到的第一屏，之前却是 Inno 默认外观（白底 +
; 分隔线 + 默认纸箱图标 + 无暗色）。Inno 6.7 起原生支持自定义样式、自定义背景色、
; 跟随系统的明暗切换（dynamic），所以这里用它做 MD3：
;   - 背景用 MD3 surface（浅 #FEF7FF / 深 #141218），与 app 主题同源；
;   - hidebevels 去掉经典分隔线（MD3 靠留白与色阶分区，不靠线）；
;   - windows11 是内置扁平样式，配上面两条后按钮/输入框是圆角扁平的现代形态；
;   - 图像是本目录 assets\ 下的 MD3 标记与竖图，明暗各一套。这里之所以不直接用
;     app_icon.ico，是因为向导要的是**按 DPI 分档的明暗两套 PNG**（带 alpha、
;     底色还得跟 WizardSmallImageBackColor 对齐），ico 顶不上这个用途；
;     安装器 exe 自身的图标则已经用上 app_icon.ico（见上面的 SetupIconFile）。
;     注：旧注释说 app_icon.ico「还是改名前的 Hibiki 字标」，那已经过期——
;     a32b885d65 把它换成了兔子，与向导右上角的标记同源。
; 版本闸门：这批指令 6.7 以下的编译器不认识，会直接编译失败。CI 已钉 6.7+
; （release-desktop.yml 的 Compile installer 步骤会校验并按需安装），这里再留一道
; ISPP 闸门，让任何老编译器上仍能出包，只是退回旧外观。
#if VER >= EncodeVer(6,7,0)
WizardStyle=modern dynamic windows11 hidebevels
WizardBackColor=#FEF7FF
WizardBackColorDynamicDark=#141218
WizardImageBackColor=#FEF7FF
WizardImageBackColorDynamicDark=#141218
; 页眉标记是带 alpha 的 PNG：底色不跟背景一致就会在页眉右上角露出一个色块。
WizardSmallImageBackColor=#FEF7FF
WizardSmallImageBackColorDynamicDark=#141218
WizardImageAlphaFormat=defined
; 每页背景：MD3 surface 底 + 两团极淡主色晕。样式接管了控件与文字颜色（见 [Code]
; 的 ApplyMd3Chrome 注释），背景图是唯一还能把 MD3 主色铺满每页的层。
WizardBackImageFile=assets\wizard_back_1630x1180.png
WizardBackImageFileDynamicDark=assets\wizard_back_dark_1630x1180.png
WizardImageFile=assets\wizard_hero_164x314.png,assets\wizard_hero_192x386.png,assets\wizard_hero_246x492.png,assets\wizard_hero_328x628.png
WizardImageFileDynamicDark=assets\wizard_hero_dark_164x314.png,assets\wizard_hero_dark_192x386.png,assets\wizard_hero_dark_246x492.png,assets\wizard_hero_dark_328x628.png
WizardSmallImageFile=assets\wizard_mark_55.png,assets\wizard_mark_64.png,assets\wizard_mark_83.png,assets\wizard_mark_110.png,assets\wizard_mark_138.png
WizardSmallImageFileDynamicDark=assets\wizard_mark_dark_55.png,assets\wizard_mark_dark_64.png,assets\wizard_mark_dark_83.png,assets\wizard_mark_dark_110.png,assets\wizard_mark_dark_138.png
#else
WizardStyle=modern
#endif

CloseApplications=no
CloseApplicationsFilter=*.exe,*.dll
RestartApplications=no
; 过渡期双 mutex：老 Hibiki 实例还持有旧名互斥量时，升级安装同样要等它退出。
AppMutex=FushiSingleInstanceMutex,HibikiSingleInstanceMutex

[Languages]
; 统一成简体中文。改之前这个安装器是**中英混杂**的：向导自身的页标题、说明、按钮
; 走 Inno 内置的英文 Default.isl（"Select Destination Location" / "Next"），而本文件
; 里的 [Tasks] 描述、数据根页文案、各种校验提示全是中文，同一屏上两种语言。
;
; 为什么把 .isl 入库而不是引用 Inno 安装目录：简体中文属于 Inno 的
; user-contributed translations，官方安装包**不随附**（本机 6.7.3 的 Languages\ 下
; 29 个语言文件里没有中文，日语韩语都有）。放进仓库，CI 才不依赖编译机上恰好装过
; 中文语言包，也不必在构建时联网取。
; 来源：jrsoftware/issrc 的 Files/Languages/ChineseSimplified.isl
;       （维护者 Zhenghan Yang，上游 github.com/kira-96/Inno-Setup-Chinese-Simplified-Translation）
;       SHA-256 E0B0B350E2245F3C5E65586DFE43D574F6E7F06F2261149ABA284954B3FC9A8D
;
; 只列一个语言，所以 Inno 不会弹语言选择框（ShowLanguageDialog=auto 在单语言时不显示）。
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
; 桌面快捷方式：默认勾选（保持旧行为——首装桌面即有图标），允许用户取消。
; 配合 [Icons] 的 Check: ShouldCreateDesktopIcon，仅在快捷方式尚不存在时创建，
; 应用内静默更新（/VERYSILENT，用户看不到向导、无法取消）不会重写已存在的 .lnk，
; 桌面图标位置得以保留（BUG-1014）。
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加快捷方式："

; 可选：把 Fushi 注册为视频文件的「打开方式」候选（不抢占系统默认播放器，
; 只在资源管理器右键「打开方式」里出现 Fushi，并支持拖视频到 fushi.exe）。
Name: "videoassoc"; Description: "将 Fushi 加入视频文件的「打开方式」（mkv / mp4 等）"; GroupDescription: "文件关联："

[InstallDelete]
; BUG-1449：galgame helper 现在以**普通文件**随包发在 {app}\voice_hook\<arch>\，
; 由 install_into_bundle.ps1 在构建期解压，与本体同一次构建产出。随包 zip 归档
; （旧模型的产物）必须在升级时清掉——否则它会以「随包真相源」的身份留在磁盘上：
; 一旦用户手工删过 voice_hook\<arch>\installed.sha256（排障时的常见动作），
; GalgameHelperInstaller 就会拿这份**旧** zip 回填，把安装器刚放好的新组件覆盖成旧的，
; 直接复发 BUG-1448 的「组件比本体旧」。删的是上一版留下的归档，不碰用户数据。
Type: filesandordirs; Name: "{app}\galgame_helper"
; 归属判据：本段只放「必须在复制前删、且删了不影响可运行性」的条目。
; 上面 {app}\galgame_helper 两点都满足——新包同样往 {app} 下写 helper 组件，
; 不先删就会被旧归档回填；而它本身不是可执行入口，删早了不会让 app 打不开。
;
; 旧名二进制（hibiki.exe / hibiki_update_launcher.exe / hibiki_torrent_ffi.dll /
; hoshidicts_ffi.dll）和旧名快捷方式**不在这里**：[InstallDelete] 在复制任何新文件
; 之前执行，且 Inno 明确不会在安装失败/取消时回滚这些删除。它们又都不与新文件同名，
; 所以「复制前删」没有任何必要性，却把一次中途失败的升级从「还剩个能跑的旧版」
; 变成「一个可执行文件都没有」（实测现场：{app} 下 hibiki.exe 与 fushi.exe 双双消失，
; 只剩 unins000.exe，快捷方式全成死链接）。这些条目已下沉到 [Code] 的
; CurStepChanged / ssPostInstall，即新文件全部落地之后才执行。

[Files]
; 包含 fushi_update_launcher.exe：应用内更新用它等待当前 fushi.exe 退出后再启动 Inno。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; MD3 文件夹图标（替换「选择安装位置」页那个经典 Win95 黄纸夹）。dontcopy = 只随
; 安装器打包、不落到 {app}；[Code] 里按 DPI 挑一档 ExtractTemporaryFile 出来。
; 跟着 [Code] 的同一道 6.6 闸门走：老编译器上那段代码整块不编译，没人 extract
; 这些图，打进去只是白占体积。
#if VER >= EncodeVer(6,6,0)
Source: "assets\wizard_folder*.bmp"; Flags: dontcopy
#endif

[Icons]
Name: "{group}\Fushi"; Filename: "{app}\fushi.exe"
; BUG-1014：只在桌面快捷方式尚不存在时创建（详见旧注释；改名后判 Fushi.lnk）。
Name: "{userdesktop}\Fushi"; Filename: "{app}\fushi.exe"; Tasks: desktopicon; Check: ShouldCreateDesktopIcon

[Registry]
; Fushi 应用 ProgId：双击/「打开方式」时以 fushi.exe "<文件>" 启动。
; "%1" 即视频绝对路径，被 runner 经 set_dart_entrypoint_arguments 传给 Dart
; main(args)（见 lib/main.dart + windows/runner/utils.cpp::GetCommandLineArguments）。
; BUG-1666：fushi:// URL 协议（Anki 卡片上的词典交叉引用 fushi://lookup?word=<词>）。
; 点击后系统以 fushi.exe "<完整URL>" 启动：冷启动走 Dart main(args)，app 已开则由
; 单实例守卫经 WM_COPYDATA 转交首实例（与外部视频同一条链路），Dart 侧
; lookupWordFromDeepLink 解析后排队显式查词。无条件注册（不挂 videoassoc 任务）。
Root: HKCU; Subkey: "Software\Classes\fushi"; ValueType: string; ValueData: "URL:Fushi Lookup"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\fushi"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\fushi\DefaultIcon"; ValueType: string; ValueData: "{app}\fushi.exe,0"
Root: HKCU; Subkey: "Software\Classes\fushi\shell\open\command"; ValueType: string; ValueData: """{app}\fushi.exe"" ""%1"""

Root: HKCU; Subkey: "Software\Classes\Fushi.Video"; ValueType: string; ValueData: "Fushi 视频"; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Fushi.Video\DefaultIcon"; ValueType: string; ValueData: "{app}\fushi.exe,0"; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Fushi.Video\shell\open\command"; ValueType: string; ValueData: """{app}\fushi.exe"" ""%1"""; Tasks: videoassoc

; 让 fushi.exe 出现在「打开方式」应用列表，并声明它支持的视频扩展名。
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\shell\open\command"; ValueType: string; ValueData: """{app}\fushi.exe"" ""%1"""; Flags: uninsdeletekey; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".mkv"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".mp4"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".m4v"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".avi"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".webm"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".mov"; ValueData: ""; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\Applications\fushi.exe\SupportedTypes"; ValueType: string; ValueName: ".ts"; ValueData: ""; Tasks: videoassoc

; 把 Fushi.Video 挂到各扩展名的 OpenWithProgids（追加候选，不改默认关联）。
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: string; ValueName: "Fushi.Video"; ValueData: ""; Flags: uninsdeletevalue; Tasks: videoassoc

; ── 旧 Hibiki 注册表迁移清理（无条件执行，不挂 videoassoc：用户这次没勾关联
;    也要把指向已删除 hibiki.exe 的死键清掉，否则「打开方式」里留一个坏条目）──
Root: HKCU; Subkey: "Software\Classes\Hibiki.Video"; ValueType: none; Flags: deletekey
Root: HKCU; Subkey: "Software\Classes\Applications\hibiki.exe"; ValueType: none; Flags: deletekey
Root: HKCU; Subkey: "Software\Classes\.mkv\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.mp4\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.m4v\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.avi\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.webm\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.mov\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue
Root: HKCU; Subkey: "Software\Classes\.ts\OpenWithProgids"; ValueType: none; ValueName: "Hibiki.Video"; Flags: deletevalue

[UninstallDelete]
; 数据存储位置引导文件（见 [Code] WriteDataRootBootstrap）。app 首启即消费并删除；
; 装完从没启动过就卸载时由这里收尾，别在安装目录留一个孤儿文件。
Type: files; Name: "{app}\data_root.bootstrap"

[Run]
Filename: "{app}\fushi.exe"; Description: "启动 Fushi"; Flags: nowait postinstall

[Code]
// -- TODO-549: app-internal self-update "AppMutex deadlock" root-cause layer --
// Regression source: TODO-431.
//
// The old app launches the new installer; Inno does its AppMutex check early
// (CheckForMutexes; per Inno source Setup.MainFunc.pas the InitializeSetup call
// runs BEFORE the CheckForMutexes loop) and finds some running instance still
// holding the single-instance mutex, so it pops "Setup has detected that the
// app is currently running". Under /VERYSILENT + /SUPPRESSMSGBOXES that
// OK/Cancel box defaults to Cancel -> Got EAbort -> immediate exit with no
// files replaced.
//
// Inno's CloseApplications / /CLOSEAPPLICATIONS go through RestartManager (by
// file usage) and are completely independent from the AppMutex check
// (CheckForMutexes), so they cannot suppress the mutex abort. The only layer
// that runs BEFORE the AppMutex check and can own the timing is this
// InitializeSetup: it actively terminates the running app (Fushi 改名过渡期
// 新旧两个 exe 名与两个 mutex 名都要照顾) and its WebView2 child processes,
// then bounded-polls until the mutex is truly released, then returns True; by
// the time Inno runs CheckForMutexes the mutex is gone, so it passes quietly.
// The [Setup] AppMutex= (both names) is kept as a fallback.

const
  FushiAppMutexName = 'FushiSingleInstanceMutex';
  LegacyAppMutexName = 'HibikiSingleInstanceMutex';
  SyncMutexAccess = $00100000; { SYNCHRONIZE }
  MutexReleasePollAttempts = 40; { 40 * 250ms = up to ~10s waiting for the kernel to reclaim the mutex }
  MutexReleasePollIntervalMs = 250;
  GracefulCloseAttempts = 8;
  { Inno 的 Pascal Script 不预定义 INVALID_HANDLE_VALUE；THandle 是无符号 32 位，
    Win32 的 (HANDLE)-1 在这里就是 $FFFFFFFF。 }
  InvalidHandleValue = $FFFFFFFF;

{ OpenMutexW: third arg is a String; Inno (Unicode) marshals it into a
  PWideChar for the W variant. Returns THandle; non-zero = the named mutex is
  still present (the app has not actually exited yet). }
function OpenMutexW(dwDesiredAccess: Cardinal; bInheritHandle: Boolean;
  lpName: String): THandle;
  external 'OpenMutexW@kernel32.dll stdcall';

function CloseHandle(hObject: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

{ Probe whether a named mutex exists; close the handle immediately to avoid
  leaking (and to avoid the probe itself keeping a reference alive). }
function NamedMutexExists(const MutexName: String): Boolean;
var
  Handle: THandle;
begin
  Handle := OpenMutexW(SyncMutexAccess, False, MutexName);
  Result := Handle <> 0;
  if Result then
    CloseHandle(Handle);
end;

{ 过渡期：新旧两个单实例互斥量任一存在都算「应用仍在运行」。 }
function AppMutexExists(): Boolean;
begin
  Result := NamedMutexExists(FushiAppMutexName) or
            NamedMutexExists(LegacyAppMutexName);
end;

{ BUG-2203：这两个过程**绝不能带 /T**。

  应用内静默更新时，本安装器就是被更新的那个 fushi.exe 的**孙进程**：
      fushi.exe → fushi_update_launcher.exe → <本 setup.exe>
  （launcher 由 app 用 CreateProcess 拉起、setup 由 launcher 拉起；Windows 无条件
  把创建者记为父进程，detached 也不例外）。而 taskkill 的 /T 是**递归**杀整条后代树
  ——不是只杀直接子进程。实测（同机，三层 cmd 副本）：
      taskkill /F /IM fk_parent.exe /T
      → 成功: 已终止 PID 88128 (属于 PID 47184 子进程)   ← 孙进程也被带走
  于是 InitializeSetup 里这一句会把 launcher 和**安装器自己**一起杀掉：安装器在
  自我防卫时自杀。现场（2026-09-06，用户机）：09:35:03.752 启动安装器，
  09:35:04.039 Inno 日志戛然而止在启动段的 DLL import 之后，**没有**任何 abort /
  exception / Deinitializing 行 —— 这正是被外部强杀而非自行中止的形状；磁盘保持旧版。
  更糟的是 launcher 一并没了，BUG-1708 那条「安装失败时把 app 拉回来」的兜底随之
  失效，Fushi 从用户桌面上静默消失（用户只能自己去开始菜单重开）。

  /T 原本是为了带走 WebView2 子进程，但它们的 image 名就是 msedgewebview2.exe，
  InitializeSetup 下面已经按 image 名单独扫了一遍 —— /T 不提供任何额外覆盖，
  只提供自杀能力。按 image 名杀就够了：fushi.exe / hibiki.exe 的每个实例都会被
  /IM 命中（包括那个持有互斥量的父进程），而 setup.exe 与 launcher 不叫这个名字
  （/IM 是整名匹配，fushi.exe 不会命中 fushi_update_launcher.exe），于是安装器
  活到装完、launcher 活到能兜底。

  本阶段只负责一件事：**让互斥量被释放**，而互斥量只有 fushi.exe 持有。其余
  helper 子进程（ffmpeg.exe / fushi_voice_injector.exe 之类）不归这里管 —— 它们
  是「文件锁」问题，由 PrepareToInstall 的 KillProcessesUnderDir 按**镜像路径**
  在复制前统一清掉（BUG-1459）。所以去掉 /T 没有留下覆盖缺口，只是把两件事各自
  还给了负责它的那一层。 }

{ Gentle close: taskkill WITHOUT /F sends WM_CLOSE so the app can save state
  and release its mutex on its own. }
procedure KillGracefully(const ExeName: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'),
       '/IM ' + ExeName,
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ Force kill: /F forces, /IM by image name. ResultCode=128 means no matching
  process; that is not an error -- the mutex poll is the source of truth. }
procedure KillImage(const ExeName: String);
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'),
       '/F /IM ' + ExeName,
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ BUG-1459: the mutex layer only proves the main exe exited. Helper processes
  launched from the install dir (ffmpeg.exe audio jobs, galgame helper) can
  outlive it and keep their image files locked, so the file-copy phase dies
  with "could not replace ...\ffmpeg.exe (DeleteFile code 5)". Sweep by image
  PATH under the target dir (not by name) so unrelated same-named processes
  elsewhere on the machine are untouched. }
procedure KillProcessesUnderDir(const Dir: String);
var
  ResultCode: Integer;
  EscapedDir: String;
  Cmd: String;
begin
  EscapedDir := Dir;
  StringChangeEx(EscapedDir, '''', '''''', True);
  Cmd := '-NoProfile -NonInteractive -Command "$d = ''' + EscapedDir + '''; ' +
    'if (-not $d.EndsWith(''\'')) { $d += ''\'' }; ' +
    'Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase) ' +
    '-and $_.ProcessName -ne ''fushi_update_launcher'' } | ' +
    'Stop-Process -Force -ErrorAction SilentlyContinue"';
  // BUG-1786：必须走 {sysnative} 而不是 {sys}。本安装器是 **32 位**进程
  // （日志里的「64-bit install mode: No」），{sys} 会被 WOW64 重定向到 SysWOW64 的
  // **32 位** PowerShell，而 32 位 PowerShell 读不到 64 位进程的 .Path（底层 MainModule
  // 跨位宽访问失败，属性取到空串）。于是过滤条件 `$_.Path -and ...` 对**每一个** 64 位
  // 进程都恒假——fushi.exe / injector / ffmpeg 一个都杀不掉，这个过程长期是发哑弹。
  // 实测（同一份命令、同一个 x64 目标进程）：
  // 64 位 PowerShell → alive=False，文件随即可写；
  // 32 位 PowerShell → alive=True，文件仍被占用，且 Path 取到空串。
  // {sysnative} 在 64 位 Windows 上绕过 WOW64 重定向指向真正的 System32；32 位 Windows
  // 上它等同 {sys}，故无平台回归。
  //
  // launcher 被显式排除（上面的 ProcessName 判断）：它是拉起本安装器的进程，且要活到
  // 安装结束才能在失败时把 app 拉回来（BUG-1708）。杀了它等于用那条 bug 的复发换这次
  // 复制成功。它自己占住的文件由 MakeWayForRunningLauncher 改名让路解决。
  Exec(ExpandConstant('{sysnative}\WindowsPowerShell\v1.0\powershell.exe'), Cmd,
       '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

{ BUG-1675: 能不能真的换掉这个文件——用「独占写方式打开」实测，而不是猜。
  被别的进程映射的 DLL 在 Windows 下**可以改名但不能覆盖**，所以 RenameFile
  探测会给出假的「没被占用」；只有以 GENERIC_WRITE + dwShareMode=0 打开才复现
  安装器复制阶段的真实约束（占用时返回 INVALID_HANDLE_VALUE / 共享冲突）。 }
function CreateFileW(lpFileName: String; dwDesiredAccess: Cardinal;
  dwShareMode: Cardinal; lpSecurityAttributes: Cardinal;
  dwCreationDisposition: Cardinal; dwFlagsAndAttributes: Cardinal;
  hTemplateFile: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';

function FileLockedForWrite(const FileName: String): Boolean;
var
  Handle: THandle;
begin
  Result := False;
  if not FileExists(FileName) then
    Exit;
  { GENERIC_WRITE=$40000000, 不共享(0), OPEN_EXISTING=3, FILE_ATTRIBUTE_NORMAL=$80 }
  Handle := CreateFileW(FileName, $40000000, 0, 0, 3, $80, 0);
  if Handle = InvalidHandleValue then
    Result := True
  else
    CloseHandle(Handle);
end;

{ 扫一个 arch 目录下所有 exe/dll，返回第一个被占用的完整路径（没有则空串）。 }
function FirstLockedFileInDir(const Dir: String): String;
var
  FindRec: TFindRec;
  Lower: String;
  Full: String;
begin
  Result := '';
  if not DirExists(Dir) then
    Exit;
  if not FindFirst(AddBackslash(Dir) + '*', FindRec) then
    Exit;
  try
    repeat
      if FindRec.Attributes and FILE_ATTRIBUTE_DIRECTORY = 0 then
      begin
        Lower := Lowercase(FindRec.Name);
        { 按**后缀**判，不用 Pos 子串：`classdata.tpk` 之类不该进来，而
          `foo.dll.stale`（换入残骸）也不是安装器要覆盖的目标。 }
        Lower := Copy(Lower, Length(Lower) - 3, 4);
        if (Lower = '.dll') or (Lower = '.exe') then
        begin
          Full := AddBackslash(Dir) + FindRec.Name;
          if FileLockedForWrite(Full) then
          begin
            Result := Full;
            Exit;
          end;
        end;
      end;
    until not FindNext(FindRec);
  finally
    FindClose(FindRec);
  end;
end;

{ 被占用的 galgame helper 组件（两个架构都查），没有则空串。 }
function LockedGalHookComponent(const AppDir: String): String;
var
  Base: String;
begin
  Base := AddBackslash(AppDir) + 'voice_hook\';
  Result := FirstLockedFileInDir(Base + 'x86');
  if Result = '' then
    Result := FirstLockedFileInDir(Base + 'x64');
end;

// BUG-1786：给正在运行的 update launcher 让路。
//
// 应用内更新时 {app}\fushi_update_launcher.exe **必然**处于运行中——它就是拉起本安装器
// 的那个进程，而且必须一直活到安装结束：BUG-1708 把「安装失败后谁把 app 拉回来」这一环
// 交给了它（app 为让出文件锁已经 exit 了，Inno 走不到 [Run] 就没人负责）。于是复制阶段
// 撞上「文件正被使用」→ DeleteFile code 5 → /SUPPRESSMSGBOXES 对 Abort/Retry/Ignore
// 默认取 **Abort** → 整包回滚。排在它后面的 data\app.so（全部 Dart 代码）和 flutter_assets
// 一个都装不上，而字母序在它之前的 fushi.exe 已经落地并被保留——半更新态：新 exe + 旧
// Dart 代码，版本号（读自 exe 资源）却显示为新版，用户完全无从察觉（现场：用户连报
// 「修好的 bug 怎么没生效」）。
//
// 这里**故意不杀 launcher**：杀了它就没人在安装失败时把 app 拉回来，等于用 BUG-1708 的
// 复发换这次复制成功。Windows 允许给正在运行的 exe **改名**（同卷，只是不能删除/覆盖），
// 改名后目标路径空出来让 Inno 正常写入新文件，而那个进程的映像仍然有效、照样兜底。
//
// 新版 app 起已改为从安装目录**外**的副本运行 launcher（platform_updater.dart 的
// stageWindowsUpdateLauncher），届时这里探测不到占用、直接返回；本过程是给**存量旧版**
// 用户的救援——他们跑的仍是安装目录里的 launcher，只有靠这一步才能把这一版装完整。
procedure MakeWayForRunningLauncher(const AppDir: String);
var
  Launcher: String;
  Stale: String;
  Attempt: Integer;
begin
  Launcher := AddBackslash(AppDir) + 'fushi_update_launcher.exe';
  Stale := AddBackslash(AppDir) + 'fushi_update_launcher.old.exe';
  { BUG-1831：launcher 不在位、只剩残留 —— 上一轮让路之后那次安装**仍然回滚了**。
    改名之后 Launcher 这个路径是空的，Inno 往里写的是一个**新建**文件，而回滚会删除
    本次新建的文件（只有被覆盖的文件才原样保留）⇒ 原件已改名、新件被删，安装目录里
    再没有 launcher。此时必须把残留**改回去**：它是同一份映像，旧版 app 又只认
    fushi_update_launcher.exe 这一个路径。先删掉它等于把「还能自愈」变成「这台机器
    永远发不出更新」（安装器一次都起不来，连 Inno 日志都不会产生）。
    改回去之后本次安装照常覆盖它，一次装完即回到正常态。 }
  if not FileExists(Launcher) then
  begin
    if FileExists(Stale) then
      RenameFile(Stale, Launcher);
    Exit;
  end;
  { 没被占用就什么都不做——不给正常路径平添一次改名和一个残留文件。
    顺手清掉上一轮的残留：原件在位说明它早已完成使命，不让它无限堆积。 }
  if not FileLockedForWrite(Launcher) then
  begin
    if FileExists(Stale) then
      DeleteFile(Stale);
    Exit;
  end;
  { 让路目标必须先空出来，否则 RenameFile 直接失败、等于没让路。残留可能正是
    **拉起本安装器的那个进程**（BUG-1831 的自愈路径上 app 就是从 .old 起的 launcher），
    删不掉就换个序号名——绝不因为一个删不掉的残留放弃整次安装。 }
  Attempt := 0;
  while FileExists(Stale) do
  begin
    if DeleteFile(Stale) then
      Break;
    Attempt := Attempt + 1;
    if Attempt > 8 then
      Exit;
    Stale := AddBackslash(AppDir) + 'fushi_update_launcher.old' +
      IntToStr(Attempt) + '.exe';
  end;
  RenameFile(Launcher, Stale);
end;

{ Runs after the user confirms install, before file copy — the last hook where
  we can still release file locks. Empty result string = proceed. }
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Locked: String;
  NL: String;
begin
  Result := '';
  KillProcessesUnderDir(ExpandConstant('{app}'));
  Sleep(500);
  { KillProcessesUnderDir 杀不到 launcher，也**不该**杀它（见上）。改名让路。 }
  MakeWayForRunningLauncher(ExpandConstant('{app}'));

  { BUG-1675：KillProcessesUnderDir 按**主模块路径**杀进程，杀得掉安装目录里的
    fushi_voice_injector.exe，却杀不掉真正的占用大头——**用户正在玩的游戏**：它的
    exe 在 D:\Games\ 之类的地方，只是把安装目录下 voice_hook\<arch>\fushi_voice_hook.dll
    映射了进去。放着不管，复制阶段就换不掉这些文件，而应用内更新用的
    /VERYSILENT /SUPPRESSMSGBOXES 会把这次失败静默吞掉，落地成「新本体 + 旧 helper」，
    用户下次开游戏才看到 `voice_hook open protocol_mismatch shm=13/want 15`，
    且那条提示给的处置（关掉游戏重开）对已经写坏的磁盘状态毫无作用。

    这里**故意不强杀游戏**：ffmpeg/injector 是我们自己的无状态子进程，杀了没有代价；
    而玩家的游戏里可能有没存档的进度，为了装个更新把它杀掉是不可接受的破坏。
    所以查出占用就在**复制任何文件之前**中止，让用户自己存档退出——这一步返回非空
    字符串，Inno 会显示它并干净地放弃本次安装，磁盘保持完整旧版本。 }
  Locked := LockedGalHookComponent(ExpandConstant('{app}'));
  if Locked <> '' then
  begin
    { NL 走变量而不是把 #13#10 直接写进串联式：ISPP 会把**行首**的 `#` 当成
      预处理指令，跨行拼接时以 #13#10 开头的续行会直接编译失败。 }
    NL := Chr(13) + Chr(10);
    { 文案不再断言占用者是「游戏」：Fushi 的捕获组件可以附着到任何被用户选中的窗口，
      实测现场里锁住 fushi_voice_hook.dll 的是**微信**（连开三天，于是每次自动更新都在
      这里中止，版本卡了五天，BUG-1708）。把占用者写死成游戏会让用户对着一个根本没开的
      东西找问题。只陈述事实：哪个文件被占用、它为什么会被别的进程持有、怎么放开。 }
    Result := '检测到 Fushi 的捕获组件正被其它程序占用，无法更新：' + NL + Locked + NL + NL +
      'Fushi 的语音捕获组件会注入到你选定的程序里（游戏，或任何你附着过的窗口），' + NL +
      '并由该程序持有到它退出为止。请关闭最近附着过的程序（游戏请先存档），' + NL +
      '然后重新运行本安装程序。' + NL + NL +
      '（本次未改动任何文件，现有版本可继续使用。）';
  end;
end;

// BUG-1014: preserve the user's desktop icon position across updates.
// Return False (skip creating the desktop shortcut) when {userdesktop}\Fushi.lnk
// already exists, so an update never rewrites it -- Explorer keeps the remembered
// grid position. On a first install the file is absent -> True -> the shortcut is
// created as before (gated by the default-checked "desktopicon" task).
function ShouldCreateDesktopIcon(): Boolean;
begin
  Result := not FileExists(ExpandConstant('{userdesktop}\Fushi.lnk'));
end;

// ── 数据存储位置（全新安装向导页）──────────────────────────────────────────
// 安装目录 ({app}) 与数据目录是两回事：书库/漫画/视频封面字幕/词典/数据库全落数据根，
// 体积可能远大于程序本身。旧行为是 app 首启无条件用默认根（<Documents>\Fushi\data +
// %APPDATA%\Fushi\Fushi），用户只能装完再去「设置 → 数据存储位置」整树迁移 + 重启。
// 这里在全新安装时多问一页；用户的选择经 {app}\data_root.bootstrap 一次性交给 app
// （lib/src/storage/installer_data_root_bootstrap.dart 首启消费后删除、之后唯一真相源
// 仍是 app 自己的 data_root 偏好）。安装器只是一次性写者，不是第二个配置来源。
//
// 只对全新安装显示：升级/重装时 app 已经有自己的数据根（默认或自定义），从安装器再
// 塞一个进去只会让既有书库「消失」；要搬走走设置里的迁移（连 DB 内绝对路径一起 rebase）。
const
  DataRootBootstrapFileName = 'data_root.bootstrap';

var
  DataRootPage: TInputDirWizardPage;
  { ShouldSkipPage 里判定并记住「本次真的向用户展示了数据目录页」。ssPostInstall 时卸载键
    已经写好，届时再调 IsFreshInstall 恒为 False，所以必须在页面阶段落下这个标记。 }
  DataRootPageOffered: Boolean;

{ Inno 卸载键：HKCU（PrivilegesRequired=lowest）\...\Uninstall\<AppId>_is1。AppId 直接
  经 ISPP 从 Setup 段取，再让 ExpandConstant 做双左括号 → 单左括号的转义——Setup 段里
  写的是双括号包着的 GUID，真值是「单左括号 + GUID + 双右括号」（尾部两个右括号是 Inno
  的既定行为，不是笔误）。手抄 GUID 会漏掉这一层，键永远匹配不上。
  注意：本注释任何一行都不能以「[」开头——Inno 段解析先于 Code 段，会当成段标签。 }
function FushiUninstallKey(): String;
begin
  Result := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\'
    + ExpandConstant('{#SetupSetting("AppId")}') + '_is1';
end;

{ 全新安装 = 卸载键不存在（没装过 / 已卸载）且 app 的平台固定落点不存在——
  %APPDATA%\Fushi\Fushi（path_provider 取 exe 版本资源 CompanyName\ProductName），
  兼看改名前的 %APPDATA%\Hibiki\Hibiki（app 首启 migrateLegacySupportDir 会把它搬成新名，
  随后认出旧库、丢弃安装器的选择）。这两条兜住「卸载但保留了数据」的重装：那种机器上
  app 首启会认出旧库，安装器不该再问。 }
function IsFreshInstall(): Boolean;
begin
  Result := (not RegKeyExists(HKCU, FushiUninstallKey()))
    and (not DirExists(ExpandConstant('{userappdata}\Fushi\Fushi')))
    and (not DirExists(ExpandConstant('{userappdata}\Hibiki\Hibiki')));
end;

{ A 等于 B、或是 B 的祖先目录（大小写不敏感、按整段路径前缀比较：尾部补反斜杠后
  'C:\Fushi\' 不会误配 'C:\FushiData\'）。 }
function IsSameOrAncestorDir(const A, B: String): Boolean;
begin
  Result := Pos(Lowercase(AddBackslash(A)), Lowercase(AddBackslash(B))) = 1;
end;

// ── MD3 排版与控件外观 ──
// [Setup] 段的 WizardStyle / WizardBackColor / Wizard*ImageFile 把**整体形态**做成
// MD3（扁平、无分隔线、MD3 surface 背景与主色晕、明暗自适应、MD3 标记与竖图）。
// 本段补的是指令覆盖不到的两件事：MD3 type scale 的页眉排版，以及控件本身的
// 圆角与配色。
//
// 【关于「样式接管颜色」的更正】旧注释断言 MainPanel.Color 与
// PageNameLabel.Font.Color 是空操作、只能靠自制 .vsf 解决。那个结论只在**没有
// StyleElements** 的前提下成立：Inno 6.6 给 Pascal Scripting 的 TControl 加了
// StyleElements 属性，从中去掉 seFont / seClient / seBorder，对应的
// Font.Color / Color / 边框就交还给控件自己。实测（6.7.3 本机深色模式，离屏
// PrintWindow 抓真实像素）标题、页眉底色、输入框底色与字色**都改得动**。
//
// 但按钮是硬例外，两条都撞死：
//   - TNewButton 在 Pascal Script 里**没有 Color 属性**（写了直接编译失败：
//     Unknown identifier 'COLOR'），填充色无从赋值；
//   - 从按钮的 StyleElements 去掉 seClient 会让它连样式绘制一起丢掉，退回系统
//     原生按钮（深色模式下是刺眼的白底黑字），比不改更糟。
// 所以**按钮填充色是这套里唯一只能靠自制 VCL 样式文件（WizardStyleFile）的项**，
// 而那条路要 Delphi 的 Bitmap Style Designer，本仓没有这条工具链。按钮字色
// （只去 seFont，保住样式填充）照常可改，已经用上。
//
// 【圆角不走样式】MD3 的 pill 按钮不需要 .vsf——控件「是什么形状」是 Win32 层的
// 事：SetWindowRgn 把按钮窗口裁成圆角矩形后，样式照常往裁剩的区域里画，角外露出
// 父窗口背景（正好是我们的 MD3 渐变图）。这反而比 .vsf 强：VCL 样式的按钮是九宫格
// 位图，做不出胶囊形。
// 版本闸门：StyleElements 与 IsDarkInstallMode 是 Inno **6.6** 才加的，6.5 及更老的
// 编译器见到直接报 Unknown identifier。[Setup] 段那道 6.7 闸门保的是「老编译器仍能
// 出包、只是退回旧外观」这个不变式，[Code] 这边不跟上就等于单方面废掉它。
// 圆角本身只用 Win32、不挑版本，但它和配色是同一套观感，一起进闸门更好懂。
#if VER >= EncodeVer(6,6,0)
  #define Md3Chrome
#endif

#ifdef Md3Chrome
const
  { 裁切时的内缩像素数，用来吃掉样式画在控件最外圈的矩形边框（见 Md3RoundControl）：
    按钮上那是默认按钮的强调框，输入框上那是一圈亮白粗边。两者都改不动颜色、又都是
    矩形，只能从可见区域里排除掉。 }
  Md3ButtonInset = 2;
  Md3EditInset = 2;
  { 圆角半径，单位是 dp（用处按 ScaleY 换算到物理像素）。
    为什么不是 MD3 那种 full-round 胶囊：SetWindowRgn 是 GDI 的二值裁切，**没有
    抗锯齿**，半径越大露出的像素阶梯越长。实测胶囊形（半径=高度一半）在 150% DPI 下
    边缘是一排肉眼可见的台阶，观感比方角还差；输入框上还会把方形的选中高亮块切掉
    一角。取小半径后锯齿只落在几像素的弧上，基本看不出来，同时按钮和输入框用同一个
    值，不会出现「一个胶囊一个方框」的不齐。
    这是 Inno 的能力边界，不是没调好：真正平滑的圆角要么靠自制 VCL 样式（需要
    Delphi），要么靠自绘控件（Inno 的 TPanel 不响应事件、TBitmapImage 要把文字烧进
    位图，见 Md3StyleButton 的长注释）。 }
  Md3CornerRadius = 4;

function CreateRoundRectRgn(X1, Y1, X2, Y2, W, H: Integer): THandle;
  external 'CreateRoundRectRgn@gdi32.dll stdcall';
function SetWindowRgn(hWnd: THandle; hRgn: THandle; bRedraw: Boolean): Integer;
  external 'SetWindowRgn@user32.dll stdcall';
function SendMessageW(hWnd: THandle; Msg: Cardinal; wParam, lParam: Longint): Longint;
  external 'SendMessageW@user32.dll stdcall';
{ 标题栏染色。Inno 自己的 includetitlebar 修饰符要 7.0，我们钉的是 6.7.3，
  所以走 DWM：Win11 (build 22000+) 允许直接指定标题栏底色/字色/边框色。
  在更老的系统上这几个属性未知，DwmSetWindowAttribute 返回 E_INVALIDARG 就完事，
  不会崩也不会画错——所以不判系统版本，失败即保持原生标题栏。 }
function DwmSetWindowAttribute(Wnd: THandle; Attr: Integer; var Value: Integer;
  Size: Integer): Integer;
  external 'DwmSetWindowAttribute@dwmapi.dll stdcall';

{ 把控件裁成圆角矩形。Radius 是角半径，GDI 要的是椭圆的宽高所以传直径。
  +1 是 GDI 的半开区间：CreateRoundRectRgn 的右下边界不含，不补会少一列像素。
  region 交给 SetWindowRgn 后由系统持有，**不要 DeleteObject**。

  Inset 让裁切区域四周内缩若干像素。这不是为了留白，是为了**吃掉样式画在控件最外
  圈的矩形边框**：默认按钮（Next）的强调框是矩形，pill region 一裁就成了上下两条
  横线加左右两小截四段断线（放大图上很刺眼），而它又摘不掉——seBorder 管不着它，
  摘 seClient 会让按钮整个丢掉样式绘制。内缩 2px 把那一圈直接排除在可见区域外。 }
procedure Md3RoundControl(Ctl: TWinControl; Radius, Inset: Integer);
var
  Rgn: THandle;
begin
  Rgn := CreateRoundRectRgn(Inset, Inset, Ctl.Width + 1 - Inset, Ctl.Height + 1 - Inset,
    Radius * 2, Radius * 2);
  SetWindowRgn(Ctl.Handle, Rgn, True);
end;

{ 按当前明暗取 MD3 色。两套都取自 app 同源的 MD3 baseline 色板，与 [Setup] 段的
  WizardBackColor（#FEF7FF / #141218）同一族。 }
function Md3Primary(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#D0BCFF')
  else
    Result := StrToColor('#6750A4');
end;

function Md3OnSurface(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#E6E0E9')
  else
    Result := StrToColor('#1D1B20');
end;

function Md3SurfaceContainer(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#2B2930')
  else
    Result := StrToColor('#F3EDF7');
end;

function Md3SurfaceContainerHighest(): TColor;
begin
  if IsDarkInstallMode then
    Result := StrToColor('#36343B')
  else
    Result := StrToColor('#E6E0E9');
end;

function Md3Surface(): TColor;
begin
  { 与 [Setup] 段的 WizardBackColor / WizardBackColorDynamicDark 同值。 }
  if IsDarkInstallMode then
    Result := StrToColor('#141218')
  else
    Result := StrToColor('#FEF7FF');
end;

{ 把标题栏也拉进 MD3：底色接上页面 surface，标题文字用 onSurface，边框用同色
  以免露出一圈系统默认的亮边。
  TColor 本身就是 COLORREF（0x00BBGGRR），可以直接喂给 DWM，不用换字节序。
  三个属性号：34=BORDER_COLOR，35=CAPTION_COLOR，36=TEXT_COLOR，均 Win11 起支持；
  返回值不检查——老系统上失败就是保持原生标题栏，这正是想要的降级。 }
procedure Md3StyleTitleBar(Wnd: THandle);
var
  Caption, Text, Border: Integer;
begin
  Caption := Md3Surface;
  Text := Md3OnSurface;
  Border := Md3Surface;
  DwmSetWindowAttribute(Wnd, 35, Caption, SizeOf(Caption));
  DwmSetWindowAttribute(Wnd, 36, Text, SizeOf(Text));
  DwmSetWindowAttribute(Wnd, 34, Border, SizeOf(Border));
end;

#endif

function Md3UiFontName(const Fallback: String): String;
begin
  { MD3 用 Roboto，Windows 上没有；按 Win11 → Win10 → 兜底取系统 UI 字体。
    不判存在就直接写字体名的话，字体缺失时 GDI 会回落到 Tahoma，比默认还难看。 }
  if FontExists('Segoe UI Variable Display') then
    Result := 'Segoe UI Variable Display'
  else if FontExists('Segoe UI') then
    Result := 'Segoe UI'
  else
    Result := Fallback;
end;

#ifdef Md3Chrome
{ 按 MD3 把一个按钮做成胶囊形并给字色。

  填充色改不了，这是试到底之后的结论，别再重走：
    - TNewButton 在 Pascal Script 里**没有 Color 属性**（写了直接编译失败：
      Unknown identifier 'COLOR'）；
    - 从 StyleElements 摘掉 seClient 会让它连样式绘制一起丢掉，退回系统原生按钮
      （深色模式下是刺眼的白底黑字），比不改更糟；
    - 拿 TPanel 盖一层「视觉按钮」也走不通：Panel 会吃掉鼠标点击，而它的 OnClick
      在 Inno 里根本不触发（赋值编译得过、运行期没反应），WS_EX_TRANSPARENT 也不
      让子窗口的命中测试穿透 —— 净结果是**按钮点不动**，对安装器是致命的；
    - TBitmapImage 的确能当自绘按钮，但那要求把 Caption（Next / Install / Finish，
      还随语言变）连同明暗、DPI 档、禁用/焦点态一起烧进位图，组合爆炸且极易与真实
      Caption 失步 —— 拿观感换一个「按钮文字可能是错的」的风险，不划算。
  所以按钮填充只能由 WizardStyleFile 指定的自制 VCL 样式决定，而那需要 Delphi 的
  Bitmap Style Designer，本仓没有这条工具链。字色和形状都已拿到，止步于填充。 }
procedure Md3StyleButton(Btn: TNewButton; TextColor: TColor);
begin
  { 连 seBorder 一起摘：默认按钮（Next）的强调边框是**矩形**，被 pill region 裁完
    只剩上下两条横线加左右两小截，比不做圆角还难看（实测放大图上四段断线清晰可见）。
    seClient 必须留着 —— 理由见上。 }
  Btn.StyleElements := Btn.StyleElements - [seFont, seBorder];
  Btn.Font.Color := TextColor;
  Btn.Font.Name := Md3UiFontName(Btn.Font.Name);
  Md3RoundControl(Btn, ScaleY(Md3CornerRadius), Md3ButtonInset);
end;

{ MD3 filled text field。
  参数类型必须是 TEdit 而不是 TCustomEdit：Color 是 TEdit 才暴露的属性，
  写成基类会编译失败（Unknown identifier 'COLOR'）。

  为什么是 filled 而不是 outlined：outlined 需要一条自己控制得了的 outline，而这里
  唯一存在的边框是样式画的那圈亮白粗边 —— 颜色改不动（seBorder 摘了也还在），形状
  又是矩形，圆角一裁就成四段断线。与其留着这条又丑又不受控的线，不如按 MD3 的
  filled 变体做：内缩 2px 把它整个吃掉，靠 surfaceContainerHighest 的底色与背景
  分层。MD3 里 filled text field 本来就是「有底色、无边框」。 }
procedure Md3StyleEdit(Edit: TEdit);
var
  Margin: Integer;
begin
  Edit.StyleElements := Edit.StyleElements - [seClient, seBorder, seFont];
  Edit.Color := Md3SurfaceContainerHighest;
  Edit.Font.Color := Md3OnSurface;
  Edit.Font.Name := Md3UiFontName(Edit.Font.Name);

  { 左右内边距。两个理由，缺一不可：
      - MD3 的 filled text field 本来就有 16dp 的水平内边距，贴边的文字不是 MD3；
      - 更要紧的是，Edit 的文本和**选中高亮块**都从 x=2 起画，紧贴左边缘，圆角一裁
        就把高亮块的左端啃掉一个弧形缺口（肉眼很明显，像文字陷在圆里）。
    EM_SETMARGINS(0xD3) + EC_LEFTMARGIN|EC_RIGHTMARGIN(3)，lParam 低位是左、高位是右。 }
  Margin := ScaleX(14);
  SendMessageW(Edit.Handle, $00D3, 3, Margin or (Margin * 65536));

  Md3RoundControl(Edit, ScaleY(Md3CornerRadius), Md3EditInset);
end;

{ 把「选择安装位置」页的经典黄纸夹换成 MD3 folder。
  Inno 不会按 DPI 缩放 TBitmapImage 的位图，所以按控件实际宽度挑一档最接近的
  ——直接拿一张大图 Stretch 会糊。 }
procedure Md3ApplyFolderIcon(Img: TBitmapImage);
var
  Side: Integer;
  AssetName: String;
begin
  { Img.Width 已经是**物理**像素（窗体整体按 DPI 放大过了），所以直接和档位比，
    别再套 ScaleX —— 那会把 150% 下 55px 宽的控件误判成 32 档，图标肉眼可见地小一圈。 }
  if Img.Width <= 40 then
    Side := 32
  else if Img.Width <= 56 then
    Side := 48
  else if Img.Width <= 80 then
    Side := 64
  else
    Side := 96;

  if IsDarkInstallMode then
    AssetName := 'wizard_folder_dark_' + IntToStr(Side) + '.bmp'
  else
    AssetName := 'wizard_folder_' + IntToStr(Side) + '.bmp';

  ExtractTemporaryFile(AssetName);
  Img.Bitmap.LoadFromFile(ExpandConstant('{tmp}\') + AssetName);
end;
#endif

procedure ApplyMd3Chrome();
begin
  WizardForm.PageNameLabel.Font.Name :=
    Md3UiFontName(WizardForm.PageNameLabel.Font.Name);
  WizardForm.PageNameLabel.Font.Style := [];
  WizardForm.PageNameLabel.Font.Size := WizardForm.PageNameLabel.Font.Size + 3;
#ifdef Md3Chrome
  { 页眉标题吃 MD3 primary：这是整屏唯一的强调色落点，也是把「Windows 蓝」换成
    「MD3 紫」最省的一处。去 seFont 才赋得动色（见上面的更正注释）。 }
  WizardForm.PageNameLabel.StyleElements :=
    WizardForm.PageNameLabel.StyleElements - [seFont];
  WizardForm.PageNameLabel.Font.Color := Md3Primary;
#endif
  { 放大后高度要重算，再把说明文字顶到新高度下面——两个标签都是固定坐标摆的，
    不重排就会叠在一起。 }
  WizardForm.PageNameLabel.AdjustHeight;

  WizardForm.PageDescriptionLabel.Font.Name :=
    Md3UiFontName(WizardForm.PageDescriptionLabel.Font.Name);
  WizardForm.PageDescriptionLabel.Top :=
    WizardForm.PageNameLabel.Top + WizardForm.PageNameLabel.Height + ScaleY(2);

#ifdef Md3Chrome
  { 常驻按钮。填充都是样式给的同一块深灰（改不动，见 Md3StyleButton 的注释），
    靠字色分主次：主按钮 primary，次要的 onSurface。 }
  Md3StyleButton(WizardForm.NextButton, Md3Primary);
  Md3StyleButton(WizardForm.BackButton, Md3OnSurface);
  Md3StyleButton(WizardForm.CancelButton, Md3OnSurface);
  Md3StyleButton(WizardForm.DirBrowseButton, Md3Primary);

  Md3StyleEdit(WizardForm.DirEdit);

  Md3ApplyFolderIcon(WizardForm.SelectDirBitmapImage);

  { 「准备安装」页的摘要框（ReadyMemo）**有意不做样式**，三种时机全试过、全有代价：
      - InitializeWizard 里做（内容还空着、重建无损）：句柄被提前创建，这个凭空实体化
        的控件盖住别的页 —— 实测把「选择附加任务」页第二项末尾的「 等)」遮掉了；
      - CurPageChanged 里做：Inno 那时**还没填完**摘要，改 StyleElements/BorderStyle
        触发的句柄重建把内容截断（末行只剩「文件关联」四个字）；
      - CurPageChanged 里先存 Lines.Text、样式化后再放回：读到的本来就是半截，赋回去
        反而覆盖了 Inno 后续的填充，摘要直接断在「附加任务」。
    换来的只是摘要框底色调一档、少一圈边框，拿这个冒「用户看不到自己装了什么」的险
    不划算。这框就保持 Inno 原样。 }

  { **不要**碰程序组页的那三个控件（GroupBrowseButton / GroupEdit /
    SelectGroupBitmapImage）。本安装器 DisableProgramGroupPage=yes，那一页从不显示，
    它们的窗口句柄本来也不该被创建 —— 而这里每个样式过程都要读 .Handle（设 region、
    发 EM_SETMARGINS），一读就把句柄强行创建出来。实测后果：这些凭空实体化的控件
    盖在「选择附加任务」页上，把任务列表第一项「创建桌面快捷方式」的文字整个遮掉，
    只剩一个孤零零的勾选框（对照 develop 版逐页截图确认，是本次改动引入的）。 }

  Md3StyleTitleBar(WizardForm.Handle);
#endif
end;

procedure InitializeWizard();
begin
  ApplyMd3Chrome();
  DataRootPageOffered := False;
  DataRootPage := CreateInputDirPage(wpSelectDir,
    '选择数据存储位置',
    '导入的书籍、漫画、视频封面与字幕、词典和数据库存放在哪里？',
    '这些数据可能远大于程序本身，建议选一个空间充足的位置。' + #13#10 +
    '之后可以在「设置 → 数据存储位置」里迁移。' + #13#10#13#10 +
    '点击「下一步」继续。',
    False, 'Fushi');
  DataRootPage.Add('');
#ifdef Md3Chrome
  { 这页是 CreateInputDirPage 自建的，控件不在 WizardForm 上，ApplyMd3Chrome 扫不到。
    全新安装必经此页，漏了就会出现「向导其余页是 MD3、唯独这页是 Windows 原样」。

    位置很讲究，两边都卡死了：
      - 必须在 Add 之后 —— Edits/Buttons 是 Add 时才创建的；
      - 必须在 Values[0] 赋值**之前** —— 改 StyleElements 会让 VCL 重建控件的窗口
        句柄，把已经写进去的文本一起丢掉。先设样式后赋值就没事；反过来（先赋值再
        设样式）实测这页的输入框会变**空白**，用户点「下一步」会被 BUG-1483 那道
        路径预检挡住，直接卡在这页。 }
  Md3StyleEdit(DataRootPage.Edits[0]);
  Md3StyleButton(DataRootPage.Buttons[0], Md3Primary);
#endif
  DataRootPage.Values[0] := ExpandConstant('{userdocs}\Fushi');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (DataRootPage <> nil) and (PageID = DataRootPage.ID) then
  begin
    { 静默安装（/SILENT、/VERYSILENT：无人值守部署、app 内自更新）没人回答这页，
      Inno 仍会逐页 ClickThrough——NextButtonClick 返回 False 会整个安装中止。
      静默 = 不问、不写引导文件，app 按默认根走，与改动前逐字节一致。 }
    DataRootPageOffered := (not WizardSilent()) and IsFreshInstall();
    Result := not DataRootPageOffered;
  end;
end;

{ ssPostInstall：把用户选的数据目录交给 app。默认值也照写——「选的是不是默认位置」由
  app 按它自己的默认根定义归一化，安装器不复制这条规则。 }
procedure WriteDataRootBootstrap();
var
  Lines: TArrayOfString;
  Target: String;
begin
  if not DataRootPageOffered then
    Exit;
  { DataRootPageOffered 只可能在 ShouldSkipPage 里被置真，那时 DataRootPage 必非 nil；
    显式再判一次，别让这条隐式不变式成为一次改动就能踩穿的解引用。 }
  if DataRootPage = nil then
    Exit;
  Target := RemoveBackslashUnlessRoot(Trim(DataRootPage.Values[0]));
  if Target = '' then
    Exit;
  SetArrayLength(Lines, 1);
  Lines[0] := Target;
  if not SaveStringsToUTF8File(ExpandConstant('{app}\' + DataRootBootstrapFileName), Lines, False) then
    Log('WriteDataRootBootstrap: 写入失败，app 将使用默认数据位置');
end;

// Fushi 改名的旧名残留清理，全部放在 ssPostInstall（新文件已全部落地之后），
// 不放 [InstallDelete]：后者在复制前执行，且 Inno 不会在安装失败/取消时回滚删除，
// 于是任何一次中途失败的升级都会把「还剩个能跑的旧版」变成「一个可执行文件都没有」。
// ssPostInstall 只有在文件复制成功后才会到达，删旧名二进制不再有这个窗口。
//
// 平台限制（如实记录）：Windows 不提供程序化「固定到任务栏」的公开接口，
// 所以任务栏固定项这里只能删掉指向已消失的 hibiki.exe 的死链接，
// 无法自动改指 fushi.exe、也无法重新固定；用户需要的话得手动再固定一次。
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then
    Exit;

  WriteDataRootBootstrap();

  // 旧名可执行文件：Inno 只覆盖同名文件，改了名的旧 exe 不清就会与 fushi.exe
  // 并存，旧快捷方式还能把上一版拉起来。
  DeleteFile(ExpandConstant('{app}\hibiki.exe'));
  DeleteFile(ExpandConstant('{app}\hibiki_update_launcher.exe'));

  // 旧名 native 产物（改名前 windows/CMakeLists.txt 装的是 hoshidicts_ffi.dll
  // 与 hibiki_torrent_ffi.dll）。留着一是纯垃圾，二是 torrent 引擎按名加载
  // 「exe 同目录」，等于给「新 DLL 缺失时静默加载上一版旧 ABI」留口子。
  DeleteFile(ExpandConstant('{app}\hibiki_torrent_ffi.dll'));
  DeleteFile(ExpandConstant('{app}\hoshidicts_ffi.dll'));

  // 三处旧名快捷方式全部指向已删除的 hibiki.exe，都是死链接。
  // 1) 桌面
  DeleteFile(ExpandConstant('{userdesktop}\Hibiki.lnk'));
  // 2) 开始菜单程序组（UsePreviousGroup=no 之后 {group} 已是 Fushi 组；
  //    这条覆盖「旧 lnk 与新组同目录」的情形，遗留的 Hibiki 组另行处理）。
  DeleteFile(ExpandConstant('{group}\Hibiki.lnk'));
  // 3) 任务栏固定项——[InstallDelete] 从来没清过它，正是用户实测那个
  //    「任务栏图标点了没反应」的死链接来源。
  DeleteFile(ExpandConstant('{userappdata}\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Hibiki.lnk'));

  // 遗留的 Programs\Hibiki 程序组：旧安装留下的 Hibiki.lnk，以及
  // UsePreviousGroup=yes 时期误建在该组里的 Fushi.lnk。两个都删掉后目录空了才移除
  // （RemoveDir 只删空目录，用户自己往里放的东西不会被波及）。
  DeleteFile(ExpandConstant('{userprograms}\Hibiki\Hibiki.lnk'));
  DeleteFile(ExpandConstant('{userprograms}\Hibiki\Fushi.lnk'));
  RemoveDir(ExpandConstant('{userprograms}\Hibiki'));
end;

function InitializeSetup(): Boolean;
var
  Attempt: Integer;
begin
  Result := True;
  { No mutex = no running instance, pass straight through (first install / the
    app has already exited cleanly). }
  if not AppMutexExists() then
    Exit;

  { Gentle first: WM_CLOSE gives the app a chance to save state and release the
    mutex on its own. 过渡期新旧 exe 名都发。 }
  KillGracefully('fushi.exe');
  KillGracefully('hibiki.exe');
  for Attempt := 1 to GracefulCloseAttempts do
  begin
    if not AppMutexExists() then
      Exit;
    Sleep(MutexReleasePollIntervalMs);
  end;

  { Still alive: force-kill both exe names, then sweep every msedgewebview2.exe.
    按 image 名逐个杀，**不用进程树**（BUG-2203：安装器自己就在 fushi.exe 的后代树里）；
    WebView2 的每一个子进程都叫 msedgewebview2.exe，第三行已经全数覆盖。 }
  KillImage('fushi.exe');
  KillImage('hibiki.exe');
  KillImage('msedgewebview2.exe');

  { Bounded poll until the mutex is truly released; on timeout still return True
    (do not hang forever) and let the [Setup] AppMutex fallback handle it. }
  for Attempt := 1 to MutexReleasePollAttempts do
  begin
    if not AppMutexExists() then
      Exit;
    Sleep(MutexReleasePollIntervalMs);
  end;
end;

{ BUG-1483: 选目录页写入预检。本安装器 PrivilegesRequired=lowest（不提权），
  用户手选 Program Files 这类需要管理员权限的目录时，老行为是复制阶段才蹦
  "Error 5: 拒绝访问" 中断安装；就算用户再手动提权装进去，运行期还有第二排雷：
  应用以普通权限跑，WebView2 数据目录与应用内自动更新都写不进安装目录
  （更新每次都得提权）。所以在用户点「下一步」时就实测一把可写性，拦下并给出
  明确指引，而不是让错误在安装中途/运行期反复浮现。
  探测方式：目录已存在→写探针文件再删掉；不存在→建目录链（建成后目录留给
  正式安装直接用，不回滚——马上就要装进去，且 RemoveDir 误删既有空目录的
  风险比留一个空目录大）。}
function InstallDirWritable(const Dir: String): Boolean;
var
  Probe: String;
  CreatedByProbe: Boolean;
begin
  Result := False;
  CreatedByProbe := False;
  if not DirExists(Dir) then
  begin
    if not ForceDirectories(Dir) then
      Exit;
    CreatedByProbe := True;
  end;
  Probe := AddBackslash(Dir) + '.fushi-setup-write-test';
  if SaveStringToFile(Probe, 'fushi setup preflight', False) then
  begin
    DeleteFile(Probe);
    Result := True;
  end;
  { 预检不该留下痕迹。探针文件一直是删的，**目录**却留着了，两个后果都实测复现过：
      - 用户在选目录页点了「下一步」之后取消安装，机器上凭空多出一个空目录；
      - 再次运行安装器时该目录已存在，Inno 于是弹「Folder Exists / 文件夹已存在，
        仍要安装到该文件夹吗？」——对一个**从没装过**的用户，这个确认框没有任何意义。
    只删我们自己刚建的这一级：目录本来就存在时（升级、或用户手动建过）一律不碰。
    ForceDirectories 可能建了多级，但上级几乎总是已存在的系统目录，多留一级空目录
    远好过误删用户的东西，所以这里只收回最后一级。 }
  if CreatedByProbe then
    RemoveDir(Dir);
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  DataRoot: String;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    if not InstallDirWritable(WizardDirValue) then
    begin
      MsgBox('当前权限无法写入所选目录：' + #13#10 + WizardDirValue + #13#10#13#10
        + '请改选用户可写的目录（推荐默认目录 '
        + ExpandConstant('{localappdata}\Fushi') + '）。' + #13#10#13#10
        + '不建议装进需要管理员权限的目录：即使以管理员身份重装到该目录，'
        + '应用日常以普通权限运行，之后每次自动更新都需要再次提权。',
        mbError, MB_OK);
      Result := False;
    end;
  end
  else if (DataRootPage <> nil) and (CurPageID = DataRootPage.ID) then
  begin
    DataRoot := RemoveBackslashUnlessRoot(Trim(DataRootPage.Values[0]));
    { 绝对路径预检，必须排在其余三条业务校验之前。TInputDirWizardPage 的编辑框允许清空、
      也照收相对路径，Inno 对自定义页的取值不做任何自动校验，而下面三条业务校验对这两种
      输入**全部放行**（Inno 6.7.3 实测，不是推断）：
        AddBackslash('') = ''           → 子目录探测变成相对路径 'documents'，DirExists 假
        IsSameOrAncestorDir 两向         → 都假
        DirExists('') = False，但 ForceDirectories('') = True，SaveStringToFile 也成功
                                        → InstallDirWritable('') 返回 True
      后果：空串一路走到 WriteDataRootBootstrap，被那里的空串兜底 Exit 掉——不写坏数据，
      但用户的选择被**静默丢弃**；相对路径更糟，安装器会在 setup 自己的工作目录（用户的
      下载目录）里真建出一个目录、写探针、再把相对路径原样写进引导文件，直到 app 侧
      installer_data_root_bootstrap.dart 的绝对路径判定才被丢掉，而那条拒绝路径是无声的。
      路径合法性不能整层下放给 app：这里就得判死并告诉用户。
      判据：盘符路径 X:\...（含盘符根 X:\，长度 3）或 UNC \\server\share。正斜杠写法
      C:/Fushi 也判非法——Inno 的目录选择框只产出反斜杠，手打正斜杠给明确报错，
      好过一路放行到 app 再无声丢弃。 }
    if (Length(DataRoot) < 3)
      or ((Copy(DataRoot, 2, 2) <> ':\') and (Copy(DataRoot, 1, 2) <> '\\')) then
    begin
      MsgBox('数据存储位置必须是完整的绝对路径（例如 D:\FushiData）。' + #13#10#13#10
        + '当前填写的是：' + #13#10 + DataRoot,
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    { 数据目录与安装目录不得相同或互相包含：自动更新 / 安装回滚会整体处理安装目录，
      数据压在下面会被一起清；反过来安装目录落在数据根里则迁移会拒绝（含运行中 exe）。
      app 侧 installer_data_root_bootstrap.dart 首启再做一次同样的双向判定。 }
    if IsSameOrAncestorDir(DataRoot, WizardDirValue)
      or IsSameOrAncestorDir(WizardDirValue, DataRoot) then
    begin
      MsgBox('数据存储位置不能与安装目录相同或互相包含：' + #13#10
        + '安装目录：' + WizardDirValue + #13#10
        + '数据目录：' + DataRoot + #13#10#13#10
        + '请另选一个独立的目录（推荐默认 '
        + ExpandConstant('{userdocs}\Fushi') + '）。',
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    { app 会在所选目录下派生 documents\ 与 support\ 两棵私有子树并整树接管（子目录名的
      真相源是 Dart 侧 AppPaths.dataRootDocumentsChild / dataRootSupportChild，源码守卫
      把两侧绑在一起，改了 Dart 常量这里会当场变红而不是静默放行）；用户自己的
      目录里已经有同名子目录（典型：把 D:\Downloads 选成数据根）就不能选——否则之后的
      数据根迁移会把用户文件当 Fushi 数据整树搬走 / 删掉。app 首启同样拒绝（targetNotEmpty），
      这里提前拦，别让用户装完才发现选择被丢弃。 }
    if DirExists(AddBackslash(DataRoot) + 'documents')
      or DirExists(AddBackslash(DataRoot) + 'support') then
    begin
      MsgBox('所选目录下已经存在 documents 或 support 子目录：' + #13#10 + DataRoot + #13#10#13#10
        + 'Fushi 会在数据目录下创建并接管这两个子目录，请选一个空目录或新建一个目录。',
        mbError, MB_OK);
      Result := False;
      Exit;
    end;
    if not InstallDirWritable(DataRoot) then
    begin
      MsgBox('当前权限无法写入所选数据目录：' + #13#10 + DataRoot + #13#10#13#10
        + '请改选用户可写的目录（推荐默认 '
        + ExpandConstant('{userdocs}\Fushi') + '）。',
        mbError, MB_OK);
      Result := False;
    end;
  end;
end;
