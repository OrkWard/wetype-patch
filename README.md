# WeType patch 维护

目标：WeType 2.2.3 (657)，产物仅 arm64，桥版本 1.3.1，IPC 协议仍为 v1。
安装路径：`/Library/Input Methods/WeType.app`。
- `patch.py`：构建、校验及新增英语入口。
- `macho.py`：在现有 header padding 中增加动态库加载命令。
- `version_profile.py`、`profiles/`：识别原版、解析私有符号、检查版本指纹。
- `src/bridge.m`、`bridge-protocol.h`：IPC 与启动初始化。
- `src/state.m`、`state.h`：当前输入会话的模式读取。
- `src/wetype-cli.m`：CLI。

## app 改动与命令

主程序提取 arm64 slice，增加加载声明：
`@executable_path/../Frameworks/libwetype-bridge.dylib`。另有三处 profile 审核的指令替换：

- `isDefaultASCIIMode(bundleID:)` 的统一返回值改为 false。原生 getter、菜单和快捷键统一读写全局模式，换 controller 不会先选中另一份应用模式。
- `resetInputMode()` 直接返回，停用原厂的激活超时、输入源同步及设置通知触发的模式重置。
- `activateServer` 的 `0x1001187ac–0x100118880` 模式处理段替换为同步调用 `WTBridgeActivate(controller)`，随后保留原版 `G.setting` 的 once 初始化和时间维护，再继续原生菜单与输入状态更新。汇编源在 `src/activation-arm64.s`，构建时校验其编译结果与 profile 一致。

新增运行文件只有该 dylib 和 `Contents/MacOS/wetype-cli`。
保留原中文入口；新增 `.english`，语言 en，显示名同为“微信输入法”。
没有内置维护资料、receipt 或诊断工具。

```sh
APP='/Library/Input Methods/WeType.app'
"$APP/Contents/MacOS/wetype-cli" status
"$APP/Contents/MacOS/wetype-cli" chinese
"$APP/Contents/MacOS/wetype-cli" english
"$APP/Contents/MacOS/wetype-cli" toggle
"$APP/Contents/MacOS/wetype-cli" auto-status
"$APP/Contents/MacOS/wetype-cli" apps
"$APP/Contents/MacOS/wetype-cli" app-set com.apple.Terminal english
"$APP/Contents/MacOS/wetype-cli" app-forget com.apple.Terminal
"$APP/Contents/MacOS/wetype-cli" auto-off   # auto-on 重新开启
```

桥复用原生输入会话激活流程，不注册应用切换通知，不轮询。目标 bundle ID 变化时，保存离开应用的模式，再按“固定配置 → 应用记忆 → 英文”决定目标模式。与当前模式相同不操作，否则调用一次原生动作。相同应用重复激活或更换 controller 不重新决策，手动切换不会被随后聚焦覆盖；动作结果不明也不重试。

应用记忆保存在 `~/Library/Preferences/local.orkward.wetype.patch.plist`。原生手动切换的状态在下次切入另一应用时保存；CLI 切换成功后立即保存。进程退出前尚未保存的手动变化可能丢失。`app-set`、`app-forget` 和 `auto-on` 对当前应用立即执行一次比较。`auto-off` 停用自定义恢复，保留当前全局模式，不恢复原厂分应用规则或自动重置。

`app-set BUNDLE_ID chinese|english` 写入独立的 `fixedAppModes` 固定配置，每次切入该应用优先使用，不会被手动切换或记忆更新覆盖。`app-forget BUNDLE_ID` 删除固定配置，恢复使用 `appModes` 记忆，没有记忆则使用英文。旧版本的记忆保持原样，不自动转换为固定配置。

`chinese/english` 已是目标模式则不切换，否则调用一次原动作并复查，同时更新当前应用记忆。自动恢复和 CLI 切换确认模式改变后，在光标旁播放原生中英文图标的翻转淡出动画；同模式设置、失败、结果不明、重复请求不播放。`app-set` / `app-forget` / `auto-on` 导致的实际模式改变同样播放。原生快捷键的动画保持原样，不额外挂钩或叠加。动画只是提示，不等待动画结束、不拦截输入；原生无法取得光标位置时可能不显示，不重试。`stop` 关闭 IPC，下次宿主启动恢复。
仅控制当前 WeType 会话，不自动选择其他系统输入源，不改 Shift 或 Caps Lock。
`status.ok` 只表示桥响应，模式还要看 `stateKnown` / `mode`。无会话时拒绝设置。
退出码：0 成功；1 拒绝/结果不明；2 参数错误；3 超时。超时不要盲目重试 toggle。

## 构建与更新

需要 Python 3、Xcode/Command Line Tools，以及干净官方 app；不能用已 patch 的 app 作为输入。
官方 ZIP 地址查询：`https://z.weixin.qq.com/web/mac/download?channel=InstallInfo`，读取 `zip_download_url` 下载，按 `zip_download_md5` 校验后解压。

