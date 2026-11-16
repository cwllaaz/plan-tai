# Ubuntu / Linux 桌面版文档

计划台的 Linux 桌面端是基于 Flutter 的 GTK3 应用，安装包为 `.deb`（安装到 `/opt/jihuatai`）。

| 文档 | 内容 |
|---|---|
| [RELEASE.md](RELEASE.md) | **最终用户**：安装、启动、升级、卸载、数据位置、云端连接 |
| [COMPATIBILITY.md](COMPATIBILITY.md) | **开发者**：Linux 兼容性矩阵与已知问题清单（原生库、插件、窗口、路径、输入法等） |
| [../../packaging/linux/build_deb.sh](../../packaging/linux/build_deb.sh) | `.deb` 打包脚本（`dpkg-deb`，最小可维护） |
| [../../packaging/linux/test_deb.sh](../../packaging/linux/test_deb.sh) | 安装 / 启动 / 升级 / 卸载的自动化验收脚本 |
| [screenshots/stage3/](screenshots/stage3/) | Ubuntu 实机运行截图（安装后主页、日面板等） |

## 构建

```bash
# 依赖（Ubuntu 22.04 / 24.04）
sudo apt install clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
  libsqlite3-dev libsecret-tools

flutter pub get
flutter build linux --release        # 必须在 Linux 主机上执行
bash packaging/linux/build_deb.sh    # 生成 dist/jihuatai_<版本>_amd64.deb
```

## 运行期要求

- Ubuntu 22.04 / 24.04 LTS（x86_64 / amd64），系统自带 GTK3、SQLite 运行库。
- 云同步需要 Secret Service（GNOME Keyring / KWallet）保存登录令牌；缺失时云同步不可用，
  但本地功能不受影响，也不会把令牌写成明文。

## 已知限制

- 窗口拖动 / 高 DPI / 输入法等在无窗口管理器环境下未做完整自动化验收。
- 未提供 AppImage / Snap 等其他发行格式。
