#!/usr/bin/env python3
"""把 10-submission 下的定稿文本编译为提交用 PDF。

版式：A4；页边距 上25 左25 右15 下15 mm；正文 12pt、行距 1.5；
页码在页脚居中（LaTeX 默认）；每份文件独立编页。
"""
import os
import re
import subprocess
import sys

PANDOC = "pandoc"
FONT = "Songti SC"
GEOM = "left=25mm,right=15mm,top=25mm,bottom=15mm"


def sh(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        raise SystemExit("失败: " + cmd)
    return r.stdout


def check_glyphs(log_text, name):
    """XeTeX 缺字时只打 warning 并静默丢弃，这里把它升级为硬错误。"""
    bad = [l for l in log_text.splitlines() if "Missing character" in l]
    if bad:
        for l in bad[:20]:
            print("   " + l.strip())
        raise SystemExit("%s 有 %d 处缺字，拒绝产出" % (name, len(bad)))


def crop_figure(src_pdf, out_png, dpi=300, cut=0.945):
    """把单页附图 PDF 栅格化为 PNG，去掉页脚页码与空白边。

    附图页含两项：图下方的图号（保留）与页脚「第 N 页」（摘要附图不需要）。
    页码在 y≈290/297 处，故按高度百分比切掉底部。
    """
    from PIL import Image

    sh("pdftoppm -r %d -f 1 -l 1 -png -singlefile %r _fig" % (dpi, src_pdf))
    im = Image.open("_fig.png").convert("L")
    w, h = im.size
    im = im.crop((0, 0, w, int(h * cut)))
    box = im.point(lambda v: 0 if v > 245 else 255).getbbox()
    if not box:
        raise SystemExit("附图栅格化后为空白")
    pad = 12
    im = im.crop((max(box[0] - pad, 0), max(box[1] - pad, 0),
                  min(box[2] + pad, im.size[0]), min(box[3] + pad, im.size[1])))
    im.save(out_png)
    print("摘要附图 %dx%d px（已切去页脚与白边）" % im.size)
    return im.size


def pages(pdf):
    out = sh("pdfinfo %r | grep '^Pages:'" % pdf)
    return int(re.search(r"Pages:\s+(\d+)", out).group(1))


def build(md, out, title, toc=False):
    cmd = (
        "%s %r -o %r --pdf-engine=tectonic "
        "-V mainfont='%s' -V CJKmainfont='%s' -V monofont='Menlo' "
        "-V CJKmonofont='%s' -V fontsize=10.5pt -V linestretch=1.5 "
        "-V papersize=a4 -V geometry:'%s' -V colorlinks=false -V documentclass=article "
        "-H header.tex -V lang=zh-CN"
        % (PANDOC, md, out, FONT, FONT, FONT, GEOM)
    )
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    check_glyphs(r.stderr, out)
    if r.returncode != 0:
        print(r.stdout)
        print(r.stderr)
        raise SystemExit("失败: " + cmd)
    return pages(out)


def main():
    os.chdir(os.path.dirname(os.path.abspath(__file__)))

    # 摘要附图：图 1 栅格化后切去页脚页码，嵌入独立一页
    crop_figure("../08-figures/figs/fig1.pdf", "fig1.png")
    abstract = open("说明书摘要.md", encoding="utf-8").read().strip()
    abstract = abstract.replace("# 说明书摘要\n\n", "")
    open("_abstract.md", "w", encoding="utf-8").write(
        "# 说明书摘要\n\n" + abstract +
        "\n\n\\newpage\n\n\\begin{center}\n"
        "\\includegraphics[width=15cm]{%s}\n\\end{center}\n" % os.path.abspath("fig1.png")
    )

    n_abs = build("_abstract.md", "02-说明书摘要.pdf", "说明书摘要")

    # 装置独立权利要求另起一页，避免同上位方法权项跨页截断
    _cl_src = open("权利要求书.md", encoding="utf-8").read()
    _cl_src = re.sub(
        r"(?m)^(\*\*\d+\.\*\* 一种[^\n]{0,40}?装置，其特征在于)",
        "\\\\newpage\n\n\\1", _cl_src)
    open("_claims.md", "w", encoding="utf-8").write(_cl_src)
    n_clm = build("_claims.md", "03-权利要求书.pdf", "权利要求书")
    n_spec = build("说明书.md", "04-说明书.pdf", "说明书")

    # 说明书附图：直接沿用已校验的 8 页线条图
    sh("cp ../08-figures/说明书附图.pdf 05-说明书附图.pdf")
    n_fig = pages("05-说明书附图.pdf")

    n_claims = len(re.findall(r"^\*\*(\d+)\.\*\* ", open("权利要求书.md", encoding="utf-8").read(), re.M))
    # 独立权利要求 = 不以「根据权利要求…」起头的项，逐项解析，不写死编号
    _cl = open("权利要求书.md", encoding="utf-8").read()
    indep = [int(n) for n, body in re.findall(r"^\*\*(\d+)\.\*\* (.+?)(?=\n\n\*\*\d+\.\*\*|\Z)", _cl, re.M | re.S)
             if "根据权利要求" not in body[:40]]
    over = max(n_claims - 10, 0) * 150   # 第 11 项起每项 150 元，且不可减缴
    n_total = n_spec + n_fig             # 说明书附加费按「说明书（包括附图）」合计页数计
    n_excess = max(n_total - 30, 0)
    overpage = n_excess * 50             # 第 31 页起每页 50 元，且不可减缴

    req = """# 发明专利请求书要素表

> 本表**不是**国家知识产权局的官方表格，仅列出录入官方电子申请系统时所需的要素，
> 供代理师或申请人逐项核对后填入官方客户端。标注「待填写」者须由申请人提供。

| 项目 | 内容 |
| :--- | :--------------- |
| 申请类型 | 发明专利申请 |
| 发明名称 | 一种基于证据优先级链的系统级实时字幕调度方法及装置 |
| 申请人 | 待填写（姓名或名称、地址、邮政编码、国籍或注册国家） |
| 发明人 | 刘鑫宇（其余发明人待填写） |
| 联系人 | 待填写（姓名、地址、邮编、电话、邮箱） |
| 代理机构 / 代理师 | 待填写 |
| 是否委托专利代理机构 | 待定 |
| 权利要求项数 | %d 项（独立权利要求 %d 项：第 %s 项；从属权利要求 %d 项） |
| 说明书页数 | %d 页 |
| 说明书摘要页数 | %d 页（含摘要附图） |
| 说明书附图页数 | %d 页（图 1 至图 8） |
| 摘要附图 | 图 1（系统总体架构图） |
| 是否请求实质审查 | 是 |
| 是否请求提前公开 | 待定 |
| 费用减缴请求 | **建议提出**（个人可减 85%%，需在提交前完成费减备案） |
| 序列表 / 生物材料 / 遗传资源 | 不适用 |
| 优先权要求 | 无（本申请为首次申请） |
| 分案申请 | 否 |
| 附件 | 说明书摘要、权利要求书、说明书、说明书附图（共 4 份文件） |

## 费用预估（按 2024 年现行标准，单位：元）

| 项目 | 全额 | 费减 85%% 后 | 说明 |
| --- | --- | --- | --- |
| 申请费 | 900 | 135 | 不含申请附加费与公布印刷费 |
| 公布印刷费 | 50 | 50 | 与申请费同时缴纳，**不属可减缴范围** |
| 申请附加费（超项） | %d | %d | 第 11 项起每项 150 元，**不属可减缴范围** |
| 申请附加费（超页） | %d | %d | 说明书 %d 页＋附图 %d 页＝%d 页，超出 30 页 %d 页，每页 50 元，**不属可减缴范围** |
| 实质审查费 | 2500 | 375 | 可与申请费一并缴，也可进入实审前缴 |
| **合计** | **%d** | **%d** | |

- 减缴依据《专利收费减缴办法》第三条：可减缴的是申请费（不含公布印刷费、**申请附加费**）、实审费、年费、复审费。
- 本稿 %d 项权利要求，未超过 10 项，**无超项附加费**。若日后增项，第 11 项起每项 150 元且**不可减缴**，增 8 项即多付 1200 元。
- 超页附加费按「说明书（**包括附图**）」合计页数计：现为说明书 %d 页＋附图 %d 页＝%d 页，超出 %d 页，计 %d 元。
- 排版口径已按《专利审查指南》第一部分第一章 5 的口径选定：宋体、**五号（10.5pt，字高约 3.7 mm，落在 3.5–4.5 mm 区间内）**、1.5 倍行距、四边留白 25/25/15/15 mm。
  2026-11-15 由小四（12pt）改为五号，只改排版、不改一个字，说明书由 32 页降到 %d 页，省下 450 元超页费。
- 若要把剩下的 %d 元也省掉，唯一办法是**把 8 幅附图并为 4 页**（每页两图、彼此明显分开），附图由 8 页降为 4 页。
  此项**未执行**：附图已按每图一页校验过线条与图号位置，合并需重做版式，收益仅 %d 元，建议由代理师决定。
- 费减须**在提交申请前**完成费减条件备案，未备案不能事后补办。
- 2026-11-15 已按申请人决定由 18 项压缩至 %d 项：删去计算机程序产品权项与 5 项从权，省下超项附加费 1200 元。被删内容全部保留在说明书中，答复审查意见时仍可上提。

## 提交前必须完成的事项

1. `docs/` 下全部技术草稿**不得**推送到公开仓库，提交前移入私有目录。
2. 请求书中「待填写」项全部补齐。
3. 附图已按《专利审查指南》第一部分第一章 4.3 处理：图号标注于各图正下方、无框线、无注释、黑白线条。
4. 本套 PDF 由 `extract.py` + `build.py` 生成；母本 `docs/PATENT-APPLICATION-证据优先级链字幕调度.md` 未改动，
   派生步骤见 `转换记录.md`。
""" % (n_claims, len(indep), "、".join(str(i) for i in indep),
       n_claims - len(indep), n_spec, n_abs, n_fig,
       over, over, overpage, overpage, n_spec, n_fig, n_total, n_excess,
       900 + 50 + over + overpage + 2500, 135 + 50 + over + overpage + 375,
       n_claims, n_spec, n_fig, n_total, n_excess, overpage,
       n_spec, overpage, overpage, n_claims)

    open("01-请求书要素表.md", "w", encoding="utf-8").write(req)
    build("01-请求书要素表.md", "01-请求书要素表.pdf", "请求书要素表")

    print("说明书摘要 %d 页 / 权利要求书 %d 页 / 说明书 %d 页 / 附图 %d 页"
          % (n_abs, n_clm, n_spec, n_fig))
    print("权利要求 %d 项，其中独立 %d 项" % (n_claims, len(indep)))

    for tmp in ("_abstract.md", "_fig.png", "_claims.md"):
        if os.path.exists(tmp):
            os.remove(tmp)
    return 0


if __name__ == "__main__":
    sys.exit(main())
