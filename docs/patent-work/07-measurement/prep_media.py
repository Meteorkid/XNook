#!/usr/bin/env python3
"""准备 G3 用的真实长音频素材。

做法：用 macOS `say` 合成 8 句中文，各自转为 16 kHz/16 bit/单声道 PCM，
首尾相接成一条约 90 s 的媒体，并记录每句的绝对源时间戳区间（regions.json）。

不使用重复拼接同一段音频——重复内容会让音频指纹无法唯一定位，
那样测出来的「重锚命中率」是假的。
"""
import json
import os
import subprocess
import wave

SR = 16000
OUT_PCM = "/tmp/xn_media.pcm"
OUT_META = "/tmp/xn_media_regions.json"

SENTENCES = [
    "第一段，会议开始，请各位把手机调成静音。",
    "第二段，今天的议程有三项，第一项是季度营收回顾。",
    "第三段，华东区的出货量比上季度增长了百分之十七点四。",
    "第四段，李明远负责的语音识别模块已经进入联调阶段。",
    "第五段，这里需要确认一个数字，合同金额是三百八十六万元。",
    "第六段，接下来讨论延迟指标，我们的目标是三百毫秒以内。",
    "第七段，如果证据不足，系统会先用流式识别兜底。",
    "第八段，好，散会，纪要明天上午发出。",
]


def synth(text, path_aiff):
    subprocess.run(["say", "-v", "Tingting", "-r", "180", "-o", path_aiff, text],
                   check=True)


def aiff_to_pcm16(path_aiff, path_wav):
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1",
                    path_aiff, path_wav], check=True)


def main():
    pcm = bytearray()
    regions = []
    t = 0.0
    for i, s in enumerate(SENTENCES):
        a = "/tmp/xn_seg_%d.aiff" % i
        w = "/tmp/xn_seg_%d.wav" % i
        synth(s, a)
        aiff_to_pcm16(a, w)
        with wave.open(w, "rb") as fh:
            assert fh.getframerate() == SR, fh.getframerate()
            assert fh.getnchannels() == 1
            data = fh.readframes(fh.getnframes())
        pcm += data
        dur = len(data) / 2 / SR
        regions.append({"idx": i, "text": s, "t0": round(t, 3),
                        "t1": round(t + dur, 3)})
        t += dur
        # 段间留 0.25 s 静音，模拟自然换气
        pcm += b"\x00\x00" * int(0.25 * SR)
        t += 0.25

    open(OUT_PCM, "wb").write(bytes(pcm))
    json.dump({"sr": SR, "duration_s": round(t, 3), "regions": regions},
              open(OUT_META, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("媒体 %.2f s，%d 段 → %s" % (t, len(SENTENCES), OUT_PCM))
    for r in regions:
        print("  [%6.2f, %6.2f] %s" % (r["t0"], r["t1"], r["text"][:24]))


if __name__ == "__main__":
    main()
