# figs_a: 图1-图4
"""图 1–图 4。坐标单位 mm，原点在图区左上角。"""

MAIN_X, MAIN_W = 38.0, 74.0
CX = MAIN_X + MAIN_W / 2


def fig1(f):
    """系统总体架构图。"""
    rows = [
        (24, "音频捕获：媒体流／标签页／系统回环，逐级降级", "1"),
        (46, "音源描述符：pid／播放前沿／速率／可访问标志", "2"),
        (68, "可预取度 P 计算", "3"),
        (88, "统一证据提供者接口\n证据等级／可预取性要求／异步许可\n产出时间区间／估计耗时／超时降级动作", "4"),
    ]
    for y, t, m in rows:
        h = 16 if "\n" in t else 13
        f.box(MAIN_X, y, MAIN_W, h, t, size=6.8, mark=m)
    for i in range(len(rows) - 1):
        y1 = rows[i][0] + (16 if "\n" in rows[i][1] else 13)
        f.arrow(CX, y1, CX, rows[i + 1][0])

    f.box(MAIN_X, 112, MAIN_W, 12, "证据优先级链（按证据等级由高到低）", size=6.8, mark="5")
    f.arrow(CX, 104, CX, 112)
    f.box(MAIN_X, 132, 35, 14, "快路径\n查表 / 缓存命中", size=6.4)
    f.box(MAIN_X + 39, 132, 35, 14, "慢路径\n播放前执行 / 异步旁路", size=6.4)
    f.path_arrow([(CX, 124), (MAIN_X + 17.5, 124), (MAIN_X + 17.5, 132)])
    f.path_arrow([(CX, 124), (MAIN_X + 56.5, 124), (MAIN_X + 56.5, 132)])

    f.box(MAIN_X, 154, MAIN_W, 14, "首帧时限调度器　D = t_audio + L_budget", size=6.8, mark="6")
    f.arrow(MAIN_X + 17.5, 146, MAIN_X + 17.5, 154)
    f.arrow(MAIN_X + 56.5, 146, MAIN_X + 56.5, 154)

    f.box(MAIN_X, 176, MAIN_W, 14, "收敛状态库\n易变 / 已稳定（两态）；已读状态为独立判定量", size=6.6, mark="7")
    f.arrow(CX, 168, CX, 176)
    f.box(MAIN_X, 198, MAIN_W, 12, "绝对源时间戳索引", size=6.8, mark="8")
    f.arrow(CX, 190, CX, 198)
    f.box(MAIN_X, 218, MAIN_W, 12, "输出仲裁：最高证据等级且已稳定", size=6.6, mark="9")
    f.arrow(CX, 210, CX, 218)
    f.box(MAIN_X, 238, MAIN_W, 12, "字幕呈现", size=6.8, mark="10")
    f.arrow(CX, 230, CX, 238)

    f.box(140, 152, 44, 16, "推理单元负载 / 内存预算\n（约束量）", size=6.4, mark="11")
    f.arrow(140, 160, MAIN_X + MAIN_W, 160, dash=([2, 2], 0))
    f.box(140, 196, 44, 16, "音频指纹重锚\n仅补处理未覆盖区间", size=6.4, mark="12")
    f.arrow(140, 204, MAIN_X + MAIN_W, 204, dash=([2, 2], 0))


def fig2(f):
    """证据优先级链与快慢路径分离图（顺序严格按权 3）。"""
    x, w = 24.0, 94.0
    items = [
        ("① 应用发布的文本流", "【快／查表】零推理", 26),
        ("② 既有全文的强制对齐结果", "【慢／播放前】必需可预取", 50),
        ("③ 媒体元数据", "【快／查表】会话级一次", 74),
        ("④ 画面文字识别结果", "【异步／晚到写入】允许异步", 98),
        ("⑤ 本地已转写缓存", "【快／查表】必需可预取", 122),
        ("⑥ 流式语音识别结果", "【兜底／不需可预取】", 146),
    ]
    for title, note, y in items:
        f.box(x, y, w, 14, title, size=6.8)
        f.text(x + w + 4, y + 9.0, note, size=6.2)
        if y != items[-1][2]:
            f.arrow(x + w / 2, y + 14, x + w / 2, y + 24)

    cx = x + w / 2
    f.diamond(cx, 180, 48, 22, "首帧时限 D 到达？", size=6.4)
    f.arrow(cx, 160, cx, 169)

    f.text(cx + 3, 176, "否", size=6.2)
    f.arrow(cx + 24, 180, cx + 44, 180)
    f.box(cx + 46, 172, 54, 16, "继续等待；到 D 仍未完成\n则按声明的超时降级动作退出", size=5.8)

    f.text(cx - 6, 196, "是", size=6.2)
    f.box(cx - 34, 202, 68, 15, "取已就绪的最高证据等级候选渲染\n（不等未完成来源）", size=6.2)
    f.arrow(cx, 191, cx, 202)



