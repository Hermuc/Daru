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

1. 参考已有 manifest 作为模板（结构最全：`QQ.json` / `WeChat.json`，含 junction 持久化与 checkver/autoupdate 全套）
2. 编写 `bucket/<包名>.json`：文件名小写、无空格；与主流 bucket 冲突时用 `Author.Software.json`（winget 风格）
3. 本地验证（见「提交前验证」）
4. commit + push（见「提交与推送」）

### 编码与脚本铁律

1. **UTF-8 with BOM**（文件头 `EF BB BF`）；`ConvertFrom-Json` 可解析；内嵌 PowerShell 兼容 **PS 5.1 与 7+**
2. **`Remove-Item` 必须带 `-Confirm:$false`**——非交互环境（定时任务、自动更新）会因确认提示挂起
3. **删除 junction 用 `(Get-Item $path -Force).Delete()`**——PS 5.1 的 `Remove-Item` 删 junction 抛 NullReferenceException
4. 注册表共享视图（`HKLM\SOFTWARE` 与 `WOW6432Node` 指向同一数据）：第二处删除加 `-ErrorAction SilentlyContinue`；脚本慎用 `$ErrorActionPreference='Stop'`，避免单点失败中断后续步骤
5. **无硬编码路径**：只使用 `$dir` / `$version` / `$persist_dir` 等变量；`bin` / `shortcuts` 一律用 current 相对路径（硬编码绝对路径会在版本更新后变死链）
6. 官方安装器提取类（QQ / WeChat 等）：删除 Uninstall.exe 等卸载器，防止误点触发官方卸载流程；notes 提示用户关闭应用内自更新，避免绕过 Scoop 版本管理

### 数据持久化（本仓库核心能力）

1. 设置类数据：用 `persist` 字段声明到 `$persist_dir`（Scoop 自动处理）
2. AppData 登录态（微信 / QQ / FlClash 等）：installer 内联 `Ensure-LinkedData` 三态函数——
   - 链接不存在 → 直接创建 junction 指向 persist 目录
   - 已是 junction → 幂等跳过
   - 真实目录有数据 → `robocopy /E /COPY:DAT /DCOPY:DAT` 迁移（勿用 `/COPYALL`，ACL 权限会失败）→ 原目录改名 `.bak-<时间戳>` 作回滚点 → 建 junction
3. uninstaller 对称处理：`.Delete()` 删 junction，保留 persist 数据
4. 效果：首次安装自动迁移用户既有数据；重装系统后 `scoop install` 即恢复登录态

### 安装包解包

1. 自解压 exe（7z SFX）：url 后加 `#/dl.7z`，交 7z 解包
2. NSIS 安装器（微信等）：7-Zip **静态提取**核心文件，不执行安装器（不注册服务、不写注册表）
3. Velopack 结构：压缩包根目录只有 stub 时，设 `extract_dir` 指向实际可执行目录
4. 7z 解包依赖：`depends=7zip` 或依赖本机 7z（nanazip）可用

### checkver 与 autoupdate

1. GitHub Releases 可用简写 `"checkver": "github"`
2. 官方提供 SHA256SUMS 时：`hash.url: $baseurl/SHA256SUMS` 自动取哈希；无哈希文件需人工补全
3. **改写 checkver 前必须核查 autoupdate 是否引用正则命名捕获组（`$match*`）**——`github` 简写形式无自定义捕获组，改写会使自动更新 URL 失效
4. 双架构（x64 / arm64）提供两个 download 条目
5. 更新链路必须可验证：`scoop checkver babylon/<包名>` 能查到新版本

### 兼容自动清理（必备能力）

本仓库自动更新管线在更新成功后执行 `scoop cleanup * -k`（删除旧版本目录与过期缓存，保留 current 与 persist）。新增软件须满足：

1. 用户数据经 persist 或存于 current，**不依赖旧版本目录**
2. manifest 不引用旧版本路径
3. 应用自带旧版本清理逻辑与全局 cleanup 并存无害

### 提交前验证

```powershell
# 1) JSON 合法性（含 BOM 检查）
Get-Content bucket/<包名>.json -Raw | ConvertFrom-Json
# 2) 版本检测链路
scoop checkver babylon/<包名>
# 3) 实机安装测试（可选，会实际安装）
scoop install babylon/<包名>
```

### 提交与推送

1. commit message 用英文简洁描述
2. push 失败：git 不读取 Windows 系统代理——先确认代理进程与监听端口，用 `git -c http.proxy=... -c https.proxy=... push` 仅本次走代理重试；再 `git pull --rebase` 解决冲突后重推；**禁止 `--force` 覆盖远程历史**

## 注意事项

- 安装时始终带 `babylon/` 前缀：`scoop install babylon/<包名>`
- QQ / WeChat 为官方安装器便携提取，仅供个人学习使用
- 无法直连 GitHub 时，请先配置代理后再添加 bucket 与安装
