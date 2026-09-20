# 发布 LiteMD

## 一次性准备

1. 在 Apple Developer 账号中创建 **Developer ID Application** 证书，并安装到本机钥匙串。
2. 保存公证凭据（App 专用密码或 API Key）：

   ```bash
   xcrun notarytool store-credentials GiantAccel --key ~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8 --key-id <KeyID> --issuer <Issuer ID>
   ```

3. 生成更新签名密钥。私钥只保存在本机，**不要提交到仓库**：

   ```bash
   swift scripts/generate-update-keys.swift ~/.litemd/update-private-key
   ```

   记下输出的公钥。

## 当前发布配置

| 项目 | 值 |
|---|---|
| 签名证书 | `Developer ID Application: GiantAccel, LLC (WPDUNPG5N8)` |
| Team ID | `WPDUNPG5N8` |
| 公证凭据 | 钥匙串配置 `GiantAccel`（App Store Connect API 密钥，团队共用一把；密钥 ID 与 Issuer ID 只留在本机，不入库） |
| 更新私钥 | `~/.litemd/update-private-key`（权限 600，**不要提交**） |
| 更新公钥 | `RMTmOQ9+dwYv+FbkLvWR6oYth9f5mDX6FslxuI6tPYI=` |

只签名与公证、暂不启用自动更新：

```bash
TEAM_ID=WPDUNPG5N8 NOTARY_PROFILE=GiantAccel scripts/release.sh
```

启用自动更新（需要已经确定的下载地址）：

```bash
TEAM_ID=WPDUNPG5N8 \
NOTARY_PROFILE=GiantAccel \
UPDATE_PRIVATE_KEY=~/.litemd/update-private-key \
UPDATE_PUBLIC_KEY=RMTmOQ9+dwYv+FbkLvWR6oYth9f5mDX6FslxuI6tPYI= \
DOWNLOAD_BASE_URL=https://example.com/litemd \
scripts/release.sh
```

## 每次发布

1. 在 `project.yml` 中更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`。
2. 运行：

   ```bash
   TEAM_ID=XXXXXXXXXX \
   NOTARY_PROFILE=GiantAccel \
   UPDATE_PRIVATE_KEY=~/.litemd/update-private-key \
   UPDATE_PUBLIC_KEY=<公钥> \
   DOWNLOAD_BASE_URL=https://example.com/litemd \
   RELEASE_NOTES=notes.json \
   scripts/release.sh
   ```

3. 把 `build/release` 中的 DMG、ZIP 与 `appcast.json` 上传到 `DOWNLOAD_BASE_URL`。

4. 发一个 GitHub Release，附上 DMG 与 ZIP：

   ```bash
   gh release create v<版本> --title "LiteMD <版本>" build/release/LiteMD-<版本>.dmg build/release/LiteMD-<版本>.zip
   ```

5. 更新 Homebrew cask（仓库 [gentpan/homebrew-tap](https://github.com/gentpan/homebrew-tap)
   的 `Casks/litemd.rb`）：把 `version` 改成新版本，`sha256` 换成

   ```bash
   shasum -a 256 build/release/LiteMD-<版本>.dmg
   ```

   的结果，提交推送即可；cask 的下载地址指向 GitHub Release。

## 自动更新的安全性

- 应用只从 `appcast.json` 指定的地址下载更新包；
- 安装包必须通过 Ed25519 签名校验（公钥在构建时写入 Info.plist）；
- 解压后还会校验 Bundle ID、版本号、代码签名以及开发者团队与当前应用一致；
- 替换失败时恢复旧版本。

未设置 `LITEMD_UPDATE_FEED_URL` 与 `LITEMD_UPDATE_PUBLIC_KEY` 的构建（例如本地调试版）不会检查更新。
