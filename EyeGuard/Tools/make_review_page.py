#!/usr/bin/env python3
"""把候选素材生成一个**可交互的筛选页**，供人工过一遍。

## 为什么不做成静态总览图

`fetch_scenes.py sheet` 输出的是 4x4 的静态拼图，一页 16 张。扩容到 400+ 候选
就是 25 页图片，人工要在 25 张图之间来回翻、还要手抄「第几张不要」——
抄错一个编号就废掉一张图，而且编号在重跑 search 后会整体位移（见 cmd_finalize
的注释）。静态图在这个规模上已经不好用了。

改成单页 HTML：
  · 一次打开，按类别分组，滚动即可；
  · **点击卡片即标记剔除**，默认全部保留（「默认保留 + 标出问题」比
    「从零挑好的」快一个数量级）；
  · 页面实时给出剔除清单，一键复制；
  · 每张卡片下面直接写出它的**标题**，与 keep.json 的定位方式一致，
    不依赖会位移的编号。

## 用法

    python make_review_page.py --candidates /tmp/eg-xxx/candidates.json \
        --out /path/to/AssetReview [--thumb-edge 480]

产出 `<out>/index.html` 与 `<out>/thumbs/*.jpg`。
缩略图按**标题哈希**缓存，重跑不重复下载。
"""

import argparse
import hashlib
import importlib.util
import json
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_fetch_scenes():
    """把 fetch_scenes.py 当模块加载，复用它的 API/下载/URL 改写逻辑。

    刻意不复制那三个函数过来 —— `sized_thumb_url` 和 `download` 里各藏着
    一个已经踩过的坑（见其 docstring），复制一份就等于把坑复制一份。
    """
    path = os.path.join(HERE, "fetch_scenes.py")
    spec = importlib.util.spec_from_file_location("fetch_scenes", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def ensure_thumb(fs, opener, entry, path, edge):
    """下载一张缩略图并**就地**缩放到页面用的尺寸。

    ⚠️ **刻意不产生临时文件。** 本机沙箱有一个「批量删除守卫」：
    一次 turn 内删除超过 50 个文件就会要求人工确认并**中止进程**，
    报 `[safe-delete][SAFE_DELETE_BULK_CONFIRM_REQUIRED] {"threshold":50,"scope":"turn"}`。

    第一版把 1280px 原图下到 `_src_<hash>.jpg`、缩放后再 `os.remove` 掉，
    跑到第 51 张就被中止；而且那个 `os.remove` 写在 `finally` 里，
    抛出时会把真正的异常一起吞掉，现场只看到守卫报错。
    改成「下到目标路径 → 就地缩放覆盖」，全程零删除。

    另注：Wikimedia 缩略图有尺寸白名单（1280 / 1920 允许），
    所以必须先按 1280 下，再本地缩到页面尺寸，不能直接请求 480。
    """
    from PIL import Image

    url = fs.sized_thumb_url(entry.get("thumb_url"), 1280)
    if not url:
        return False

    for attempt in range(2):
        if not os.path.exists(path):
            if not fs.download(opener, url, path):
                return False
            time.sleep(0.35)
        try:
            with Image.open(path) as image:
                image = image.convert("RGB")
                if max(image.size) > edge:
                    image.thumbnail((edge, edge), Image.LANCZOS)
                    image.save(path, "JPEG", quality=82, optimize=True)
            return True
        except Exception as error:                        # noqa: BLE001
            # 只可能是上次中断留下的半截文件。删掉重下一次（失败删除极少，
            # 不会逼近 50 的守卫阈值）。
            print("  ! 缩略图损坏 %s：%s" % (os.path.basename(path), error),
                  file=sys.stderr)
            if attempt == 0:
                try:
                    os.remove(path)
                except OSError:
                    pass
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--exclude-keep", default="",
                        help="keep.json 路径；其中已收录的标题会被排除，避免重复劳动")
    parser.add_argument("--thumb-edge", type=int, default=480)
    parser.add_argument("--no-refilter", action="store_true",
                        help="跳过用 fetch_scenes 词表重筛（默认会重筛）")
    parser.add_argument("--proxy", default="http://127.0.0.1:7899")
    args = parser.parse_args()

    fs = load_fetch_scenes()

    with open(args.candidates, encoding="utf-8") as handle:
        candidates = json.load(handle)

    already = set()
    if args.exclude_keep and os.path.exists(args.exclude_keep):
        with open(args.exclude_keep, encoding="utf-8") as handle:
            keep = json.load(handle)
        already = {item["title"].strip().lower()
                   for items in keep.values() for item in items}
        print("已收录 %d 张，将从候选里排除" % len(already))

    thumbs_dir = os.path.join(args.out, "thumbs")
    os.makedirs(thumbs_dir, exist_ok=True)

    opener = fs.build_opener(args.proxy)
    items = []
    skipped = 0
    failed = 0
    blocked = []

    for category, entries in candidates.items():
        for entry in entries:
            if entry["title"].strip().lower() in already:
                skipped += 1
                continue
            # 用与 search 阶段**同一套**词表再筛一遍。
            #
            # 理由：`candidates.json` 是补词表**之前**跑出来的。扩容过程中人工
            # 抽查发现漏网图后往 BLOCK_WORDS 补了新词，若不在这一步重筛，
            # 新词就只对下一次 search 生效，当前这批等于白补。
            # 复用 fs 的正则（而不是自己再写一份）是为了两处永远同源 ——
            # 词表有两份副本时，一定会有一份先过期。
            if not args.no_refilter and (
                    fs.BLOCK_RE.search(entry["title"])
                    or fs.BLOCK_SUBSTRING_RE.search(entry["title"])):
                blocked.append(entry["title"])
                continue

            digest = hashlib.sha1(entry["title"].encode("utf-8")).hexdigest()[:12]
            small = os.path.join(thumbs_dir, digest + ".jpg")
            if not ensure_thumb(fs, opener, entry, small, args.thumb_edge):
                failed += 1
                continue

            items.append({
                "key": digest,
                "category": category,
                "title": entry["title"].replace("File:", ""),
                "full": entry["title"],
                "aspect": entry.get("aspect"),
                "size": "%dx%d" % (entry.get("width", 0), entry.get("height", 0)),
                "license": entry.get("license", ""),
                "artist": (entry.get("artist") or "")[:60],
            })

    order = list(candidates.keys())
    items.sort(key=lambda i: (order.index(i["category"]), i["key"]))

    html = render(items, order, args.thumb_edge)
    index_path = os.path.join(args.out, "index.html")
    with open(index_path, "w", encoding="utf-8") as handle:
        handle.write(html)

    print("\n候选 %d 张：排除已收录 %d，词表重筛掉 %d，缩略图失败 %d，进入筛选页 %d 张"
          % (sum(len(v) for v in candidates.values()), skipped, len(blocked),
             failed, len(items)))
    if blocked:
        print("\n被词表重筛掉的（新补的词才有效，这批是实际命中的）：")
        for title in blocked:
            print("  - " + title[:80])
    print("筛选页：%s" % index_path)
    return 0


