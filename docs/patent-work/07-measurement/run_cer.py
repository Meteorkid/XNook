#!/usr/bin/env python3
"""识别准确率（CER）：真实语音 + 已知文稿，算字错率与实体正确率。

素材：/tmp/xn_media.pcm（8 句，约 45 s，文稿见 /tmp/xn_media_regions.json）。
模型：faster-whisper base，int8，CPU（本机只部署了 base）。

**注意：准确率不是本专利主张的效果。** 权利要求主张的是调度与延迟上界，
本测量只为说明「接入真实识别引擎后系统仍能正常出字」，不作为创造性依据。

两个条件：clean（原始）、snr15（加高斯白噪声到 15 dB，模拟远场拾音）。

运行：~/.cache/xnook-asr/venv/bin/python run_cer.py --out runs.cer.csv
"""
import argparse
import csv
import json

import numpy as np
from faster_whisper import WhisperModel

SR = 16000
PROMPT = "以下是普通话的简体中文句子。"
ENTITIES = ["李明远", "华东区", "语音识别", "三百八十六万", "百分之十七点四", "三百毫秒"]
PUNCT = "，。、；：！？,.;:!? \n\t“”‘’（）()「」"
NUMC = "0123456789.．%％一二三四五六七八九十百千万亿零两"


def norm(s):
    return "".join(c for c in s if c not in PUNCT)


def strip_num(s):
    """去掉数字与数词，用来把「格式差异」与「识别错误」分开。"""
    return "".join(c for c in s if c not in NUMC)


def cer(ref, hyp):
    """字错率 = 编辑距离 / 参考长度（字符级）。"""
    r, h = list(ref), list(hyp)
    prev = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        cur = [i] + [0] * len(h)
        for j in range(1, len(h) + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1,
                         prev[j - 1] + (0 if r[i - 1] == h[j - 1] else 1))
        prev = cur
    return prev[-1] / max(1, len(r))


def add_noise(x, snr_db, rng):
    p_sig = float(np.mean(x ** 2))
    p_noise = p_sig / (10 ** (snr_db / 10.0))
    return np.clip(x + rng.normal(0, np.sqrt(p_noise), len(x)), -1, 1).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="runs.cer.csv")
    ap.add_argument("--models", default="base,small")
    args = ap.parse_args()

    meta = json.load(open("/tmp/xn_media_regions.json", encoding="utf-8"))
    ref_raw = "".join(r["text"] for r in meta["regions"])
    ref = norm(ref_raw)
    audio = np.frombuffer(open("/tmp/xn_media.pcm", "rb").read(),
                          dtype="<i2").astype(np.float32) / 32768.0

    rng = np.random.default_rng(20261114)
    rows = []

    for mname in args.models.split(","):
        model = WhisperModel(mname, device="cpu", compute_type="int8",
                             download_root="/Users/meteor/.cache/xnook-asr/models",
                             cpu_threads=6)
        for cond, sig in (("clean", audio), ("snr15", add_noise(audio, 15.0, rng))):
            segs, info = model.transcribe(sig, language="zh", beam_size=1,
                                          vad_filter=False, initial_prompt=PROMPT)
            txt = "".join(x.text for x in segs).strip()
            hyp = norm(txt)
            e = cer(ref, hyp)
            e2 = cer(strip_num(ref), strip_num(hyp))
            ent_hit = sum(1 for t in ENTITIES if t in hyp)
            rows.append(dict(cond=cond, model="%s-int8" % mname, ref_chars=len(ref),
                             hyp_chars=len(hyp), cer=round(e, 4),
                             cer_nodigit=round(e2, 4),
                             entity_hit=ent_hit, entity_total=len(ENTITIES),
                             ref=ref_raw, hyp=txt, synthetic=0,
                             workload="whisper-%s-int8" % mname))
            print("[%s/%s] 参考 %d 字，CER %.2f%%（去数字口径 %.2f%%），实体 %d/%d"
                  % (mname, cond, len(ref), e * 100, e2 * 100, ent_hit, len(ENTITIES)))
            print("    识别：%s" % txt)

    with open(args.out, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), lineterminator="\n")
        w.writeheader()
        w.writerows(rows)
    print("写出 %s" % args.out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
