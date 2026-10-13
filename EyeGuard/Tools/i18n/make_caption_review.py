#!/usr/bin/env python3
"""生成「图片介绍人工核对页」—— 为 FR-11 的红线「不要虚假的」做的工装。

## 为什么需要它

`--self-test` 的 FR-11 段能验的全是**字符串形态**：两种语言齐备、不超长、
有依据、署名放得进一行、英文侧无汉字。这些判据再多也回答不了唯一重要的那个问题：

    这句介绍写的，是不是这张图上真有的东西？

那只能人眼对着图看。所以这个页面把**缩略图**和**介绍**并排放，
并给出该条介绍的**依据**（`captionSource`）与通往**原始图源页**的链接 ——
`captionSource` 存在的全部意义就是让每条介绍都能回溯。

## 用法

    python Tools/i18n/make_caption_review.py [--out <路径.html>] [--thumb 200]

默认产出工作区根目录下的 `图片介绍-人工核对.html`。
缩略图以 base64 内嵌，避免预览面板的 `file://` 限制 —— 代价是文件约 4 MB。

需要 pillow。
"""

import argparse
import base64
import collections
import io
import json
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))          # EyeGuard/
SCENES = os.path.join(ROOT, "Assets", "Scenes")
MAN = os.path.join(SCENES, "manifest.json")
DEFAULT_OUT = os.path.abspath(os.path.join(ROOT, "..", "图片介绍-人工核对.html"))

CAT_ZH = {
    "mountain": "山峦", "ocean": "海洋", "forest": "森林", "lake": "湖泊",
    "desert": "荒漠", "snow": "雪景", "starfield": "星空", "grassland": "草原",
    "canyon": "峡谷", "aerial": "航拍",
}

# 依据 → 色带。越靠左越「硬」：直接来自图源元数据；越靠右越依赖人工判断。
SOURCE_TONE = {
    "GPS 反查": "gps", "元数据地名": "meta", "类别锚点": "cat", "Apple": "apple",
}


def tone_of(src):
    for k, v in SOURCE_TONE.items():
        if k in src:
            return v
    return "other"


def esc(s):
    return (str(s or "").replace("&", "&amp;")
                        .replace("<", "&lt;").replace(">", "&gt;"))


