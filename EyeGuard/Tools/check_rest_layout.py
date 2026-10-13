#!/usr/bin/env python3
"""休息画面布局的像素级校验 —— 只信渲染出来的 PNG，不信任何自报坐标。

## 为什么需要这个脚本

`--shot-rest` 自带的探针读的是 `geo.frame(in: .global)`。它能证明
「控件在窗口内」（越界检查，见《测试指南》3.0.1），但**证明不了控件在
画面的哪个位置** —— 坐标系原点、y 轴朝哪边，都是约定问题。
把「文字在右下角」这种结论建立在自报坐标上，等于用尺子量自己的刻度。

渲染出来的 PNG 没有这个歧义：左上角就是 (0,0)，y 向下增大。
所以本脚本只读像素。

## 它检查两件事

1. **位置**：主文案/健康提示/倒计时/按钮是不是真的都在右下象限，
   以及画面左上半张有没有被压暗。
   做法：16 宫格平均亮度 + 16 宫格高亮像素占比 + 高亮簇包围盒。
   高亮像素（亮度 > 235）**只应该出现在右下那几格**。

2. **可读性**：把文字挪到更亮的背景上，会不会看不清。
   做法：在信息区范围内逐行统计亮像素占比找出文字行，对每行取
   「暗的四分位作背景、亮的 97 分位作字面」，算 WCAG 对比度比。
   正文 AA 要求 4.5:1。

## 用法

    pip install pillow
    python3 check_rest_layout.py /tmp/eg-rest

退出码非 0 表示有检查项不通过。
"""
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("需要 pillow：pip install pillow")
    sys.exit(2)

GRID = 4
BRIGHT_FRAC = 0.030       # 一行里亮像素占比超过这个值，就认为这行有文字
# 「亮像素」的阈值。用**线性**相对亮度表示，0.83 约等于 8bit 的 235 ——
# 只挑接近纯白的像素（白字、白环、白按钮字），这样照片里的亮天空、
# 雪地不会被误判成界面元素。设低了会满屏「泄漏」，设高了会漏掉文字。
BRIGHT_LUM = 0.83
# 信息区的位置由 RestView 里的固定边距决定，**不随窗口缩放** —— 所以这里
# 必须按边距推导，不能拿 1440×900 的一组坐标去按比例缩放。之前那样写，
# 在 3440×1440 上算出来的区域整体偏左偏上，直接漏判。
CLUSTER_RIGHT_PAD = 44     # .padding(.horizontal, 44)
CLUSTER_BOTTOM_PAD = 40    # .padding(.bottom, 40)
CLUSTER_MAX_WIDTH = 430    # .frame(maxWidth: 430)
CLUSTER_BAND_HEIGHT = 340  # 内容高度上限（1440×900 实测 238，留余量）
CONTRAST_MIN = 4.5        # WCAG AA 正文


