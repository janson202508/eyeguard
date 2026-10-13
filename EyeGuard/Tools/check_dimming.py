#!/usr/bin/env python3
"""量出**压暗层到底把画面压暗了多少** —— 按区域、按百分比，不靠感觉。

## 为什么这个量法才是对的

前面 `check_rest_layout.py` 比的是「左上象限 vs 右下象限的亮度」。
那是个**代理指标**：它假设照片本身亮度是均匀的，所以某个区域变暗
就等于压暗层在起作用。对绝大多数照片够用，但对「本来右下就比左上亮」
的照片会误判 —— 超宽屏（3440×1440）上就真的误判了一次。

真正想要的是**压暗量**本身，而不是亮度的相对关系。压暗量的定义是

    压暗量 = 1 − 渲染像素 / 原照片像素

只要拿到原照片，这个量就跟照片内容无关了 —— 无论照片多亮多暗，
它都直接告诉你「这一块被压掉了百分之多少」。

## 做法

1. 从 `--shot-rest` 的日志里读出每张截图对应的素材 id；
2. 从 `Assets/Scenes/manifest.json` 找到原图；
3. 按 `aspectRatio(.fill)` 的规则复现裁切（等比放大到铺满，再居中裁）；
4. 逐像素算比值，**取中位数**而不是均值 —— 信息区里的白字比照片亮，
   属于少数派，中位数会把它们自动排除掉。

## 用法

    python3 check_dimming.py <截图目录> <日志文件>

退出码非 0 表示有区域超出了 FR-3.11 的限值。
"""
import json
import re
import statistics
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    print("需要 pillow：pip install pillow")
    sys.exit(2)

GRID = 4
# FR-3.11 的判据。为什么按「象限」而不是「上半部分」一刀切：
#
# 信息区贴着右下角，而径向渐变是以那个角为圆心的同心圆。文字要读得清，
# 渐变就必须在「信息区远角」那个距离（约 550pt）上还足够强 —— 而那个
# 距离上正好也是画面右边缘中段所在的位置。所以「压暗只出现在右下角」
# 这个说法在几何上做不到：右边缘中段必然带一点。
#
# 真正能做到、也是用户真正在意的是：**信息区的对角（左上）和左下角
# 不受影响**。所以判据按象限给：
#   · 左上象限（信息区正对角）≤ 0.15 —— 「看风景」的主区域
#   · 左下象限 ≤ 0.20 —— Stage 9 的缺陷正是这里被压到 0.63
#   · 上半部分整体 ≤ 0.40 —— 兜底，防径向半径重新变成无上限
UPPER_LEFT_MAX = 0.15
LOWER_LEFT_MAX = 0.20
UPPER_HALF_MAX = 0.40
# 反过来也要有下限：右下角（信息区所在处）必须确实被压暗，否则白字在
# 亮背景上就没有底衬。这一条是「别把压暗层顺手删掉」的守卫。
LOWER_RIGHT_MIN = 0.30
NIGHT = False          # 这些截图都是白天场景

LINE = re.compile(r"^\s*(\S+\.png)\s+id=(\S+)")


def load_manifest(project_root):
    path = project_root / "Assets" / "Scenes" / "manifest.json"
    items = json.loads(path.read_text(encoding="utf-8"))
    return {it["id"]: it for it in items}


def fill_crop(photo, size):
    """复现 SwiftUI `.aspectRatio(contentMode: .fill)` 的裁切。"""
    cw, ch = size
    iw, ih = photo.size
    scale = max(cw / iw, ch / ih)
    new = (max(cw, int(round(iw * scale))), max(ch, int(round(ih * scale))))
    resized = photo.resize(new, Image.LANCZOS)
    left = (new[0] - cw) // 2
    top = (new[1] - ch) // 2
    return resized.crop((left, top, left + cw, top + ch))


def darkening_grid(shot_path, photo_path):
    shot = Image.open(shot_path).convert("RGB")
    W, H = shot.size
    photo = fill_crop(Image.open(photo_path).convert("RGB"), (W, H))

    # 降采样到 1/8 再逐像素算，够快也够稳
    sw, sh = W // 8, H // 8
    s = shot.resize((sw, sh), Image.BILINEAR).load()
    p = photo.resize((sw, sh), Image.BILINEAR).load()

    cw, ch = sw // GRID, sh // GRID
    cells = []
    for r in range(GRID):
        for c in range(GRID):
            ratios = []
            for y in range(r * ch, (r + 1) * ch):
                for x in range(c * cw, (c + 1) * cw):
                    sp = sum(s[x, y]) / 3.0
                    pp = sum(p[x, y]) / 3.0
                    if pp < 6:          # 原图接近纯黑，比值没有意义
                        continue
                    ratios.append(min(sp / pp, 1.4))
            cells.append(1 - statistics.median(ratios) if ratios else None)
    return cells


