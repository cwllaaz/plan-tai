# 计划台 Android · 签名、发布与升级说明

> 适用版本：Android 1.0.0（versionCode 1，applicationId `com.jihuatai.planner`）。
> 本文所有密钥材料都在**仓库之外**，且已确认被 `android/.gitignore` 忽略，不会进入 Git。

---

## 1. 正式签名配置（已建立）

| 项 | 值 |
|---|---|
| Keystore 路径 | `<本地密钥目录>\jihuatai-release.jks`（PKCS12，RSA 4096，有效期 100 年） |
| 别名（alias） | `jihuatai` |
| 密码 | 随机生成，保存在 `<本地密钥目录>\key.properties` 与仓库内 `android/key.properties`（两者均被 Git 忽略） |
| 证书主题 | `CN=JihuaTai, OU=Android Release, O=JihuaTai, L=Shanghai, ST=Shanghai, C=CN` |
| SHA-1 指纹 | `70:9C:43:1A:4B:92:B6:88:09:69:9D:89:EE:3C:DA:38:3A:38:4F:3B` |
| SHA-256 指纹 | `CA:D1:8B:A0:95:8F:20:16:A5:B8:54:62:65:D5:DC:93:27:B4:0B:42:64:CB:BF:7D:56:8C:07:4E:F5:64:7B:BD` |
| 生成脚本 | `scripts/android/gen_keystore.ps1`（会拒绝把密钥写进仓库目录） |

### 1.1 用户必须做的事（重要）

1. 把 **整个 `<本地密钥目录>` 目录**离线备份两份（例如 U 盘 + 加密压缩包），并记录上面的 SHA-256 指纹。
2. 只通过 `android/key.properties`（或 `<本地密钥目录>\key.properties`）指向该密钥；**不要**把 `.jks`、`key.properties` 提交到任何 Git 仓库。
3. 丢失 keystore（或密码）= 以后**无法覆盖升级**已发布的应用，只能更换 applicationId 重新发布一个新应用，老用户数据不会自动迁移。
4. 若更换开发机：把 `<本地密钥目录>` 复制到新机同路径，或在 `key.properties` 中写新的绝对路径。

### 1.2 构建签名包

```powershell
# 在纯 ASCII 路径的 worktree 中（AGP 拒绝中文路径）
cd <worktree>\android-integration
. .\scripts\android\env.ps1
powershell -File scripts\android\build_apk.ps1 -Mode release -Abi arm64 -Check -RequireReleaseSignature -NoPub
powershell -File scripts\android\build_apk.ps1 -Mode release -Abi all -Check -RequireReleaseSignature -NoPub
```

- `-RequireReleaseSignature` 会让 `check_apk.ps1` 校验签名者必须是正式证书（不是 Android Debug）。
- 产物在 `build\app\outputs\flutter-apk\`，本仓库已复制到 `dist\android\`（含 SHA-256）。

---

## 2. 版本与升级策略

| 项 | 规则 |
|---|---|
| applicationId | `com.jihuatai.planner`（**永久不变**，升级只认它 + 签名） |
| versionName / versionCode | `pubspec.yaml` 的 `version: 2.0.0+5`（当前 2.0.0 / 5） |
| 下一版 | 把构建号 `+5` 递增（versionCode 必须单调递增；更低版本系统会拒绝安装） |
| 升级来源 | 同一正式签名 + versionCode 递增的 APK，`adb install -r` 或用户点开安装包覆盖 |
| 用户数据 | 覆盖安装保留 `/data/user/0/com.jihuatai.planner/files/data/`（SQLite + 备份 + 账号工作区），不会重建或清空 |
| schema 迁移 | 只前进不后退（v1→v2 已内置事务迁移）；降级安装被系统拒绝，回滚需发更高 versionCode 修复包 |

> 已验证：同签名 versionCode 递增后覆盖安装，应用私有数据库文件与业务数据完整保留。

---

## 3. 发布产物

正式发布的 APK 由 GitHub Actions 的 Release 工作流构建，统一命名：

| 产物 | 用途 |
|---|---|
| `PlanTai-<版本>-Android-arm64-v8a.apk` | 主流手机（arm64-v8a） |
| `PlanTai-<版本>-Android-armeabi-v7a.apk` | 老旧 32 位设备 |
| `PlanTai-<版本>-Android-x86_64.apk` | x86_64 模拟器 / 平板 |

CI 会在上传前用 `apksigner verify --print-certs` 校验签名者，**发现 Debug 签名直接失败**，
不会把调试包冒充正式包。签名密钥通过仓库 Secrets 注入，不进入仓库与日志。

---

## 4. 已知限制

- Debug 包使用 Android Debug 签名，**不能**覆盖安装在正式签名版本之上（签名不一致，属系统安全约束）。
- 正式包不可 `run-as`，这是 Android 的安全设计；排障请优先用 Debug 包或应用内「数据与备份」导出。
- release 包只随附 `arm64-v8a`（按发布策略裁剪 Flutter 引擎 ABI）；如目标设备是 armeabi-v7a/x86_64，请使用 universal 包。
