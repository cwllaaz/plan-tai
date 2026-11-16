# 计划台 V2.0 · 生产部署方案（PocketBase + Caddy + systemd）

> 状态：**方案已就绪，尚未在用户的 2C2G 服务器上执行**。
> 原因：本会话没有服务器地址、SSH 凭据与域名，且部署会修改生产环境。
> 按本方案逐步执行前，请先确认 §1 的现状核查与 §7 的变更审批。

## 1. 部署前现状核查（只读）

在服务器上执行并把结果贴回：

```bash
uname -a
cat /etc/os-release
uname -m
free -h
df -h /
ss -tlnp
systemctl list-units --type=service --state=running
docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null
systemctl list-timers --all
ls -la /etc/caddy 2>/dev/null
crontab -l 2>/dev/null
```

重点确认：

- [ ] 架构是 x86_64 还是 arm64（决定 PocketBase 二进制）；
- [ ] 80/443 是否被占用（Nginx/Apache/其他面板）；
- [ ] 8090 是否空闲（PocketBase 只绑定 127.0.0.1）；
- [ ] 是否已有 Caddy/Nginx；有则优先复用，不重复安装；
- [ ] 磁盘 ≥ 2 GB 可用、内存 ≥ 1.5 GB 可用；
- [ ] 现有备份机制与备份落点（避免覆盖）；
- [ ] 域名是否已解析到该服务器（A/AAAA 记录）。

## 2. 目标拓扑

```
Internet
  │ 443 (TLS, Let's Encrypt)
  ▼
Caddy  ──反代──►  PocketBase 127.0.0.1:8090
                   ├─ pb_data/data.db（业务库，唯一写入点）
                   ├─ pb_hooks/（/api/planner/*）
                   └─ pb_migrations/
```

- 系统用户 `jihuatai`（无登录 shell），目录 `/opt/jihuatai`。
- `pb_data` 仅该用户可读写；`/opt/jihuatai` 其余目录只读。
- 8090 只监听 loopback；防火墙仅放行 22/80/443。

## 3. 安装步骤（草案）

```bash
# 3.1 用户与目录
sudo useradd --system --home /opt/jihuatai --shell /usr/sbin/nologin jihuatai
sudo mkdir -p /opt/jihuatai/{bin,pb_data,pb_hooks,pb_migrations}
# 上传 server/pb_hooks、server/pb_migrations；下载 PocketBase 0.23.12 linux-amd64 到 bin/
sudo chown -R jihuatai:jihuatai /opt/jihuatai
sudo chmod 750 /opt/jihuatai/pb_data

# 3.2 systemd
sudo tee /etc/systemd/system/jihuatai.service >/dev/null <<'EOF'
[Unit]
Description=JihuaTai sync (PocketBase)
After=network-online.target
Wants=network-online.target

[Service]
User=jihuatai
Group=jihuatai
WorkingDirectory=/opt/jihuatai
Environment=PA_RATE_LIMIT_AUTH=20
Environment=PA_RATE_LIMIT_SYNC=120
ExecStart=/opt/jihuatai/bin/pocketbase serve \
  --http=127.0.0.1:8090 \
  --dir=/opt/jihuatai/pb_data \
  --hooksDir=/opt/jihuatai/pb_hooks \
  --migrationsDir=/opt/jihuatai/pb_migrations
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/opt/jihuatai/pb_data
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now jihuatai
curl -s http://127.0.0.1:8090/api/planner/health

# 3.3 Caddy（若未安装，用官方 apt 源；已装则只加站点）
sudo tee /etc/caddy/Caddyfile >/dev/null <<'EOF'
sync.example.com {
    encode zstd gzip
    request_body {
        max_size 1MB
    }
    reverse_proxy 127.0.0.1:8090 {
        transport http {
            read_timeout 30s
            write_timeout 30s
        }
    }
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy no-referrer
        -Server
    }
}
EOF
sudo systemctl reload caddy
```

