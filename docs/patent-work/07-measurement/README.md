# 07 测量方案与数据分析器

> **状态：G1／G2／G3／G5 已实测（2026-11-14）；G4 为参数注入的机理验证；CER 已测但不在主张范围内。**
> - `runs.asr.csv`：**真实 ASR 端到端**（G1／G2，`synthetic=0`），180 帧。说明书 3.5 节的延迟数字取自本文件。结果见 `RESULTS.md` 结果 B。
> - `runs.seek.csv`：**真实音频指纹重锚**（G3，`synthetic=0`），20 次跳转 × 2 策略。说明书 3.5 节的跳转数字取自本文件。结果见结果 C。
> - `runs.jitter.csv`：**链长抖动**（G5，`synthetic=0`，抖动为受控注入），2000 帧 × 3 种子 × 3 策略。说明书 3.5 节的抖动数字取自本文件。结果见结果 D。
> - `runs.drift.csv`：**长时漂移**（G4，`synthetic=2`），晶振偏斜为参数注入，非硬件实测。只入 `RESULTS.md`，**不写入说明书**。结果见结果 E。
> - `runs.cer.csv`：识别字错率（base／small 两档、clean／SNR15 两条件）。**不属于本专利主张的效果**，只作背景说明。结果见结果 F。
> - `runs.real.csv`：调度器原型（sha256 标定负载，**不是 ASR**），720 帧，用于隔离调度逻辑。结果见结果 A。
> - `runs.SYNTHETIC.csv`：合成样本，仅供脚本自检，`synthetic` 列恒为 1，**不得引用**。

## 一、要证的命题

不是「延迟低」，而是「延迟对来源数不敏感」。唯一有说服力的形式是**一条平的上界**（P95 不随 N 抬升）：

> 在 G1／G2 中，本方案（B3／B4）的最大首帧延迟 ≤ L_budget + 2×渲染余量（316 ms）；
> 同组基线 B1（不剪枝、等全部来源返回）必然越界。

审查意见答复时，这条"上界与 N 无关"的对照就是「预料不到的技术效果」的全部证据。

**判据变更记录（2026-11-14）**：初版用「P95 对 N 的斜率 |slope| ≤ 5 ms/来源」判定。接入真实 ASR 后失效——G2-B3 的斜率算出 74.3 ms/来源，但最大值 307 ms 完全在预算内；斜率把"必要路径由可预取来源切换为流式识别"误判为"上界失效"。现判据为**上界判定**，斜率降为参考列。`analyze.py` 已按此实现。

## 二、五组设计

| 组 | 变量 | 素材 | 记录 |
| --- | --- | --- | --- |
| G1 可预取点播 | N ∈ {1,2,3,5} | 本地视频，重复播放 | 首帧 P50/P95、推理调用次数、重复转写秒数、峰值 RSS、缓冲字节数 |
| G2 不可预取直播 | N ∈ {1,2,3,5} | 会议／直播流 | 同上，另记链路重建次数 |
| G3 seek | 20 次随机 seek | G1 素材 | 重锚命中率、补处理区间数、seek 后首帧延迟 |
| G4 长时播放 | 连续 2 h | 单一长视频 | 字幕相对音频的偏移量（每 10 min 采样一次） |
| G5 阈值抖动 | P ±0.05 人为抖动 | G2 素材 | 链路重建次数（B2 单阈值 vs B3 双阈值滞回） |

方案代号：B1 不剪枝等全部、B2 仅超时降级、B3 本方案层 0、B4 本方案层 3（证书短路）。

## 三、CSV 字段（`runs.csv`）

| 字段 | 含义 |
| --- | --- |
| run / group / policy / n | 运行标识、组别（G1–G5）、方案代号、来源数 |
| prefetchable | 1 可预取，0 不可预取 |
| synthetic | 0 = 实测；1 = 合成样本（仅脚本自检，不得引用）；2 = 参数注入的机理验证（如 G4 的晶振偏斜），可复现但不是硬件实测 |
| frame | 帧序号（同一 run 内递增） |
| t_audio_ms | 音频帧到达时刻（单调时钟） |
| t_emit_ms | 该帧字幕提交呈现层时刻 |
| latency_ms | t_emit_ms − t_audio_ms |
| infer_calls | 本帧触发的推理调用次数 |
| dup_ms | 重复转写累计毫秒 |
| rss_mb / buf_kb | 进程峰值 RSS（MB）／音频缓冲字节（KB） |
| rebuilds | 本条记录所属 run 内的链路重建次数（G5 用） |

## 四、运行

```bash
python3 prep_media.py                                 # G3 素材：8 段真实语音拼成 45 s
python3 harness.py  --frames 30 --out runs.real.csv   # 调度器原型（sha256 负载，非 ASR）
python3 run_e2e.py  --frames 10 --out runs.asr.csv    # G1/G2 真实 ASR 端到端
python3 run_seek.py --seeks 20  --out runs.seek.csv   # G3 跳转重锚
python3 run_jitter.py --frames 2000 --out runs.jitter.csv  # G5 阈值抖动（无需 ASR）
python3 run_drift.py --hours 2  --out runs.drift.csv  # G4 长时漂移（参数注入）
python3 run_cer.py                  --out runs.cer.csv     # 识别准确率（base、small）
python3 analyze.py runs.asr.csv                       # 输出 Markdown 表 + summary.md
```

`run_e2e.py` 依赖：`~/.cache/xnook-asr/venv`（faster-whisper 1.2.1 + CTranslate2 4.9.0）、模型 `base` 存于 `~/.cache/xnook-asr/models`。首次运行会下载约 145 MB 模型。

退出码 0 表示上界判据全部通过（B3／B4 在界内且 B1 越界），1 表示存在 FAIL。

## 五、文件清单

| 文件 | 作用 |
| --- | --- |
| `prep_media.py` | 合成 G3 素材（8 段不同语音）与 `regions.json` 文稿 |
| `fingerprint.py` | 音频指纹：对数梅尔锚点表 + 波形局部对齐，含置信度 |
| `run_e2e.py` | G1／G2 真实 ASR 端到端（并发 + D 到点抢占） |
| `run_seek.py` | G3 跳转重锚 |
| `run_jitter.py` | G5 阈值抖动（单阈值 vs 滞回） |
| `run_drift.py` | G4 长时漂移（注入偏斜） |
| `run_cer.py` | 识别字错率与实体命中 |
| `harness.py` | 调度器原型（sha256 标定负载，与 ASR 解耦） |
| `analyze.py` | G1／G2 上界判定与汇总表 |

## 六、记录纪律

1. 每次运行保留原始 CSV、素材文件的 SHA-256、命令与 Python 版本；
2. 实测数据的 `synthetic` 必须为 0，且一帧一行、不聚合、不手改；
3. 只有 `analyze.py` 的退出码为 0，才可把对应数字写入说明书 3.5 节（3.3 节的机理推导口径不变）；
4. 未通过的组如实保留，不得只报通过的组。
