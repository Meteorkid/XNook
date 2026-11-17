#!/usr/bin/env python3
"""音频指纹：两级匹配（对数梅尔带能量粗检索 + 波形局部对齐细补偿）。

为什么不用时域波形直接点乘：锚点表按 0.25 s 网格建立，跳转点一般落在两格之间，
50 ms 的错位会让时域波形的归一化相关从 1.0 掉到 0 附近——匹配不可用。
对数梅尔带能量对 50 ms 内的时移不敏感，适合做候选检索；
命中后再在候选位置 ±0.4 s 内用波形互相关做 0.125 ms 级对齐。
"""
import numpy as np

SR = 16000
FP_SR = 8000
NFFT = 512
HOP = 80            # 8 kHz 下 10 ms
NBAND = 32


def mel_bands(n_fft=NFFT, sr=FP_SR, nband=NBAND):
    def hz2mel(f):
        return 2595.0 * np.log10(1.0 + f / 700.0)

    def mel2hz(m):
        return 700.0 * (10.0 ** (m / 2595.0) - 1.0)

    fmax = sr / 2
    pts = mel2hz(np.linspace(hz2mel(80.0), hz2mel(fmax), nband + 2))
    bins = np.floor((n_fft + 1) * pts / sr).astype(int)
    fb = np.zeros((nband, n_fft // 2 + 1), dtype=np.float32)
    for b in range(nband):
        l, c, r = bins[b], bins[b + 1], bins[b + 2]
        if c == l:
            c = l + 1
        if r <= c:
            r = c + 1
        fb[b, l:c] = np.linspace(0, 1, c - l, endpoint=False)
        fb[b, c:r] = np.linspace(1, 0, r - c, endpoint=False)
    return fb


_FB = mel_bands()


def logmel(x):
    """返回 (帧数, NBAND) 的对数梅尔带能量。"""
    n = 1 + max(0, (len(x) - NFFT) // HOP)
    idx = np.arange(NFFT)[None, :] + HOP * np.arange(n)[:, None]
    frames = x[idx] * np.hanning(NFFT).astype(np.float32)
    spec = np.abs(np.fft.rfft(frames, axis=1)).astype(np.float32) ** 2
    e = spec @ _FB.T
    return np.log(e + 1e-8)


def znorm(v):
    return (v - v.mean()) / (v.std() + 1e-9)


class Index:
    """锚点表：网格上存对数梅尔指纹，附绝对源时间戳。"""

    def __init__(self, audio16k, hop_s=0.25, win_s=0.5):
        self.fp = audio16k[: len(audio16k) // 2 * 2].reshape(-1, 2).mean(axis=1)
        self.win = int(win_s * FP_SR)
        self.hop = hop_s
        ts, vecs = [], []
        t = 0.0
        dur = len(self.fp) / FP_SR
        while t + win_s <= dur:
            i = int(t * FP_SR)
            vecs.append(znorm(logmel(self.fp[i:i + self.win]).ravel()))
            ts.append(t)
            t += hop_s
        self.A = np.vstack(vecs)
        self.ts = np.array(ts)

    def match(self, t_query, topk=20, fine_span_s=0.4):
        """返回 (mapped_s, score_norm, rank)；score_norm ∈ [-1,1]，>0.3 视为可信。"""
        qi = int(t_query * FP_SR)
        q = znorm(logmel(self.fp[qi:qi + self.win]).ravel())
        s = self.A @ q
        order = np.argsort(-s)[:topk]
        qw = znorm(self.fp[qi:qi + self.win])
        best_off, best_c, best_rank = -1, -2.0, 0
        for rank, k in enumerate(order):
            c0 = int(self.ts[k] * FP_SR)
            lo = max(0, c0 - int(fine_span_s * FP_SR))
            hi = min(len(self.fp) - self.win, c0 + int(fine_span_s * FP_SR))
            if hi <= lo:
                continue
            reg = self.fp[lo:hi + self.win]
            c = np.correlate(reg, qw, mode="valid") / self.win
            j = int(np.argmax(c))
            seg = reg[j:j + self.win]
            cc = float(c[j]) / (seg.std() + 1e-9)
            if cc > best_c:
                best_c, best_off, best_rank = cc, lo + j, rank
        if best_off < 0:
            return float(self.ts[order[0]]), -1.0, 0
        return best_off / FP_SR, best_c, best_rank
