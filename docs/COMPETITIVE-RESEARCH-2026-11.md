# 同类竞品调研报告

> 调研日期：2026-11-05
> 调研对象：X Nook（macOS 刘海工具中心）+ X Island（AI Agent 刘海监控器）
> 数据来源：各产品官网 / GitHub 仓库 / 第三方对比站，价格与功能以 2026-09 至 2026-11 公开页面为准
> 说明：本报告中的价格与功能均为第三方或官方页面声明，未经实测，采购/宣传前需自行复核

---

## 〇、两个必须先处理的问题

### 问题 1：品类头部产品正在动荡，窗口期已打开

**NotchNook** 是这个品类的开创者，也是 X Nook 在 `README.md` 里明确对标的产品。它近期的公开状态：

| 时间 | 事件 |
|---|---|
| 2026-09 | 产品页下线，购买入口关闭 |
| 2026-10 | 在新站点重新开卖，价格从 **$25 一次性 / $3 月付 降到 $15 一次性 / $2 月付**，授权从 5 台 Mac 降到 2 台 |
| 进行中 | 继任产品 **NOOTCH** 内测；官方声明 NotchNook 很可能会开源 |

**这对 X Nook 意味着什么：**

1. 品类第一名的信誉受损，大量用户在主动搜索 "NotchNook alternative"（有第三方站点披露该关键词 90 天内带来 557 次站内搜索）。
2. 对手的定价锚点从 $25 跌到 $15，说明这个品类的价格天花板在往下走。
3. 但**不要指望捡漏**：NotchNook 用户流失的主要承接方是 Alcove 和 Droppy，两者都在密集投放 "NotchNook alternative" 类内容。
4. 另一个信号：头部产品倒下时，**信任比功能更值钱**——这也是下面 2.1 节把签名与公证列为最高优先级的原因。

### 问题 2：「X Island」存在同名产品，且对方在先

**`xisland.app` 是真实存在的产品**，不是占位站。开发者为 GitHub 用户 `bluedusk`（Dan，墨尔本，自述 10+ 年开发经验），产品是 macOS 刘海 AI agent 监控器，定位与你的 X Island 几乎完全一致。

**完整时间线（2026-11-05 经 GitHub API 核实）**：

| 日期 | xisland.app（Dan） | 你的 X Island |
|---|---|---|
| 2026-04-10 | 建仓 `bluedusk/xisland` + 首篇博客 | — |
| 2026-04-11 | 首个版本 v0.2.0 | — |
| 2026-04-13 | — | 上游 TowerIsland 创建（`g535879/TowerIsland`） |
| 2026-04-21 | Product Hunt 上线，103 票，日榜 #17 | — |
| 2026-05-02 | **v0.18.0 — 最后一个应用版本** | — |
| 2026-05-15 | — | 建仓 `Meteorkid/XIsland`，接手维护 |
| 2026-11-05 | 落地页有维护（10-30 提交），**应用 6 个月无新版本** | **v2.0.16，当日仍有提交** |

**对方在先约 5 周。** 但两个事实改变了实际判断：

1. **对方应用已实质停更**：35 个版本全部集中在 4 月 11 日–5 月 2 日三周内，此后无新版本。仓库 17 star、2 fork，最新版本累计下载 811 次（DMG 658 + ZIP 153）。
2. **你的项目体量远超对方**：226 次提交（你本人 160 次），版本 2.0.16，含 Windows 客户端；对方仓库仅托管落地页，应用本体闭源。

**三点需要注意**：

1. 对方仓库是**落地页仓库**（描述为 "Landing page for xisland"），应用本体不开源；其 `homebrew-xisland` tap 最后更新于 2026-05-02。
2. **双方均未注册商标**。你的 `TRADEMARK.md` 自述「未在中国大陆或其它司法辖区完成商标注册」，对方仓库无 LICENSE 文件。
3. **同名在搜索层面已是既成事实**。对方有 Product Hunt 记录、三篇 4 月发布的博客（其中一篇标题即 "the best free alternative to Vibe Island"）、独立站点，搜索引擎有留存。

