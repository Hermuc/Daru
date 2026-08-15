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

## 维护规范

修改或新增软件时，请逐项确认：

1. **命名**：小写、无空格；与主流 bucket 冲突时用 `Author.Software.json`（winget 风格）
2. **编码**：UTF-8 with BOM；JSON 可解析；内嵌 PowerShell 兼容 PS 5.1；`Remove-Item` 必须带 `-Confirm:$false`
3. **无硬编码路径**：脚本只使用 `$persist_dir` / `$version` / `$dir` 等变量
4. **兼容自动清理**：本仓库依赖 `scoop cleanup * -k` 删除旧版本目录，须满足：
   - 用户数据经 persist 或存于 current，不依赖旧版本目录
   - manifest 不引用旧版本路径
   - 应用自带旧版本清理逻辑时，与全局 cleanup 并存无害
5. **提交**：修改在 git 中提交（英文简洁 commit message），便于发布到其他机器

## 注意事项

- 安装时始终带 `babylon/` 前缀：`scoop install babylon/<包名>`
- QQ / WeChat 为官方安装器便携提取，仅供个人学习使用
- 无法直连 GitHub 时，请先配置代理后再添加 bucket 与安装
