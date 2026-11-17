#!/usr/bin/env python3
"""生成说明书附图：每图一页 A4，黑白线条；另合并为 说明书附图.pdf。"""
import os
import sys

from reportlab.pdfgen import canvas

import figlib
from figlib import PAGE_H, PAGE_W, new_page
import figs_a
import figs_b

FIGS = [
    ("图 1  系统总体架构图", figs_a.fig1),
    ("图 2  证据优先级链与快慢路径分离图", figs_a.fig2),
    ("图 3  首帧时限时序图", figs_a.fig3),
    ("图 4  可预取性剪枝决策图", figs_a.fig4),
    ("图 5  收敛状态转换图", figs_b.fig5),
    ("图 6  绝对源时间戳与切换边界示意图", figs_b.fig6),
    ("图 7  seek 重锚与未覆盖区间补处理流程图", figs_b.fig7),
    ("图 8  装置模块框图", figs_b.fig8),
]


def draw(c, fn, title, page_no):
    f = new_page(c, title, page_no)
    fn(f)
    f.finish()
    return f


def main():
    os.makedirs("figs", exist_ok=True)
    for i, (title, fn) in enumerate(FIGS, 1):
        p = "figs/fig%d.pdf" % i
        c = canvas.Canvas(p, pagesize=(PAGE_W * figlib.MM, PAGE_H * figlib.MM))
        c.setTitle(title)
        draw(c, fn, title, i)
        c.showPage()
        c.save()
        print("写出", p)

    c = canvas.Canvas("说明书附图.pdf", pagesize=(PAGE_W * figlib.MM, PAGE_H * figlib.MM))
    c.setTitle("说明书附图（图 1–图 8）")
    for i, (title, fn) in enumerate(FIGS, 1):
        draw(c, fn, title, i)
        c.showPage()
    c.save()
    print("写出 说明书附图.pdf（%d 页）" % len(FIGS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
