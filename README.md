# babylon

本地自定义 Scoop bucket，收录主流 bucket 中搜索不到的小众 Windows 软件，以 GitHub Releases 的绿色便携包（zip / 7z）为主。

## 快速开始

前置条件：已安装 Scoop 与 Git（Git 可用 `winget install Git.Git` 安装）。

```powershell
# 1. 添加 bucket
scoop bucket add babylon https://github.com/Hermuc/babylon.git

# 2. 搜索软件
scoop search <关键字>

# 3. 安装（带 babylon/ 前缀，避免与主流 bucket 同名包冲突）
scoop install babylon/<包名>

# 4. 更新（自动同步所有 bucket）
scoop update
```

当前收录的软件清单见 `bucket/` 目录（每个 .json 即一个软件），也可用 `scoop search` 查询。

若本机已存在同名 bucket，可换名导入：

```powershell
scoop bucket add bbn https://github.com/Hermuc/babylon.git   # 之后用 bbn/<包名> 引用
```

## 目录结构

```
babylon/
├── bucket/            # 全部 manifest（每个软件一个 .json）
│   └── scripts/       # 辅助脚本（部分为维护者本地方案存档，普通用户无需关注；用户可双击 .cmd 入口，见「脚本双击运行与可移植性」）
│       └── auto-update/  # Scoop 登录自动更新 + 逐应用清理旧版本全套脚本（含 .cmd 双击包装器，可移植，无硬编码路径）
├── .github/           # 自动检查上游新版本的 GitHub Actions
└── README.md
```

## 收录原则

- 仅收录绿色便携软件（解压即可运行）；无法便携时须在 description 标注 `[NOT PORTABLE]` 并说明原因
- 用户数据（设置、登录态等）必须经 `persist` 声明或存放于 `current` 目录内，重装系统后不丢失
- 依赖运行库（如 WebView2、VC++）时，在 notes / description 中说明

## 新增软件指南（开发者 / Agent）

本仓库的维护经验总结。新增或修改软件时，按下述流程与规范执行。

### 流程

1. 参考已有 manifest 作为模板（结构最全：`QQ.json` / `WeChat.json`，含 junction 持久化与 checkver/autoupdate 全套；AppData 数据较轻的 Flutter 系应用参考 `Kazumi.json` / `PiliPlus.json`）
2. 编写 `bucket/<包名>.json`：文件名即软件名（如 `QQ.json` / `PiliPlus.json`），小写、无空格
3. 本地验证（见「提交前验证」）
4. commit + push（见「提交与推送」）

### 编码与脚本铁律

1. **UTF-8 with BOM**（文件头 `EF BB BF`）；`ConvertFrom-Json` 可解析；内嵌 PowerShell 兼容 **PS 5.1 与 7+**
2. **`Remove-Item` 必须带 `-Confirm:$false`**——非交互环境（定时任务、自动更新）会因确认提示挂起
3. **删除 junction 用 `(Get-Item $path -Force).Delete()`**——PS 5.1 的 `Remove-Item` 删 junction 抛 NullReferenceException
4. 注册表共享视图（`HKLM\SOFTWARE` 与 `WOW6432Node` 指向同一数据）：第二处删除加 `-ErrorAction SilentlyContinue`（适用于涉及注册表清理的 manifest 内嵌脚本）；manifest 内嵌脚本慎用 `$ErrorActionPreference='Stop'`，避免单点失败中断后续步骤（独立的交互式脚本不受此限）
5. **无硬编码路径**：只使用 `$dir` / `$version` / `$persist_dir` 等变量；`bin` / `shortcuts` 只写 current 内的相对路径（文件名），不写绝对路径（版本更新后绝对路径会变死链）
6. **GUI 启动包装器**（需先设环境变量再启动，如 HypoMux 的 HYPOMUX_DATA_DIR）：shortcut 指向 `.vbs`（wscript 以窗口样式 0 运行，零黑窗闪现；vbs 文件必须 ASCII——WScript 按 ANSI 读取）；`bin` 用 `.cmd`——scoop shim 对 `.vbs` 无专门分支，会生成无效 shim；manifest 内嵌生成 vbs 时用 `Chr(34)` 拼接引号，避免双重转义
7. **面向用户的脚本须支持双击运行且可移植**（仅供维护者终端使用的脚本不受此限）：`.ps1` 默认双击用记事本打开，须提供 Windows 原生 `.cmd` / `.bat` 双击包装器（不得要求安装额外软件），包装器带 `-ExecutionPolicy Bypass`，路径用 `%~dp0` / `$PSScriptRoot` 推导——详见「脚本双击运行与可移植性」

### 数据持久化（本仓库核心能力）