**建议（按优先级）**：

1. **不建议改名**——你的项目在体量、活跃度、完整度上均占优，且已投入软著材料，改名成本高于收益。
2. **尽快提交商标注册**。你的 `TRADEMARK.md` 已建议「尽早提交第 9 类（计算机软件）与第 42 类（软件设计开发）」。对方在先使用约 5 周，这个时间差在审查中可能被援引，越早提交越有利。
3. **品牌串固定写全**。所有公开材料（README、官网、软著、简历）统一使用 `X Island by Meteorkid` 或 `X Island（Meteor Store）`，把搜索唯一性从「X Island」转移到可区分的组合。
4. **可选：在 README 加一句溯源说明**。注明本项目自 2026-04-13 起基于 TowerIsland 开发、2026-05-15 起由你维护，避免日后被误认为跟随者。

另外，「Nook」这个词在品类里已经很拥挤：**Nook**X、Notch**Nook**、NOOTCH（NotchNook 继任者）、Notch**Nest**。X Nook 的品牌辨识度建立难度比预期高。

---

## 一、竞品全景（截至 2026-11）

### 1.1 X Nook 的直接竞品：刘海工具中心

| 产品 | 价格 | 授权 | 开源 | 签名/公证 | 最低系统 | 关键差异 |
|---|---|---|---|---|---|---|
| **NotchNook** | $15 一次性 / $2 月付 | 2 Mac | 否 | 未核实 | 14.6 | 品类开创者，最成熟；近期因开发商纠纷信誉受损 |
| **Alcove** | $13.99–14.99 一次性 | 3 Mac | 否 | 是 | 15 | 动效最接近 iPhone 灵动岛；Live Activities、锁屏小组件、自定义 HUD；**无文件架、无剪贴板**（文件架称 1.8 加入）；自述依赖私有 API |
| **Boring Notch** | 免费 | — | GPL-3.0 | **未签名** | 14 | 11,000+ star、1,121 fork、63 贡献者；2.7.3 下载 92 万次；可视化音乐+文件架+日历+HUD |
| **Atoll** | 免费 | — | GPL-3.0 | 自 2.0（2026-03） | 14 | Boring Notch 的分支；系统监控（CPU/GPU/内存/网络/磁盘）+ 剪贴板 + 取色器 + 锁屏组件；**仅限带刘海 14/16 寸 MBP** |
| **Vorssaint** | 免费 | — | GPL-3.0 | 是 | 14 | **32,700 star**（品类最高）；菜单栏工具合集，灵动岛是其中一块；模块可单独卸载，卸载后不加载；含 AI Agent 用量监控 |
| **Droppy** | $9.99 一次性 | 2 Mac | 否 | 是 | 14 | 41 个扩展（Droplets）+ 扩展商店；文件架 + 浮动篮子；Droppy Cloud 分享链接；免费 iOS 伴生应用；无刘海屏可显示浮动胶囊；有 MCP Server |
| **Notchy** | $24.99 一次性 | 1 Mac | 否 | 未核实 | **13** | 74 项功能；最低系统版本最宽；含番茄钟、AI 用量、Face Unlock |
| **DynamicLake (Pro)** | 未公开标价 | — | 否 | 未核实 | 未公开 | 模块化命名（DynaKeys/DynaMusic/DynaGlance/DynaClip/DynaConnect）；有插件市场；已支持 macOS 27 |
| **Seam** | $19.90 一次性 | 2 Mac | 否 | 是 | 14 | 端侧听写 + 专注计时器；对 Sonoma 友好 |
| **NotchBay** | $19 一次性 | — | 否 | 未核实 | **26** | 「工作日层」：会前 2 分钟提醒并一键入会、Zoom/Meet 通话中静音/摄像头/共享控制、剪贴板历史 + 端侧 OCR、听写、分享链接 |
| **Halo** | 未核实 | — | 否 | 未核实 | 未核实 | 配置自由度最高：Simple/Advanced 双模式、可视化工作区编辑器、App Bubbles、按前台应用切换行为 |
| **MediaMate** | ~$7 | — | 否 | 未核实 | 13 | 只做 HUD 替换 + Now Playing |
| **Yoink** | 未核实 | — | 否 | 是 | 10.13 | 文件暂存架的鼻祖，已 15 年，v3.7.6（2026-08）；不依赖刘海 |
| **FavTray / FavShelf** | 免费 + $4.99 Pro | — | 否 | 未核实 | 14 | 开发者视角：Claude/Codex 用量条、Claude Code 审批、会议提醒、CI、端口占用 |

