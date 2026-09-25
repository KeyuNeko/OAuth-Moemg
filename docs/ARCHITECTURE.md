# 目标架构：游戏公司统一身份系统

## 范围与现状
当前仓库仅提供 Keycloak 与 PostgreSQL 部署基线，没有自研玩家门户、员工目录、第三方 Client 审批门户、账号绑定服务或生产 HA 配置。本文是未来设计与验收目标，不代表这些能力已经交付。身份中心负责认证、会话和标准令牌；游戏服务负责角色、库存、支付、进度、风控和业务授权。

## 协议策略
- 使用已发布的 OpenID Connect Core 1.0（基于 OAuth 2.0）完成登录和身份声明；采用 discovery、Authorization Code、签名 ID Token、JWKS 轮换及标准登出。
- 新客户端统一 Authorization Code + PKCE（S256）；验证 state、OIDC nonce、issuer、audience、签名算法和时间声明。禁用 Implicit Grant、Resource Owner Password Credentials（密码模式）和生产通配回调。
- OAuth 2.1 在本文撰写时仍为 IETF 草案，并非最终发布标准。可以采用与草案方向一致的安全实践，但协议承诺应以已发布 OAuth 2.0/OIDC 标准和实际实现为准；不得宣称通过 OAuth 2.1 认证。
- 使用短时访问令牌、按 API 限定 audience、最小 scopes、刷新令牌轮换与重用检测。密钥只保存在服务端 Secret Manager；公用客户端不使用可保密的静态 secret。日志、URL、分析事件不得记录令牌、授权码或凭据。
- 原生 App 使用系统浏览器 + PKCE。回调可使用平台验证的 claimed HTTPS URI，或按 RFC 8252 使用 loopback IP URI（动态端口、路径精确）；不得用嵌入式 WebView 收集密码。纯 Web 客户端必须使用精确 HTTPS 回调。SPA 优先使用 BFF 和安全会话 Cookie；纯 SPA 作为 public client 使用 PKCE 并评估 XSS 风险。

## 玩家与员工隔离
玩家和员工是不同信任域。建议采用独立 Keycloak Realm（或独立 IdP）和不同公开 issuer，例如 login.example.com/realms/player 与 staff-login.example.com/realms/staff。两域分别管理客户端、签名密钥、会话、MFA/密码策略、管理员、审计和恢复流程；不能只靠角色区分。

- 玩家域承担游戏登录、账号恢复与玩家自助体验；开放注册前完成邮箱/手机验证、反滥用、恢复和隐私流程。
- 员工域优先联邦公司现有企业 IdP，启用抗钓鱼 MFA、条件访问、生命周期同步和快速禁用；管理入口限于 VPN/零信任网络，员工令牌不可被玩家客户端接受。
- 客服/运营工具使用独立、受审计的后台授权，遵守最小权限、理由记录和敏感操作审批。
- 账号关联或合并必须让双方重新认证并证明控制权，留存审计、撤销和支持流程；禁止按邮箱自动合并。

## PC、移动与主机登录（首期聚焦 Web 与 PC）

| 客户端 | 流程 | 控制 |
|---|---|---|
| PC 游戏启动器（首期） | 系统浏览器 + Authorization Code + PKCE；可使用平台验证的 claimed HTTPS 回调，或 RFC 8252 loopback IP 回调（动态端口、路径精确） | 不在嵌入式 WebView 输入密码；校验 state/nonce；服务端交换授权码 |
| iOS/Android（后续阶段） | 系统浏览器 + Authorization Code + PKCE；使用平台验证的 claimed HTTPS 回调 | 禁止在嵌入式 WebView 输入密码；令牌进系统安全存储；登出清理会话；上线前单独验收 |
| 游戏主机（后续评估） | 优先平台认证/账号关联 SDK；无浏览器时评估 Device Authorization Grant（RFC 8628） | 短码限时、限速、一次使用；提示核对设备；轮询遵守间隔；包内不得有 client secret；上线前单独验收 |

平台账号是独立身份来源。建立 federated_identity 前要求先登录目标玩家账号，再验证平台提供的稳定主体 ID；不得凭昵称或邮箱关联。解绑、封禁、恢复须有审计规则。

## 第三方 Client 审批
第一阶段由管理员手动审批；只有具备运营能力后再开发申请门户/API。不得让公开自助申请立即取得任意回调配置。申请收集主体/联系人、用途、隐私政策、域名所有权、精确 redirect/logout URI、客户端类型、所需 claims/scopes、数据留存和事件响应联系人。

- 每个环境、产品、信任边界使用独立 Client。第三方纯 Web Client 的生产回调只允许精确 HTTPS URI；原生 Client 按 RFC 8252 使用经注册的 claimed HTTPS 或 loopback IP 回调（动态端口、路径精确）。所有类型均拒绝通配符和开放重定向。
- 默认只发 openid 与最小 profile；邮箱、手机号和游戏资料需说明目的、用户同意并限制 scope。第三方强制授权同意页，并提供用户查看与撤销入口。
- 服务端 Web 使用 confidential client，凭据放 Secret Manager 并轮换；移动、桌面、SPA、主机均按 public client 处理。
- 保存 owner、审批人、回调、权限、轮换时间和状态；定期复核未使用 Client。滥用时可立即禁用 Client、撤销会话/授权并通知相关方。
- 资源服务器验证 issuer、签名、audience、scope、过期时间与撤销策略；第三方登录令牌不能调用内部游戏 API。