def srgb_to_linear(v):
    v = v / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def rel_lum(px):
    r, g, b = (srgb_to_linear(v) for v in px[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def lum8(px):
    """8bit 空间的亮度，只用于「这格有多亮」这种给人看的数字。"""
    return 0.2126 * px[0] + 0.7152 * px[1] + 0.0722 * px[2]


def contrast(l1, l2):
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def grid_stats(im):
    """返回 (每格平均亮度 0-255, 每格高亮占比 0-1)，按行优先，共 GRID*GRID 项。"""
    W, H = im.size
    small = im.resize((W // 8, H // 8), Image.BILINEAR)
    sw, sh = small.size
    cw, ch = sw // GRID, sh // GRID
    data = list(small.getdata())
    means, fracs = [], []
    for r in range(GRID):
        for c in range(GRID):
            vals = [data[(r * ch + y) * sw + c * cw + x]
                    for y in range(ch) for x in range(cw)]
            means.append(sum(lum8(v) for v in vals) / len(vals))
            fracs.append(sum(1 for v in vals if rel_lum(v) > BRIGHT_LUM) / len(vals))
    return means, fracs


def bright_bbox(im, threshold=0.85):
    """高亮簇（白字/白环）的包围盒，返回 (x0, y0, x1, y1) 或 None。"""
    W, H = im.size
    px = im.load()
    xs, ys = [], []
    for y in range(0, H, 3):
        for x in range(0, W, 3):
            if rel_lum(px[x, y]) > threshold:
                xs.append(x)
                ys.append(y)
    return (min(xs), min(ys), max(xs), max(ys)) if xs else None


def text_lines(im, cluster_px):
    """在信息区内找出文字行，返回 [(y0_px, y1_px, 对比度比)]。"""
    x0, y0, x1, y1 = cluster_px
    region = im.crop((x0, y0, x1, y1))
    rw, rh = region.size
    if rw < 20 or rh < 20:
        return []
    px = region.load()

    rows = []
    for y in range(rh):
        n = sum(1 for x in range(0, rw, 2) if rel_lum(px[x, y]) > BRIGHT_LUM)
        rows.append(n / (rw / 2))

    bands, start = [], None
    for y, frac in enumerate(rows):
        if frac > BRIGHT_FRAC and start is None:
            start = y
        elif frac <= BRIGHT_FRAC and start is not None:
            if y - start >= 4:
                bands.append((start, y))
            start = None
    if start is not None and rh - start >= 4:
        bands.append((start, rh))

    out = []
    for a, b in bands:
        lums = sorted(rel_lum(px[x, y])
                      for y in range(a, b) for x in range(0, rw, 2))
        if len(lums) < 40:
            continue
        bg = lums[int(len(lums) * 0.25)]
        fg = lums[int(len(lums) * 0.97)]
        out.append((a, b, contrast(fg, bg)))
    return out


def check(path):
    im = Image.open(path).convert("RGB")
    W, H = im.size
    means, fracs = grid_stats(im)

    failures = []

    # --- 1. 高亮像素（文字/按钮）必须只在右下象限 ---
    # 右下象限 = 第 3、4 行 × 第 3、4 列 → 下标 10, 11, 14, 15
    bottom_right = {10, 11, 14, 15}
    leaked = [(i, fracs[i]) for i in range(GRID * GRID)
              if fracs[i] > 0.02 and i not in bottom_right]
    if leaked:
        failures.append("高亮像素出现在右下象限之外：" +
                        "、".join(f"第{i // GRID + 1}行第{i % GRID + 1}列 {v:.1%}"
                                  for i, v in leaked))

    # 宫格是降采样后的粗查，细笔画的白字会被平均掉。所以再加一条
    # **全分辨率**的硬断言：高亮簇的包围盒必须整个落在右半 + 下半。
    # 这条才是「文字真的在右下角」最直接的证据。
    bbox = bright_bbox(im)
    if bbox:
        x0, y0, x1, y1 = bbox
        if x0 < W * 0.5:
            failures.append(f"高亮簇左边缘在 {x0 / W:.0%}，越过了画面中线")
        if y0 < H * 0.5:
            failures.append(f"高亮簇上边缘在 {y0 / H:.0%}，越过了画面中线")
    else:
        failures.append("没有检测到任何高亮像素（文字/按钮都没渲染出来？）")

    # --- 2. 右下角应当有压暗（文字的底衬）---
    #
    # 这里**刻意只比两个对角单元格**，而不是比「左上象限 vs 右下象限」。
    # 象限级的比较是个代理指标，它假设照片本身亮度均匀 —— 在 3440×1440
    # 的带鱼屏上，右下象限有 1720×720pt 那么大，径向渐变只盖住紧贴角落的
    # 一小块，于是「照片本身右下更亮」就把它压过去了，误判成「没有压暗」。
    # 对角单元格的尺度不随屏幕尺寸变，才是稳的。
    #
    # 精确的压暗量由 Tools/check_dimming.py 量（拿渲染结果除以原照片），
    # 这里只做一个粗筛：右下角明显比左上角暗。
    #
    # 前提是「背景是一张真实照片」。素材库为空时走的是深色渐变退化层
    # （见 RestView.emptySceneLayer），底色本身就够暗、不需要底衬，
    # 硬比会误判。所以左上角本身就暗（< 60/255）时跳过这一项。
    tl_cell, br_cell = means[0], means[GRID * GRID - 1]
    if tl_cell < 60:
        pass          # 深色退化层，无需底衬
    elif tl_cell > 0 and br_cell / tl_cell > 0.90:
        failures.append(f"右下角没有被压暗（右下/左上 = {br_cell / tl_cell:.2f}），"
                        f"文字可能缺少底衬")

    # --- 3. 文字行对比度 ---
    # 截图是 2x Retina，所以 1 pt = 2 px。信息区贴着右下角，位置由边距决定，
    # 与窗口尺寸无关 —— 所以这里按边距推导，而不是按比例缩放一组固定坐标。
    scale = 2                              # Retina 缩放：1 pt = 2 px
    lw, lh = W // scale, H // scale        # 逻辑尺寸（pt）
    cluster_px = (int((lw - CLUSTER_RIGHT_PAD - CLUSTER_MAX_WIDTH) * scale),
                  int((lh - CLUSTER_BOTTOM_PAD - CLUSTER_BAND_HEIGHT) * scale),
                  W, H)
    lines = text_lines(im, cluster_px)
    worst = min((c for _, _, c in lines), default=None)
    if worst is not None and worst < CONTRAST_MIN:
        failures.append(f"文字对比度最低只有 {worst:.2f}:1（要求 ≥ {CONTRAST_MIN}）")
    if not lines:
        failures.append("信息区内没有检测到任何文字行（渲染失败？）")
    return W, H, means, fracs, lines, worst, bbox, failures


def main(directory):
    files = sorted(Path(directory).glob("*.png"))
    if not files:
        print(f"{directory} 下没有 PNG")
        return 1

    total_failures = 0
    for f in files:
        W, H, means, fracs, lines, worst, bbox, failures = check(f)
        status = "通过" if not failures else f"未通过（{len(failures)}）"
        print(f"\n=== {f.name}  ({W}x{H})  {status} ===")

        print("  16 宫格平均亮度（0-255）：")
        for r in range(GRID):
            print("    " + "".join(f"{means[r * GRID + c]:7.1f} " for c in range(GRID)))
        print("  16 宫格高亮像素占比（%）：")
        for r in range(GRID):
            print("    " + "".join(f"{fracs[r * GRID + c] * 100:7.2f} " for c in range(GRID)))

        if bbox:
            x0, y0, x1, y1 = bbox
            print(f"  高亮簇：x {x0}..{x1}  y {y0}..{y1}"
                  f"  → 横跨 {x0 / W:.0%}..{x1 / W:.0%}，纵跨 {y0 / H:.0%}..{y1 / H:.0%}")
        if lines:
            print(f"  文字行对比度：{'、'.join(f'{c:.2f}' for _, _, c in lines)}"
                  f"   最低 {worst:.2f}:1")
        for msg in failures:
            print(f"  ✗ {msg}")
        total_failures += len(failures)

    print("\n" + "=" * 60)
    if total_failures == 0:
        print(f"全部通过（{len(files)} 张：文字/控件都在右下象限，上半张未被压暗，"
              f"文字对比度 ≥ {CONTRAST_MIN}:1）")
        return 0
    print(f"未通过：共 {total_failures} 项")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "/tmp/eg-rest"))