def main(directory, log_path):
    project_root = Path(__file__).resolve().parent.parent
    manifest = load_manifest(project_root)
    shots_dir = Path(directory)

    id_by_shot = {}
    for line in Path(log_path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = LINE.match(line)
        if m:
            id_by_shot[m.group(1)] = m.group(2)

    print(f"{'截图':<22}{'素材':<22}")
    print(" " * 44 + "     c0      c1      c2      c3")
    print("-" * (44 + 8 * GRID))

    worst = {"ul": (0.0, ""), "ll": (0.0, ""), "uh": (0.0, ""), "lr": (1.0, "")}
    measured = 0

    for name in sorted(id_by_shot):
        asset_id = id_by_shot[name]
        shot_path = shots_dir / name
        if not shot_path.exists():
            continue
        if asset_id == "nil" or asset_id.startswith("user-"):
            print(f"{name:<22}{asset_id:<22}  （无对应原图，跳过）")
            continue
        item = manifest.get(asset_id)
        if not item:
            print(f"{name:<22}{asset_id:<22}  （清单里找不到，跳过）")
            continue
        photo_path = project_root / "Assets" / "Scenes" / item["fileName"]
        if not photo_path.exists():
            print(f"{name:<22}{asset_id:<22}  （原图缺失）")
            continue

        cells = darkening_grid(shot_path, photo_path)
        measured += 1
        print(f"{name:<22}{asset_id:<22}")

        def cell(r, c):
            return cells[r * GRID + c]

        labels = ["上半 row0", "     row1", "下半 row2", "     row3"]
        for r in range(GRID):
            row = " " * 44 + f"{labels[r]}  "
            for c in range(GRID):
                v = cell(r, c)
                row += f"{v * 100:7.1f}%" if v is not None else "      —"
            print(row)
        print()

        def block(rows, cols):
            vals = [cell(r, c) for r in rows for c in cols if cell(r, c) is not None]
            return max(vals) if vals else None

        ul = block([0, 1], [0, 1])
        ll = block([2, 3], [0, 1])
        uh = block([0, 1], [0, 1, 2, 3])
        lr = cell(GRID - 1, GRID - 1)          # 右下角那一格
        for key, val, tag in (("ul", ul, "左上象限"), ("ll", ll, "左下象限"),
                              ("uh", uh, "上半部分")):
            if val is not None and val > worst[key][0]:
                worst[key] = (val, f"{name} · {tag}")
        if lr is not None and lr < worst["lr"][0]:
            worst["lr"] = (lr, f"{name} · 右下角")

    print("-" * (44 + 8 * GRID))
    print(f"共量了 {measured} 张。每格数字 = 该区域被压掉的百分比（中位数）。")
    if measured == 0:
        print("没有可量的截图")
        return 1

    failures = []
    for key, limit, label in (("ul", UPPER_LEFT_MAX, "左上象限（信息区对角）"),
                              ("ll", LOWER_LEFT_MAX, "左下象限"),
                              ("uh", UPPER_HALF_MAX, "上半部分")):
        val, where = worst[key]
        ok = val <= limit
        print(f"  {'✓' if ok else '✗'} {label}最大压暗 {val * 100:5.1f}%"
              f"（限值 {limit * 100:.0f}%）  最差：{where}")
        if not ok:
            failures.append(label)

    lr_val, lr_where = worst["lr"]
    ok = lr_val >= LOWER_RIGHT_MIN
    print(f"  {'✓' if ok else '✗'} 右下角（信息区）最小压暗 {lr_val * 100:5.1f}%"
          f"（下限 {LOWER_RIGHT_MIN * 100:.0f}%）  最差：{lr_where}")
    if not ok:
        failures.append("右下角底衬不足")

    if failures:
        print(f"\n✗ 未通过 FR-3.11：{'、'.join(failures)}")
        return 1
    print("\n✓ 通过 FR-3.11")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2]))