## 主体与数据模型
OIDC sub 是客户端身份标识；业务不得用邮箱、手机号、昵称或平台显示名作为主键。内部生成不可猜测、不可变的随机 player_id，各游戏保存自己的映射。可启用 pairwise subject 降低跨 Client 关联能力；不同 Realm/Client 的 sub 不保证相同。

建议逻辑实体：identity_subject（player_id、状态、创建时间）；federated_identity（issuer、外部 subject、provider、player_id、验证时间，对来源主体加唯一约束）；application_client（owner、环境、回调、scope、审批和轮换记录）；consent_grant（主体、Client、授权/撤销时间）；credential_reference（只引用由 IdP 管理的密码/MFA/Passkey）；audit_event（管理、恢复、绑定和授权事件，脱敏并限制访问）。身份库不存游戏进度或明文凭据。

合并账号需重新认证双方、验证控制权、检查冲突、预览影响、记录操作并提供人工恢复。删除需协调身份、游戏、分析和风控数据及法定留存；删除 IdP 账号不等于全链路删除。

## 生产拓扑、HA 与灾备
首期目标为 10 万账号以内、登录峰值较低，入口为网页与 PC 客户端。建议从单区域、单台 Linux 主机上的 Compose 部署起步，维持 Keycloak 与 PostgreSQL 的低复杂度运维；这有单机故障停服风险，不能称为 HA。业务需接受明确的恢复时间，并做好加密异地备份、恢复演练和告警。账号总量本身不能推导容量，首发前仍应压测登录峰值。若业务要求更短恢复时间，可在首期直接采用托管 PostgreSQL 与多 Keycloak 节点。达到扩容触发条件后再规划：
1. 多个无状态 Keycloak 节点置于负载均衡后，稳定 issuer/hostname；使用当前版本官方支持的集群/缓存配置，验证滚动升级与节点故障。
2. 采用受支持的 PostgreSQL 托管 HA 或演练过的主备；启用存储加密、TLS、访问控制、连接池和容量告警，数据库不接公网。
3. 加密异地备份数据库、必要 Realm/配置、主题和部署版本清单；定义 RPO/RTO，定期隔离恢复并实际登录验证。
4. 用 Secret Manager/KMS 管理数据库、Client、签名和 SMTP 凭据；区分环境，生产管理启用 MFA、最小权限、网络限制和敏感操作审批。
5. 监控登录成功率/延迟、错误、邮件失败、数据库连接/复制、磁盘、节点、证书、备份新鲜度与暴力尝试；审计日志集中保存和限权。
6. 镜像固定 digest，生成 SBOM 并扫描；预发布迁移和兼容验证后分批发布。回滚同时评估镜像和数据库 schema，不能假设降级安全。
7. 明确值班、事件分级、密钥泄露响应和业务 SLO；定期演练区域/数据库切换与灾备。多区域会影响会话、缓存、密钥、数据驻留，必须按实际版本设计压测，不能只加副本就宣称 HA。

## 分阶段迁移
0. **加固基线**：更新受支持补丁，配置真实 TLS/可信反代、管理员 MFA、SMTP、玩家 Realm 策略、加密备份与恢复演练；注册默认关闭，记录 issuer、Client、RPO/RTO、责任人。
1. **预发布接入**：建隔离玩家 Realm，选低风险 PC/Web 应用接入；验证 PKCE、state/nonce、登出、过期/轮换、禁用、恢复。不复制密码。
2. **移动与跨游戏**：接入系统浏览器和平台绑定，设计关联/合并/解绑/恢复/删除；逐游戏迁移，校验映射并保留回退。
3. **第三方和员工**：启用 Client 审批、同意、权限复核与撤销；员工 Realm 联邦企业 IdP；主机按平台逐个验收。
4. **规模化**：当单机故障恢复超出业务目标、压测接近资源上限或登录峰值增长时，再部署负载均衡、多 Keycloak 节点与 PostgreSQL HA；演练切换、灾备、发布回滚、密钥泄露和滥用响应。移动与主机端在产品需求明确后逐步接入。

## 生产验收
首期上线前在真实预发布环境留存证据，并经业务负责人接受单机故障期间的恢复目标；扩容为 HA 后增加故障切换验收：
- discovery、JWKS、issuer、TLS 和回调正确；首期 Web 与 PC 流程通过。移动端和主机端须在各自开放前分别验证平台回调、令牌安全存储/设备流程与登出。
- 正反向登录、PKCE/state/nonce、错误回调拒绝、锁定/恢复、MFA、邮件、登出和撤销有端到端结果。
- 玩家与员工隔离；第三方仅取得审批的 claims/scopes，用户可查看和撤销授权。
- 备份在隔离环境恢复至批准的 RPO；升级/迁移和回滚经过实测。
- 扫描、权限审查、日志脱敏、轮换、告警和值班就绪；压测/故障切换符合已批准的 SLO/RTO/RPO。
- 数据留存、隐私、地区要求、删除与事件响应经法务、安全、隐私和业务负责人审阅。本文不构成合规认证或法律意见。

验收门槛通过前，项目应标记为身份服务试运行/生产候选，不标称生产级或合规认证。
