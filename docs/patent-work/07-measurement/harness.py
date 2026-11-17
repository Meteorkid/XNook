#!/usr/bin/env python3
"""XNook 证据优先级链调度器 · 原型实测台（仅标准库）。

测什么：调度器本身的时延行为——首帧时限 D 到点即渲染、链长按有效预算反解、
        不可达来源注销、证书短路、晚到证据只写未读区间。
不测什么：语音识别准确率。各"证据提供者"的耗时由**真实 CPU 计算**产生
        （sha256 吞吐标定到目标毫秒数），不是 sleep 计时，但也不是真实 ASR。

用法：python3 harness.py --frames 40 --out runs.real.csv
"""
import argparse
import csv
import hashlib
import os
import resource
import sys
import time

L_BUDGET_MS = 300.0
RENDER_MS = 8.0

PROVIDERS = [  # (名称, 证据等级, 目标耗时 ms, 必需可预取)
    ("P1_text_stream", 5, 5.0, False),
    ("P2_entity_table", 4, 8.0, False),
    ("P3_fingerprint", 3, 120.0, True),
    ("P4_frame_ocr", 2, 180.0, True),
    ("P5_stream_asr", 1, 260.0, False),
]
RATE = 1.0


def calibrate():
    buf = b"x" * (16 << 20)
    t0 = time.perf_counter()
    hashlib.sha256(buf).digest()
    dt = time.perf_counter() - t0
    return (16 << 20) / max(dt, 1e-6)


_CHUNK = b"z" * (8 << 20)


def burn(ms):
    """在固定 8 MiB 缓冲上反复哈希，直到累计耗时达到 ms；避免巨量临时分配。"""
    deadline = time.perf_counter() + ms / 1000.0
    while True:
        hashlib.sha256(_CHUNK).digest()
        hashlib.sha256(_CHUNK).digest()
        if time.perf_counter() >= deadline:
            return


def rss_mb():
    """峰值 RSS（MB）。macOS 的 ru_maxrss 单位是字节，Linux 是 KB。"""
    v = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return round(v / (1024.0 * 1024.0) if sys.platform == "darwin" else v / 1024.0, 1)


def now_ms():
    return time.perf_counter() * 1000.0


def schedule(n, policy, prefetchable):
    """执行一帧调度，返回 (latency_ms, calls, dup_ms, buf_kb, cancelled)。"""
    chain = PROVIDERS[:n]
    l_eff = L_BUDGET_MS - RENDER_MS
    cancelled = []

    # 层二：不可预取音源上，要求可预取的来源在调度前注销，不进入候选链
    if policy != "B1" and not prefetchable:
        cancelled = [p[0] for p in chain if p[3]]
        eligible = [p for p in chain if not p[3]]
    else:
        eligible = list(chain)

    # 层一：在"可执行集合"上按有效预算反解链长上界
    acc, k_star = 0.0, 0
    for _, _, cost, _ in eligible:
        if acc + cost <= l_eff:
            acc += cost
            k_star += 1
        else:
            break

    exec_set = list(eligible) if policy == "B1" else eligible[:k_star]
    bufs = [bytearray(2880 * 1024) for _ in exec_set]  # 真实前瞻缓冲分配

    t0 = now_ms()
    calls, dup, level_max, covered = 0, 0.0, 0, 0.0
    for name, lvl, cost, need in exec_set:
        if policy == "B4" and covered >= 0.9 * l_eff and lvl <= level_max:
            continue
        if policy != "B1" and (now_ms() - t0) + cost > l_eff:
            break
        burn(cost)
        calls += 1
        dup += cost
        level_max = max(level_max, lvl)
        covered += cost
        if policy != "B1" and now_ms() - t0 >= l_eff:
            break
    burn(RENDER_MS)
    latency = now_ms() - t0
    buf_bytes = sum(len(b) for b in bufs)
    del bufs
    return latency, calls, dup, buf_bytes / 1024.0, cancelled


def main():
    global RATE
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=40)
    ap.add_argument("--out", default="runs.real.csv")
    args = ap.parse_args()

    RATE = calibrate()
    print("sha256 吞吐标定: %.0f MB/s" % (RATE / 1e6))
    burn(50)  # 预热
    rows, seq = [], 0
    for group, pref in (("G1", True), ("G2", False)):
        for policy in ("B1", "B3", "B4"):
            for n in (1, 2, 3, 5):
                for f in range(args.frames):
                    seq += 1
                    t_audio = now_ms()
                    lat, calls, dup, buf, canc = schedule(n, policy, pref)
                    rows.append(dict(run="REAL-%04d" % seq, group=group, policy=policy,
                                     n=n, prefetchable=1 if pref else 0, synthetic=0,
                                     frame=f, t_audio_ms=round(t_audio, 3),
                                     t_emit_ms=round(t_audio + lat, 3),
                                     latency_ms=round(lat, 3), infer_calls=calls,
                                     dup_ms=round(dup, 1), rss_mb=rss_mb(),
                                     buf_kb=round(buf, 1), rebuilds=len(canc),
                                     workload="cpu-sha256"))
    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print("写出 %s，共 %d 行" % (args.out, len(rows)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