1. 设置类数据：用 `persist` 字段声明到 `$persist_dir`（Scoop 自动处理）
2. AppData 登录态（微信 / QQ / FlClash 等）：installer 内联 `Ensure-LinkedData` 三态函数——
   - 链接不存在 → 直接创建 junction 指向 persist 目录
   - 已是 junction → 幂等跳过
   - 真实目录有数据 → `robocopy /E /COPY:DAT /DCOPY:DAT` 迁移（勿用 `/COPYALL`，ACL 权限会失败）→ 原目录改名 `.bak-<时间戳>` 作回滚点 → 建 junction
3. AppData 数据较轻的 Flutter 系应用（Kazumi / OpenSpeedy / PiliPlus / tubatools）：pre_install / post_install 用 `robocopy /E /MOVE` 直接搬移（无 `.bak` 残留），但**必须检查 `$LASTEXITCODE`**——迁移失败（≥8）时保留原数据、不删原链接，禁止无条件继续
4. 建 junction 必须幂等（两种模式通用）：链接不存在 → 创建；已是 junction → 跳过；真实目录残留（迁移失败等）→ 警告并跳过，数据保留原地
5. pre_uninstall / uninstaller 对称处理：`.Delete()` 删 junction，保留 persist 数据
6. 效果：首次安装自动迁移用户既有数据；重装系统后 `scoop install` 即恢复登录态

### 安装包解包

1. exe 安装包（含 7z SFX 自解压，如 QQ / WeChat / mpv-lazy）：url 后加 `#/dl.7z`，交 7z 解包（nanazip 特例除外）
2. NSIS 安装器（微信等）：7-Zip **静态提取**核心文件，不执行安装器（不注册服务、不写注册表）
3. Velopack 结构：压缩包根目录只有 stub 时，设 `extract_dir` 指向实际可执行目录
4. 解包统一用 `Expand-7zipArchive`（scoop 内置，无需 `depends` 字段）；nanazip 为特例：零 7zip，用 .NET `ZipFile` 原生解包（URL 不带 `#/dl.7z`）
5. 官方安装器提取类（QQ / WeChat 等）：删除 Uninstall.exe 等卸载器，防止误点触发官方卸载流程；notes 提示用户关闭应用内自更新，避免绕过 Scoop 版本管理

### checkver 与 autoupdate

1. GitHub Releases 可用简写 `"checkver": "github"`
2. 官方提供 SHA256SUMS 时：`hash.url: $baseurl/SHA256SUMS` 自动取哈希；无哈希文件需人工补全
3. **改写 checkver 前必须核查 autoupdate 是否引用正则命名捕获组（`$match*`）**——`github` 简写形式无自定义捕获组，改写会使自动更新 URL 失效
4. 多架构（x86 / x64 / arm64）各提供独立 download 条目
5. 更新链路必须可验证：`scoop checkver <包名>`（不带 bucket 前缀；本机新版 Scoop 已移除 checkver，可用 `scoop info babylon/<包名>` 核对 manifest）

### 兼容自动清理（必备能力）

本仓库自动更新管线在更新后逐应用执行 `scoop cleanup <应用> -k`（删除旧版本目录与过期缓存，保留 current 与 persist；完整实现见 `bucket/scripts/auto-update/`，部署方法见该目录内 register 脚本头部注释）。注意：**必须逐应用调用而非 `scoop cleanup *`**——后者遇到被进程占用的文件（如常驻后台工具）会报错并中断整个命令，导致后续应用都不被清理。新增软件须满足：

1. 用户数据经 persist 或存于 current，**不依赖旧版本目录**，manifest 也不引用旧版本路径
2. 应用自带旧版本清理逻辑与全局 cleanup 并存无害
3. **不要使用 `cleanup` 字段**（当前 Scoop 已不处理该字段，OpenSpeedy / PiliPlus 曾误用后移除）；卸载后的残留目录如需清理，在 notes 中提示用户手动删除

### 脚本双击运行与可移植性

`bucket/scripts/` 下提供给用户使用的脚本，必须支持在 Windows 资源管理器中**双击直接运行**，且具备**可移植性**（重装系统、更换盘符、复制到其他机器后仍可用）。范例：`bucket/scripts/auto-update/`（Scoop 登录自动更新 + 逐应用清理旧版本）。

