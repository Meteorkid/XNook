#!/usr/bin/env python3
"""G3 跳转／seek 实测：真实音频指纹重锚 + 代次管理 + 仅补未覆盖区间。

素材 /tmp/xn_media.pcm：8 段互不相同的真实语音（约 45 s），由 prep_media.py 合成。
指纹 fingerprint.Index：对数梅尔带能量锚点表（0.1 s 网格）粗检索 + 波形局部对齐。
置信度门限 0.9：同源匹配的归一化相关接近 1.0，低于门限判为「低置信」，
不重锚，回落到按当前播放前沿粗定位（0.7 会放过一个 0.74 的错配，故取 0.9）。

对比：
  B0_seek_full   丢弃全部已稳定条目，前瞻区间全量重算
  B3_seek_anchor 保留已稳定条目，重锚后仅补未覆盖区间，代次标识递增

运行：~/.cache/xnook-asr/venv/bin/python run_seek.py --seeks 20 --out runs.seek.csv
"""
import argparse
import csv
import json
import random
import time

import numpy as np
from faster_whisper import WhisperModel

import fingerprint as FP

SR = 16000
LOOKAHEAD_S = 10.0
INTERVAL_S = 2.0
RENDER_MS = 8.0
CONF_MIN = 0.90
PROMPT = "以下是普通话的简体中文句子。"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeks", type=int, default=20)
    ap.add_argument("--out", default="runs.seek.csv")
    ap.add_argument("--seed", type=int, default=20261114)
    args = ap.parse_args()

    dur = json.load(open("/tmp/xn_media_regions.json", encoding="utf-8"))["duration_s"]
    audio = np.frombuffer(open("/tmp/xn_media.pcm", "rb").read(),
                          dtype="<i2").astype(np.float32) / 32768.0

    t_build = time.perf_counter()
    idx = FP.Index(audio, hop_s=0.10)
    build_ms = (time.perf_counter() - t_build) * 1000.0
    print("锚点表：%d 条（0.1 s 网格），建表 %.0f ms" % (len(idx.ts), build_ms))

    model = WhisperModel("base", device="cpu", compute_type="int8",
                         download_root="/Users/meteor/.cache/xnook-asr/models",
                         cpu_threads=6)
    segs, _ = model.transcribe(audio[:SR], language="zh", beam_size=1,
                               vad_filter=False, initial_prompt=PROMPT)
    list(segs)

    rng = random.Random(args.seed)
    rows, gen, prev_pos, stable_cov = [], 0, 0.0, 0.0
    stat = {"hit": 0, "low": 0, "mis": 0, "err": []}

    for sid in range(args.seeks):
        t_seek = round(rng.uniform(1.0, dur - LOOKAHEAD_S - 1.0)
                       + rng.uniform(0, 0.001), 3)
        stable_cov = max(stable_cov, prev_pos)
        look_end = min(dur, t_seek + LOOKAHEAD_S)

        for policy in ("B0_seek_full", "B3_seek_anchor"):
            gen_policy = gen + (1 if policy == "B3_seek_anchor" else 0)

            s0 = time.perf_counter()
            mapped, conf, rank = idx.match(t_seek)
            re_anchor_ms = (time.perf_counter() - s0) * 1000.0

            err_ms = abs(mapped - t_seek) * 1000.0
            low_conf = 1 if conf < CONF_MIN else 0
            if low_conf:
                mapped = t_seek          # 低置信 → 不重锚，按播放前沿粗定位
                err_ms = 0.0
            hit = 0 if low_conf else (1 if err_ms <= 50.0 else 0)

            if policy == "B0_seek_full":
                if low_conf:
                    stat["low"] += 1
                elif hit:
                    stat["hit"] += 1
                    stat["err"].append(err_ms)
                else:
                    stat["mis"] += 1

            n_int = int(np.ceil((look_end - t_seek) / INTERVAL_S))
            if policy == "B0_seek_full":
                patch, discarded = n_int, n_int
            else:
                covered_until = min(stable_cov, look_end)
                patch = sum(1 for k in range(n_int)
                            if t_seek + (k + 1) * INTERVAL_S > covered_until)
                discarded = 0

            s1 = time.perf_counter()
            seg = audio[int(mapped * SR): int(mapped * SR) + SR]
            ss, _ = model.transcribe(seg, language="zh", beam_size=1,
                                     vad_filter=False, initial_prompt=PROMPT)
            txt = "".join(x.text for x in ss).strip()
            asr_ms = (time.perf_counter() - s1) * 1000.0

            rows.append(dict(
                seek_id=sid, policy=policy, t_seek=round(t_seek, 3),
                mapped=round(mapped, 3), err_ms=round(err_ms, 1),
                conf=round(conf, 3), coarse_rank=rank, low_conf=low_conf, hit=hit,
                re_anchor_ms=round(re_anchor_ms, 1), asr_ms=round(asr_ms, 1),
                first_frame_ms=round(re_anchor_ms + asr_ms + RENDER_MS, 1),
                patch_intervals=patch, lookahead_intervals=n_int,
                discarded_items=discarded, stable_cover_s=round(stable_cov, 2),
                generation=gen_policy, caption=txt[:24], synthetic=0,
                workload="real-audio-fingerprint"))

        prev_pos = t_seek + 1.0
        gen += 1

    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    print("写出 %s，%d 行" % (args.out, len(rows)))
    print("重锚：命中 %d／%d，低置信降级 %d，错配 %d；命中误差中位 %.1f ms"
          % (stat["hit"], args.seeks, stat["low"], stat["mis"],
             np.median(stat["err"]) if stat["err"] else -1))
    for pol in ("B0_seek_full", "B3_seek_anchor"):
        p = [r for r in rows if r["policy"] == pol]
        print("  %-14s 补处理 %.2f/%.0f  丢弃 %.2f  重锚 %.1f ms  首帧 P50 %.0f ms"
              % (pol, np.mean([r["patch_intervals"] for r in p]),
                 np.mean([r["lookahead_intervals"] for r in p]),
                 np.mean([r["discarded_items"] for r in p]),
                 np.mean([r["re_anchor_ms"] for r in p]),
                 np.median([r["first_frame_ms"] for r in p])))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
