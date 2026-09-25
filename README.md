# Moemg Identity

基于 Keycloak 与 PostgreSQL 的统一登录中心。Keycloak 提供 OAuth 2.0 / OpenID Connect 标准端点，OIDC 授权码流程支持 PKCE；业务应用只接收标准 OIDC 登录结果，不共享密码。账号目录、MFA、会话、客户端凭据由成熟 IdP 管理。

## 架构与固定版本

- Keycloak `26.2.5`、PostgreSQL `17.4-alpine` 是当前可复现基线，Compose 中固定版本标签；这不代表它们在当前部署日期仍是最新或受支持补丁。每次发布前维护者必须核对 Keycloak/PostgreSQL 官方安全公告和支持周期，更新到受支持补丁版本并在预发布环境验证迁移。
- PostgreSQL 只在 Compose 私有网络中开放；Keycloak 仅绑定宿主机回环地址 `127.0.0.1:8080`。
- 外部 TLS 在 Nginx/宝塔终止。Keycloak 的 issuer 固定为公开 HTTPS 域名，代理头模式为 `xforwarded`。
- 数据只存于 Docker 命名卷 `postgres_data`。升级前备份数据库；不要删除卷来“修复”问题。

## Linux 首次部署

要求 Linux x86_64/arm64、Docker Engine 和 Docker Compose v2 插件。先在 DNS 添加 `id.example.com` 指向服务器，并在宝塔添加站点和签发 HTTPS 证书。

```sh
git clone https://github.com/YOUR_ORG/OAuth-Moemg.git
cd OAuth-Moemg
cp .env.example .env
openssl rand -hex 32
```

将两条独立随机值分别填入 `.env` 的 `POSTGRES_PASSWORD` 和 `KC_BOOTSTRAP_ADMIN_PASSWORD`，再修改 `KC_HOSTNAME=https://id.example.com`。不要提交 `.env` 或把密钥发给客户端。启动：

```sh
bash scripts/preflight.sh
docker compose up -d
docker compose ps
docker compose logs -f keycloak
```

首次启动会初始化数据库，等待 Keycloak 日志显示启动完成。按 [nginx/identity.conf.example](nginx/identity.conf.example) 在宝塔 Nginx 配置反代，保存并重载配置。示例将 `/admin/` 限制为白名单 IP，请将 `203.0.113.10` 换成你的固定运维出口地址；如果出口 IP 会变，在宝塔启用面板 VPN/访问控制后再开放管理端。OIDC 登录和回调流量仍需公开访问。

验证发现文档：

```sh
curl -fsS https://id.example.com/realms/moemg/.well-known/openid-configuration
```

本仓库不自动创建生产 Realm 或带固定密码的客户端。首次访问 `https://id.example.com/admin/`，使用 `.env` 的引导管理员账号登录，按下方步骤建立正式 Realm 和应用。Keycloak 引导管理员只用于初始管理；创建具 MFA 的日常管理账户后，禁用或更换引导管理员密码。

当前工作区尚未执行容器启动、HTTPS 回调或备份恢复端到端验证：运行环境没有 Docker CLI 和 Linux 服务器。仓库 CI 会在 GitHub Actions 中校验 Compose 配置模型和示例 JSON；合并前应在 Linux 预发布机实际走通首次启动、OIDC 登录、邮箱验证、更新和回滚演练。

## 初始化和生产加固

1. 在管理控制台创建 Realm `moemg`，设置登录主题、允许的登录方式与会话期限。生产建议启用邮件验证和密码重置；先配置 SMTP，再启用验证邮件及公开注册。默认避免无意开放自助注册。
2. 配置 Realm 的密码策略（至少长度、字典检查、失败登录锁定），启用 brute force detection。给所有管理员强制 OTP/WebAuthn MFA，避免共用管理员账号。
3. 配置 SMTP 并测试验证邮件、密码重置邮件。`verifyEmail` 应开启后再开放注册。
4. 设置 HTTPS、正确的公开 hostname，并在宝塔/Nginx 限制 `/admin/`。保留可信来源代理头；不要将 8080 端口直接暴露公网或把 `KC_HOSTNAME` 改为内网地址。
5. 配置事件审计和日志留存；定期演练 PostgreSQL 备份恢复，监控磁盘空间、服务健康和证书到期。
6. 管理员在受控网络登记 OAuth 客户端，验证应用归属、HTTPS、隐私政策、回调域名所有权和登出行为。回调 URI 必须使用具体 HTTPS 路径，禁止生产通配符。定期轮换客户端密钥。

