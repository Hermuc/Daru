# hermuc-bucket

本地自定义 Scoop bucket，用于收录主流 bucket（main / extras / versions / dorado 等）
中搜索不到的小众 Windows 软件，主要面向 GitHub Releases 的便携包（zip / 7z / portable）。

## 目录结构

```
hermuc-bucket/
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
scoop bucket add hermuc-bucket https://github.com/Hermuc/hermuc-bucket.git

# 搜索 / 安装
scoop search <name>
scoop install hermuc-bucket/<name>

# 更新 bucket（scoop update 时自动 git pull；也可手动）
git -C $env:SCOOP\buckets\hermuc-bucket pull
```

## Manifest 命名规则

- 每个软件一个 JSON 文件，文件名（不含 .json）即包名，安装时用 `hermuc-bucket/<包名>` 引用。
- 推荐使用小写、无空格的名称，如 `hypomux.json`；
- 担心与主流 bucket 冲突时可使用 `Author.Software.json`（winget 风格）命名，
  例如 `bggRGjQaUbCoE.PiliPlus.json`。
- 同名冲突时，`scoop bucket list` 中排序靠前（先添加）的 bucket 优先，
  因此安装时建议始终带 bucket 前缀：`scoop install hermuc-bucket/<name>`。

## 注意事项

- 仅收录真正便携（绿色）的软件；
- 若软件需要 exe/msi 安装器、管理员权限、写注册表或系统级安装，
  请在 manifest 的 `description` 中标注 `[NOT PORTABLE]`，
  或考虑使用 nonportable 类型的处理方式（见 Scoop 官方 nonportable bucket）。
- 本 bucket 的修改请在 git 中提交，便于版本管理与发布到其他机器。
