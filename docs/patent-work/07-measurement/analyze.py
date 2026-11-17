#!/usr/bin/env python3
"""G1-G5 测量数据分析器（仅标准库）。

输入 : runs.csv（字段见 README.md）
输出 : 终端 Markdown 表 + summary.md

判定口径（写进说明书前必须满足）：
  G1/G2 中，本方案（B3/B4）在全部 N 下的最大首帧延迟 <= L_budget + 2*渲染余量（316 ms），
  即上界与来源数无关；基线 B1（不剪枝、等全部来源）必然越界。斜率仅作参考。
"""
import csv
import os
import sys
from collections import defaultdict


def pct(vals, q):
    if not vals:
        return float("nan")
    v = sorted(vals)
    k = max(0, min(len(v) - 1, int(round(q * (len(v) - 1)))))
    return v[k]


def mean(vals):
    return sum(vals) / len(vals) if vals else float("nan")


def slope(xs, ys):
    n = len(xs)
    if n < 2:
        return float("nan")
    mx, my = mean(xs), mean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    if den == 0:
        return float("nan")
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den


def load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            r = {(k or "").strip(): (v or "").strip() for k, v in r.items()}
            if not r.get("latency_ms"):
                continue
            for k in ("latency_ms", "infer_calls", "dup_ms", "rss_mb", "buf_kb",
                      "rebuilds", "n", "t_audio_ms", "t_emit_ms"):
                r[k] = float(r[k])
            r["n"] = int(r["n"])
            rows.append(r)
    return rows


def main(path):
    rows = load(path)
    if not rows:
        sys.exit("runs.csv 为空或字段缺失")
    grid = defaultdict(lambda: defaultdict(list))
    for r in rows:
        grid[(r["group"], r["policy"], r["n"])]["lat"].append(r["latency_ms"])
        grid[(r["group"], r["policy"], r["n"])]["inf"].append(r["infer_calls"])
        grid[(r["group"], r["policy"], r["n"])]["dup"].append(r["dup_ms"])
        grid[(r["group"], r["policy"], r["n"])]["rss"].append(r["rss_mb"])
        grid[(r["group"], r["policy"], r["n"])]["buf"].append(r["buf_kb"])
        grid[(r["group"], r["policy"], r["n"])]["reb"].append(r["rebuilds"])

    out = ["| 组 | 方案 | N | 样本 | P50 ms | P95 ms | 推理调用 | 重复转写 s | 峰值 RSS MB | 缓冲 KB | 链重建 |",
           "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    series = defaultdict(list)
    for key in sorted(grid, key=lambda k: (k[0], k[1], k[2])):
        g, p, n = key
        d = grid[key]
        p95 = pct(d["lat"], 0.95)
        out.append("| {} | {} | {} | {} | {:.0f} | {:.0f} | {:.1f} | {:.1f} | {:.0f} | {:.0f} | {:.1f} |".format(
            g, p, n, len(d["lat"]), pct(d["lat"], 0.50), p95,
            mean(d["inf"]), mean(d["dup"]) / 1000.0, max(d["rss"]), mean(d["buf"]), mean(d["reb"])))
        series[(g, p)].append((n, p95, max(d["lat"])))

    verdict = ["", "## 上界判定（首帧延迟是否被 L_budget 约束）", "",
               "| 组 | 方案 | P95 斜率 ms/来源 | 最大延迟 ms | 判定 |", "| --- | --- | --- | --- | --- |"]
    ok = True
    bound = 300.0 + 16.0
    for (g, p), pts in sorted(series.items()):
        if g not in ("G1", "G2") or len(pts) < 2:
            continue
        sl = slope([x[0] for x in pts], [x[1] for x in pts])
        mx = max(x[2] for x in pts)
        if p in ("B3", "B4"):
            good = mx <= bound
            tag = "PASS（上界与 N 无关）" if good else "FAIL（越界 %.0f ms）" % mx
            ok = ok and good
        else:
            tag = "基线越界（符合预期）" if mx > bound else "异常（基线未越界，检查负载）"
        verdict.append("| {} | {} | {:.1f} | {:.0f} | {} |".format(g, p, sl, mx, tag))

    text = "\n".join(out + verdict)
    print(text)
    if any(r.get("synthetic") == "1" for r in rows):
        print("\n> 警告：输入含 synthetic=1 的合成样本，仅用于验证脚本可运行，"
              "**不得**作为实测数据写入说明书。")
    with open("summary.md", "w", encoding="utf-8") as f:
        f.write("# G1-G5 分析摘要\n\n" + text + "\n")
    print("\n已写出 summary.md")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "runs.csv"))
