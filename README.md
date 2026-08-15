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
│   └── scripts/       # 辅助脚本（部分为维护者本地方案存档，普通用户无需关注）
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
4. 注册表共享视图（`HKLM\SOFTWARE` 与 `WOW6432Node` 指向同一数据）：第二处删除加 `-ErrorAction SilentlyContinue`；脚本慎用 `$ErrorActionPreference='Stop'`，避免单点失败中断后续步骤
5. **无硬编码路径**：只使用 `$dir` / `$version` / `$persist_dir` 等变量；`bin` / `shortcuts` 只写 current 内的相对路径（文件名），不写绝对路径（版本更新后绝对路径会变死链）
6. 官方安装器提取类（QQ / WeChat 等）：删除 Uninstall.exe 等卸载器，防止误点触发官方卸载流程；notes 提示用户关闭应用内自更新，避免绕过 Scoop 版本管理
7. **GUI 启动包装器**（需先设环境变量再启动，如 HypoMux 的 HYPOMUX_DATA_DIR）：shortcut 指向 `.vbs`（wscript 以窗口样式 0 运行，零黑窗闪现；vbs 文件必须 ASCII——WScript 按 ANSI 读取）；`bin` 用 `.cmd`——scoop shim 对 `.vbs` 无专门分支，会生成无效 shim；manifest 内嵌生成 vbs 时用 `Chr(34)` 拼接引号，避免双重转义

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

### checkver 与 autoupdate

1. GitHub Releases 可用简写 `"checkver": "github"`
2. 官方提供 SHA256SUMS 时：`hash.url: $baseurl/SHA256SUMS` 自动取哈希；无哈希文件需人工补全
3. **改写 checkver 前必须核查 autoupdate 是否引用正则命名捕获组（`$match*`）**——`github` 简写形式无自定义捕获组，改写会使自动更新 URL 失效
4. 多架构（x86 / x64 / arm64）各提供独立 download 条目
5. 更新链路必须可验证：`scoop checkver <包名>`（不带 bucket 前缀；本机新版 Scoop 已移除 checkver，可用 `scoop info babylon/<包名>` 核对 manifest）

### 兼容自动清理（必备能力）

本仓库自动更新管线在更新成功后执行 `scoop cleanup * -k`（删除旧版本目录与过期缓存，保留 current 与 persist）。新增软件须满足：

1. 用户数据经 persist 或存于 current，**不依赖旧版本目录**
2. manifest 不引用旧版本路径
3. 应用自带旧版本清理逻辑与全局 cleanup 并存无害
4. **不要使用 `cleanup` 字段**（当前 Scoop 已不处理该字段，OpenSpeedy / PiliPlus 曾误用后移除）；卸载后的残留目录如需清理，在 notes 中提示用户手动删除

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

## 注意事项

- 安装时始终带 `babylon/` 前缀：`scoop install babylon/<包名>`
- QQ / WeChat 为官方安装器便携提取，仅供个人学习使用
- 无法直连 GitHub 时，请先配置代理后再添加 bucket 与安装
