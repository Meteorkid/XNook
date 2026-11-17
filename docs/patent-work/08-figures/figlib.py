"""专利附图绘制工具：黑白线条图，A4 竖向，单位 mm。

只用 reportlab 的底层 canvas 接口，保证输出是可缩放的矢量线条图，
不含灰度填充、阴影、彩色或位图——符合《专利审查指南》对附图的制图要求。
"""
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont

MM = 72.0 / 25.4
PAGE_W, PAGE_H = 210.0, 297.0
MARGIN = 22.0
LW = 0.35                      # 主线宽 mm
FONT = "STSong-Light"

pdfmetrics.registerFont(UnicodeCIDFont(FONT))

# 版面：图区（mm），左上角为原点，y 向下
X0, Y0 = MARGIN, MARGIN
W, H = PAGE_W - 2 * MARGIN, PAGE_H - 2 * MARGIN


class Fig:
    MMf = MM

    def __init__(self, c, title, page_no=1):
        self.c = c
        self.title = title
        self.page_no = page_no
        self.ymax = 0.0          # 图形实际占到的最低点（自上而下，mm）

    # ---------- 基础 ----------
    def _y(self, y):
        """把自上而下的 y(mm) 换成 PDF 自下而上的坐标。"""
        if y > self.ymax:
            self.ymax = y
        return (PAGE_H - (Y0 + y)) * MM

    def finish(self):
        """收尾：图号标在附图正下方，页码标在页面底部居中。

        依据《专利审查指南》第一部分第一章 4.3：「附图总数在两幅以上的，
        应当使用阿拉伯数字顺序编号，并在编号前冠以“图”字……该编号应当
        标注在相应附图的正下方。」
        """
        num = self.title.split("  ")[0]
        y = min(self.ymax + 8.0, 252.0)
        self.text(PAGE_W / 2, y, num, size=9.0, anchor="c")
        # 页码：内容坐标 y=268 → 距页顶 290 mm、距页底 7 mm（边距区内）
        self.text(PAGE_W / 2, 268.0, "第 %d 页" % self.page_no, size=8.0, anchor="c")

    def line(self, x1, y1, x2, y2, dash=None, lw=LW):
        c = self.c
        c.setLineWidth(lw * MM)
        c.setDash(*(dash if dash else ([], 0)))
        c.line(x1 * MM, self._y(y1), x2 * MM, self._y(y2))
        c.setDash([], 0)

    def rect(self, x, y, w, h, lw=LW):
        c = self.c
        c.setLineWidth(lw * MM)
        c.rect(x * MM, self._y(y + h), w * MM, h * MM, stroke=1, fill=0)

    def poly(self, pts, lw=LW):
        p = self.c.beginPath()
        p.moveTo(pts[0][0] * MM, self._y(pts[0][1]))
        for x, y in pts[1:]:
            p.lineTo(x * MM, self._y(y))
        self.c.setLineWidth(lw * MM)
        self.c.drawPath(p, stroke=1, fill=0)

    def path_arrow(self, pts, head=2.2, spread=0.38):
        """正交折线连接，末端带箭头。"""
        for a, b in zip(pts[:-2], pts[1:-1]):
            self.line(a[0], a[1], b[0], b[1])
        self.arrow(pts[-2][0], pts[-2][1], pts[-1][0], pts[-1][1],
                   head=head, spread=spread)

    def arrow(self, x1, y1, x2, y2, dash=None, head=2.2, spread=0.38):
        self.line(x1, y1, x2, y2, dash=dash)
        import math
        dx, dy = x2 - x1, y2 - y1
        L = math.hypot(dx, dy)
        if L < 0.5:
            return
        ux, uy = dx / L, dy / L
        bx, by = -ux * head, -uy * head
        for s in (+1, -1):
            ca, sa = math.cos(s * spread), math.sin(s * spread)
            self.line(x2, y2,
                      x2 + bx * ca - by * sa,
                      y2 + bx * sa + by * ca, lw=LW)

    def circle(self, x, y, r, fill=0):
        self.c.setLineWidth(LW * MM)
        self.c.circle(x * MM, self._y(y), r * MM, stroke=1, fill=fill)

    def text(self, x, y, s, size=7.5, anchor="l", dy=0.0):
        c = self.c
        c.setFont(FONT, size)
        yy = self._y(y) - size * 0.35 + dy
        if anchor == "l":
            c.drawString(x * MM, yy, s)
        elif anchor == "c":
            c.drawCentredString(x * MM, yy, s)
        else:
            c.drawRightString(x * MM, yy, s)

    def wrap(self, s, size, maxw_mm):
        """按毫米宽度断行（CJK 逐字断，ASCII 按空格断）。"""
        out, cur = [], ""
        for ch in s:
            trial = cur + ch
            if pdfmetrics.stringWidth(trial, FONT, size) / MM > maxw_mm:
                if ch in " ，。、；：）】":
                    out.append(trial.strip())
                    cur = ""
                    continue
                cut = cur.rfind(" ")
                if cut > 0 and ord(ch) < 128:
                    out.append(cur[:cut])
                    cur = cur[cut + 1:]
                else:
                    out.append(cur)
                    cur = ""
                cur += ch
            else:
                cur = trial
        if cur:
            out.append(cur)
        return out

    # ---------- 组合元件 ----------
    def box(self, x, y, w, h, lines, size=7.2, mark=None, dash=None, lead=3.6):
        """矩形框 + 居中多行文字；mark 为左上角附图标记。"""
        if dash:
            self.c.setLineWidth(LW * MM)
            self.c.setDash(dash, 0)
            self.c.rect(x * MM, self._y(y + h), w * MM, h * MM, stroke=1, fill=0)
            self.c.setDash([], 0)
        else:
            self.rect(x, y, w, h)
        if isinstance(lines, str):
            lines = lines.split("\n")
        wrapped = []
        for ln in lines:
            if pdfmetrics.stringWidth(ln, FONT, size) / MM > w - 4.0:
                wrapped.extend(self.wrap(ln, size, w - 4.0))
            else:
                wrapped.append(ln)
        lines = wrapped
        n = len(lines)
        start = y + h / 2 - (n - 1) * lead / 2 + 1.2
        for i, ln in enumerate(lines):
            self.text(x + w / 2, start + i * lead, ln, size=size, anchor="c")
        if mark:
            self.text(x + 1.6, y + 3.4, mark, size=7.0, anchor="l")

    def diamond(self, cx, cy, w, h, lines, size=7.2, lead=3.4):
        pts = [(cx, cy - h / 2), (cx + w / 2, cy), (cx, cy + h / 2), (cx - w / 2, cy)]
        p = self.c.beginPath()
        p.moveTo(pts[0][0] * MM, self._y(pts[0][1]))
        for x, y in pts[1:]:
            p.lineTo(x * MM, self._y(y))
        p.close()
        self.c.setLineWidth(LW * MM)
        self.c.drawPath(p, stroke=1, fill=0)
        if isinstance(lines, str):
            lines = lines.split("\n")
        n = len(lines)
        start = cy - (n - 1) * lead / 2
        for i, ln in enumerate(lines):
            self.text(cx, start + i * lead + 1.0, ln, size=size, anchor="c")


def new_page(c, title, page_no):
    """title 形如「图 3  首帧时限时序图」。只建对象，图号与页码在 finish() 中绘制。"""
    c.setLineWidth(0.2 * MM)
    return Fig(c, title, page_no)
