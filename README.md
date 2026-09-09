# WeType patch 维护

目标：WeType 2.2.3 (657)，产物仅 arm64，IPC 版本 1.0.1。
安装路径：`/Library/Input Methods/WeType.app`。
- `patch.py`：构建、校验及新增英语入口。
- `macho.py`：在现有 header padding 中增加动态库加载命令。
- `version_profile.py`、`profiles/`：识别原版、解析私有符号、检查版本指纹。
- `src/bridge.m`、`bridge-protocol.h`：IPC 与启动初始化。
- `src/state.m`、`state.h`：当前输入会话的模式读取。
- `src/wetype-cli.m`：CLI。

## app 改动与命令

主程序提取 arm64 slice，保留原 arm64 指令，增加加载声明：
`@executable_path/../Frameworks/libwetype-bridge.dylib`。
新增运行文件只有该 dylib 和 `Contents/MacOS/wetype-cli`。
保留原中文入口；新增 `.english`，语言 en，显示名同为“微信输入法”。
没有内置维护资料、receipt 或诊断工具。

```sh
APP='/Library/Input Methods/WeType.app'
"$APP/Contents/MacOS/wetype-cli" status
"$APP/Contents/MacOS/wetype-cli" chinese
"$APP/Contents/MacOS/wetype-cli" english
"$APP/Contents/MacOS/wetype-cli" toggle
```

`chinese/english` 已是目标模式则不切换，否则调用一次原动作并复查。`stop` 关闭 IPC，下次宿主启动恢复。
仅控制当前 WeType 会话，不自动选择系统输入源，不改默认语言、Shift 或 Caps Lock。
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

其他维护者把 input 换成自己的干净原版。输出必须不存在，不能直接构建到 Input Methods。
verify 使用外部 profile；只证明签名完整性、原代码哈希、加载命令和依赖满足检查，不能替代真实输入测试。

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
确认 getter 仍综合按应用状态与全局设置、weak 存储/token 未变、返回值含义未变、toggle 副作用正确。

`state.m` 使用 Swift weak runtime 取得控制器强引用，Clang `swiftcall` / `swift_context` 以 x20 传 self，不能改成普通 C ABI。
初始化 token 必须为 -1；运行时先核对版本与整个 __text 哈希，再用符号地址加 ASLR slide。
调用原 ObjC `changeInputMode`，不写 Boolean，不手工解码 Swift Dictionary。
getter 可能触发原厂创建会话；没有当前控制器时不猜状态。

padding 不足、非零、未知 Mach-O 命令或指纹不符时停止，不自动挪 section 或删命令腾空间。
适配后真实测试：TextEdit 中保持焦点，中文两次→英文两次→中文两次；核对第二次不切换，并检查实际文字/候选、跨应用记忆和新 PID 的自动加载。

## 已知边界

dylib 随宿主启动，在主队列等 delegate 就绪后注册 IPC。使用同登录会话的 distributed notifications，缓存最近 128 个请求去重；不是永久 exactly-once。
通道名为 `local.orkward.wetype.bridge.request.v1` / `reply.v1`，**不认证同会话进程身份**，其他本地程序可能发请求或伪造回复。

app 使用 ad-hoc 签名，保留 Hardened Runtime，允许库加载、移除调试权限。这不是腾讯签名或苹果公证；不关闭 SIP，不改 TCC。