## 接入业务或第三方应用

每个应用在 Realm `moemg` 中注册独立 OIDC Client。服务端 Web 应用使用 Confidential client；原生/SPA 使用 Public client 并强制 Authorization Code + PKCE（S256），客户端不能保存 secret。不要启用 Implicit Flow 或 Direct Access Grants（密码模式）。第三方客户端应启用 **Consent Required**，配置清晰的应用名称、用途和最小权限 Client Scopes，让用户在首次授权时确认数据共享；自家业务可按产品体验决定是否显示授权页。

Realm `moemg` 的发现地址：

```text
https://id.example.com/realms/moemg/.well-known/openid-configuration
```

OIDC 库应从 discovery 自动读取授权、令牌、JWKS、userinfo、logout 地址；校验 `state`、`nonce`、ID Token 签名、`iss`、`aud`、过期时间。服务端使用 code 换 token，并从 UserInfo/ID Token 取得稳定 `sub` 作为账号标识，不要用邮箱作为永久主键。内部游戏和第三方应用都走相同 Realm/账号目录；跨应用账号数据仍由业务系统自行关联 `sub`。

`examples/realm-demo.json` 是演示 Realm/客户端配置样例，不由 Compose 自动导入；默认关闭自助注册，也不含客户端密钥。先在 Keycloak 配置 SMTP、验证邮件和其他生产策略，再启用注册；客户端在管理控制台创建并由 Keycloak 生成密钥。样例域名和回调地址需替换成各应用真实值。

## 备份、恢复、升级

升级前做数据库逻辑备份，并保存 `.env`、当前镜像版本、反代配置和自定义主题。示例：

```sh
mkdir -p backups
docker compose exec -T postgres pg_dump -U keycloak -d keycloak -Fc > "backups/keycloak-$(date +%F-%H%M%S).dump"
```

以上备份命令使用默认数据库名和用户 `keycloak`；若 `.env` 自定义了 `POSTGRES_DB` 或 `POSTGRES_USER`，请将命令中的值改为实际配置。

恢复前先停止 Keycloak，再对空数据库恢复：

```sh
docker compose stop keycloak
cat backups/your-backup.dump | docker compose exec -T postgres pg_restore -U keycloak -d keycloak --clean --if-exists
docker compose up -d keycloak
```

恢复会覆盖目标数据库；确认目标和备份后再运行。生产可使用仓库 `scripts/` 下的更新脚本进行更新，它先备份，再拉取固定发布标签所指向的仓库配置并启动服务，随后检查 OIDC 元数据是否可用。若检查失败，脚本会停止并输出备份位置；需要人工查看日志后运行 `bash scripts/rollback.sh <更新前备份.dump> <更新前 Git 引用>` 回滚。回滚会将数据库恢复到备份时间点，覆盖此后的数据。宝塔“计划任务”可定期运行 `bash scripts/check-update.sh`；确认发布后可在宝塔手动点击执行 `bash scripts/update.sh`。项目维护者发布 `vX.Y.Z` 标签时需要同步更新 Compose 中的固定镜像版本，更新脚本不会自动跟踪浮动的 `latest` 镜像。先在测试环境验证新版本和数据库迁移，Keycloak 只支持按升级路径迁移，不能随意跳过大版本。备份文件包含身份数据库敏感信息，应限制权限并异地加密保存。

### 宝塔一键更新入口

在宝塔「计划任务」新增两个 Shell 脚本任务。将 `/opt/OAuth-Moemg` 换成实际 Git 克隆目录：

- 更新检查：`cd /opt/OAuth-Moemg && bash scripts/check-update.sh`，可每天运行并在任务日志查看当前/最新标签。
- 一键更新：`cd /opt/OAuth-Moemg && bash scripts/update.sh`，设置为手动执行；确认发布后在宝塔点击「执行」。

两个任务仅应由服务器管理员管理。不要把更新脚本暴露成公开 Web 按钮，也不要给 Keycloak 容器挂载 Docker socket。更新失败时任务日志会给出备份路径和回滚命令。
## 项目文件

- `docker-compose.yml`：服务编排和本机端口绑定。
- `nginx/identity.conf.example`：宝塔 Nginx 反代示例。
- `examples/realm-demo.json`：OIDC 客户端配置样例。
- `scripts/`：更新检查、备份与升级运维脚本。
