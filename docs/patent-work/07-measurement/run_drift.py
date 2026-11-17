#!/usr/bin/env python3
"""G4 长时漂移：连续 2 小时音频时间，字幕相对音频的偏移是否累积。

**性质：参数注入的机理验证，不是硬件时钟实测。**
本机无法在不接外部音频设备的情况下测得真实晶振偏差，故按常见值注入：
  eps = +100 ppm（廉价晶振最坏值）、-50 ppm（典型值）。
测的是「同一注入下，不同时间戳实现方式会不会把偏差累积成可听偏移」。

三种实现：
  A_cumulative      每帧按标称帧长递增播放位置（不看采样计数）
  B_abs_ts          播放位置 = 已播放采样计数 / 采样率（绝对源时间戳）
  C_abs_ts_cal      在 B 上叠加每 30 s 一次的偏斜标定，用估计值 eps_hat 修正

偏移 = 管道认为的播放位置 － 真实播放位置。每 10 分钟音频时间采样一次。

运行：python3 run_drift.py --hours 2 --out runs.drift.csv
"""
import argparse
import csv
import random

TICK_MS = 20.0
SR = 16000
CAL_INTERVAL_S = 30.0
SAMPLE_EVERY_S = 600.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hours", type=float, default=2.0)
    ap.add_argument("--out", default="runs.drift.csv")
    ap.add_argument("--skews", default="100,-50")
    args = ap.parse_args()

    total_s = args.hours * 3600.0
    ticks = int(total_s / (TICK_MS / 1000.0))
    rows = []
    rng = random.Random(20261114)
    CAL_NOISE_PPM = 10.0          # 标定精度：两钟差在 30 s 窗口内的估计误差

    for eps_ppm in [float(x) for x in args.skews.split(",")]:
        eps = eps_ppm * 1e-6
        # A：按标称帧长递增；B：采样计数；C：采样计数 + 周期标定修正
        pos_a = pos_b = pos_c = 0.0
        eps_hat = 0.0
        t_cal, a_cal = 0.0, 0.0
        next_sample = 7.0     # 采样点错开标定时刻，否则每次采样都恰好落在刚标定完的瞬间
        for i in range(1, ticks + 1):
            t_sys = i * TICK_MS / 1000.0                 # 系统时钟
            a_true = t_sys * (1.0 + eps)                 # 真实音频位置（受偏斜影响）
            pos_a += TICK_MS / 1000.0                    # 标称帧长递增
            pos_b = a_true                               # 采样计数换算
            if t_sys - t_cal >= CAL_INTERVAL_S:          # 周期标定：用区间两钟差估计偏斜
                if t_sys > t_cal:
                    raw = (a_true - a_cal) / (t_sys - t_cal) - 1.0
                    eps_hat = max(-500e-6, min(500e-6,
                                  raw + rng.gauss(0.0, CAL_NOISE_PPM * 1e-6)))
                t_cal, a_cal = t_sys, a_true
            pos_c = a_cal + (t_sys - t_cal) * (1.0 + eps_hat)

            if t_sys >= next_sample or i == ticks:
                for pol, pos in (("A_cumulative", pos_a),
                                 ("B_abs_ts", pos_b),
                                 ("C_abs_ts_cal", pos_c)):
                    rows.append(dict(
                        run="D%+dppm" % int(eps_ppm), policy=pol,
                        eps_ppm=eps_ppm, audio_t_s=round(t_sys, 1),
                        pos_pipeline_s=round(pos, 6),
                        pos_true_s=round(a_true, 6),
                        offset_ms=round((pos - a_true) * 1000.0, 3),
                        cal_eps_ppm=round(eps_hat * 1e6, 2),
                        synthetic=2, workload="skew-injected-model"))
                next_sample += SAMPLE_EVERY_S

    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    print("写出 %s，%d 行（%.0f h 音频时间，采样 %d 次/策略）"
          % (args.out, len(rows), args.hours,
             int(total_s / SAMPLE_EVERY_S) + 1))
    for eps_ppm in [float(x) for x in args.skews.split(",")]:
        print("  注入 %+d ppm：" % int(eps_ppm))
        for pol in ("A_cumulative", "B_abs_ts", "C_abs_ts_cal"):
            v = [r for r in rows if r["policy"] == pol and r["eps_ppm"] == eps_ppm]
            offs = [abs(r["offset_ms"]) for r in v]
            print("    %-13s 末端偏移 %8.1f ms  全程最大 %8.1f ms"
                  % (pol, v[-1]["offset_ms"], max(offs)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
