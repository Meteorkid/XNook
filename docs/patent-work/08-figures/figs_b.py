"""图 5–图 8。"""


def _loop_right(f, x, y, h, label=None, up=True):
    """在方框右侧画一个自环箭头。"""
    c = f.c
    x0 = x
    y1 = y + h * 0.62
    y2 = y + h * 0.38
    p = c.beginPath()
    p.moveTo(x0 * f.MMf, f._y(y1))
    p.curveTo((x0 + 16) * f.MMf, f._y(y1 - 2),
              (x0 + 16) * f.MMf, f._y(y2 + 2),
              x0 * f.MMf, f._y(y2))
    c.setLineWidth(0.35 * f.MMf)
    c.drawPath(p, stroke=1, fill=0)
    f.arrow(x0 + 1.2, y2 + 0.6, x0, y2)
    if label:
        f.text(x0 + 4, (y1 + y2) / 2 - 1, label, size=5.8)


def fig5(f):
    """收敛状态转换图：两态 + 已读为独立判定量。"""
    x, w, h = 64.0, 58.0, 16.0
    f.box(x, 56, w, h, "易变", size=9.0)
    f.box(x, 104, w, h, "已稳定", size=9.0)

    f.arrow(x + w / 2, 72, x + w / 2, 104)
    f.text(x + w / 2 + 3, 82, "连续两个调度周期内采纳值与", size=6.0)
    f.text(x + w / 2 + 3, 87, "证据权重均不再变化，且该区间", size=6.0)
    f.text(x + w / 2 + 3, 92, "起始绝对源时间戳未越已读边界", size=6.0)

    # 自环
    for y, lab1, lab2 in ((56, "晚到证据仅在未读后续区间", "按证据权重更新"),
                          (104, "被冻结，不参与证据权重更新", "并禁止回改已呈现条目")):
        f.path_arrow([(x + w, y + 5), (x + w + 8, y + 5),
                      (x + w + 8, y + 11), (x + w, y + 11)])
        f.text(x + w + 10, y + 6.5, lab1, size=5.8)
        f.text(x + w + 10, y + 11.0, lab2, size=5.8)

    # 首帧时限到达
    f.box(18, 57, 34, 14, "首帧时限 D 到达时渲染\n可仍处于易变态", size=5.8)
    f.arrow(52, 64, x - 1, 64)

    # 已读：独立判定量
    bx, by = 64.0, 148.0
    c = f.c
    c.setLineWidth(0.35 * f.MMf)
    c.setDash([2, 2], 0)
    c.rect(bx * f.MMf, f._y(by + 20), 58 * f.MMf, 20 * f.MMf, stroke=1, fill=0)
    c.setDash([], 0)
    f.text(bx + 29, by + 7, "已读状态（独立判定量）", size=6.4, anchor="c")
    f.text(bx + 29, by + 13, "按已读保护时长判定", size=5.8, anchor="c")
    f.text(bx + 29, by + 17.5, "判为已读后不再写入", size=5.8, anchor="c")
    f.arrow(bx + 29, 120, bx + 29, by - 1)
    f.text(bx + 32, 132, "呈现后被判定为已读", size=6.0)



def fig6(f):
    """绝对源时间戳与切换边界示意图。"""
    tx = [34.0, 71.0, 108.0, 145.0, 180.0]
    ya = 46.0
    # 条目区间
    f.text(24, 22, "条目区间", size=6.0)
    for i in range(4):
        f.line(tx[i], 26, tx[i + 1], 26)
        f.line(tx[i], 24.5, tx[i], 27.5)
        f.line(tx[i + 1], 24.5, tx[i + 1], 27.5)
        f.text((tx[i] + tx[i + 1]) / 2, 30.5, "E%d" % (i + 1), size=6.4, anchor="c")

    # 绝对源时间轴
    f.arrow(28, ya, 186, ya)
    f.text(184, ya + 4.5, "绝对源时间轴 t", size=6.4, anchor="r")
    for i, x in enumerate(tx):
        f.line(x, ya - 2, x, ya + 2)
        f.text(x, ya - 5, "t%d" % i, size=6.0, anchor="c")

    tracks = [
        ("轨A 文本流／既有全文（证据等级最高，已稳定）", 64, ([], 0), 1.6, 0, 2),
        ("轨B 元数据／缓存（中等级）", 84, ([4, 2], 0), 1.2, 2, 4),
        ("轨C 流式识别（兜底，低等级）", 104, ([1, 2], 0), 1.0, 0, 4),
    ]
    for label, y, dash, width, a, b in tracks:
        f.text(28, y - 2.5, label, size=5.8)
        f.line(tx[a], y, tx[b], y, dash=dash, lw=width)

    f.line(tx[2], ya + 3, tx[2], 108, dash=([6, 2, 1, 2], 0))
    f.text(tx[2] + 2, 114, "轨间切换边界：只能取已稳定条目的起始绝对源时间戳", size=6.0)



