# WeType patch

适用于微信输入法 **2.2.3 (657)，Apple Silicon**。

- 按应用恢复中英文模式：固定配置 → 应用记忆 → 默认英文。
- 支持 CLI 切换，模式改变时显示原生翻转提示。
- 停用原厂自动模式重置，保留手动切换；新增英文输入源入口。

Windows 版见文末 [Windows](#windows) 一节。

## 构建与安装

需要 Python 3、Xcode Command Line Tools 和 just。先安装官方输入法，另备一份未修改的同版本 app 作为构建输入。

```sh
just build /path/to/original/WeType.app
# 先切到其他输入法
just install
```

## just 命令

在项目目录运行 `just` 查看列表。除上述构建、安装外：

```sh
just verify                          # 校验构建产物
just inspect /path/to/WeType.app      # 查看版本与符号信息
just restart                         # 结束进程，下次聚焦时重新启动
just status                          # 当前中英文状态
just chinese                         # 切中文
just english                         # 切英文
just auto-status                     # 自动切换配置
just auto-on                         # 开启按应用恢复
just auto-off                        # 关闭按应用恢复
just apps                            # 应用模式列表
just app-set com.apple.Terminal english  # 固定应用模式
just app-forget com.apple.Terminal    # 删除固定配置，恢复应用记忆
```

## CLI 命令

先选中微信输入法并聚焦输入框：

```sh
CLI='/Library/Input Methods/WeType.app/Contents/MacOS/wetype-cli'
"$CLI" status
"$CLI" chinese
"$CLI" english
"$CLI" toggle
"$CLI" auto-status
"$CLI" auto-on
"$CLI" auto-off
"$CLI" apps
"$CLI" app-set com.apple.Terminal english
"$CLI" app-forget com.apple.Terminal
"$CLI" stop
```

- `chinese/english` 已是目标模式时不切换；只控制当前 WeType 会话，不选择其他系统输入源。
- `app-set BUNDLE_ID chinese|english` 固定应用模式，不被手动切换或记忆覆盖；`app-forget` 删除固定配置，恢复应用记忆。
- `auto-off` 保留当前模式，停用应用恢复；`stop` 同时停用 IPC 和应用恢复，宿主重启后恢复，原生手动切换不受影响。
- `status.ok` 只表示桥响应，实际模式看 `stateKnown` / `mode`。退出码：0 成功，1 拒绝或结果不明，2 参数错误，3 超时；不要盲目重试 `toggle`。

模式记忆在 `~/Library/Preferences/local.orkward.wetype.patch.plist`，`fixedAppModes` 存固定配置，`appModes` 存记忆。CLI 切换成功后立即保存；原生手动切换在离开应用时保存，提前退出进程可能丢失这次变化。`app-set`、`app-forget`、`auto-on` 对当前应用立即应用规则。

## 二进制分析与补丁

以下结论对应 **2.2.3 (657) arm64**，符号地址及指纹见 `profiles/wetype-2.2.3-657.json`。

### 模式处理

主程序提取 arm64 slice，在现有 Mach-O header padding 中加入加载路径 `@executable_path/../Frameworks/libwetype-bridge.dylib`。原中文入口保留，新增 `.english` 入口，语言为 en，显示名仍为“微信输入法”。

三处指令补丁：

| 位置 | 修改及作用 |
| --- | --- |
| `isDefaultASCIIMode(bundleID:)` | 统一返回 false，让原生 getter、菜单及快捷键共用全局模式；更换 controller 不再隐式选中另一份应用模式。 |
| `resetInputMode()` | 直接返回，停用激活超时、输入源同步和设置通知触发的模式重置。 |
| `activateServer` 的 `0x1001187ac–0x100118880` | 同步调用 `WTBridgeActivate(controller)`，x22 为当前 controller；保留 `G.setting` 的 once 初始化、时间维护及后续菜单和输入状态更新。汇编见 `src/activation-arm64.s`。 |

原生激活流程创建会话并设置 `currentInputController`；其 `didSet` 比较模式、按条件显示提示并更新提示标记，不直接切换模式。桥在目标 bundle ID 改变时保存旧模式、恢复新模式，不使用应用切换通知或轮询；同一应用重复激活或换 controller 不重新决策，避免覆盖手动切换。

### 私有接口与 ABI

```text
_$s6WeType15InputControllerC16currentASCIIModeSbvg
_$s6WeType1GV22currentInputControllerAA0dE0CSgvpZ
_$s6WeType1GV22currentInputController_Wz
_$s6WeType11AppDelegateC15changeInputModeyyFTo
_$s6WeType15InputControllerC7sessionAA0C7SessionCvg
_$s6WeType12InputSessionC9sessionIDSuvg
_$s6WeType5ToastC17showInputModeTips_4type11isASCIIModeySu_AC0efB0OSbtFZTf4nnnd_n
```

- 当前 controller 是 Swift weak 存储，初始化 token 为 -1 后才能读取；`swift_unknownObjectWeakLoadStrong` 返回 +1 引用，交给 ARC 持有，不能把 weak 存储直接当对象指针。
- `currentASCIIMode` 使用 Swift 调用约定，arm64 的 self 在 x20；`state.m` 用 Clang `swiftcall` / `swift_context` 调用。getter 可能触发原厂创建会话。
- 模式切换调用原生 ObjC `changeInputMode`，不直接写 Boolean，也不手工解码 Swift Dictionary。
- 私有地址加 ASLR slide 使用；运行时先校验宿主版本和整个 `__text` 指纹。

### 原生翻转提示

二进制保留的源码路径为 `WeType/Model/Toast.swift` 和 `WeType/Windows/ToastWindow.swift`。

- `InputController.session` getter（`0x10011d78c`）返回 +1 Swift 对象，用 `swift_release` 释放；不能交给 ObjC ARC。`InputSession.sessionID` getter（`0x100392c38`）同样以 x20 传 self。
- 特化的 `Toast.showInputModeTips`（`0x10035e124`）参数为 x0=sessionID、w1=枚举标签、w2=英文 Bool；标签 0 表示中英文，metatype 参数已被优化移除。
- 它通过 `Windows.cursorRect` 定位光标，选择 `input_chinese` / `input_english` 图标，调用 `ToastWindow.show(...shouldFlip:)` 执行 `transform.rotation.y` 翻转和淡出；光标位置不可用时不显示。
- 原生 `AppDelegate.changeInputMode` 路径不播放提示，原生快捷键路径会播放。桥只在自动或 CLI 切换确认模式改变后补一次，不挂钩原生快捷键，不等待动画、不缓存按键。

### 版本适配

```sh
python3 -B patch.py inspect /path/to/new/WeType.app > profiles/new-candidate.json
```

`inspect` 只提取符号与指纹，候选默认 `reviewed=false`。用 `xcrun nm -arch arm64 -n` 和 LLDB 核查 getter 回退、weak 存储、toggle 副作用、激活段寄存器，以及提示函数的枚举和所有权；不能仅替换版本号或哈希。profile 中的 x86_64 信息仅用于识别原包。

官方包地址查询：`https://z.weixin.qq.com/web/mac/download?channel=InstallInfo`，字段为 `zip_download_url` 和 `zip_download_md5`。

## 运行限制

- 2.2.3 原厂要求安装在 `/Library/Input Methods/WeType.app`，拒绝用户目录；更新同一路径、bundle ID 和入口 ID 时不需重复注册。
- IPC 使用同登录会话的 distributed notifications，通道为 `local.orkward.wetype.bridge.request.v1` / `reply.v1`，最近 128 个请求去重；不认证发送进程，其他本地程序可能发送请求或伪造回复。

## Windows

适用于微信输入法 Windows 版，在 WeType 2.1.4.6、Windows 10 21H2 x64 上验证。

- 按应用恢复中英文模式，优先级为固定配置、应用记忆、默认英文。
- 提供 CLI 查看和切换当前应用的中英文模式。
- 停用系统的 Ctrl+Space 输入法开关热键，Ctrl+Space 交给应用使用。

不修改 WeType 文件，不注入进程。

### 构建

需要 portablemsvc（x64 工具链）、nushell 和 just。源码在 `src/windows/wetype-cli.cpp`。

```nu
just build        # 输出 build/wetype-cli.exe
```

### 运行方式

- justfile 和 whkdrc 调用的是 `C:\Program Files\Tencent\WeType\wetype-mode\wetype-cli.exe`，构建后手动复制过去。
- 守护进程由计划任务 `wetype-mode` 在登录时以最高权限启动，动作是 `conhost.exe --headless wetype-cli.exe daemon`，不显示窗口。提升权限后守护进程也能处理管理员权限窗口。任务需关闭运行时长限制，否则 72 小时后被结束。
- `wetype-cli start` 先运行这个任务，守护进程以提升权限启动且没有 UAC 提示。任务不存在时直接启动普通权限的守护进程。

### 命令

```sh
wetype-cli start                       # 后台启动守护进程
wetype-cli stop
wetype-cli daemon                      # 前台运行，日志同时输出到 stderr
wetype-cli status                      # 前台应用的当前模式
wetype-cli chinese
wetype-cli english
wetype-cli toggle
wetype-cli auto-status
wetype-cli auto-on
wetype-cli auto-off
wetype-cli apps
wetype-cli app-set chrome.exe english  # 固定应用模式
wetype-cli app-forget chrome.exe       # 删除固定配置，恢复应用记忆
wetype-cli hotkey                      # 系统 Ctrl+Space 热键状态
wetype-cli hotkey fix
wetype-cli hotkey restore
```

- 应用以小写 exe 文件名区分，省略扩展名时补 `.exe`。UWP 应用取 ApplicationFrameHost 内实际应用进程的 exe 名。
- `status`、`chinese`、`english`、`toggle` 在没有守护进程时直接作用于前台窗口，不写入记忆。有守护进程时，切换成功后立即保存为该应用的记忆。
- `app-set` 的固定配置不会被手动切换或记忆覆盖，应用内仍可手动切换。`app-set`、`app-forget`、`auto-on` 对当前前台应用立即应用规则。
- `auto-off` 保留当前模式，停止记忆和恢复。`stop` 退出守护进程。
- 输出为 JSON。`status` 的 `ok` 只表示请求得到应答，实际模式看 `stateKnown` 和 `mode`。退出码：0 成功，1 拒绝或结果不明，2 参数错误，3 守护进程不可达。

状态保存在 `~/.local/state/wetype-mode/modes.tsv`，每行一条，`auto`、`fixed`、`app` 三种记录。日志在同目录的 `daemon.log`。

### 原理

#### 中英文模式

WeType 的 TSF 输入法 `wetype_tip_core.dll` 基于 Mozc 改写，源码路径保留在二进制里（`wxkb\01_mozc\win32\tip\tip_text_service.cc`）。

- 中英文模式就是 TSF 的 `GUID_COMPARTMENT_KEYBOARD_OPENCLOSE`，值为 1 是中文，0 或空是英文。按 Shift 切换时由 WeType 写这个值。
- WeType 把模式当作全局值。线程获得焦点时，`TipTextServiceImpl::SwitchInputMode` 把全局值写进该线程，调用点在 `wetype_tip_core.dll+0x104ea4`。新进程也继承最近一次的模式。
- IMM 的打开状态与 OPENCLOSE 同步。向线程默认 IME 窗口（`ImmGetDefaultIMEWnd`）发送 `WM_IME_CONTROL` 的 `IMC_GETOPENSTATUS`（5）和 `IMC_SETOPENSTATUS`（6），可以跨进程读写，WeType 在 `OnChange` 中收到变化并更新全局值。已在 Win32 编辑框、记事本和 wezterm 中验证读写，Chrome、Telegram、UWP CoreWindow 验证了读取。

#### 守护进程

1. 用 `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` 监听前台切换，延迟 80 ms 合并连续切换，同时让 WeType 先完成焦点同步。
2. 读取上一个前台窗口的打开状态，保存为上一个应用的记忆。失去焦点的线程保留离开时的值，窗口已关闭时改用每秒轮询得到的最近值。
3. 按固定配置、应用记忆、默认英文决定目标模式，不同则写入，150 ms 后校验，不符时重试一次。写入打开状态是幂等操作，重试不会来回切换。
4. 同一进程内换窗口不重新决策，保留用户手动切换的结果。同一 exe 的新进程按切换处理。
5. 跳过任务栏、任务切换界面、桌面等外壳窗口。前台线程的键盘布局语言不是 zh-CN 时不记忆也不恢复。

CLI 和守护进程通过命名管道 `\\.\pipe\wetype-mode-<会话号>-<用户 SID>` 通信，DACL 只允许当前用户和 SYSTEM 连接，拒绝远程客户端。管道带中完整性标签，普通权限的 CLI 可以连接提升权限的守护进程。

#### Ctrl+Space

这个热键由系统注册和处理，WeType 只响应结果。

- WeType 不调用 `ImmGetHotKey` 或 `ImmSetHotKey`，不读取热键注册表项。它用 `ITfKeystrokeMgr::PreserveKey` 注册的保留键只有 Shift+Space、Ctrl+.、Ctrl+Shift+F、Ctrl+Alt+I 四个。
- 内核按 IME 热键表匹配到 Ctrl+Space 后回调 `USER32!_ClientImmProcessKey`，经 `IMM32!ImmProcessKey`、`MSCTF!CtfImeProcessCicHotkey`、`CThreadInputMgr::CallImm32HotkeyHanlder`、`MyToggleCompartmentDWORD` 翻转 OPENCLOSE，并吞掉 Space 的按下消息。因为 OPENCLOSE 就是 WeType 的中英文模式，Ctrl+Space 表现为中英文切换。
- 热键表来自 `HKCU\Control Panel\Input Method\Hot Keys`。`user32!CliImmInitializeHotKeys` 在登录和键盘布局重新加载时读取该项，简体中文的 0x10、0x11、0x12 中缺哪一项就补回默认值，0x10 的默认值是 Ctrl+Space。系统设置里选“无”会删除 0x10，下次初始化时 Ctrl+Space 又回来了。
- `hotkey fix` 用 `ImmSetHotKey` 把 0x10 改成 Ctrl+Alt+Shift+F24，同时写入注册表和当前会话的热键表，初始化时不会再补默认值。守护进程启动时和之后每分钟检查一次，被改回时重新设置。`hotkey restore` 恢复 Ctrl+Space，需要先停止守护进程，否则一分钟内会被改回。

### 限制

- 守护进程以普通权限运行时（没有登录任务时 `wetype-cli start` 直接启动），无法读写管理员权限窗口（UIPI 拒绝跨完整性级别的消息），这些窗口不记忆也不恢复。由登录任务启动时没有这个限制。
- 用键盘布局语言判断输入法，无法区分 WeType 和微软拼音等其他 zh-CN 输入法。
- 应用退出前最后一秒内的手动切换可能没有保存。
- 应用之间模式不同时，Alt+Tab 切换过程中 WeType 状态栏会闪几次。守护进程停止时同样操作也会出现，原因在 WeType 状态栏，最终模式正确。
