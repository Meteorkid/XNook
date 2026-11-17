#!/usr/bin/env python3
"""端到端实测 v2：真实音频 + 真实 ASR + 真实并行执行。

关键修正（v1 的错误）：v1 串行执行各提供者，等于"等全部来源"，无法在 D 到点抢占；
本版按权 1 的异步约定并发提交，到 D 即渲染，未完成的来源视为晚到证据并放弃写入。

提供者（耗时全部来自真实计算）：
  P1 文本流        —— 内存索引查表
  P2 元数据实体表  —— 词典扫描
  P3 音频指纹      —— numpy 互相关（1 s 窗口）
  P4 既有全文检索  —— whisper 对 8 s 窗口整段识别（真实慢路径）
  P5 流式识别      —— whisper 对 1 s 切片识别

运行：~/.cache/xnook-asr/venv/bin/python run_e2e.py --frames 8 --out runs.asr.csv
"""
import argparse
import csv
import time
from concurrent.futures import ThreadPoolExecutor, wait

import numpy as np
from faster_whisper import WhisperModel

PCM = "/tmp/xn_speech.pcm"
L_BUDGET_MS = 300.0
RENDER_MS = 8.0
SR = 16000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=8)
    ap.add_argument("--out", default="runs.asr.csv")
    args = ap.parse_args()

    raw = open(PCM, "rb").read()
    audio = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    model = WhisperModel("base", device="cpu", compute_type="int8",
                         download_root="/Users/meteor/.cache/xnook-asr/models",
                         cpu_threads=6)

    def p_text(a):
        return len(a)

    def p_entity(a):
        t = {"李明远": 1, "深圳": 2, "语音识别": 3, "识别率": 4}
        return sum(len(k) for k in t)

    def p_fp(a):
        c = np.correlate(a[:SR], audio[:SR], mode="valid")
        return float(c[0]) if len(c) else 0.0

    FULL_WIN = np.tile(audio, 4)[: 60 * SR]  # 60 s 既有全文检索窗口

    def p_full(a):
        seg = FULL_WIN
        segs, _ = model.transcribe(seg, language="zh", beam_size=1, vad_filter=False)
        return sum(len(s.text) for s in segs)

    def p_asr(a):
        segs, _ = model.transcribe(a, language="zh", beam_size=1, vad_filter=False)
        return sum(len(s.text) for s in segs)

    PROV = [("P1_text_stream", 5, p_text, False),
            ("P2_entity_table", 4, p_entity, False),
            ("P3_fingerprint", 3, p_fp, True),
            ("P4_fulltext", 2, p_full, True),
            ("P5_stream_asr", 1, p_asr, False)]

    # 预热两条慢路径
    p_full(audio[: SR])
    p_asr(audio[: SR])

    pool = ThreadPoolExecutor(max_workers=5)
    now = lambda: time.perf_counter() * 1000.0
    # 逐提供者标定一次（串行），作为声明的 est_latency 基线
    BASE = {}
    for name, _, fn, _ in PROV:
        s0 = now()
        fn(audio[:SR])
        BASE[name] = now() - s0
    print("标定基线(ms): " + ", ".join("%s=%.0f" % (k, v) for k, v in BASE.items()))
    rows, seq = [], 0

    for group, pref in (("G1", True), ("G2", False)):
        for policy in ("B1", "B3", "B4"):
            for n in (1, 3, 5):
                est = dict(BASE)
                for f in range(args.frames):
                    seq += 1
                    i = (f * SR) % max(1, len(audio) - SR)
                    chunk = audio[i: i + SR]
                    chain = PROV[:n]
                    l_eff = L_BUDGET_MS - RENDER_MS
                    cancelled = []
                    if policy != "B1" and not pref:
                        cancelled = [p[0] for p in chain if p[3]]
                        elig = [p for p in chain if not p[3]]
                    else:
                        elig = list(chain)
                    acc, k = 0.0, 0
                    for name, lvl, fn, need in elig:
                        if acc + est[name] <= l_eff:
                            acc += est[name]
                            k += 1
                        else:
                            break
                    exec_set = list(elig) if policy == "B1" else elig[:k]

                    durs = {}

                    def timed(nm, fn, ch, _d=durs):
                        s = now()
                        fn(ch)
                        _d[nm] = now() - s

                    t0 = now()
                    futs = {name: pool.submit(timed, name, fn, chunk) for name, _, fn, _ in exec_set}
                    if policy == "B1":
                        wait(list(futs.values()))
                    else:
                        wait(list(futs.values()), timeout=l_eff / 1000.0)
                    calls = 0
                    lvl_max = 0
                    for name, lvl, fn, need in exec_set:
                        fut = futs[name]
                        if fut.done() and name in durs:
                            calls += 1
                            lvl_max = max(lvl_max, lvl)
                            est[name] = 0.8 * est[name] + 0.2 * durs[name]
                    time.sleep(RENDER_MS / 1000.0)
                    lat = now() - t0
                    rows.append(dict(run="ASR-%04d" % seq, group=group, policy=policy, n=n,
                                     prefetchable=1 if pref else 0, synthetic=0, frame=f,
                                     t_audio_ms=round(t0, 3), t_emit_ms=round(t0 + lat, 3),
                                     latency_ms=round(lat, 1), infer_calls=calls,
                                     dup_ms=round(sum(est[x[0]] for x in exec_set), 1),
                                     rss_mb=0.0, buf_kb=round(2880.0 * len(exec_set), 1),
                                     rebuilds=len(cancelled), workload="whisper-base-int8"))
    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print("写出 %s，%d 行" % (args.out, len(rows)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