```sh
cd /path/to/wetype-patch
python3 -B patch.py build \
  --input '/path/to/original-2.2.3-657/WeType.app' \
  --output "$PWD/WeType.app" \
  --profile profiles/wetype-2.2.3-657.json --english-entry
python3 -B patch.py verify "$PWD/WeType.app"
```

也可通过 `just build input=/path/to/original/WeType.app` 构建，`just install` 完整替换系统 app 并重启进程；只有 install recipe 使用 sudo。

其他维护者把 input 换成自己的干净原版。输出必须不存在，不能直接构建到 Input Methods。
verify 使用外部 profile；只证明签名完整性、原代码加审核指令补丁后的哈希、加载命令和依赖满足检查，不能替代真实输入测试。

正常更新：准备并校验完整新包 → 先选其他输入法、停止旧进程 → 替换原路径的整个 app 目录 → 正常启动。
**同一路径、bundle ID 和入口 ID 不变时，不重复注册。** 临时目录用完删除，不混合覆盖新旧文件。
2.2.3 原厂只接受 `/Library/Input Methods/WeType.app`，用户目录会被拒绝。可先由当前用户把新包复制到 `/private/tmp`，再由管理员移入系统目录，完成后清理临时文件。
首次安装后在系统设置中添加入口；缓存未更新时重新登录，不循环强制注册。

## 新版本适配

```sh
python3 -B patch.py inspect '/path/to/new/WeType.app' > profiles/new-candidate.json
```

候选默认 `reviewed=false`。必须核查私有接口后再批准；不能只改版本号/哈希。旧 profile 不覆盖。
原版可能是 universal，profile 保留其识别信息，但当前只构建 arm64。

核心符号（nm 名称）：

```text
_$s6WeType15InputControllerC16currentASCIIModeSbvg
_$s6WeType1GV22currentInputControllerAA0dE0CSgvpZ
_$s6WeType1GV22currentInputController_Wz
_$s6WeType11AppDelegateC15changeInputModeyyFTo
```

用 `xcrun nm -arch arm64 -n` 和 LLDB 静态反汇编核查；LLDB 通常去掉首个下划线。
确认原 getter 的全局回退、weak 存储/token、返回值含义、toggle 副作用。还要核查 ASCII 判断的全部调用点、模式重置的调用点及激活段的寄存器约定。当前三处补丁仅适配 2.2.3 (657)，旧 profile 不能用于构建这个版本的桥。

`state.m` 使用 Swift weak runtime 取得控制器强引用，Clang `swiftcall` / `swift_context` 以 x20 传 self，不能改成普通 C ABI。
动画新增三个 profile 审核符号：`InputController.session` getter、`InputSession.sessionID` getter、特化的 `Toast.showInputModeTips`。session getter 返回 +1 Swift 对象，用 `swift_release` 平衡，不能交给 ObjC ARC。arm64 提示函数参数为 x0=sessionID、w1=枚举 0（中英文）、w2=英文 Bool，特化入口已移除 metatype 参数。地址、枚举、所有权和 ABI 均须随版本重新审核。原生 `AppDelegate.changeInputMode` 不播放该动画，桥只在确认成功后补一次；不替换原生快捷键入口。
初始化 token 必须为 -1；运行时先核对版本与整个 __text 哈希，再用符号地址加 ASLR slide。
调用原 ObjC `changeInputMode`，不写 Boolean，不手工解码 Swift Dictionary。
getter 可能触发原厂创建会话；没有当前控制器时不猜状态。

padding 不足、非零、未知 Mach-O 命令或指纹不符时停止，不自动挪 section 或删命令腾空间。
适配后真实测试：TextEdit 中保持焦点，中文两次→英文两次→中文两次；核对第二次不切换，并检查实际文字/候选、跨应用记忆和新 PID 的自动加载。

## 自动测试

```sh
python3 -B tests/run.py
```

mock 测试覆盖自动/CLI 切换、同模式、重复请求、目标或输入源变化、未知结果、动画异常隔离；同时编译生产桥。测试不启动宿主、不修改偏好或安装包。实际光标定位、图标和翻转效果仍需安装后检查：中→英→中、跨应用恢复、相同模式不重复、原生快捷键不叠加。

## 已知边界

dylib 随宿主启动，在主队列等 delegate 就绪后注册 IPC。使用同登录会话的 distributed notifications，缓存最近 128 个请求去重；不是永久 exactly-once。
通道名为 `local.orkward.wetype.bridge.request.v1` / `reply.v1`，**不认证同会话进程身份**，其他本地程序可能发请求、修改应用模式配置或伪造回复。
自动恢复仅在原生激活回调中确认当前输入源与 controller 后执行；目标不确定时不改变模式，不安排延迟重试。`stop` 同时停用 IPC 和自定义决策，原生手动切换仍可用。

app 使用 ad-hoc 签名，保留 Hardened Runtime，允许库加载、移除调试权限。这不是腾讯签名或苹果公证；不关闭 SIP，不改 TCC。