1. **双击可运行**：`.ps1` 默认双击用记事本打开（且受 ExecutionPolicy 限制），不能直接作为用户入口；须提供 Windows 原生可双击运行的包装器 `.cmd`（或 `.bat`），由 cmd.exe 直接执行，**不得要求用户安装额外软件**；不建议通过修改 `.ps1` 文件关联实现（全局安全降级，机器本地设置重装即失效）
2. **绕开执行策略**：包装器调用 `powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0<脚本>.ps1"`；Bypass 仅作用于本次调用，不修改系统策略；交互入口建议以 `pause` 结尾，让结果停留可见
3. **禁止硬编码路径**：脚本与包装器均不得写死本机盘符或绝对路径——包装器用 `%~dp0`，PowerShell 用 `$PSScriptRoot`（兼容 PS 5.1 可降级 `Split-Path -Parent $MyInvocation.MyCommand.Path`）推导自身位置
4. **部署前置条件须在脚本输出和 README 中明确说明**：如脚本必须位于 Scoop 根目录（含 `apps\` 与 `shims\`），脚本应在启动时校验并给出清晰错误提示，不得默默失败
5. **编码要求**：`.cmd` / `.bat` 保持纯 ASCII（cmd.exe 按 OEM 代码页读取，中文易乱码）；其余同铁律 1、6（`.vbs` 纯 ASCII、含中文的 `.ps1` 为 UTF-8 with BOM、PowerShell 兼容 5.1 与 7+）
6. **README / 脚本头部注释须说明运行方式**：哪些文件可双击（推荐入口）、哪些需终端运行、部署步骤与前置条件

现有 auto-update 脚本的运行方式：

| 文件 | 双击行为 | 正确用法 |
|------|----------|----------|
| `register-scoop-autoupdate.cmd` | ✅ **推荐双击入口**：注册/重建 ScoopAutoUpdate 计划任务（部署后运行一次；重装系统后再跑一次） | 也可终端：`powershell -ExecutionPolicy Bypass -File .\register-scoop-autoupdate.ps1` |
| `auto-update.cmd` | ✅ **双击入口**：手动全量更新+逐应用清理（控制台可见进度，日志写 `update.log`） | 与计划任务同一管线 |
| `auto-update.vbs` | 可双击但**不建议**：计划任务静默启动器，零窗口无反馈 | 仅供计划任务调用 |
| `auto-update.ps1` / `register-scoop-autoupdate.ps1` | ❌ 双击用记事本打开 | 经上方 .cmd 包装器或终端运行 |
| `ScoopAutoUpdate.xml` | ❌ 仅供查看 | 任务定义模板，勿手动导入（Action 为示例路径），交给 register 脚本动态构建 |

部署前置条件：将 auto-update 目录整套文件拷到 Scoop 根目录（含 `apps\` 与 `shims\` 的那一层）再双击 `.cmd`；在仓库原位置双击会报错退出（设计使然）。

### 提交前验证

```powershell
# 1) JSON 合法性（含 BOM 检查）
Get-Content bucket/<包名>.json -Raw -Encoding UTF8 | ConvertFrom-Json
# 2) 内嵌 PowerShell 脚本语法检查（pre_install / post_install / installer / uninstaller 等 script 字段，报错即修复）
$m = Get-Content bucket/<包名>.json -Raw -Encoding UTF8 | ConvertFrom-Json
[System.Management.Automation.Language.Parser]::ParseInput(((@($m.pre_install) + @($m.post_install) + @($m.pre_uninstall) + @($m.installer.script) + @($m.uninstaller.script)) -join "`n"), [ref]$null, [ref]$null) | Out-Null
# 3) 版本检测链路（不带前缀；本机新版 Scoop 无 checkver 时改用 scoop info）
scoop checkver <包名>
scoop info babylon/<包名>
# 4) 实机安装测试（可选，会实际安装）
scoop install babylon/<包名>
```

### 提交与推送

1. commit message 用英文简洁描述
2. push 失败：git 不读取 Windows 系统代理——先确认代理进程与监听端口，用 `git -c http.proxy=... -c https.proxy=... push` 仅本次走代理重试；再 `git pull --rebase` 解决冲突后重推；**禁止 `--force` 覆盖远程历史**
3. **excavator 自动更新（GitHub Actions）重写 manifest 时可能移除 BOM 并损坏中文注释**（Kazumi 2.2.8 实证：`首次/迁移` 变 `�?`）——已自动化：`.github/workflows/excavator.yml` 的 `verify-integrity` job 在每次自动更新后校验全部 manifest 的 BOM（`EF BB BF`）与中文完整性（U+FFFD 检测），异常时 workflow 失败告警；发现损坏时用 `git checkout <更新前提交> -- <文件>` 从 git 历史恢复并重新提交（缺 BOM 而中文完好时可直接补回 `EF BB BF` 文件头）

## 注意事项

- 安装时始终带 `babylon/` 前缀：`scoop install babylon/<包名>`
- QQ / WeChat 为官方安装器便携提取，仅供个人学习使用
- 无法直连 GitHub 时，请先配置代理后再添加 bucket 与安装