def fig3(f):
    """首帧时限时序图。"""
    y0 = 96.0
    xa, xd, xe = 40.0, 116.0, 180.0
    f.arrow(28, y0, 186, y0)
    f.text(184, y0 + 4.5, "绝对源时间轴 t", size=6.4, anchor="r")

    # 时间刻度
    for x, lab in ((xa, "t_audio"), (xd, "D")):
        f.line(x, y0 - 4, x, y0 + 4)
        f.text(x, y0 - 8.5, lab, size=6.6, anchor="c")
    f.text(xd + 3, y0 - 8.5, "= t_audio + L_budget", size=6.4, anchor="l")

    # 时限窗
    yb = y0 - 20
    f.line(xa, yb, xd, yb)
    f.line(xa, yb, xa, yb + 3)
    f.line(xd, yb, xd, yb + 3)
    f.text((xa + xd) / 2, yb - 3.5, "时限窗 [t_audio, D)", size=6.4, anchor="c")

    # 各来源就绪时刻
    ready = [(56, "文本流就绪"), (78, "元数据就绪"), (100, "缓存就绪")]
    for x, lab in ready:
        f.circle(x, y0, 1.4, fill=1)
        f.line(x, y0 - 2.5, x, y0 - 8)
        f.text(x, y0 - 10.5, lab, size=5.6, anchor="c")

    # 首帧渲染点
    f.circle(xd, y0, 1.8, fill=1)
    f.text(xd + 4, y0 + 9, "首帧渲染：到 D 即出，不等未完成来源", size=6.2)

    # 区间
    ytop = y0 + 18
    f.rect(xa, ytop, xd - xa, 17)
    f.text((xa + xd) / 2, ytop + 7, "已呈现区间（冻结）", size=6.4, anchor="c")
    f.text((xa + xd) / 2, ytop + 12.5, "不回改已呈现条目", size=6.0, anchor="c")
    f.rect(xd, ytop, xe - xd, 17)
    f.text((xd + xe) / 2, ytop + 7, "未读后续区间", size=6.4, anchor="c")
    f.text((xd + xe) / 2, ytop + 12.5, "晚到证据按证据权重更新", size=6.0, anchor="c")

    # 已读边界
    f.line(xd, y0 + 6, xd, ytop + 17, dash=([3, 2], 0))
    f.text(xd, ytop + 21, "已读状态边界", size=6.2, anchor="c")

    # 晚到证据
    f.arrow(xd + 34, ytop - 8, xd + 34, ytop - 1)
    f.text(xd + 36, ytop - 6, "晚到证据到达点", size=5.8)

    f.text(28, ytop + 40, "输出延迟上界 = D − t_audio = L_budget", size=7.2)


def fig4(f):
    """可预取性剪枝决策图（两条分支：前移 / 剪除）。"""
    cx = 100.0
    f.box(24, 26, 152, 12, "读取音源描述符（进程标识／播放前沿／播放速率／可访问标志）", size=6.4)
    f.arrow(cx, 38, cx, 46)
    f.box(cx - 34, 46, 68, 12, "计算可预取度 P", size=6.8)
    f.arrow(cx, 58, cx, 66)
    f.diamond(cx, 80, 56, 22, "P 是否不小于第一阈值？", size=6.4)

    # 左分支（P 高）
    f.path_arrow([(cx - 28, 80), (56, 80), (56, 100)])
    f.text(cx - 30, 76, "是（P 高）", size=6.2, anchor="r")
    f.box(24, 100, 64, 14, "耗时来源前移至播放前执行", size=6.2)
    f.arrow(56, 114, 56, 122)
    f.box(24, 122, 64, 16, "命中结果按绝对源时间戳缓存\n播放时仅查表读取", size=6.0)

    # 右分支（P 低）
    f.path_arrow([(cx + 28, 80), (144, 80), (144, 100)])
    f.text(cx + 30, 76, "否（P 低）", size=6.2)
    f.box(112, 100, 64, 14, "从链中移除要求可预取的来源", size=6.2)
    f.arrow(144, 114, 144, 122)
    f.box(112, 122, 64, 16, "链路塌缩为：实体表 + 流式兜底\n+ 异步收敛", size=6.0)

    # 汇合
    f.path_arrow([(56, 138), (56, 152), (cx, 152)])
    f.path_arrow([(144, 138), (144, 152), (cx, 152)])
    f.box(cx - 34, 156, 68, 12, "输出：链长／各来源执行时机", size=6.4)
    f.arrow(cx, 152, cx, 156)
    f.arrow(cx, 168, cx, 176)
    f.box(24, 176, 152, 16, "首帧时限调度器：D = t_audio + L_budget\n剪枝不改变 D，只改变链长", size=6.2)