### 1.2 X Island 的直接竞品：AI Agent 刘海监控

| 产品 | 价格 | 开源 | Agent 覆盖 | 终端覆盖 | 关键差异 |
|---|---|---|---|---|---|
| **Vibe Island** | $19.99 一次性（含 1 年更新） | 否 | 26–30 | **20+ 含 tmux 与分屏** | 付费标杆；双向交互（审批/答题/Markdown 计划审阅）；8-bit 音效；用量限额；自动更新；零配置 |
| **Open Island** | 免费 | GPL-3.0 | 13 | 含 Zellij / cmux / Kaku / JetBrains / Windsurf / Trae / Zed | 自称「开源版 Vibe Island」；支持 OpenCode 的权限与提问；**已有简体中文** |
| **Vibe Notch**（原 Claude Island） | 免费 | Apache-2.0 | 1（Claude Code） | 基础 | 赛道原型，社区最大；MioIsland、Buddi 均衍生自它；**含 Mixpanel 埋点**；最后推送 2026-04-20 |
| **XIsland**（`xisland.app`，⚠️ 与你的同名） | 免费 | 否（落地页仓库无 LICENSE） | 6 | 7 | **对方在先约 5 周**；Product Hunt 103 票/日榜 #17；35 版本集中在 3 周内发布，**2026-05-02 后应用停更**；最新版下载 811 次；仓库 17 star |
| **CodeIsland** | 免费 | MIT | 30+ | 精确跳转 | 生态最广：iPhone + Apple Watch + ESP32 桌面屏 + Bark/ntfy/Slack/Telegram 推送 + Webhook；像素风吉祥物；安静时段；7 种语言 |
| **Ping Island** | 免费 | 是 | 17 | SSH 桥接 | 事件级过滤、远程 SSH 监控、用量分析 |
| **Notchi** | 免费 | GPL-3.0 | 2 | 无 | 像素精灵动画；**只读**，不能审批；需 macOS 15 + 带刘海 |
| **Agent Island** | 免费 | MIT | 5 | — | **macOS + Windows 双平台** |
| **AgentNotch** | 免费 | MIT | 2 | — | 支持到 macOS 12；零配置 |
| **Pushary Isle** | $9.99/月起（订阅） | 否 | — | — | 唯一订阅制；手机端决策 + 策略 + 审计 |
| **TokenTracker** | 免费 | 是 | 43 个工具 | — | 用量/成本仪表盘，非刘海应用；macOS 菜单栏 + 4 桌面组件 + 桌面宠物 + 15 个成就线；跨 Linux/Windows |
| **Notchmeter** | 未核实 | 否 | — | — | 闭源 |

### 1.3 同名产品 XIsland 详细档案（`xisland.app`）

由于与你的 X Island 同名，单独列档。数据均于 2026-11-05 经 GitHub API 与官网核实。

**开发者**：GitHub `bluedusk`，显示名 Dan，墨尔本。自述「10+ yrs shipping things」「TypeScript · React · Node · Go · AWS · AI Agents」，有 100 个公开仓库，主体是 JS/TS 生态（`html-slides` 95 star、`awesome-pretext` 42 star）。**这是其首个公开的 Swift/macOS 项目**，博客自述「也想要学 Swift。做 xisland 是个好借口」。

**产品规格**：

