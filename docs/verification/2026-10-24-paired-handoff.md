# 双端切换候选

用户已确认将修复扩展到XIsland，使用独立工作区。XNook保留横向封面、背景预设和自动适配，补齐最终屏幕定位及快速取消后的明确显示恢复；XIsland同步实现，并保留审批/问答/计划草稿与任务功能。

XNook最终源码完整530项回归通过，Release与严格签名校验通过，书签entitlement保留；55项定向测试也通过，与完整测试有重叠。候选`.build/paired-handoff-20261024/X Nook.app`，可执行文件SHA256为`ada74e4db23645803209a4b1c03e4469978ebf549f136b0ebb94b967f7f77186`。版本仍1.3.19。

XIsland基线15c993e/2.0.9，独立分支`codex/handoff-motion-20261024`。最终源码完整测试1583项通过、18按条件跳过，102项专项也通过；其主工作区未改动，未安装bridge或改PATH。

两端候选和兼容状态见本证据目录`paired-acceptance.json`；完整跨仓库记录在`/Users/meteor/.codex/worktrees/xisland-handoff-motion/docs/verification/2026-10-24-bidirectional-handoff.md`。

尚未提交、安装或发布。真正的双应用切换、跨屏、触控板和玻璃合成需安装后验收，不能由离屏/注入测试替代。
