# 计划台 Ubuntu 安装与使用说明（Release / .deb）

> 适用：计划台 `2.0.0` Ubuntu 桌面版（`pubspec.yaml` 的构建号随版本递增）；包名 `jihuatai`；应用 ID `com.jihuatai.jihuatai`。
> 适用系统：Ubuntu 22.04 / 24.04 LTS（x86_64/amd64）。仅依赖系统自带的 GTK3 / SQLite /
> libsecret 等运行库，安装包自带完整 Flutter 运行资源与所需共享库，**不需要安装 Flutter SDK**。

---

## 1. 安装

```bash
sudo apt install ./PlanTai-2.0.0-Ubuntu-amd64.deb
```

`apt` 会自动安装缺失的运行时依赖。若用 `dpkg` 手工安装后提示依赖问题：

```bash
sudo dpkg -i PlanTai-2.0.0-Ubuntu-amd64.deb
sudo apt-get install -f
```

安装位置（遵循 Linux 规范）：

| 内容 | 路径 |
|---|---|
| 程序与完整 Flutter bundle | `/opt/jihuatai/`（`jihuatai`、`data/`、`lib/`） |
| 命令行启动器 | `/usr/bin/jihuatai` → `/opt/jihuatai/jihuatai` |
| 应用菜单入口 | `/usr/share/applications/com.jihuatai.jihuatai.desktop` |
| 图标 | `/usr/share/icons/hicolor/{16..256}/apps/jihuatai.png` |

## 2. 启动

- **应用菜单**：在 Ubuntu 应用列表搜索「计划台」（或 jihuatai、日历、任务）点击启动；
- **命令行**：`jihuatai`；
- **Dock**：启动后可在 Dock 图标上右键 →「添加到收藏夹」固定。

首次启动会自动在用户目录创建数据库（见 §3），界面为空态属于正常。

## 3. 用户数据位置（不在安装目录内）

| 内容 | 路径 |
|---|---|
| 本地数据库 | `~/.local/share/计划台/data/app.db`（WAL 模式；XDG_DATA_HOME 优先） |
| 账号工作区 | `~/.local/share/计划台/data/accounts/<ownerId>/app.db` |
| 工作区指针 | `~/.local/share/计划台/data/cloud_workspace.json` |
| 设备标识 | `~/.local/share/计划台/data/device.json`（本机独立，不随备份/云端复制） |
| 本地备份 | `~/.local/share/计划台/data/backups/*.json` 与恢复前 SQLite 快照 |
| 云端 UI 偏好 | `~/.local/share/计划台/data/cloud_ui.json` |

**升级 / 重装 / 卸载都不会删除上述用户数据**（deb 的 postrm 只清理系统级文件，
不会触碰用户家目录）。若要彻底清除个人数据，由用户自行删除：

```bash
rm -rf ~/.local/share/计划台
```

便携/隔离运行可用环境变量 `JIHUATAI_DATA_DIR=/some/dir` 覆盖基目录；
演示模式 `JIHUATAI_DEMO=1`（内存数据、不写盘、不连云）。

## 4. 云端连接（可选）

- 顶栏云图标 → 填写服务器地址、账号（邮箱或用户名）、密码 →「连接并登录」；
- 服务器地址要求 **HTTPS**；本机 `localhost/127.0.0.1` 调试允许 HTTP；
- 首次登录按向导选择数据归属（上传本机 / 以云端为准 / 暂不关联），**不会自动上传**；
- 登录令牌保存在系统密钥环（GNOME Keyring / KWallet 的 Secret Service），
  **不写入 SQLite / JSON / 日志**；依赖包 `libsecret-tools`（已作为 Recommends）；
- 没有可用密钥环时会给出安装/解锁提示，并保持本地离线可用，不会退化为明文保存。

## 5. 升级

```bash
sudo apt install ./jihuatai_<新版本>_amd64.deb
```

- 升级只替换 `/opt/jihuatai` 与菜单/图标文件，不触碰用户数据库；
- 数据库 schema 由应用启动时的事务化迁移自动升级（`PRAGMA user_version`）；
- 包名与应用 ID 保持稳定，因此升级后 Dock 收藏、桌面入口、账号工作区均保持连续。

## 6. 卸载

```bash
sudo apt remove jihuatai     # 移除程序与菜单入口，保留用户数据
sudo apt purge jihuatai      # 同样不会删除用户数据；如需清除见 §3
```

- 卸载后用户数据库、备份、云端绑定文件仍保留在 `~/.local/share/计划台/`；
- 重新安装后数据与（若密钥环仍在）登录状态可继续使用。

## 7. 依赖说明

运行期依赖（deb `Depends`，Ubuntu 22.04/24.04 默认源均有）：

`libc6 (>= 2.35)`、`libgtk-3-0`、`libsqlite3-0`、`libsecret-1-0`、`libx11-6`、`libxi6`、
`libstdc++6`、`libgl1`、`libegl1`、`libglx0`

推荐（`Recommends`）：`fonts-noto-cjk`（中文字体）、`libsecret-tools` + `gnome-keyring`（云端令牌）。

> 说明：本项目在 Linux 上使用**系统 SQLite**（Ubuntu 22.04 自带 3.37 / 24.04 自带 3.45，
> 满足 `VACUUM INTO` 与窗口函数需求）；Windows 仍使用系统 `winsqlite3.dll`。

## 8. 从源码构建 / 打包（开发者）

```bash
# Ubuntu 上（Flutter 3.50.0 stable）
bash tool/ubuntu/guest_setup.sh          # 一次性准备依赖与 Flutter SDK（幂等）
cd <repo>
flutter pub get
flutter build linux --release            # 产出 build/linux/x64/release/bundle/
bash packaging/linux/build_deb.sh        # 产出 dist/jihuatai_<version>_amd64.deb
```

打包脚本只做三件事：复制**完整** Release bundle 到 `/opt/jihuatai`、安装 `.desktop`/图标/启动器、
用 `dpkg-deb` 生成 deb；不含额外打包框架，便于维护与审计。

## 9. 已知限制

- 未使用系统文件选择器：备份/恢复沿用与 Windows 一致的应用内固定备份目录（见 §3），
  这是功能对等而非缺失；
- Wayland 纯会话下窗口控制依赖 XWayland（window_manager 后端基于 X11/Xi）；
- 无 keyring 的极简桌面环境需先安装并解锁 GNOME Keyring/KWallet 才能使用云端登录。