| 维度 | 内容 |
|---|---|
| 定位 | macOS 刘海 AI coding agent 监控器 |
| 支持 Agent | Claude Code（最佳）、Codex、Gemini CLI、OpenCode、VS Code、Cursor |
| 支持终端 | Ghostty（最佳）、iTerm2（最佳）、Terminal.app、WezTerm、Cmux、Warp（有限）、Kaku（未上线） |
| 显示模式 | Notch 模式 / Pill 模式（可随时切换） |
| 技术栈 | 原生 Swift + SwiftUI + AppKit，无 Electron |
| 通信 | Unix socket 读取 agent hook 事件 |
| 隐私 | 本地优先，无服务器、无账号、无遥测 |
| 系统要求 | macOS 14.0+ |
| 价格 | 免费，无付费层 |
| 安装 | `brew install --cask bluedusk/xisland/x-island` |
| 分发 | 自建落地页 + GitHub Releases + 自有 Homebrew tap |

**功能集**：会话监控（状态点：运行中/等待审批/有疑问/完成）、权限审批（拦截文件编辑、命令、删除）、行内答题（多选）、一键跳回精确终端标签页/分屏、vim 风格键盘导航（hjkl 移动、enter 执行）、配置导入导出、双显示模式、会话命名（需 CLI）。

**关键指标**：

| 指标 | 数值 |
|---|---|
| 仓库创建 | 2026-04-10 |
| 首个应用版本 | v0.2.0（2026-04-11） |
| 版本总数 | 35 个，**全部集中在 2026-04-11 至 05-02** |
| 最后应用版本 | v0.18.0（2026-05-02） |
| 最新版下载量 | 811 次（DMG 658 + ZIP 153） |
| GitHub star / fork | 17 / 2 |
| 仓库性质 | **落地页仓库**，应用本体闭源 |
| 许可证 | 无（仓库无 LICENSE 文件） |
| Product Hunt | 2026-04-21 上线，103 票，日榜 #17，7 条评论 |
| Issue 活跃度 | 20 个（2 个仍开放，最后新 issue 2026-05-26） |
| 落地页维护 | 最近提交 2026-10-30（改名 launch post、加 PWA 图标/sitemap） |

**当前状态评估**：应用本体自 2026-05-02 起约 6 个月无新版本，issue 活动停止于 5 月下旬。落地页在 10 月底仍有维护动作（SEO 相关：改名 launch post、加 sitemap 与 PWA manifest），说明开发者仍在做搜索可见性优化，但产品迭代已停滞。其博客明确承认维护边界：「agents change fast... It's not realistic to support every agent version forever. I focus on the latest versions of each agent」。

**与你的 X Island 的对比**：

| 维度 | 你的 X Island | XIsland（Dan） |
|---|---|---|
| 首发时间 | 2026-05-15（接手 TowerIsland） | 2026-04-10（**在先约 5 周**） |
| 当前版本 | 2.0.16（当日仍在提交） | v0.18.0（2026-05-02，停更） |
| 提交数 | 226（你本人 160） | 落地页仓库，应用闭源 |
| Agent 覆盖 | Claude Code、Cursor、Codex、OpenCode、Gemini CLI 等 | 6 个 |
| 终端覆盖 | iTerm2 标签级精度 + 多终端 | 7 个 |
| 独有功能 | SSH 远程管理、子 agent 嵌套、安静时段、正则静音规则、Bypass/Auto 模式、会话回顾、5 语言、额度追踪（Kimi/DeepSeek/GLM） | 键盘导航（hjkl）、配置导入导出 |
| 跨平台 | **有 Windows 客户端**（Tauri） | 无 |
| 隐私 | 本地优先 | 本地优先，无遥测 |
| 商标 | 未注册（`TRADEMARK.md` 自述） | 未注册（无 LICENSE） |

**结论**：对方**在先但已停滞**，你在**体量、活跃度、功能深度、跨平台**上全面领先。这不是「被抄袭」，而是**同赛道同名撞车**——两个独立开发者先后选中了同一个名字与同一个细分方向。

---

## 二、可学习的地方

### 2.1 信任门槛：签名与公证（优先级最高）

