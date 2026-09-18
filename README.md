# WeType patch

适用于微信输入法 **2.2.3 (657)，Apple Silicon**。

- 按应用恢复中英文模式：固定配置 → 应用记忆 → 默认英文。
- 支持 CLI 切换，模式改变时显示原生翻转提示。
- 停用原厂自动模式重置，保留手动切换；新增英文输入源入口。

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