域名与 HTTPS 必须一次成功；失败时保留 Caddy 日志并回滚 Caddyfile。

## 4. 账号与安全

```bash
# 管理员（只在服务器本机执行；密码用强随机，不写 Git）
/opt/jihuatai/bin/pocketbase superuser upsert admin@example.com '<强密码>' \
  --dir=/opt/jihuatai/pb_data

# 普通用户：在 Dashboard → Collections → users 新建；
# 或使用 API_CONTRACT §3 的管理员 token 调用 users/records。
```

- 公共注册已关闭（`users.createRule = null`）；
- 普通用户只能读取自己（`listRule/viewRule/updateRule = id = @request.auth.id`）；
- 每用户登录/同步限流由迁移写入（`PA_RATE_LIMIT_*` 可调）；
- 不要给 `users` 开 `manageRule`；管理员与普通用户是两套集合。

## 5. 备份与恢复

### 5.1 服务端备份

```bash
# 每日 03:20，SQLite 在线备份 + 保留 14 天，落点独立于 pb_data
sudo tee /etc/cron.d/jihuatai-backup >/dev/null <<'EOF'
20 3 * * * jihuatai /usr/bin/sqlite3 /opt/jihuatai/pb_data/data.db ".backup '/var/backups/jihuatai/data-$(date +\%F).db'" && find /var/backups/jihuatai -name 'data-*.db' -mtime +14 -delete
EOF
sudo mkdir -p /var/backups/jihuatai
sudo chown jihuatai:jihuatai /var/backups/jihuatai
```

- 备份目录不要与 `pb_data` 同盘/同目录；
- 另做一份异地（对象存储/另一台机器）每周快照；
- 每季度演练一次恢复：停服务 → 替换 `data.db` → 启服务 → 健康检查 → 抽样同步。

### 5.2 客户端数据

- 客户端本地库在 `%APPDATA%\计划台\data\app.db`；
- 应用内「本地备份与恢复」导出 JSON、恢复前自动 SQLite 快照；
- 换账号/以云端为准时，同步引擎会先整库备份 + 归档（`binding.json` 旁路记录）。

## 6. 升级与回滚

1. 升级前：`systemctl stop jihuatai` → 备份 `data.db` + `pb_hooks` + `pb_migrations`；
2. 替换二进制/代码 → `systemctl start jihuatai`；
3. 验证 `/api/planner/health` 的 `protocolVersion/schemaVersion`；
4. 失败：恢复备份与旧二进制，`systemctl restart`；
5. 客户端不需要同时升级；协议 `protocolVersion=1` 保持兼容。

## 7. 变更审批（执行前必须确认）

部署会实际影响生产环境，执行前请逐项确认：

- [ ] 服务器地址 / SSH 方式 / 是否允许我直接操作；
- [ ] 域名与 DNS 是否已就绪；
- [ ] 维护窗口（预计 15–30 分钟，期间云端同步不可用，本地功能不受影响）；
- [ ] 现有 80/443 服务是否可复用 Caddy；不可复用时的替代方案；
- [ ] 备份落点与保留策略；
- [ ] 是否创建生产管理员账号，以及账号交付方式（不要发在聊天里）。

## 8. 验证清单（部署后）

- [ ] `curl https://sync.example.com/api/planner/health` 返回 `status=ok`、`features` 含 push/pull；
- [ ] 管理员能登录 Dashboard；普通用户不能访问 Dashboard；
- [ ] Windows 客户端用 HTTPS 地址登录、绑定、同步成功；
- [ ] 停掉客户端网络 → 本地可用 → 恢复后自动同步；
- [ ] `systemctl restart jihuatai` 后数据仍在、客户端可继续同步；
- [ ] 备份文件存在且 `PRAGMA integrity_check` 为 ok；
- [ ] 日志不含 token/密码/请求体。