这是整个品类**最一致的信号**，也是 X Nook 当前最明确的短板。

- **Boring Notch** 最大的公开抱怨就是「没有 Apple 开发者账号，所以未签名，首次启动被 Gatekeeper 拦截」。第三方评测文章反复用整段篇幅解释如何绕过，甚至教用户跑 `xattr -dr com.apple.quarantine`。这直接导致：搜索结果里出现 3 个假冒官网，用户不敢装。
- **Atoll** 把「自 2.0 起已公证」当作独立卖点写进第三方对比表。
- **Droppy、Vorssaint、Alcove、Seam** 全部把「已签名并公证」列为核心优势。
- 反例：Claude Island 因为是 Apache-2.0 且社区最大，未公证仍被接受——但它有 3 万级社区兜底。

**X Nook 现状**：`docs/releases/1.3.19.md` 明确写「使用与上一版相同的 ad-hoc 本地签名，**尚未使用 Developer ID 签名或 Apple 公证**」。

**建议**：这是投入产出比最高的一件事。Apple Developer Program 年费 $99，换来的是「打开就能用」和「不会被当成木马」。在申请材料语境下，「完成 Developer ID 签名与 Apple 公证」也是一个可验证、可量化的工程完成度指标。

### 2.2 睡眠唤醒与稳定性：品类的「硬骨头」，也是最好的技术故事

- Boring Notch 的**头号开放 issue #336**（45 条评论，2025-01 至今未解）就是「长时间睡眠后刘海消失，只能强制退出重启」。
- 同类 issue 还有 #370、#279（唤醒后刘海位置错误）。
- Atoll 反复出现的问题：更新后 CPU 飙升、每次启动都弹权限请求、HUD 与系统 HUD 冲突、浏览器音乐检测不到。
- Alcove 在 2025 年有长达 6 个月的静默期，期间支持邮件、授权码、退款全部无人回复。

**X Nook 现状**：`CHANGELOG.md` 已经做了不少相关工作——收起路径看门狗兜底、跨进程显示权仲裁的文件锁超时、快速收起后旧延迟任务重新展开的修复。但 `1.3.19.md` 结尾诚实记录了「**多屏与睡眠唤醒仍未验收**」。

**建议**：睡眠唤醒是这个品类公认最难、也最没人解决好的问题。如果 X Nook 能把它做成有实测数据支撑的稳定项，这既是一个真实的差异化卖点，也是一个比「做了 4 个 Widget」强得多的申请素材——因为它符合「遇到真问题 → 定位 → 解决 → 验证」的叙事。

### 2.3 性能数字要主动公开

- Droppy 在对比表里直接写「0% CPU 空闲占用、约 45 MB 内存」（Dynamic Notch 同样如此）。
- Boring Notch 被反复批评：M4 MacBook Air 上 12 小时能耗异常、336 MB 内存、空闲时每小时掉 5% 电量、可视化动效持续耗电。
- 「footprint（常驻开销）」被 Vibe Island 的评测列为评价这类应用的五大维度之一——「always-on companion must stay invisible in Activity Monitor」。

**X Nook 现状**：README 和 CHANGELOG 里没有任何性能数字。

**建议**：用已有的测试基建（411 项测试、`swift test --disable-sandbox`）顺手加一个空闲占用基准测试，把「空闲 CPU / 常驻内存」写进 README。这是一个低成本、高可信度、可复核的量化主张——正好符合 `XNook-Portfolio.md` 里「只写能溯源的内容」的原则。

### 2.4 分发渠道：Homebrew Cask 是事实标准

品类内几乎所有产品都提供 `brew install --cask`：Boring Notch、Atoll、Droppy、Alcove、Vorssaint、Notchy、Vibe Island、Claude Island。

**X Nook 现状**：README 只写了「克隆仓库 + `./build-app.sh`」。这对普通用户是硬门槛，对想快速试用的人是劝退项。

