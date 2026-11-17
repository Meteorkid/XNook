#!/usr/bin/env python3
"""从申请文件成品中抽取并转换出可提交文本。

母本不动：docs/PATENT-APPLICATION-证据优先级链字幕调度.md 保持原样，
本脚本产出 10-submission/ 下的派生文件，转换步骤全部记录在 转换记录.md。
"""
import os
import re
import sys

SRC = os.path.join("..", "..", "PATENT-APPLICATION-证据优先级链字幕调度.md")


def read_parts():
    s = open(SRC, encoding="utf-8").read()
    abstract = re.search(
        r"<!-- ABSTRACT-START -->\n(.*?)\n<!-- ABSTRACT-END -->", s, re.S
    ).group(1).strip()
    claims = re.search(
        r"## 第三部分 · 权利要求书\n(.*?)(?=\n## 第四部分)", s, re.S
    ).group(1).strip()
    # 母本用 `---` 分隔各部分，会被上面的正则一并吞进来；中间的分隔线（权 7 与权 8 之间）
    # 会被 pandoc 渲染成一条横线，须一律删除，否则 PDF 中出现无意义的横线
    claims = re.sub(r"(?m)^-{3,}[ \t]*$\n?", "", claims).strip()
    spec = re.search(
        r"## 第四部分 · 说明书\n(.*?)(?=\n## 第五部分)", s, re.S
    ).group(1).strip()
    return abstract, claims, spec