def render(items, order, thumb_edge):
    from collections import Counter
    counts = Counter(item["category"] for item in items)
    blob = json.dumps(items, ensure_ascii=False)

    return """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>EyeGuard 素材筛选</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; background: #14141a; color: #e8e8ee;
         font: 14px/1.5 -apple-system, "PingFang SC", sans-serif; }
  header { position: sticky; top: 0; z-index: 10; background: #1c1c24;
           border-bottom: 1px solid #2e2e3a; padding: 12px 20px;
           display: flex; gap: 18px; align-items: center; flex-wrap: wrap; }
  h1 { font-size: 15px; font-weight: 600; margin: 0; }
  .stat { color: #9a9aab; font-size: 13px; }
  .stat b { color: #ffd76e; font-weight: 600; }
  button { background: #2b2b38; color: #e8e8ee; border: 1px solid #3c3c4c;
           border-radius: 7px; padding: 6px 14px; font-size: 13px; cursor: pointer; }
  button:hover { background: #35354a; }
  main { padding: 18px 20px 60px; }
  h2 { font-size: 14px; font-weight: 600; margin: 26px 0 10px;
       color: #ffd76e; border-bottom: 1px solid #2e2e3a; padding-bottom: 6px; }
  h2:first-child { margin-top: 0; }
  .grid { display: grid; gap: 10px;
          grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); }
  .card { background: #1c1c24; border: 2px solid #2e2e3a; border-radius: 9px;
          overflow: hidden; cursor: pointer; transition: border-color .12s; }
  .card img { display: block; width: 100%; height: 132px; object-fit: cover;
              background: #0d0d12; }
  .card .meta { padding: 6px 8px 8px; }
  .card .t { font-size: 11px; color: #b9b9c8; line-height: 1.35;
             height: 30px; overflow: hidden; }
  .card .s { font-size: 10px; color: #6f6f80; margin-top: 3px; }
  .card.dropped { border-color: #d9534f; }
  .card.dropped img { opacity: .28; filter: grayscale(1); }
  .card.dropped .meta { opacity: .45; }
  .legend { font-size: 12px; color: #9a9aab; margin: 8px 0 0; }
  code { background: #2b2b38; padding: 1px 5px; border-radius: 4px; font-size: 12px; }
  .export { display: none; padding: 10px 20px; background: #1c1c24;
            border-bottom: 1px solid #2e2e3a; }
  .export.show { display: block; }
  .export .hint { font-size: 12px; color: #9a9aab; margin-bottom: 6px; }
  .export textarea { width: 100%; height: 108px; background: #0d0d12; color: #e8e8ee;
                     border: 1px solid #3c3c4c; border-radius: 6px; padding: 8px;
                     font: 12px/1.4 ui-monospace, Menlo, monospace; resize: vertical; }
</style>
</head>
<body>
<header>
  <h1>EyeGuard 素材筛选</h1>
  <span class="stat">共 <b id="total">0</b> 张 · 已剔除 <b id="ndrop">0</b> 张 · 保留 <b id="nkeep">0</b> 张</span>
  <button id="copy">复制剔除清单</button>
  <button id="reset">全部恢复</button>
  <button id="copykeep">复制保留清单</button>
</header>
<div class="export" id="export">
  <div class="hint" id="exportHint"></div>
  <textarea id="exportText" readonly spellcheck="false"></textarea>
</div>
<main>
  <p class="legend">
    默认全部保留。<b>点击卡片 = 剔除</b>（再点一次撤销）。看完后点「复制剔除清单」，
    把结果发给我即可。缩略图只用于判断构图与内容，成品是 1920px 原图。
  </p>
  <div id="root"></div>
</main>
<script>
const ITEMS = __BLOB__;
const ORDER = __ORDER__;
const dropped = new Set();
const root = document.getElementById('root');
const byCat = {};
for (const it of ITEMS) (byCat[it.category] ||= []).push(it);

for (const cat of ORDER) {
  const list = byCat[cat];
  if (!list || !list.length) continue;
  const h = document.createElement('h2');
  h.textContent = cat + '（' + list.length + ' 张）';
  root.appendChild(h);
  const g = document.createElement('div');
  g.className = 'grid';
  for (const it of list) {
    const c = document.createElement('div');
    c.className = 'card';
    c.dataset.key = it.key;
    c.innerHTML =
      '<img loading="lazy" src="thumbs/' + it.key + '.jpg" alt="">' +
      '<div class="meta"><div class="t">' + it.title + '</div>' +
      '<div class="s">' + it.size + ' · ' + it.license + '</div></div>';
    c.onclick = () => {
      if (dropped.has(it.key)) dropped.delete(it.key); else dropped.add(it.key);
      c.classList.toggle('dropped', dropped.has(it.key));
      update();
    };
    g.appendChild(c);
  }
  root.appendChild(g);
}

function update() {
  document.getElementById('total').textContent = ITEMS.length;
  document.getElementById('ndrop').textContent = dropped.size;
  document.getElementById('nkeep').textContent = ITEMS.length - dropped.size;
}
function writeClipboard(text, label) {
  const box = document.getElementById('export');
  const area = document.getElementById('exportText');
  const hint = document.getElementById('exportHint');
  const manual = '已填入下方文本框。按 <code>⌘A</code> 全选、<code>⌘C</code> 复制后发给我即可。';
  area.value = text;
  box.classList.add('show');
  area.focus();
  area.select();
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        () => { hint.innerHTML = '✅ ' + (label || '清单') + '已复制到剪贴板，直接粘贴给我即可。'; },
        () => { hint.innerHTML = '自动复制被浏览器拦截。' + manual; });
      hint.innerHTML = '已填入下方文本框，正在尝试复制到剪贴板…';
      return;
    }
  } catch (e) { /* 落到手动复制 */ }
  hint.innerHTML = manual;
}
document.getElementById('copy').onclick = () => {
  const lines = ITEMS.filter(i => dropped.has(i.key))
                     .map(i => i.category + '\\t' + i.full);
  writeClipboard(lines.join('\\n') || '（没有剔除任何一张）', '剔除清单');
};
document.getElementById('copykeep').onclick = () => {
  const lines = ITEMS.filter(i => !dropped.has(i.key))
                     .map(i => i.category + '\\t' + i.full);
  writeClipboard(lines.join('\\n'), '保留清单');
};
document.getElementById('reset').onclick = () => {
  dropped.clear();
  document.querySelectorAll('.card').forEach(c => c.classList.remove('dropped'));
  update();
};
update();
</script>
</body>
</html>
""".replace("__BLOB__", blob).replace("__ORDER__", json.dumps(order))


if __name__ == "__main__":
    sys.exit(main())