**建议**：做一个自己的 Homebrew tap（可以同时绕过未公证的 Gatekeeper 问题——Boring Notch 的 Homebrew 安装会自动跳过安全警告）。这是低工作量、高转化率的一步。

### 2.5 模块化与扩展系统：你已有架构优势，但没暴露出来

- **Vorssaint** 的做法被评价为「真正的工程决策而非营销」：用户可以逐个卸载模块，卸载后该模块**不再加载**、从界面消失，重装后设置恢复。这直接解决菜单栏工具「全家桶拖慢系统」的问题。
- **Droppy**：41 个 Droplets + Droplet Store（扩展商店），「每个扩展默认关闭，不用的不运行」。
- **DynamicLake**：从固定功能集转向插件平台，有 DynamicLake Market。
- **Atoll** 的 README 明确标注代码血统（Boring Notch 提供媒体与文件架、Stats 提供 SMC 温度读取、Alcove 提供极简模式灵感）——这种**开源致谢的透明度**本身在建立信任。

**X Nook 现状**：架构已经是模块化的（`Features/MediaWidget`、`CalendarWidget`、`NotesWidget`、`TrayWidget`），README 也提到「模块化设计 — 功能可选，按需启用」，但**没有做成用户可感知的扩展系统**。

**建议**：把现有模块化架构产品化——「每个 Widget 可独立关闭且关闭后不占用资源」是一个可以直接宣传的能力，也是当前品类里被验证过的卖点。如果精力允许，未来可考虑扩展接口。

### 2.6 功能缺口：三个已被验证的必备项

按品类渗透率排序，X Nook 目前缺失的功能：

1. **剪贴板历史** — Atoll、Droppy、Notchy、NotchNook Pro、Vorssaint、NotchBay、OneNotch 全部具备。Alcove 因为**没有**剪贴板而被评测明确列为短板。这是当前事实上的必备项。
2. **锁屏小组件 + Live Activities** — Alcove（核心卖点）、Atoll、Droppy、NotchNook Pro 均已具备。Atoll 的 README 直接写「锁屏组件设计受 Alcove 启发」。这是 2026 年的功能前沿。
3. **HUD 替换（音量/亮度/键盘背光）** — Boring Notch、Atoll、Alcove、Droppy、MediaMate、NotchNook 1.6+ 都有。中文评测里对这个痛点的描述非常强烈（「按一下音量键，屏幕中间瞬间弹出一个大方块挡住视线」）。

**X Nook 已有的优势项**（README 与 CHANGELOG 可佐证，且竞品普遍没有）：
- 多版本能力探测层 + macOS 26 Liquid Glass / 14–15 回退的对比度实测（竞品普遍是「一刀切」）
- 封面取色（从专辑封面提取强调色）
- 果冻动画 / 磁吸 / 透明光标（`COMPARISON.md` 已标注为差异项）
- NookFlow 任务上下文工作流（**全品类独有**，没有任何竞品做「任务 + 关联笔记 + 关联文件 + 历史重开」）
- 中英双语（中文评测渠道有真实受众，且明确表达对隐私与稳定性的关注）

### 2.7 命名与品牌：需要收紧

- 品类内已有：NookX、NotchNook、NOOTCH、NotchNest、NotchBay、NotchDrop、Notchmeter、NotchClaude……
- 你的 X Island 与 `xisland.app` 的 XIsland 完全同名同赛道。

**建议**：
- 在所有公开材料中固定使用完整品牌串（如 `X Nook by Meteorkid`），提升搜索唯一性。
- 强化 NookFlow 这类**独有名词**的传播——竞品无法复用，是天然的品牌资产。
- 考虑为 X Nook / X Island 注册商标，或至少确认 X Island 名称的可用性。

### 2.8 生态延伸：竞品正在向多端扩张

- Droppy：免费 iOS 伴生应用（同步剪贴板/文件/笔记，Live Activities 上锁屏）+ Droppy Cloud + MCP Server + 扩展商店。
- CodeIsland：iPhone + Apple Watch + ESP32 桌面屏 + 多种推送通道 + Webhook。
- X Island 已有 **Windows 客户端**（`windows/`，TypeScript/Rust/Tauri）——这反而是**超过多数竞品**的一步：Agent Island 是唯一另一个跨 macOS/Windows 的同类产品。