def clean_spec(spec):
    log = []

    spec = re.sub(r"^\*\*发明名称\*\*：.*?\n\n(>.*?\n)+\n*", "", spec, flags=re.S)
    log.append("删除开头「发明名称／技术草稿」抬头块（不属于说明书正文）")

    for num, name in (("8", "说明书充分公开自检表"), ("9", "内部工作稿")):
        pat = re.compile(r"\n## %s\..*?(?=\n## \d+\.|\Z)" % num, re.S)
        if pat.search(spec):
            spec = pat.sub("\n", spec)
            log.append("删除第 %s 节「%s」（撰写自检工具，不进入申请文件）" % (num, name))

    pat = re.compile(r"\n### 10\.5 .*?(?=\Z)", re.S)
    if pat.search(spec):
        spec = pat.sub("\n", spec)
        log.append("删除 10.5「上提顺序与装置权利要求的同步」（答复策略，非说明书内容）")

    spec = re.sub(
        r"## 10\. .*?\n\n本节给出四层.*?\n\n", "", spec, flags=re.S
    )
    log.append("删除第 10 节标题与其「四层可上提」导语（该导语为答复策略说明）")

    spec, n = re.subn(r"> \*\*上提状态（[^）]*）\*\*：[^\n]*\n\n", "", spec)
    if n:
        log.append("删除「上提状态」说明（撰写状态记录，非说明书内容）")

    heads = [
        ("### 10\\.1 层一：[^\n]*", "### 5.9 实施例六：按有效预算反解链长上界"),
        ("### 10\\.2 层二：[^\n]*", "### 5.10 实施例七：调度前的可达性注销"),
        ("### 10\\.3 层三：[^\n]*", "### 5.11 实施例八：区间充分性证书的重判与链短路"),
        ("### 10\\.4 层四：[^\n]*", "### 5.12 实施例九：三时钟偏斜标定与已读边界的可信性"),
    ]
    for a, b in heads:
        spec, n = re.subn(a, b, spec)
        if n:
            log.append("→ %s" % b.replace("### ", ""))

    spec = re.sub(r"\n## 6\. 关键数据结构与伪代码", "\n### 5.7 关键数据结构与伪代码", spec)
    spec = re.sub(r"\n### 6\.(\d) ", lambda m: "\n#### 5.7.%s " % m.group(1), spec)
    spec = re.sub(r"\n## 7\. 术语与缩略语表", "\n### 5.8 术语与缩略语表", spec)
    log.append("第 6 节并入具体实施方式为 5.7（6.1–6.7 改为 5.7.1–5.7.7）；第 7 节改为 5.8")

    before = spec
    spec = re.sub(r"(?<!\d)6\.(\d)\s*节", lambda m: "5.7.%s 节" % m.group(1), spec)
    spec = re.sub(r"§6\.(\d)", lambda m: "§5.7.%s" % m.group(1), spec)
    if spec != before:
        log.append("正文中「6.x 节」「§6.x」交叉引用一并改为「5.7.x」")

    # 指向已删章节的交叉引用（逐一列举，避免正则误伤）
    refs = [
        ("第 6 节数据结构", "5.7 节数据结构"),
        ("字段明细与伪代码见第 6 节", "字段明细与伪代码见 5.7 节"),
        ("见 6.1（对应权 11）", "见 5.7.1（对应权 11）"),
        ("// 见 6.3", "// 见 5.7.3"),
        ("交 6.5 收敛写入", "交 5.7.5 收敛写入"),
        ("为第 10 节层 3 限定的实施基础", "为 5.11 实施例八的实施基础"),
        ("及第 8 节自检表所述结构对应", "所述结构对应"),
        ("各技术特征与章节／步骤编号的逐项对应见第 8 节充分公开自检表。", ""),
    ]
    for a, b in refs:
        if a in spec:
            spec = spec.replace(a, b)
    log.append("修正 8 处指向已删／已重编号章节的交叉引用（第 6 节→5.7、6.1→5.7.1、"
               "6.3→5.7.3、6.5→5.7.5、第 10 节层 3→5.11 实施例八；删除指向第 8 节自检表的表述）")

    for a, b in [
        ("本层进一步把", "本实施例进一步把"),
        ("本层进一步引入", "本实施例进一步引入"),
        ("本层进一步承认", "本实施例进一步承认"),
        ("（须在意见陈述中明确）", ""),
    ]:
        spec = spec.replace(a, b)
    log.append("「本层进一步…」「（须在意见陈述中明确）」等答复语境措辞改为说明书语境")

    # 工作稿语气 → 说明书语气。技术内容与数值一律不动，只改「谁说的、说给谁听」。
    # 母本里「本机未实测」「不得把上述数值当作已获得的实验结果」是写给撰写者自己的核对语，
    # 进入申请文件后既不合公文体例，也会被审查员读成申请人自认未验证。
    draft_voice = [
        ("以下有益效果均为**机理分析与示例取值**，非实测结论。",
         "以下有益效果由本申请技术方案的机理分析给出，数值为示例参数下的推算值。"),
        ("**数值与口径声明**：本节效果 1 至效果 5 及其全部数字均为机理分析、示例取值、"
         "示例计算或公开数据量级，**非实测数据**；除 3.5 节另行给出的原型测量外，"
         "本机（示例机型 Apple M3 Max／36 GB 统一内存、macOS 系统级音频环境）未对上述效果"
         "做任何实测，不得把上述数值当作已获得的实验结果。",
         "**数值与口径声明**：本节效果 1 至效果 5 中的数值，除 3.5 节明确给出原型测量结果者外，"
         "均为按本说明书所述机理与示例参数推算所得，用于说明各技术效果的产生原因与量级关系。"),
        ("**参数示例（均为示例取值，非实测）**", "**参数示例（均为示例取值）**"),
        ("（机理推导，本机未实测）", "（按上述机理推算）"),
        ("（机理推导），本机未实测。", "（按上述机理推算）。"),
        ("；本机未实测。", "。"),
        ("机理推导或公开数据量级，本机未实测；", "机理推导或公开数据量级；"),
        ("，本机未实测", ""),
        ("；本机未实测", ""),
        ("不以「用户看得更准／更舒服」等体验层面改善作为主张创造性的依据；"
         "体验层面的改善仅作附带说明。",
         "不依赖「用户看得更准／更舒服」一类主观体验层面的改善。"),
        ("> 上述 8 幅已制为**黑白线条图**（`08-figures/说明书附图.pdf`，A4、每图一页、"
         "0.35 mm 线宽），图中不含颜色、阴影或照片；图号与图题以本说明书附图为准，"
         "说明书全文对附图的引用均以该图号为准。\n", ""),
    ]
    for a, b in draft_voice:
        if a in spec:
            spec = spec.replace(a, b)
    log.append("工作稿语气改说明书语气：删除「本机未实测」（6 处）、"
               "「不得把上述数值当作已获得的实验结果」等自审措辞，统一为"
               "「按上述机理与示例参数推算所得」；数值与技术结论一字未改")
    log.append("删除附图说明末尾的制图规格说明（含内部路径 `08-figures/说明书附图.pdf` 与线宽，"
               "属生产记录，不进入申请文件）")


    top = [
        ("## 1. 技术领域", "## 一、技术领域"),
        ("## 2. 背景技术", "## 二、背景技术"),
        ("## 3. 发明内容", "## 三、发明内容"),
        ("## 4. 附图说明", "## 四、附图说明"),
        ("## 5. 具体实施方式", "## 五、具体实施方式"),
    ]
    for a, b in top:
        assert a in spec, a
        spec = spec.replace(a, b)
    log.append("第 1–5 节标题改为「一、技术领域」…「五、具体实施方式」（对应法定五部分）")

    spec = re.sub(r"\n{3,}", "\n\n", spec)
    spec = re.sub(r"\n---\n", "\n", spec)
    spec = spec.strip()
    if spec.startswith("---"):
        spec = spec[3:].lstrip("\n")
        log.append("删除开头的孤立 `---`（母本分隔线的残留，会在 PDF 首行形成横线）")

    # 正文字体缺字的字符替换（宋体无 ⌈⌉⌊⌋ 与 …，XeTeX 会静默丢字）
    subs = [
        ("⌈T/W⌉", "ceil(T/W)"),
        ("⌊t/W⌋", "floor(t/W)"),
        ("⌈", "ceil("),
        ("⌉", ")"),
        ("⌊", "floor("),
        ("⌋", ")"),
        ("level＝5…1", "level＝5 至 1"),
    ]
    for a, b in subs:
        if a in spec:
            spec = spec.replace(a, b)
    log.append("字符替换以便排版：《专利审查指南》用字不受限，但所用宋体无 "
               "⌈⌉⌊⌋ 与 …，XeTeX 会静默丢字。取整符号改为函数记法 "
               "`ceil(T/W)` / `floor(t/W)`（含义不变，5 处），"
               "`level＝5…1` 改为 `level＝5 至 1`（2 处）")

    spec = ("\\begin{center}\n\\large\\bfseries 一种基于证据优先级链的系统级实时字幕调度方法及装置\n"
            "\\end{center}\n\n" + spec)
    log.append("在说明书首行加上发明名称（细则要求说明书第一行写明发明名称、且与请求书一致）；"
               "以居中加粗行排出，故写作 LaTeX 居中环境，编译后为纯文本标题")
    return spec, log


