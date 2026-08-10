# babylon

本地自定义 Scoop bucket，用于收录主流 bucket（main / extras / versions / dorado 等）
中搜索不到的小众 Windows 软件，主要面向 GitHub Releases 的便携包（zip / 7z / portable）。

## 目录结构

```
babylon/
├── .github/workflows/excavator.yml  # 自动检查上游新版本并更新 manifest
├── README.md          # 本说明文件
└── bucket/            # ScoopInstaller/GithubActions 要求的嵌套结构
    └── bucket/        # 所有 manifest（JSON）必须放在此目录
        ├── example-app.json
        └── ghost-downloader-3.json
```

## 使用方法

```powershell
# 添加
scoop bucket add babylon https://github.com/Hermuc/babylon.git

# 搜索 / 安装
scoop search <name>
scoop install babylon/<name>

# 更新 bucket（scoop update 时自动 git pull；也可手动）
git -C $env:SCOOP\buckets\babylon pull
```

## Manifest 命名规则

- 每个软件一个 JSON 文件，文件名（不含 .json）即包名，安装时用 `babylon/<包名>` 引用。
- 推荐使用小写、无空格的名称，如 `hypomux.json`；
- 担心与主流 bucket 冲突时可使用 `Author.Software.json`（winget 风格）命名，
  例如 `bggRGjQaUbCoE.PiliPlus.json`。
- 同名冲突时，`scoop bucket list` 中排序靠前（先添加）的 bucket 优先，
  因此安装时建议始终带 bucket 前缀：`scoop install babylon/<name>`。

## 注意事项

- 仅收录真正便携（绿色）的软件；
- 若软件需要 exe/msi 安装器、管理员权限、写注册表或系统级安装，
  请在 manifest 的 `description` 中标注 `[NOT PORTABLE]`，
  或考虑使用 nonportable 类型的处理方式（见 Scoop 官方 nonportable bucket）。
- 本 bucket 的修改请在 git 中提交，便于版本管理与发布到其他机器。

## 准入规则：更新成功后自动清理旧版本（必备能力）

本机自动更新管线（`Scoop\auto-update.ps1`，由计划任务 ScoopAutoUpdate 调用）已在两步更新
全部成功后自动执行 `scoop cleanup * -k`：删除各应用旧版本目录与过期下载缓存，
保留 `current` 指向的当前版本与 `persist` 持久化数据，单个失败不阻塞流程。

新增软件到本 bucket 时必须确认与该机制兼容（逐项检查，例外需在 PR/commit 说明中注明原因）：

1. **用户数据必须经 `persist` 声明或存于 `current` 目录内**——cleanup 会直接删除旧版本目录，
   存于旧版本目录且未 persist 的数据将在更新后被清除（参照 ghost-downloader-3、mpv-lazy 的 persist 写法）；
2. **manifest 不得依赖旧版本目录存在**（如硬编码旧版本路径的 shim/post_install 逻辑）；
3. 若应用自带旧版本清理逻辑（如 ghost-downloader-3 的 post_install），与全局 cleanup 并存无害，无需移除。

注：当前 Scoop 版本不支持 `scoop config cleanup` 内建自动清理配置项，故该能力由更新脚本承担；
若未来 Scoop 内建支持，可迁移至 `scoop config cleanup true` 并同步更新本节。