**建议**：X Island 的跨平台能力值得在宣传中前置。这是稀缺项，不是补充项。

### 2.9 如果你要收费：价格锚点参考

| 档位 | 产品 | 授权范围 |
|---|---|---|
| 免费 | Boring Notch / Atoll / Vorssaint / Open Island / CodeIsland | — |
| $7 | MediaMate | — |
| $9.99 | Droppy | 2 Mac |
| $13.99–14.99 | Alcove | 3 Mac |
| $15 | NotchNook（重新定价后） | 2 Mac |
| $19.90 | Seam | 2 Mac |
| $19.99 | Vibe Island | 1 Mac + 1 年更新 |
| $24.99 | Notchy | 1 Mac |

**观察**：一次性买断是绝对主流，订阅制在品类内明显不受欢迎（Pushary Isle 是唯一订阅制，NotchNook 的月付选项被评测建议「不如买断」）。$9.99–15 是甜点区间。

**但注意**：X Nook 当前是「源码可用、非商业」许可。以港科大 PhD 申请为目标，**星标数与社区声量比收入更重要**——Vorssaint 的 32.7K star 就是「免费 + 高可见度」路线的样本。

---

## 三、优先级建议

### P0 — 立刻处理

1. **X Island 同名冲突已查清（见〇-问题 2）**。结论：对方在先约 5 周但已停更，你在体量与活跃度上全面领先。**不建议改名**，但建议尽快提交商标注册（第 9 类 + 第 42 类），并把所有公开材料的品牌串固定为 `X Island by Meteorkid`。
2. **Developer ID 签名 + Apple 公证**（$99/年）。这是整个品类最一致的信任门槛。**注意：你的 X Island 官网当前也在教用户跑 `xattr -cr` 绕过 Gatekeeper**，与 Boring Notch 的处境相同——这是可以立即消除的信任损耗。
3. **睡眠唤醒与多屏验收**（`1.3.19.md` 已自认未完成）。这是品类的头号未解难题，也是最好的技术叙事素材。

### P1 — 短期

4. **补上剪贴板历史**（品类事实必备项）。
5. **加 Homebrew tap**（降低试用门槛，顺带绕过 Gatekeeper）。
6. **测量并公开空闲 CPU / 内存占用**（竞品普遍公开，你目前无数据）。
7. **README 中英文都要加「NotchNook alternative」类的定位说明**（对手动荡期流量正在寻找承接方）。

### P2 — 中期

8. **锁屏小组件 / Live Activities**（2026 年功能前沿）。
9. **HUD 替换**（中文用户痛点明确，实现成本低）。
10. **把模块化架构暴露为「可独立关闭且不加载」的用户可见能力**。
11. **强化 NookFlow 的独有性宣传**（全品类无竞品，是最好的差异点）。
12. **X Island 的跨平台（含 Windows）能力前置到宣传首位**。

---

## 四、调研方法说明

- 价格、功能、系统要求、开源协议均来自各产品官网、GitHub 仓库 README / Releases 页面，以及第三方对比站（getdroppy.app、notchbay.com、getseam.app、favtray.com、macnotch.io、vibeisland.app、notchmeter.com、agent-island.dev 等），读取时间 2026-09 至 2026-11。
- **第三方对比站多由竞品方运营**（如 Droppy 的博客同时评测 Boring Notch 与 Atoll，Seam 的博客评测 Alcove），其结论存在商业立场，本报告仅采用其中可交叉验证的事实性信息（版本号、价格、协议、GitHub 数据），并已尽量用多来源交叉确认。
- GitHub star / fork / issue 数量为第三方在 2026-10-20 至 2026-11-04 期间读取的快照，存在时效性。
- 本报告未对任何竞品做实际安装与上手测试，所有功能描述均为公开声明，**不等同于实测结论**。

---