def thumb(path, edge, quality=58):
    """缩略图 → data URI。单张失败不中断整页（报一行 stderr 即可）。"""
    try:
        im = Image.open(path).convert("RGB")
        w, h = im.size
        im = im.resize((edge, max(1, int(h * edge / w))), Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, "JPEG", quality=quality, optimize=True)
        return "data:image/jpeg;base64," + base64.b64encode(buf.getvalue()).decode()
    except Exception as e:                                       # noqa: BLE001
        print(f"  ! {os.path.basename(path)}: {e}", file=sys.stderr)
        return ""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--thumb", type=int, default=200, help="缩略图宽（px），默认 200")
    args = ap.parse_args()

    man = json.load(open(MAN, encoding="utf-8"))
    total = len(man)

    by_cat = collections.defaultdict(list)
    for a in man:
        by_cat[a["category"]].append(a)

    sections = []
    for cat in sorted(by_cat, key=lambda c: -len(by_cat[c])):
        items = by_cat[cat]
        rows = []
        for a in sorted(items, key=lambda x: x["id"]):
            src = a.get("captionSource") or ""
            credit = " · ".join(
                x for x in [a.get("photographer") or "", str(a.get("shotYear") or "")] if x
            ) or "—"
            link = a.get("sourceURL") or ""
            link_html = (
                f'<a class="lnk" href="{esc(link)}" target="_blank" rel="noreferrer">原图页</a>'
                if link else '<span class="lnk off">无来源链接</span>'
            )
            rows.append(f"""      <figure class="card">
        <img loading="lazy" src="{thumb(os.path.join(SCENES, a['fileName']), args.thumb)}" alt="">
        <figcaption>
          <p class="en">{esc(a.get('captionEn'))}</p>
          <p class="zh">{esc(a.get('captionZh'))}</p>
          <p class="blurb">{esc(a.get('blurbEn'))}　/　{esc(a.get('blurbZh'))}</p>
          <p class="meta"><span class="cred">{esc(credit)}</span>
             <span class="src" data-src="{tone_of(src)}">{esc(src)}</span></p>
          <p class="meta2"><code>{esc(a['id'])}</code> · {esc(a.get('license'))} · {link_html}</p>
        </figcaption>
      </figure>""")
        sections.append(f"""  <section>
    <h2>{esc(CAT_ZH.get(cat, cat))} <span class="n">{len(items)} 张</span></h2>
    <div class="grid">
{chr(10).join(rows)}
    </div>
  </section>""")

    dist = collections.Counter(a.get("captionSource") or "" for a in man)
    dist_html = "".join(
        f'<li><b>{n}</b> 条 <span class="src" data-src="{tone_of(k)}">{esc(k)}</span></li>'
        for k, n in dist.most_common()
    )
    with_link = sum(1 for a in man if a.get("sourceURL"))
    no_credit = sum(1 for a in man if not (a.get("photographer") or "").strip())

    html = f"""<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<title>EyeGuard · 图片介绍人工核对（{total} 张）</title>
<style>
  :root {{ color-scheme: light dark; }}
  * {{ box-sizing: border-box; }}
  body {{ margin:0; padding:28px 32px 80px; background:#f6f6f8; color:#1c1c1e;
         font:14px/1.6 -apple-system,"Helvetica Neue","PingFang SC",sans-serif; }}
  h1 {{ font-size:22px; margin:0 0 6px; }}
  .lead {{ color:#5b5b66; margin:0 0 22px; max-width:900px; }}
  .lead b {{ color:#1c1c1e; }}
  .panel {{ background:#fff; border:1px solid #e2e2e8; border-radius:12px;
            padding:16px 20px; margin-bottom:26px; }}
  .panel ul {{ margin:8px 0 0; padding-left:18px; columns:2; }}
  .panel li {{ margin:2px 0; break-inside:avoid; }}
  h2 {{ font-size:17px; margin:34px 0 12px; padding-bottom:6px;
        border-bottom:1px solid #e2e2e8; }}
  h2 .n {{ font-weight:400; font-size:13px; color:#7a7a86; margin-left:8px; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(240px,1fr)); gap:16px; }}
  .card {{ margin:0; background:#fff; border:1px solid #e2e2e8; border-radius:10px;
           overflow:hidden; display:flex; flex-direction:column; }}
  .card img {{ width:100%; display:block; background:#ddd; }}
  figcaption {{ padding:9px 11px 11px; }}
  .en {{ margin:0; font-size:13.5px; font-weight:600; }}
  .zh {{ margin:3px 0 0; font-size:13px; color:#3a3a44; }}
  .blurb {{ margin:4px 0 0; font-size:12px; color:#6b6b78;
            border-top:1px dashed #e2e2e8; padding-top:4px; }}
  .meta, .meta2 {{ margin:7px 0 0; font-size:11.5px; color:#7a7a86;
                   display:flex; flex-wrap:wrap; gap:6px; align-items:center; }}
  .meta2 {{ margin-top:3px; }}
  code {{ font-size:10.5px; color:#8a8a96; }}
  .src {{ font-size:10.5px; padding:1px 6px; border-radius:99px; white-space:nowrap; }}
  .src[data-src=gps]   {{ background:#e3f0ff; color:#1a5fb4; }}
  .src[data-src=meta]  {{ background:#e6f5ea; color:#1a7f45; }}
  .src[data-src=cat]   {{ background:#fdf0dc; color:#8a5a10; }}
  .src[data-src=apple] {{ background:#f0e8fb; color:#6b3fa0; }}
  .src[data-src=other] {{ background:#ececf0; color:#5b5b66; }}
  .lnk {{ color:#1a5fb4; text-decoration:none; }}
  .lnk.off {{ color:#b0b0ba; }}
  @media (prefers-color-scheme: dark) {{
    body {{ background:#131316; color:#e8e8ee; }}
    .panel, .card {{ background:#1c1c21; border-color:#2e2e36; }}
    .lead, .meta, .meta2 {{ color:#9a9aa6; }}
    .zh {{ color:#c8c8d2; }}
    h2 {{ border-color:#2e2e36; }}
    .lnk {{ color:#7ab0ff; }}
    .src[data-src=gps]   {{ background:#12294a; color:#9cc6ff; }}
    .src[data-src=meta]  {{ background:#12331f; color:#9fe0b6; }}
    .src[data-src=cat]   {{ background:#3a2b0f; color:#f0cc8a; }}
    .src[data-src=apple] {{ background:#2a1c42; color:#c8a8f0; }}
    .src[data-src=other] {{ background:#26262c; color:#9a9aa6; }}
  }}
</style>
</head>
<body>
<h1>EyeGuard · 图片介绍人工核对</h1>
<p class="lead">
  共 <b>{total}</b> 条介绍。核对的目标只有一条：<b>这句介绍写的是不是这张图上真有的东西</b>。
  每张卡片给出缩略图、英文介绍、中文介绍、<code>作者 · 年份</code> 出处行、
  这条介绍的<b>依据</b>，以及通往原始图源页的链接（<b>{with_link}/{total} 条有</b>）。
</p>

<div class="panel">
  <b>依据分布</b>（越「硬」越靠左：GPS / 元数据是机器反查，类别锚点依赖人工标注）
  <ul>{dist_html}</ul>
</div>

<div class="panel">
  <b>本次核对的四个关注点</b>
  <ul>
    <li><b>地名对不对</b> —— 缩略图上的地貌是否与介绍里的地名相符</li>
    <li><b>有没有人造物</b> —— 图里是否出现建筑、船只、人物、道路等（收录标准要求纯自然）</li>
    <li><b>中文侧的中英混排是不是「该保留的」</b> —— 地名不做臆测翻译是<b>有意为之</b>；
        但若整句中文都成了英文，那是没生成出来</li>
    <li><b>出处行是人名吗</b> —— 不是授权话术、网址或 <code>(7.5 million views +)</code>；
        {no_credit} 张只有年份</li>
  </ul>
</div>
{chr(10).join(sections)}
</body>
</html>
"""
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"✓ {args.out}")
    print(f"  {total} 条 · {os.path.getsize(args.out)/1048576:.1f} MB"
          f" · 缩略图 {args.thumb}px · 有原图页 {with_link}")


if __name__ == "__main__":
    main()