def fig7(f):
    """seek 重锚与未覆盖区间补处理流程图。"""
    cx, w = 96.0, 96.0
    y = 26.0
    f.box(cx - w / 2, y, w, 12, "检测到音源变化 或 播放前沿跳变", size=6.6)
    f.arrow(cx, y + 12, cx, y + 20); y += 20
    f.box(cx - w / 2, y, w, 12, "代次标识自增；取消在途任务，保留已完成条目", size=6.2)
    f.arrow(cx, y + 12, cx, y + 20); y += 20
    f.box(cx - w / 2, y, w, 12, "提取当前音频指纹", size=6.6)
    f.arrow(cx, y + 12, cx, y + 20); y += 20
    dy = y + 11
    f.diamond(cx, dy, 64, 22, "在锚点表中检索到匹配锚点？", size=6.2)

    # 两支
    f.path_arrow([(cx - 32, dy), (cx - 52, dy), (cx - 52, dy + 20)])
    f.text(cx - 50, dy - 4, "匹配", size=6.0)
    f.box(cx - 76, dy + 20, 48, 20, "把跳变后播放前沿重映射\n到绝对源时间戳", size=5.8)
    f.path_arrow([(cx + 32, dy), (cx + 52, dy), (cx + 52, dy + 20)])
    f.text(cx + 34, dy - 4, "未匹配", size=6.0)
    f.box(cx + 28, dy + 20, 48, 20, "退化为流式兜底冷启动", size=5.8)

    ym = dy + 40
    f.line(cx - 52, ym, cx, ym)
    f.line(cx, ym, cx + 52, ym)
    f.box(cx - 52, ym + 8, 104, 12, "在统一时间轴上计算未覆盖区间", size=6.4)
    f.arrow(cx, ym, cx, ym + 8)

    yy = ym + 26
    f.box(cx - 52, yy, 104, 14, "仅对未覆盖区间发起补处理，并提升其调度优先级", size=6.2)
    f.arrow(cx, ym + 20, cx, yy)
    f.box(cx - 52, yy + 22, 104, 12, "丢弃代次小于当前代次的迟到结果", size=6.4)
    f.arrow(cx, yy + 14, cx, yy + 22)
    f.box(cx - 52, yy + 42, 104, 12, "写入收敛状态表", size=6.6)
    f.arrow(cx, yy + 34, cx, yy + 42)
    f.box(cx - 52, yy + 62, 104, 14, "输出仲裁：切换边界限定在已稳定条目处", size=6.2)
    f.arrow(cx, yy + 54, cx, yy + 62)


def fig8(f):
    """装置模块框图：严格对应权 13 的六个模块。"""
    mods = [
        ("1 音源描述模块", "进程标识／播放前沿\n播放速率／可访问标志"),
        ("2 证据接口模块", "六字段契约\n绝对源时间戳索引"),
        ("3 链剪枝模块", "算 P／组链／按 P 剪枝链长"),
        ("4 时限调度模块", "D = t_audio + L_budget\n到点取已就绪最高等级"),
        ("5 收敛模块", "晚到证据写入未读区间\n按证据权重更新"),
        ("6 切换边界模块", "边界限于已稳定条目\n起始绝对源时间戳"),
    ]
    x0, w, gx = 30.0, 56.0, 14.0
    y0, h, gy = 30.0, 26.0, 16.0
    for i, (name, body) in enumerate(mods):
        col, row = i % 2, i // 2
        x = x0 + col * (w + gx)
        y = y0 + row * (h + gy)
        f.box(x, y, w, h, name + "\n" + body, size=6.0)
        if col == 0:
            f.arrow(x + w, y + h / 2, x + w + gx, y + h / 2)
        if row < 2:
            f.arrow(x + w / 2, y + h, x + w / 2, y + h + gy)


    # 汇流母线
    ybus = 190.0
    f.line(128, 140, 128, ybus)
    f.line(58, ybus, 166, ybus)
    prods = ["电子设备：处理器\n＋存储器＋计算机程序", "计算机可读存储介质", "计算机程序产品"]
    for i, lab in enumerate(prods):
        px = 40.0 + i * 50.0
        f.box(px, 200, 44, 15, lab, size=5.8)
        f.arrow(px + 22, ybus, px + 22, 200)
