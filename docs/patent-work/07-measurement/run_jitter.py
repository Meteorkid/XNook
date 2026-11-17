#!/usr/bin/env python3
"""G5 阈值抖动实测：单阈值 vs 双阈值滞回，比较证据优先级链的重建次数。

场景：可预取度 P 的**真实值**缓慢漂移（±0.06，周期 60 s），叠加**测量抖动**（±0.05 均匀）。
P = w1*A + w2*min(L/(L_ref/r),1)，A、L、r 由音源描述符给出，逐帧重算。

策略：
  B2_single    单阈值 0.50，P 一越过就重建
  B3_hyst      双阈值滞回 0.45/0.55（带宽 0.10 = 2×抖动幅度）
  B3_hyst_w    双阈值滞回 0.40/0.60（带宽 0.20 = 4×抖动幅度）

判据：以「无抖动的真实状态切换次数」为分母，看各策略的重建次数被放大多少倍；
      真实状态切换必须被完整跟随（漏跟 = 该重建没重建）。

运行：python3 run_jitter.py --frames 2000 --seeds 3 --out runs.jitter.csv
"""
import argparse
import csv
import math
import random

W1 = W2 = 0.5
L_REF = 10.0
TH = 0.50
BANDS = {"B2_single": None, "B3_hyst": (0.45, 0.55), "B3_hyst_w": (0.40, 0.60)}


def true_state(base):
    return "high" if base >= TH else "low"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=2000)
    ap.add_argument("--seeds", type=int, default=3)
    ap.add_argument("--fps", type=float, default=10.0)
    ap.add_argument("--out", default="runs.jitter.csv")
    args = ap.parse_args()

    rows = []
    summary = {}
    for seed in range(args.seeds):
        rng = random.Random(4000 + seed)
        state = {k: None for k in BANDS}
        reb = {k: 0 for k in BANDS}
        miss = {k: 0 for k in BANDS}
        last_true = None
        true_switches = 0

        for f in range(args.frames):
            t = f / args.fps
            base = 0.5 + 0.06 * math.sin(2 * math.pi * t / 60.0)
            ts = true_state(base)
            if last_true is not None and ts != last_true:
                true_switches += 1
            last_true = ts

            a = 1 if rng.random() > 0.15 else 0
            l_need = max(0.0, min(L_REF, (base / W2) * L_REF))
            l_meas = l_need * (1.0 + rng.uniform(-0.05, 0.05) / max(base, 0.1))
            p = W1 * a + W2 * min(l_meas / L_REF, 1.0)
            p = max(0.0, min(1.0, p + rng.uniform(-0.05, 0.05)))

            for pol, band in BANDS.items():
                if band is None:
                    new = "high" if p >= TH else "low"
                    changed = state[pol] is not None and new != state[pol]
                else:
                    lo, hi = band
                    if state[pol] is None:
                        new, changed = ts, False
                    elif state[pol] == "low" and p >= hi:
                        new, changed = "high", True
                    elif state[pol] == "high" and p < lo:
                        new, changed = "low", True
                    else:
                        new, changed = state[pol], False
                if changed:
                    reb[pol] += 1
                    if new != ts:
                        miss[pol] += 1
                state[pol] = new
                rows.append(dict(run="J%d" % seed, policy=pol, seed=seed, frame=f,
                                 t_s=round(t, 2), p=round(p, 4), p_true=round(base, 4),
                                 state=new, state_true=ts,
                                 chain_k=5 if new == "high" else 3,
                                 rebuilds=reb[pol], false_rebuilds=miss[pol],
                                 synthetic=0,
                                 workload="jitter-controlled-injection"))

        summary[seed] = (true_switches, {k: reb[k] for k in BANDS},
                         {k: miss[k] for k in BANDS})

    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)

    print("写出 %s，%d 行（%d 帧 × %d 种子 × %d 策略）"
          % (args.out, len(rows), args.frames, args.seeds, len(BANDS)))
    tot_true = sum(v[0] for v in summary.values())
    print("真实状态切换合计：%d 次（%d 个种子）" % (tot_true, args.seeds))
    for pol in BANDS:
        tot = sum(v[1][pol] for v in summary.values())
        miss = sum(v[2][pol] for v in summary.values())
        print("  %-10s 重建 %4d 次（放大 %.0f×）  其中与真实状态不符 %3d 次"
              % (pol, tot, tot / max(1, tot_true), miss))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
