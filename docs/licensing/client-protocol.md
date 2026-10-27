# XNook macOS 软件授权客户端

> 实现日期：2026-10-26。交付基线：`xnook-overview-header` 工作树的 `7a1522a`，保留 1.3.23 连续双岛、布局与全局快捷键实现。

## 使用与构建

网站统一提供 XNook、XIsland 的月度、年度、永久授权。每份付费授权最多绑定三台设备，由网站原子分配设备名额；客户端不自行决定名额。首次试用和激活需要联网。服务器首次登记设备时计算完整 14 × 24 小时试用期，刷新不重置试用。

`swift build` 可验证源码。正式 app 通过 `build-app.sh` 构建时，从环境变量 `SOFTWARE_LICENSE_PUBLIC_KEY` 读取原始 32 字节 Ed25519 公钥的 Base64，将其写入 bundle 的 `SoftwareLicensePublicKey`。公钥不是私钥。私钥只由网站服务持有，不能进入客户端、仓库、构建日志或下载包。构建脚本将 `SoftwareLicenseAPIBaseURL` 设置为 `https://www.imagentx.top`。未配置公钥的开发包显示配置提示并关闭完整功能；缺公钥不能生成售卖 DMG。

已使用网站测试 fixture 的公钥生成任务独占 App/DMG，并验证 ad-hoc 签名、Info.plist、共享核心符号与 DMG 校验和；路径、SHA-256 和验证记录见 `validation-2026-10-26.json`。测试包文件名包含 `TEST-KEY-DO-NOT-PUBLISH`。本次未生成生产密钥，未安装、发布或公证。源码与测试包验证不等于线上订单、真实设备与正式签名包验收。

## 协议

所有请求是 HTTPS JSON POST，路径以 `/api/software-licenses/` 开始。

| 路径 | 请求字段 |
| --- | --- |
| `trial` | `productId`, `deviceId`, `deviceName` |
| `activate` | 上述字段和 `code` |
| `refresh` | `productId`, `deviceId`, `deviceToken` |
| `deactivate` | `productId`, `deviceId`, `deviceToken` |

XNook 固定 `productId = "xnook"`。设备身份使用 `IOPlatformUUID` 的 SHA-256 十六进制哈希，原始硬件 UUID 不离开机器；硬件信息不可得时生成随机值并保存到设备专用钥匙串条目，不能每次启动重新生成。测试注入模拟硬件值与内存存储，不操作用户钥匙串。

前三个成功响应为 `{ "lease": "...", "deviceToken": "..." }`；解绑只要求成功 HTTP 状态。错误响应支持 `code`、`message` 或字符串 `error`。刷新返回 401、403、404、410 时立即保存阻止访问状态；网络超时和 5xx 不延长租约，只允许已有、签名有效且未到期的凭证继续使用。

租约格式：`MSL1.<base64url UTF8 JSON>.<base64url Ed25519 signature>`。签名原文是 ASCII `MSL1.` 与原始 payload segment 的连接，不对解析后的 JSON 重新排序签名。

载荷字段：`version: 1`、`productId`、`deviceId`、`licenseId`、`kind: trial|monthly|annual|lifetime`、`issuedAt`、`expiresAt`、`entitlementExpiresAt`。时间为 Unix 秒，永久授权的使用权终止时间为 null。客户端先验签，再校验产品、设备、字段和时间关系；单份租约最长 7 天且不得超过试用/月/年使用权期限。永久使用权无需续费，但仍须至少每 7 天联网核验一次。旧 `XNK1` 邀请码只能提示联系管理员迁移，不能绕过设备限制。

## 凭据与运行状态

租约、设备令牌、最近时间与服务端撤销状态存于产品专属 Keychain 服务 `com.meteorkid.xnook.software-license`，关闭 iCloud 同步并仅限此设备。恢复时重新验签。离线时间取本地时间、已保存的最近时间、签名时间以及当前进程单调时钟推算时间的最大值，时钟回拨不能恢复已过期租约。误设未来时间后，应先校准系统时间；只有签发时刻与本机时间相差不超过 5 分钟的新近已验签 HTTPS 响应能重新建立时间锚点，旧缓存不能执行此校正。

启动先恢复有效离线租约，再联网刷新；没有凭据时申请试用。每 30 秒检查有效期，并为精确截止时间设置单次定时器；唤醒立即重验，正常运行每 6 小时刷新。到期或服务端撤销会停止主窗口、媒体轮询、日历提醒、任务截止监控、Claude hook 监听、双岛预览与全局快捷键；保留设置中的授权、购买、解绑及本地数据导出。保存失败时保留内存笔记用于导出，重新激活复用原笔记实例并恢复服务与原配置。

解绑需要服务器成功确认，成功后清除本机租约和令牌，保留不能自动重新申请试用的状态。离线时无法可靠释放名额，因此解绑失败不会显示成功。

## 验证与验收

- `swift test --filter SoftwareLicenseTests`：签名/产品/设备隔离、请求字段、离线期限、14 天边界、回拨、撤销、解绑和安全存储失败。
- `swift test --filter 'LicenseManagerTests|GlobalPanelShortcutTests'`：无需重启的截止定时器锁定、媒体停止、热键挂起及恢复。
- 跨语言：`METEOR_LICENSE_FIXTURE_PATH=/absolute/path/fixture.json swift test --filter SoftwareLicenseTests.testExternalServerFixture`。fixture 只含公钥、服务端签名租约、产品、设备以及测试时刻，不包含私钥。
- 发布前需要实际支付回调/订单交付、第四设备拒绝、管理员解绑后换机、续费、撤销、断网 7 天边界、休眠跨期以及正式签名包的 Keychain 持久化验收。

## 文件

- `Sources/MeteorLicenseCore/`：可复制到 XIsland 的独立协议核心。
- `Sources/XNook/Licensing/`：状态展示、定时器、Keychain 生产配置、数据导出。
- `Sources/XNook/App/AppDelegate.swift`：运行门禁与恢复。
- `Tests/MeteorLicenseCoreTests/`、`Tests/XNookTests/LicenseManagerTests.swift`：隔离验证。