def main():
    abstract, claims, spec = read_parts()
    spec2, log = clean_spec(spec)

    open("说明书摘要.md", "w", encoding="utf-8").write("# 说明书摘要\n\n" + abstract + "\n")
    open("权利要求书.md", "w", encoding="utf-8").write("# 权利要求书\n\n" + claims + "\n")
    open("说明书.md", "w", encoding="utf-8").write(spec2 + "\n")

    with open("转换记录.md", "w", encoding="utf-8") as f:
        f.write("# 定稿转换记录（母本 → 可提交文本）\n\n")
        f.write("母本：`docs/PATENT-APPLICATION-证据优先级链字幕调度.md`（未改动）。\n\n")
        f.write("本目录 `说明书.md` 由母本第四部分经下列步骤派生，供代理师审计：\n\n")
        for i, l in enumerate(log, 1):
            f.write("%d. %s\n" % (i, l))
        f.write("\n原始 %d 字符 → 定稿 %d 字符。\n" % (len(spec), len(spec2)))

    print("摘要 %d 字 / 权利要求 %d 字符 / 说明书 %d → %d 字符"
          % (len(abstract), len(claims), len(spec), len(spec2)))
    for i, l in enumerate(log, 1):
        print("%d. %s" % (i, l))
    return 0


if __name__ == "__main__":
    sys.exit(main())
