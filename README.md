# scoop-local-bucket

本地自定义 Scoop bucket，用于收录主流 bucket（main / extras / versions / dorado 等）
中搜索不到的小众 Windows 软件，主要面向 GitHub Releases 的便携包（zip / 7z / portable）。

## 目录结构

```
scoop-local-bucket/
├── README.md          # 本说明文件
└── bucket/            # 所有 manifest（JSON）必须放在此目录
    └── example-app.json
```

## 使用方法

```powershell
# 添加（已添加则跳过）
scoop bucket add local-bucket D:\PortableApps\scoop-local-bucket

# 搜索 / 安装
scoop search <name>
scoop install local-bucket/<name>

# 更新 bucket（git pull）
scoop bucket update local-bucket
```

## Manifest 命名规则

- 每个软件一个 JSON 文件，文件名（不含 .json）即包名，安装时用 `local-bucket/<包名>` 引用。
- 推荐使用小写、无空格的名称，如 `hypomux.json`；
- 担心与主流 bucket 冲突时可使用 `Author.Software.json`（winget 风格）命名，
  例如 `bggRGjQaUbCoE.PiliPlus.json`。
- 同名冲突时，`scoop bucket list` 中排序靠前（先添加）的 bucket 优先，
  因此安装时建议始终带 bucket 前缀：`scoop install local-bucket/<name>`。

## 注意事项

- 仅收录真正便携（绿色）的软件；
- 若软件需要 exe/msi 安装器、管理员权限、写注册表或系统级安装，
  请在 manifest 的 `description` 中标注 `[NOT PORTABLE]`，
  或考虑使用 nonportable 类型的处理方式（见 Scoop 官方 nonportable bucket）。
- 本 bucket 的修改请在 git 中提交，便于版本管理与发布到其他机器。
