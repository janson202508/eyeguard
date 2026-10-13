#!/usr/bin/env python3
"""从 Wikimedia Commons 抓取护眼程序用的风景素材。

为什么要自己抓，而不是手工存图：
  · **授权要可追溯** —— 每张图都要记录作者、许可证、来源页，写进 manifest。
    手工存图做不到这一点，而「不知道来源的图」不能用。
  · **分辨率与构图要卡门槛** —— 横构图、长边 >= 2400、无人无建筑无文字，
    这些条件靠肉眼在一堆候选里筛，成本高且会漏。
  · **可重跑** —— 素材看腻了或想换风格，改一下查询词重跑即可。

数据源：Wikimedia Commons（免密钥）。
  · 只收录自由许可：CC0 / 公有领域 / CC-BY / CC-BY-SA
  · 走 Commons 官方 API，遵守其 User-Agent 要求

两条取候选的路子（产出同一份 candidates.json，下游完全复用）：
  · search —— 关键词 + 分类搜索。覆盖面广，但类别靠查询词猜，脏图多。
  · pools  —— 遍历 Commons 的**人工评审质量池**（Quality images / Featured
              pictures）。覆盖面窄，但质量有保证、类别是现成的。
  两者是**互补**关系：pools 打底，search 补 pools 覆盖不到的类别（grassland、
  aerial 就没有对得上的评审池）。

子命令：
  search    按类别跑关键词查询，把候选元数据写成 candidates.json（不下载）
  pools     改从评审质量池取候选（同上，产出同构）
  sheet     下载缩略图并拼成带编号的总览图，供人眼筛选
  finalize  按筛选结果下载原图、压到 2560px、写 manifest.json

用法示例（⚠️ `--proxy` / `--out` 是**顶层**参数，必须写在子命令前面）：
  python fetch_scenes.py --out ~/eg-assets search
  python fetch_scenes.py --out ~/eg-assets pools --per-pool 100
  python fetch_scenes.py --out ~/eg-assets sheet
  python fetch_scenes.py --out ~/eg-assets finalize --keep keep.json
"""

import argparse
import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

API = "https://commons.wikimedia.org/w/api.php"
UA = "EyeGuard-asset-fetcher/1.0 (personal eye-health app; offline asset curation)"

# 类别配额（与《需求规格书》附录 A 一致）
QUOTA = {
    "mountain": 6, "ocean": 6, "forest": 5, "lake": 5, "desert": 4,
    "snow": 4, "starfield": 5, "grassland": 5, "canyon": 4, "aerial": 6,
}

# 每个类别多路查询：先取「特色图片」类（质量最好），再用关键词兜底。
# 加 incategory 的查询命中率低但质量高，因此两者都要。
#
# ⚠️ `incategory:` 里必须写真实存在的分类名，写错不会报错，只会静默返回 0 条。
# 因此每个类别都配了 2 条纯关键词查询兜底，不依赖分类名猜得对。
# ⚠️ **`incategory:` 写错不会报错，只会静默返回 0 条。**
#
# 2026-10-11 逐条实测，发现老版本里有 **3 条查询是死的**，从建库到现在
# 一张候选都没贡献过：
#     Featured pictures of seascapes   totalhits=0
#     Featured pictures of deserts     totalhits=0
#     Featured pictures of canyons     totalhits=0
# 同时还有 9 条挂在「不存在」的分类上（glaciers / fjords / valleys /
# the night sky / aerial views / grasslands / hills / rivers / panoramas …）。
# 也就是说「候选池太薄」有很大一部分是**查询写错**造成的，不是 Commons 没图。
# 这次全部换成实测过的真实分类名。判定方法（别靠猜）：
#     action=query&list=search&srsearch=filetype:bitmap incategory:"名字"
#     看 searchinfo.totalhits 是不是 0
#
# 实测存在的分类及其文件数（2026-10-11，括号内为 files 数）：
#     Quality images of snow (1290) / nature (1094) / fjords (587)
#     landscapes (566) / valleys (553) / sunsets (522)
#     Featured pictures of landscapes (514) / Quality images of lakes (356)
#     canyons (270) / mountains (225) / beaches (186) / waterfalls (173)
#     rock formations (164) / Featured pictures of mountains (162)
#     lakes (138) / rivers (132) / sunsets (127) / islands (101)
#     national parks (96) / clouds (88) / glaciers (77) / beaches (74)
#     waterfalls (72) / forests (64) / panoramas (53) / forests (47)
#     snow (40) / volcanoes (38) / islands (31) / clouds (31) / ice (25)
#     nature (15) / national parks (4)
# 实测**不存在**（别再写）：Featured/Quality pictures of seascapes, deserts,
#     canyons, valleys, glaciers, fjords, volcanoes, grasslands, the night sky,
#     aerial views, hills, plains, tundra, wetlands, rivers, rock formations,
#     panoramas, Earth, sand dunes, ice
#
# 因此 desert / starfield / grassland / aerial 这四类**没有可用分类**，
# 只能靠关键词查询 —— 这几类的候选池天然更薄，属已知限制。
#
# 注意：查询挂在哪个类别下**不决定**成品的类别。`finalize` 的类别取自
# keep.json 的分组（见 `cmd_finalize`），所以人工筛选时完全可以把一张
# 「landscapes」查询捞来的图归到 lake 名下。挂载位置只影响构图过滤
# （ASPECT_RANGE 按类别取）与去重时的先到先得。
QUERIES = {
    "mountain": [
        'filetype:bitmap incategory:"Featured pictures of mountains"',
        'filetype:bitmap incategory:"Quality images of mountains"',
        'filetype:bitmap incategory:"Quality images of valleys"',
        'filetype:bitmap incategory:"Quality images of glaciers"',
        'filetype:bitmap incategory:"Featured pictures of volcanoes"',
        'filetype:bitmap incategory:"Featured pictures of ice"',
        'filetype:bitmap incategory:"Featured pictures of landscapes"',
        'filetype:bitmap mountain range panorama distant peaks',
        'filetype:bitmap alpine peaks landscape horizon',
        'filetype:bitmap distant mountain range haze layers',
        'filetype:bitmap summit ridge view distant valley',
        'filetype:bitmap highland plateau distant peaks horizon',
        'filetype:bitmap massif distant horizon sky',
    ],
    "ocean": [
        'filetype:bitmap incategory:"Quality images of beaches"',
        'filetype:bitmap incategory:"Featured pictures of beaches"',
        'filetype:bitmap incategory:"Quality images of islands"',
        'filetype:bitmap incategory:"Featured pictures of islands"',
        'filetype:bitmap sea horizon open ocean waves distant',
        'filetype:bitmap ocean coast horizon seascape',
        'filetype:bitmap open sea horizon calm water sky',
        'filetype:bitmap sea view from cliff distant horizon',
        'filetype:bitmap atlantic ocean horizon distant water',
        'filetype:bitmap pacific coast distant horizon sea',
        'filetype:bitmap ocean surface horizon clouds distant',
    ],
    "forest": [
        'filetype:bitmap incategory:"Featured pictures of forests"',
        'filetype:bitmap incategory:"Quality images of forests"',
        'filetype:bitmap incategory:"Quality images of nature"',
        'filetype:bitmap forest mist layers distant trees',
        'filetype:bitmap forest landscape distant valley',
        'filetype:bitmap boreal forest distant horizon',
        'filetype:bitmap rainforest canopy distant ridge',
        'filetype:bitmap woodland distant hills horizon',
        'filetype:bitmap pine forest distant mountains haze',
    ],
    "lake": [
        'filetype:bitmap incategory:"Featured pictures of lakes"',
        'filetype:bitmap incategory:"Quality images of lakes"',
        'filetype:bitmap incategory:"Quality images of fjords"',
        'filetype:bitmap incategory:"Quality images of landscapes"',
        'filetype:bitmap lake reflection mountains calm',
        'filetype:bitmap alpine lake landscape reflection',
        'filetype:bitmap glacial lake distant mountains',
        'filetype:bitmap lake shore distant horizon',
        'filetype:bitmap tarn lake mountains distant',
        'filetype:bitmap fjord water distant mountains',
    ],
    "desert": [
        # 第一轮 desert 出来的几乎全是美国犹他州 Little Sahara 娱乐区，
        # 还混进两张航天飞机舷窗照。原因是查询词只命中了一个上传者的批次。
        # 改成按沙漠名分头查 —— 撒哈拉/纳米布/阿塔卡马各自成句，
        # 出来的构图才不是一个模子。
        # ⚠️ Commons **没有** Featured/Quality pictures of deserts 分类
        # （实测 totalhits=0），这一类只能靠关键词，因此候选天然偏薄。
        'filetype:bitmap sand dunes sahara desert landscape',
        'filetype:bitmap namib desert dunes landscape',
        'filetype:bitmap atacama desert landscape distant',
        'filetype:bitmap desert dunes distant horizon sky',
        'filetype:bitmap arabian desert sand dunes landscape',
        'filetype:bitmap gobi desert landscape distant',
        'filetype:bitmap wadi desert distant horizon',
        'filetype:bitmap erg sand sea distant dunes',
        'filetype:bitmap mojave desert distant landscape',
        'filetype:bitmap kalahari desert landscape distant',
        'filetype:bitmap dune field distant horizon sand',
    ],
    "snow": [
        'filetype:bitmap incategory:"Featured pictures of snow"',
        'filetype:bitmap incategory:"Quality images of snow"',
        'filetype:bitmap incategory:"Quality images of glaciers"',
        'filetype:bitmap incategory:"Featured pictures of ice"',
        'filetype:bitmap snow covered mountains winter landscape',
        'filetype:bitmap snowfield glacier landscape horizon',
        'filetype:bitmap tundra snow distant horizon',
        'filetype:bitmap arctic snow landscape distant',
        'filetype:bitmap antarctic ice landscape distant horizon',
    ],
    "starfield": [
        # ⚠️ Commons **没有** Featured/Quality pictures of the night sky
        # （实测 totalhits=0）。这一类只能靠关键词。
        'filetype:bitmap milky way night sky landscape stars',
        'filetype:bitmap starry night sky above landscape',
        'filetype:bitmap milky way above mountain landscape night',
        'filetype:bitmap night sky stars landscape horizon',
        'filetype:bitmap star trail night sky landscape',
        'filetype:bitmap southern cross night sky landscape',
        'filetype:bitmap night sky above desert landscape stars',
        'filetype:bitmap galaxy band night sky above landscape',
    ],
    "grassland": [
        # ⚠️ Commons **没有** Featured/Quality pictures of grasslands
        # （实测 totalhits=0）。老版本写的 incategory:"Grasslands" 等几条
        # 是普通主题分类，文件数不小但混入大量近景与人工草坪，命中率低。
        'filetype:bitmap rolling hills grass landscape distant',
        'filetype:bitmap alpine meadow mountains landscape',
        'filetype:bitmap grassland horizon sky distant',
        'filetype:bitmap pasture hills landscape distant',
        'filetype:bitmap savanna grassland distant horizon',
        'filetype:bitmap steppe grassland distant horizon',
        'filetype:bitmap prairie grass landscape distant',
        'filetype:bitmap pampas grassland distant horizon',
        'filetype:bitmap meadow distant mountains horizon',
    ],
    "canyon": [
        # ⚠️ Featured pictures of canyons 实测 totalhits=0，
        # 只有 Quality images of canyons 是真的。
        'filetype:bitmap incategory:"Quality images of canyons"',
        'filetype:bitmap incategory:"Quality images of rock formations"',
        'filetype:bitmap canyon gorge valley depth landscape',
        'filetype:bitmap canyon landscape layered rock distant',
        'filetype:bitmap slot canyon distant light',
        'filetype:bitmap gorge river distant walls',
        'filetype:bitmap mesa butte distant landscape',
        'filetype:bitmap badlands landscape distant horizon',
    ],
    "aerial": [
        # 第一轮 aerial 只筛出 23 个候选（需要 6 张），是候选池最薄的类别。
        # 原因是 incategory:"Aerial photographs" 的几路查询把海岸度假小镇、
        # 缆车、运河灌溉网都带进来了，全被拦掉。改成按「俯瞰的是自然地貌」
        # 这个语义去查：河谷、冰川、三角洲、林海。
        # ⚠️ Featured/Quality pictures of aerial views 实测 totalhits=0，
        # 这一类只能靠关键词。
        'filetype:bitmap aerial view river valley landscape from above',
        'filetype:bitmap aerial view glacier mountains landscape from above',
        'filetype:bitmap aerial view forest landscape from above',
        'filetype:bitmap aerial photograph of a valley landscape',
        'filetype:bitmap aerial view mountains valley landscape above',
        'filetype:bitmap aerial view river delta landscape from above',
        'filetype:bitmap aerial view coastline landscape from above',
        'filetype:bitmap aerial view desert landscape from above',
        'filetype:bitmap aerial view mountain range from above',
    ],
}

# 各类别允许的构图范围。航拍里方构图与接近方形的比例不低，
# 一刀切 1.25 会把整个类别筛空 —— 门槛要按类别给，而不是图省事统一。
ASPECT_RANGE = {
    "aerial": (1.12, 3.4),
    "grassland": (1.20, 3.4),
}
DEFAULT_ASPECT = (1.25, 3.2)

# ── Commons「人工评审质量池」→ 本项目类别 ────────────────────────────────
#
# 这些分类的成员是 Commons 志愿者**逐张评审**后收进去的（Quality images 要过
# 构图/技术两道，Featured pictures 更高）。所以从池子里取图，等于白拿一层质量
# 过滤；而且**池子名本身就是类别**，不用再按查询词猜。
#
# 与关键词搜索的分工：池子覆盖面窄但准，搜索覆盖面广但脏。
# 两者产出同一份 candidates.json，下游 sheet / finalize 完全复用。
#
# 括号里是 2026-10-11 实测的直接成员数（子分类另有更多）。
#
# 🔴 2026-10-12 实测：**池子保证「拍得好」，不保证「没有人造物」**。
#    把 8 个类别的池子跑全、逐张人眼过完 267 张候选，实际保留率只有
#    **63%（168/267）**，远高于先前用 16 张 mountain 抽样得出的 6%。
#    分类别保留率（越高越干净）：
#      forest 86% ｜ ocean 73% ｜ canyon 71% ｜ mountain 66%
#      lake 66%   ｜ starfield 47% ｜ snow 30% ｜ desert 28%
#    snow / desert 特别脏，原因是这两类的「美图」大量是**滑雪场设施**
#    （缆车支架、雪道标杆、雪地摩托、滑雪者）与**荒漠公路/纪念碑/盐田**。
#    ⇒ 池子省不掉人工筛选这一步，只是把候选质量整体抬高一点。
QUALITY_POOLS = {
    "mountain":  ["Quality images of mountains",          # 225
                  "Featured pictures of mountains",        # 162
                  "Featured pictures of volcanoes",        # 38
                  "Quality images of valleys",             # 553
                  "Featured pictures of the Alps"],        # 34
    "forest":    ["Quality images of forests",             # 47
                  "Featured pictures of forests"],         # 64
    "lake":      ["Quality images of bodies of water",     # 51
                  "Featured pictures of bodies of water",  # 79
                  "Quality images of wetlands",
                  "Quality images of nature reserves",     # 25
                  "Quality images of lakes",               # 356
                  "Featured pictures of lakes",            # 138
                  "Quality images of rivers"],             # 132
    # ⚠️ ocean 的池子偏脏。实测抽 16 张有 8 张带人造物（石塔、城堡、修道院、
    #    海滩遮阳伞、游船、城市夜景），全量跑完保留率 73%。原因是「漂亮的海岸
    #    往往有人」，而 Featured pictures 评的是构图与技术，不管有没有人。
    #    试过的替代池同样不行：`Quality images of the North Sea` 全是
    #    Borkum 海滨度假地、`Quality images of beaches` 全是度假海滩。
    #    ⇒ ocean 以 search 为主、pools 只作补充，且**必须过人工筛选**。
    "ocean":     ["Featured pictures of coasts",           # 50
                  "Featured pictures of islands",          # 31
                  "Quality images of islands"],            # 101
    "canyon":    ["Quality images of canyons",             # 270
                  "Featured pictures of caves",            # 17
                  "Quality images of waterfalls",          # 173
                  "Featured pictures of waterfalls"],      # 72
    "snow":      ["Quality images of snow",                # 1290
                  "Quality images of glaciers",            # 77
                  "Featured pictures of ice"],             # 25
    "desert":    ["Quality images of dunes"],              # 179
    "starfield": ["Featured pictures of astronomy",        # 112
                  "Quality images of the Milky Way"],      # 4
    # ⚠️ 这两个类别**没有**对得上的评审池，只能靠关键词搜索（见 QUERIES）：
    #    · grassland —— 只有 `Quality images of fields`，但那是农田，属人造景观，
    #      正是本项目一直在剔除的东西，不能拿来充数。
    #    · aerial    —— 只有 `Aerial photographs`（73 张），那是普通分类不是评审池。
    "grassland": [],
    "aerial":    [],
}

# 标题/类别里出现这些词就丢掉。分五组：
#   1. 地图与图示 —— 不是风景
#   2. 人与人造物 —— 引导式定位要的是「自然界的远处」
#   3. 版画/标本/动物 —— 实测这三类最容易混进来：
#      搜 grasslands 会搜到 19 世纪的钢版画，搜 aerial 会搜到野生动物的
#      「从上方拍摄」，搜 canyon 会搜到带标签的岩石标本。它们都满足
#      「高分辨率 + 横构图」，只能靠标题与分类名筛掉。
#   4. 交通与工程 —— 第一轮漏得最狠的一组：缆车、管线、运河、推土机
#   5. 航天与黑白 —— 轨道/卫星拍的地球、以及去色后的图
#
# ⚠️ 匹配用 \b 词边界，不是子串包含。子串包含会误杀：
#    "sign" ⊂ "design"、"map" ⊂ "maple"、"plan" ⊂ "plantation"、
#    "cow " 抓不到 "cows"。第一版用子串，靠运气没出事，但不该继续靠运气。
BLOCK_WORDS = [
    # 1 地图与图示
    "map", "maps", "mapping", "diagram", "chart", "plan", "plans", "logo",
    "flag", "coat of arms", "seal", "topographic", "topographical",
    "satellite image", "satellite imagery", "landsat", "sentinel",
    "orthophoto", "orthomosaic", "gis", "modis",
    # 2 人与人造物
    "portrait", "person", "people", "man", "men", "woman", "women", "child",
    "children", "girl", "boy", "lady", "posing", "tourist", "hiker", "hikers",
    "building", "buildings", "church", "cathedral", "chapel", "castle", "tower",
    "bridge", "street", "city", "urban", "town", "village", "house", "houses",
    "monument", "statue", "sign", "signs", "poster", "stamp", "book",
    "painting", "drawing", "screenshot", "crowd", "ruin", "ruins", "temple",
    "monastery", "windmill", "lighthouse", "gurudwara", "gurdwara", "shrine",
    "pagoda", "mosque", "restaurant", "hotel", "cafe", "café", "resort",
    "campus", "university", "parking", "airport", "factory", "refinery",
    # 教堂在不同语言里的写法。第一轮只写了英文 church，于是漏进
    # "Crkva Gospa od Zdravlja"（克罗地亚语）这种明显是建筑的照片。
    "crkva", "kirche", "chiesa", "iglesia", "église", "eglise",
    "harbor", "harbour", "dock", "docks", "marina", "pier", "jetty",
    "promenade", "boardwalk", "umbrella", "parasol", "chair", "chairs",
    "highway",
    # ⚠️ 以下这些**故意不收**，因为误杀代价大于漏杀：
    #   "path" / "road" —— 森林小径、通往远处的路其实是很好的纵深线索，
    #                      而且 "shimmering path across the water"（水面光路）
    #                      这种纯描述性用法会被误伤；
    #   "crow" / "gate" —— "Crow Peak"（山峰名）、"Gates of the Arctic"（国家公园）
    #                      是地名，不是乌鸦和门。
    # 宁可漏掉几张有人行道的图，也不能把好素材按名字毙掉。
    # 3 版画/标本/动物
    "engraving", "lithograph", "etching", "aquatint", "woodcut", "watercolor",
    "watercolour", "illustration", "manuscript", "postcard", "photochrom",
    "specimen", "mineral", "crystal", "fossil", "hand-colored", "hand-coloured",
    "chromolithograph", "mezzotint", "steel engraving",
    "guanaco", "deer", "goat", "goats", "rooster", "chicken", "turkey", "owl",
    "bear", "cattle", "cow", "cows", "sheep", "horse", "horses", "wildlife",
    "elephant", "lion", "tiger", "bird", "birds", "eagle", "fox", "wolf",
    "squirrel", "butterfly", "insect", "lizard", "snake", "frog", "shrike",
    "gull", "seagull", "raven", "duck", "swan", "stork", "penguin",
    "flamingo", "camel", "llama", "albatross", "warbler", "finch",
    # 4 交通与工程
    "gondola", "cableway", "cable car", "cablecar", "taubane", "chairlift",
    "railway", "railroad", "train", "tram", "station", "pipeline", "canal",
    "irrigation", "distributary", "aqueduct", "dam", "reservoir", "weir",
    "bulldozer", "excavator", "crane", "construction", "machinery", "vehicle",
    "vehicles", "car", "cars", "truck", "trucks", "motorcycle", "bicycle",
    "cyclist", "tractor", "harvester", "boat", "boats", "ship", "ships",
    "sailboat", "yacht", "ferry", "kayak", "canoe", "surfboard", "surfer",
    "riding", "eclipse", "observatory", "telescope", "antenna", "radar",
    "wind turbine", "turbine", "solar panel", "power plant", "powerline",
    "pylon", "quarry", "mine", "mining", "landfill", "oil", "gas field",
    "locomotive", "wagon", "yurt", "yurts", "ovoo", "tumulus", "tumuli",
    "burial", "grave", "cemetery", "mansion", "palace", "equipment",
    "lounger", "loungers", "breakwater", "petrified",
    # 德语地名里的市政设施。德语把词连写成一个长词
    # （"FernmeldeturmKahlheidAllenbachMorbach" 整体是一个 token），
    # 词边界规则匹配不到 —— 所以这几条放在 BLOCK_SUBSTRING_RE 里按词根匹配。
    # 实测漏进来的：Fernmeldeturm 电信塔 / Ortsansicht 城镇景观 /
    # Strandbad 湖边浴场 / Stausee 水库
    # 高尔夫球场：有球道、球车、修剪过的草坪 —— 是人工景观，不是自然草原
    "golf", "golfer", "golfers", "fairway", "putting",
    # 船与园艺
    "rowboat", "rowing", "manicured", "hedge", "hedges", "mtab",
    # 5 航天与黑白
    "sts-", "sts0", "iss-", "astronaut", "from space", "from orbit",
    "space shuttle", "spacecraft", "mars", "moon", "jupiter", "saturn",
    "nebula", "galaxy cluster", "hubble", "potw", "eso", "vlt",
    "black and white", "monochrome", "grayscale", "greyscale", "bw",
    "sepia",
    # 6 专名：靠词表抓不到的矿物名与拼错的动物名
    #   "BlueTailedLizzard" 把 lizard 拼成双 z，"Howlite" 是硼钙石，
    #   两者都满足「高分辨率 + 横构图」，只能点名拉黑。
    "howlite", "lizzard", "turkenite",
    # 7 2026-10-11 扩容时人工抽查 408 张候选，补上实际漏进来的几类。
    #   下面每条都对应一张**实际看过**的漏网图，不是凭空设想的：
    #     建筑与聚落 —— "IT Pforzheimer Huette"（山间小屋，Huette 是 hut 的
    #       ASCII 拼法，旧词表只有英文 hut）、"Winter view of typical norwegian
    #       hytte (cabin)"、"Dülmen, Sportzentrum Süd, Parkplatz"（停车场）
    #     矿业 —— "Mina de Chuquicamata"（世界最大露天铜矿，旧词表只有英文 mine）
    #     赛事 —— "2018 STM Austria Skibob Hochficht GRUBER Sarah"（雪地自行车赛）
    #     档案 —— "Operation Crossroads Baker Edit"（1946 年核试验照片）、
    #       "...(NBY 443614)"（博物馆藏品编号）、"...(Ifremer 00704-81596...)"
    #   多语言拼法必须逐个列：德语连写与罗曼语系的词形变化，
    #   英文词表一条都盖不住。
    #
    # ⚠️ 刻意**不收**的，误杀代价大于漏杀：
    #   "refuge" —— "National Wildlife Refuge" 是保护区名，不是避难小屋；
    #   "station" —— 气象站/地名里太常见，而 "bahnhof" 已经能盖住车站；
    #   "hut" 单列 —— 会误伤 "Beehut"/"Hutch" 之类，只收带语言特征的 hütte/huette。
    "cabin", "hytte", "huette", "hütte", "chalet", "lodge", "rifugio", "berghaus",
    "barn", "shed", "resort", "hotel", "motel", "parkplatz", "sportzentrum",
    "dorf", "stadt", "ville", "gebäude", "bahnhof",
    "kreuz", "chapelle", "capela", "denkmal", "memorial",
    "skibob", "rennen", "wettkampf", "championship", "tournament",
    "ifremer", "nby", "mina",
    # 核试验与军事行动照片。词边界匹配下误伤风险极低 ——
    # 风景标题里不会出现单独的 "operation" / "nuclear"。
    "operation", "nuclear",
    # 8 2026-10-11 第二轮人工筛选（397 张逐张看图）后补。
    #
    #   ⚠️ 这一轮剔除的 67 张里，**旧词表一张都拦不住**。原因不是词表太短，
    #   而是漏网的全是「标题里没有英文通用词」的图，三类：
    #     ① 纯地名 —— "Chalon-sur-Saône - Île-Saint-Laurent"、"Bellinzona from above"；
    #     ② 非英语词形 —— 词表只有英文 castle/bridge/tower，盖不住
    #        castillo / puente / torre / pont / château；
    #     ③ 连写词 —— 词边界规则对 "Houseboats" 里的 boats 无效（前面是字母 e）。
    #   下面每条都对应一张**实际看过**的图。
    #
    # ① 不规则复数。`city` + `s?` 匹配不到 `cities`，于是
    #    "The Indian empire- history, topography, … chief cities and provinces"
    #    这本 19 世纪的书漏了进来。⚠️ 注意 "valleys" 是**自然景观**，绝不能收。
    "cities", "countries", "monasteries",
    # ② 非英语的建筑/塔/桥
    "castillo", "torre", "torreon", "fortress", "château", "chateau",
    "pont", "puente", "brücke", "brucke",
    # ③ 德语连写的农业与道路设施（"Feldweg" 田间路、"Felder" 田地、
    #    "Baumreihe" 树列）
    #
    #    ⚠️ 刻意**不收** "Kirchspiel"：它是 Dülmen 的**区域名**，该区域既有
    #    农田道路也有自然景观。实测加进去会误杀两张好图
    #    （"Dülmen, Kirchspiel, Bauerschaft Börnste" 是仰视树冠、
    #     "…Oedlerteich" 是芦苇日落）。误杀代价大于漏杀收益。
    "feldweg", "felder", "baumreihe", "dieselpump",
    # ③ 连写词：词边界规则对 "Houseboats" / "Lifeguard stand" 无效
    "houseboat", "lifeguards", "lifeguard",
    # 拼贴与仪式
    "montage", "collage", "ceremony",
    # 船与动物
    "carrack", "carracks", "whale", "whales", "accentor",
    # 荷兰语藏品描述词
    "gezicht",
]

# 词边界匹配，并允许可选的复数 s。
#
# ⚠️ 复数必须显式允许。第一版写成 `\bword\b`，结果 `umbrella` 匹配不到
# "colorful umbrellas"、`boat` 匹配不到 "boats" —— 一批含遮阳伞/渔船/
# 遮阳椅的海滩图全部漏过。改成 `s?` 后同时覆盖单复数，不必逐个列。
BLOCK_RE = re.compile(
    r"(?<![a-z0-9])(?:" + "|".join(re.escape(w) for w in BLOCK_WORDS) + r")s?(?![a-z0-9])",
    re.IGNORECASE)

# 这些是**前缀**，不能要求词尾边界 —— 它们总是和编号连写：
#   potw2335a（ESO 每周一图）、STS055-09-008（航天飞机舷窗照）、
#   ISS-31（空间站）、ann22042a（ESO 新闻稿）
# 用 `\bpotw\b` 匹配 "potw2335a" 会失败，因为 potw 后面紧跟数字 2。
# 第一版就是这么放进来一整批天文图片的：
#   "Hidden in the Chilean Andes (potw2335a)" 被当成沙漠风景。
BLOCK_PREFIX_RE = re.compile(
    r"(?<![a-z0-9])(?:potw|sts-?\d|iss-?\d|eso|esa\d|vlt|ann\d|jwst|hst\b)",
    re.IGNORECASE)

# 1935 年以前的作品一律不要。这一条同时干掉三类漏网：
#   油画 —— "François Diday, Glacier d'Arolla, 1874"
#   老书扫描 —— "American homes and gardens (1910)"、"Scribner's magazine (1887)"
#   早期照片 —— "Scenic, Les Zones, 1909"
# 它们的共同点是标题里带一个 19xx 年份；现代风景照不会带。
OLD_WORK_RE = re.compile(r"(?<!\d)(1[0-8]\d\d|19[0-2]\d|193[0-5])(?!\d)")

# 这几个按**子串**匹配，不要求词边界 —— 它们要么是拼错的词，要么是连写的专名：
#   "BlueTailedLizzard" —— 双 z 拼法，前面还紧跟字母 d，\b 过不去
#   "Art.IWMART1438" —— 帝国战争博物馆的藏品编号
#   德语连写词 —— "FernmeldeturmKahlheidAllenbachMorbach" 整串是一个 token
#   几位风景画家姓氏 —— 他们的作品标题往往不带年份，年份规则抓不到
BLOCK_SUBSTRING_RE = re.compile(
    r"(lizzard|art\.iwmart|momper|diday|heade|bierstadt|hokusai|hiroshige|"
    r"fernmeldeturm|ortsansicht|strandbad|stausee|"
    # ⚠️ 德语连写词必须按**子串**匹配：BLOCK_RE 的词边界要求词首前面不是字母，
    # 而 "Escheckstraße" 里的 straße 前面是 k、"Sylvensteinspeicher" 里的
    # speicher 前面是 n —— 两条都过不了词边界。2026-10-11 实测漏网。
    r"straße|strasse|speicher|"
    # `; or,` 是 19 世纪书籍标题的固定分隔式（"Wonders of the tropics; or,
    # Explorations and adventures of Henry M. Stanley"）。这类图是**书里的
    # 插图版画**，年份不在标题里所以 OLD_WORK_RE 抓不到，分类名也可能不含
    # "Books"。2026-10-11 抽查时实际漏进来一张，用这个模式补上。
    r"; or,|explorations and adventures)",
    re.IGNORECASE)

# 分类名命中这些，说明它不是「一张风景照」：
# 画作/版画/书籍/杂志，或者天文航天机构的图像库。
# 比看标题可靠 —— "Joos de Momper II - Winter landscape" 标题里看不出是画，
# 但它的分类里有 Paintings。
BLOCK_CATEGORY_RE = re.compile(
    r"\b(paintings?|oil on canvas|drawings?|prints?|engravings?|lithographs?|"
    r"books?|magazines?|postcards?|photochrom|artworks?|sculptures?|"
    r"outer space|astronomy|hubble|james webb|space telescopes?|"
    r"satellite imagery|images from nasa|images from esa)\b", re.IGNORECASE)

# 同一处风景往往会被上传成一串连续帧（"… -- 2018 -- 1253" / "… -- 1254"），
# 或者同一次拍摄的多张（"Stars and Milky Way above a Joshua tree (53433928626)"）。
# 这类近重复正是用户说的「只有几张」的成因 —— 单看每张都合格，
# 放在一起就露馅。这里按标题的**词集合相似度**去重：
# 先剥掉纯数字 token（年份、编号、文件序号），再算 Jaccard。
SERIES_JACCARD = 0.80


def series_tokens(title):
    text = title.lower()
    text = re.sub(r"\.[a-z0-9]{2,5}$", " ", text)      # 扩展名
    tokens = re.findall(r"[a-z]{2,}", text)            # 只保留长度 >= 2 的字母词
    return set(tokens)


def near_duplicate(a, b):
    """标题词集合的 Jaccard 相似度超阈值即视为近重复。"""
    if not a or not b:
        return False
    return len(a & b) / len(a | b) >= SERIES_JACCARD


def dedupe(candidates):
    """跨类别全局去重。先精确同名，再近重复。

    返回 (保留列表, 被合并列表)。被合并的要打出来 —— 静默去重会让人
    以为候选本来就少，重跑时又找不到原因。
    """
    kept, dropped, seen_tokens = [], [], []
    for candidate in candidates:
        tokens = series_tokens(candidate["title"])
        if any(near_duplicate(tokens, previous) for previous in seen_tokens):
            dropped.append(candidate)
            continue
        seen_tokens.append(tokens)
        kept.append(candidate)
    return kept, dropped

# 只收自由许可。Commons 上全部是自由许可，这里只是把清单固化下来，
# 避免以后 API 返回了别的字段被误收。
OK_LICENSE = re.compile(
    r"(cc0|cc-by|cc by|public domain|pd-|no restrictions)", re.IGNORECASE)


def build_opener(proxy):
    handlers = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers)


def api(opener, params, retries=6):
    """调 API。Commons 对匿名调用限流很紧（429），必须退避重试。

    限流时无脑重试只会加剧限流，因此这里用递增退避 + 尊重 Retry-After，
    并把最终失败显式打出来 —— 静默吞掉会让「某类别 0 候选」看起来像
    「确实没有合适的图」，而实际是限流。
    """
    url = API + "?" + urllib.parse.urlencode(params)
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with opener.open(req, timeout=60) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as error:          # noqa: PERF203
            last = error
            if error.code == 429:
                wait = float(error.headers.get("Retry-After") or 0) or (2.0 * (attempt + 1))
                time.sleep(min(wait, 20))
                continue
            time.sleep(1.5 * (attempt + 1))
        except Exception as error:                        # noqa: BLE001
            last = error
            time.sleep(1.5 * (attempt + 1))
    print(f"  ! API 失败：{last}", file=sys.stderr)
    return {}


def strip_html(value):
    text = re.sub(r"<[^>]+>", "", value or "")
    return html.unescape(text).strip()


def build_candidate(page, category, rejected):
    """把一个 API page 转成候选条目；不合格返回 None，并给 `rejected` 计数。

    `search_category`（关键词）与 `pool_category`（质量池）**共用这一段**。
    两处各写一份的话过滤规则迟早会漂移 —— 典型表现是只在一处补了新屏蔽词，
    另一条路径静默漏图，而"漏"是看不见的。
    """
    title = page.get("title", "")
    if not title:
        return None
    info = (page.get("imageinfo") or [{}])[0]
    width, height = info.get("width") or 0, info.get("height") or 0
    meta = info.get("extmetadata") or {}

    def field(key):
        return strip_html(str(meta.get(key, {}).get("value", "")))

    license_name = field("LicenseShortName") or field("UsageTerms")
    if not OK_LICENSE.search(license_name):
        rejected["license"] += 1
        return None
    if info.get("mime") not in ("image/jpeg", "image/png"):
        rejected["mime"] += 1
        return None
    # 长边够大 + 横构图。竖图在全屏休息画面上会被裁得很难看
    if width < 2400 or height < 1000:
        rejected["size"] += 1
        return None
    aspect = width / height if height else 0
    low, high = ASPECT_RANGE.get(category, DEFAULT_ASPECT)
    if not (low <= aspect <= high):
        rejected["aspect"] += 1
        return None

    title_text = title.lower()
    category_text = " ".join(
        c.get("title", "") for c in (page.get("categories") or [])).lower()
    haystack = title_text + " " + category_text

    if (BLOCK_RE.search(title_text)
            or BLOCK_PREFIX_RE.search(title_text)
            or BLOCK_SUBSTRING_RE.search(title_text)
            or BLOCK_CATEGORY_RE.search(category_text)):
        rejected["blocked"] += 1
        return None
    # 1935 年前的作品单独计数，便于区分「词表拦的」与「年份拦的」
    if OLD_WORK_RE.search(title_text):
        rejected["oldwork"] += 1
        return None
    # 除星空外不要夜景 —— 夜间素材会被 FR-4.7 排除，白天放出来又太暗
    if category != "starfield" and re.search(r"night|nocturn|aurora", haystack):
        rejected["night"] += 1
        return None

    return {
        "title": title,
        "category": category,
        "width": width,
        "height": height,
        "aspect": round(aspect, 2),
        "license": license_name,
        "license_url": field("LicenseUrl"),
        "artist": field("Artist")[:120],
        "credit": field("Credit")[:120],
        "source_page": info.get("descriptionurl", ""),
        "thumb_url": info.get("thumburl", ""),
        "original_url": info.get("url", ""),
    }


def search_category(opener, category):
    """返回 (该类别候选列表, 各类过滤计数)。候选不做截断 —— 截断在全局去重之后。"""
    seen = {}
    rejected = {"license": 0, "mime": 0, "size": 0, "aspect": 0,
                "blocked": 0, "oldwork": 0, "night": 0}
    for query in QUERIES[category]:
        data = api(opener, {
            "action": "query", "format": "json",
            "generator": "search",
            "gsrsearch": query,
            "gsrnamespace": 6,
            "gsrlimit": 40,
            "prop": "imageinfo|categories",
            "iiprop": "url|size|extmetadata|mime",
            "iiurlwidth": 1600,
            # ⚠️ `cllimit` 默认只有 10 —— 也就是**只检查前 10 个分类**。
            # 而 BLOCK_CATEGORY_RE 正是靠分类名挡掉画作/版画/书籍的
            # （标题里看不出来："Joos de Momper II - Winter landscape"）。
            # 一本插图版画的书名分类很可能排在前 10 之外，于是漏过。
            # 放宽到 50 条，代价是响应体变大，收益是分类拦截真正生效。
            "cllimit": 50,
        })
        pages = (data.get("query") or {}).get("pages") or {}
        for page in pages.values():
            title = page.get("title", "")
            if not title or title in seen:
                continue
            candidate = build_candidate(page, category, rejected)
            if candidate:
                seen[title] = candidate
        time.sleep(1.2)

    return sort_candidates(seen, category, rejected)


def pool_category(opener, category, pools, per_pool_limit=100):
    """从 Commons 的**人工评审质量池**里取候选。

    与 `search_category` 的根本区别：不靠关键词，而是直接遍历
    `Quality images …` / `Featured pictures …` 这类分类。好处有两个：

      · **质量有保证** —— 这些分类的成员是志愿者逐张评出来的，
        天然排掉了石头特写、游客照、构图不合格的图；
      · **类别是现成的** —— 池子名本身就映射到 SceneCategory，
        不需要事后按查询词猜。而"按查询词猜类别"恰恰是关键词搜索
        最不可靠的一环（搜 mountain 可能回来一堆石头）。

    代价是覆盖面窄：只有被评过图、且分类名刚好对得上我们 10 个类别的池子，
    所以它**不是替代 search，而是补充 search**。
    """
    seen = {}
    rejected = {"license": 0, "mime": 0, "size": 0, "aspect": 0,
                "blocked": 0, "oldwork": 0, "night": 0}
    for pool in pools:
        data = api(opener, {
            "action": "query", "format": "json",
            "generator": "categorymembers",
            "gcmtitle": f"Category:{pool}",
            "gcmtype": "file",
            "gcmlimit": per_pool_limit,
            "prop": "imageinfo|categories",
            "iiprop": "url|size|extmetadata|mime",
            "iiurlwidth": 1600,
            # 同 search_category：默认 10 条会让分类拦截漏检
            "cllimit": 50,
        })
        pages = (data.get("query") or {}).get("pages") or {}
        kept = 0
        for page in pages.values():
            title = page.get("title", "")
            if not title or title in seen:
                continue
            candidate = build_candidate(page, category, rejected)
            if candidate:
                seen[title] = candidate
                kept += 1
        print(f"    · {pool:<46s} 取到 {len(pages):>4d}  留下 {kept:>4d}")
        time.sleep(1.2)
    return sort_candidates(seen, category, rejected)


def sort_candidates(seen, category, rejected):
    """共用的收尾：按「接近 16:9」排序 + 全空时打一行日志。"""
    candidates = list(seen.values())
    # 宽的排前面：越接近 16:9~2:1，全屏展示越不容易被裁掉主体
    candidates.sort(key=lambda c: abs(c["aspect"] - 1.78))
    if not candidates:
        print(f"  · 该类别全部被过滤：{rejected}")
    return candidates, rejected


def cmd_search(args):
    opener = build_opener(args.proxy)
    path = os.path.join(args.out, "candidates.json")
    result = {}
    if args.only and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            result = json.load(handle)

    targets = [name.strip() for name in args.only.split(",")] if args.only else list(QUOTA)
    for category in targets:
        if category not in QUOTA:
            print(f"  ! 未知类别 {category}", file=sys.stderr)
            continue
        candidates, rejected = search_category(opener, category)
        result[category] = candidates
        print(f"{category:<10} 配额 {QUOTA[category]}  候选 {len(candidates)}"
              f"   过滤掉 {rejected}")

    return write_candidates(result, args.per_category, path)


def cmd_pools(args):
    """从 Commons 的评审质量池取候选，产出与 `search` **同构**的 candidates.json。

    这样 `sheet` / `make_review_page.py` / `finalize` 三个下游一步都不用改 ——
    「换数据源」和「换处理流程」是两件事，不该捆在一起。
    """
    opener = build_opener(args.proxy)
    path = os.path.join(args.out, "candidates.json")
    result = {}
    if args.only and os.path.exists(path):
        with open(path, encoding="utf-8") as handle:
            result = json.load(handle)

    targets = [name.strip() for name in args.only.split(",")] if args.only else list(QUOTA)
    for category in targets:
        if category not in QUOTA:
            print(f"  ! 未知类别 {category}", file=sys.stderr)
            continue
        pools = QUALITY_POOLS.get(category) or []
        if not pools:
            print(f"{category:<10} 无对应评审池，跳过（该类别请走 search）")
            result[category] = []
            continue
        print(f"{category:<10} 质量池 {len(pools)} 个：")
        candidates, rejected = pool_category(opener, category, pools, args.per_pool)
        result[category] = candidates
        print(f"{category:<10} 候选 {len(candidates)}   过滤掉 {rejected}")

    return write_candidates(result, args.per_category, path)


def write_candidates(result, per_category, path):
    """去重 → 按类别截断 → 落盘。`search` 与 `pools` 共用。"""
    # 全局去重必须在「按类别截断」之前做，否则截断先砍掉候选，
    # 去重再砍一遍，最后每类数量对不上配额。
    flat = [(category, candidate) for category in QUOTA
            for candidate in result.get(category, [])]
    kept, dropped = dedupe([candidate for _, candidate in flat])
    print(f"\n去重：合并掉 {len(dropped)} 张近重复")
    for candidate in dropped:
        print(f"  - {candidate['category']:<10} {candidate['title'][:70]}")

    kept_ids = {id(candidate) for candidate in kept}
    result = {category: [c for c in result.get(category, []) if id(c) in kept_ids]
              for category in QUOTA}
    result = {category: candidates[:per_category]
              for category, candidates in result.items()}

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2)
    print(f"\n已写出 {path}")
    print("最终每类：" + "  ".join(f"{c}={len(v)}" for c, v in result.items()))
    return 0


def sized_thumb_url(thumb_url, max_edge):
    """把 API 给的缩略图 URL 改写成指定长边；改不了就原样返回。

    API 回来的 thumb_url 形如
      .../commons/thumb/b/bb/Name.jpg/1920px-Name.jpg?utm_source=…
    最后一段路径的 `1920px-` 前缀就是尺寸标记，替换它即可。

    几个必须照顾到的边界：
      · **只动最后一段路径。** 不能直接
        `re.sub(r"/\\d+px-", …, count=1)`：文件名本身完全可能带
        `1234px-` 这样的字样（`Foo 1234px-bar.jpg`），那样 count=1 会
        改到路径里的文件名，而真正的尺寸段原封不动 —— 静默改错 URL。
      · 图片本身比请求尺寸还小时，API 直接把原图 URL 当 thumburl 返回，
        最后一段没有 `NNNpx-` 前缀 —— 此时原样返回（它仍然走
        upload.wikimedia.org，属于限流路径，但也没别的选择）。
      · `max_edge` 为空表示「不限制尺寸」，此时也原样返回。
    """
    if not thumb_url or not max_edge:
        return thumb_url or ""
    head, _, tail = thumb_url.rpartition("/")
    if not head:
        return thumb_url
    sized = re.sub(r"^\d+px-", f"{max_edge}px-", tail, count=1)
    return head + "/" + sized if sized != tail else thumb_url


def download(opener, url, path, retries=5):
    """下载一个文件。已存在且非空则跳过，因此重跑是增量式的。

    ⚠️ 退避必须**尊重完整的 Retry-After**，不能自己截断。
    实测 Wikimedia 在额度耗尽时返回 429 + `Retry-After: 600`：
    这是「这个滑动窗口内别再来了」，而不是「过一会儿重试」。

    第一版把等待截断在 60 秒（`min(wait, 60)`），于是在一个已经枯竭的
    10 分钟窗口里反复撞墙 —— 5 次重试全废，接着试下一个 URL 又是 5 次，
    表现成「10 分钟只下到 1 张图」，看起来像网络不通或图片下不动。

    实测的正确节奏（安静 10 分钟后）：间隔 3 秒连续请求 12 次全部 200。
    所以只要不突发、并且被限流后真的等满窗口，下载是稳的。
    """
    if os.path.exists(path) and os.path.getsize(path) > 4096:
        return True
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with opener.open(req, timeout=180) as response:
                data = response.read()
            with open(path, "wb") as handle:
                handle.write(data)
            return True
        except urllib.error.HTTPError as error:          # noqa: PERF203
            last = error
            if error.code == 429:
                wait = float(error.headers.get("Retry-After") or 0) or (10.0 * (attempt + 1))
                # 上限放到 600 秒：Retry-After 报多少就等多少。
                time.sleep(min(wait, 600))
                continue
            time.sleep(2.5 * (attempt + 1))
        except Exception as error:                        # noqa: BLE001
            last = error
            time.sleep(2.5 * (attempt + 1))
    print(f"  ! 下载失败（已重试 {retries} 次）{url[:90]}：{last}", file=sys.stderr)
    return False


def cmd_sheet(args):
    from PIL import Image, ImageDraw, ImageFont

    with open(os.path.join(args.out, "candidates.json"), encoding="utf-8") as handle:
        data = json.load(handle)

    opener = build_opener(args.proxy)
    font = None
    for path in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                 "/System/Library/Fonts/Helvetica.ttc"):
        if os.path.exists(path):
            try:
                font = ImageFont.truetype(path, 26)
                break
            except Exception:                             # noqa: BLE001
                pass
    if font is None:
        font = ImageFont.load_default()

    cell_w, cell_h = 420, 264
    columns, rows = 4, 4
    per_sheet = columns * rows
    sheets_dir = os.path.join(args.out, "sheets")
    os.makedirs(sheets_dir, exist_ok=True)

    index = {}
    counter = 0
    for category, candidates in data.items():
        thumbs_dir = os.path.join(args.out, "curate", category)
        os.makedirs(thumbs_dir, exist_ok=True)
        tiles = []
        for candidate in candidates:
            counter += 1
            key = f"{category}-{counter:03d}"
            index[key] = candidate
            # ⚠️ 缩略图文件名用**标题哈希**，不用编号。
            #
            # 编号是「第几张候选」，重跑一次检索就整体位移。而 download()
            # 会跳过已存在的文件当作「已下载」——于是位移之后，旧编号下的
            # 旧图会被当成本次候选的缩略图，总览图上看到的是**上一轮的图**。
            # 这种错位不会报错，只会让人对着一张对不上号的图做决策。
            # 用内容哈希做文件名，缓存就永远对得上，重跑也快。
            digest = hashlib.sha1(candidate["title"].encode("utf-8")).hexdigest()[:12]
            path = os.path.join(thumbs_dir, digest + ".jpg")
            # 筛选阶段只要看清「构图与内容」，用 1280px 就够。
            #
            # ⚠️ Wikimedia 对缩略图尺寸有白名单（见 w.wiki/GHai）：1280 / 1920 允许，
            # 2560 直接 400。成品因此也走 1920px 这条白名单路径，
            # 而不是去下原图（原图接口对批量下载限流极狠，见 cmd_finalize 的注释）。
            #
            # 走 sized_thumb_url 而不是就地 re.sub：后者不锚定「最后一段路径」，
            # 文件名里带 `1234px-` 时会把文件名改掉、尺寸段却没动。
            small = sized_thumb_url(candidate["thumb_url"], 1280)
            if download(opener, small, path):
                tiles.append((key, path))
            # 0.15 秒太急：一轮 200 张缩略图会把匿名额度烧光，
            # 紧接着的 finalize 就会整批 429。宁可选图慢一点。
            time.sleep(0.45)

        for start in range(0, len(tiles), per_sheet):
            chunk = tiles[start:start + per_sheet]
            sheet = Image.new("RGB", (cell_w * columns, cell_h * rows), (18, 18, 20))
            draw = ImageDraw.Draw(sheet)
            for position, (key, path) in enumerate(chunk):
                column, row = position % columns, position // columns
                try:
                    with Image.open(path) as image:
                        image = image.convert("RGB")
                        image.thumbnail((cell_w - 8, cell_h - 8))
                except Exception:                         # noqa: BLE001
                    continue
                x = column * cell_w + (cell_w - image.width) // 2
                y = row * cell_h + (cell_h - image.height) // 2
                sheet.paste(image, (x, y))
                label = key.split("-")[-1]
                draw.rectangle([column * cell_w + 4, row * cell_h + 4,
                                column * cell_w + 62, row * cell_h + 34],
                               fill=(0, 0, 0))
                draw.text((column * cell_w + 10, row * cell_h + 6), label,
                          fill=(255, 235, 120), font=font)
            name = f"{category}-{start // per_sheet + 1}.jpg"
            sheet.save(os.path.join(sheets_dir, name), quality=88)
            print(f"已写出 sheets/{name}（{len(chunk)} 张）")

    with open(os.path.join(args.out, "index.json"), "w", encoding="utf-8") as handle:
        json.dump(index, handle, ensure_ascii=False, indent=2)
    print(f"\n共 {len(index)} 张候选，索引已写出 index.json")
    return 0


def _manifest_entry(category, position, name, candidate, item, width, height, size):
    """构造一条 manifest 记录。

    授权信息直接从 Commons 的 extmetadata 取（`artist` / `license` /
    `source_page`），不靠人工补 —— FR-4.10 要求来源与授权可展示，
    而「不知道来源的图」不能用。
    """
    return {
        "id": f"builtin-{category}-{position:02d}",
        "fileName": name,
        "category": category,
        "source": "bundled",
        "sourceURL": candidate["source_page"],
        "photographer": candidate["artist"] or candidate["credit"] or "Wikimedia Commons",
        "license": candidate["license"],
        "width": width,
        "height": height,
        "byteSize": size,
        "depthScore": item["depthScore"],
        "tone": item["tone"],
        "originalName": candidate["title"].replace("File:", ""),
        "shownCount": 0,
    }


def cmd_finalize(args):
    """按人工筛选结果下载图片、统一长边、写 manifest.json。

    keep.json 形如：
      {"mountain": [{"title": "Hochries, Alpes del Chiemgau …", "depthScore": 4.7,
                     "tone": "cool"}, ...]}

    ⚠️ **用 title 定位，不要用 key。** key 里的编号是「第几张候选」，
    重跑一次 search 就会整体位移（多抓一轮 ocean，后面每个类别的编号都 +8），
    第一版 keep.json 就是这么失效的：50 条里有 22 条指向了不存在的编号。
    标题虽然啰嗦，但它是候选的稳定身份。key 仍兼容，仅用于手工调试。

    ⚠️ **成品长边默认 1920，不是 2560。** 原因见下面 urls 那段的注释：
    Wikimedia 对原图批量下载限流极狠（429 + Retry-After 600），
    而缩略图白名单只放 1280 / 1920。想换回 2560 就加 `--prefer-original`，
    但要有心理准备等很久。

    depthScore 与 tone 由人工看图后给出 —— 这两项是选片算法的输入，
    不能靠猜（FR-4.6 要求 >= 4 的占比不低于 70%，FR-4.7 夜间排除暖调）。
    """
    from PIL import Image, ImageOps

    with open(args.keep, encoding="utf-8") as handle:
        keep = json.load(handle)
    with open(os.path.join(args.out, "index.json"), encoding="utf-8") as handle:
        index = json.load(handle)

    by_title = {}
    for key, candidate in index.items():
        by_title.setdefault(candidate["title"].strip().lower(), (key, candidate))

    def resolve(item):
        if item.get("title"):
            hit = by_title.get(item["title"].strip().lower())
            if hit:
                return hit
            return None
        if item.get("key"):
            candidate = index.get(item["key"])
            if candidate:
                return item["key"], candidate
        return None

    opener = build_opener(args.proxy)
    out_dir = os.path.join(args.out, "final")
    os.makedirs(out_dir, exist_ok=True)

    manifest = []
    missing = []
    for category, items in keep.items():
        for position, item in enumerate(items):
            found = resolve(item)
            if not found:
                missing.append(item.get("title") or item.get("key"))
                continue
            key, candidate = found
            name = f"{category}-{position:02d}.jpg"
            target = os.path.join(out_dir, name)

            # 已经处理过的成品直接复用。批量拉原图是最容易触发 429 的操作，
            # 上一次跑到一半被限流是常态 —— 重跑时不该为已完成的图再拉一遍。
            if os.path.exists(target) and os.path.getsize(target) > 4096:
                size = os.path.getsize(target)
                with Image.open(target) as done:
                    final_w, final_h = done.size
                manifest.append(_manifest_entry(
                    category, position, name, candidate, item, final_w, final_h, size))
                print(f"  {name}  {final_w}x{final_h}  {size // 1024} KB  （已存在，跳过）")
                continue

            # 拿哪张？**优先缩略图，原图只做兜底。**
            #
            # ⚠️ 这条不是偏好，是同一次运行里对着同一个文件量出来的：
            #
            #   A) thumb.wikimedia.org/.../1920px-X.jpg      → 200
            #      x-ratelimit-limit: 600000, 600000;w=60
            #      x-ratelimit-remaining: 593537
            #      即缩略图 CDN 的额度是 60 万次/分钟，等于不限流。
            #
            #   B) upload.wikimedia.org/.../X.jpg            → 429
            #      server: Varnish / x-cache-status: int-front / retry-after: 600
            #      原图走的是内网前端，额度极小，且按 IP 共享。
            #
            # 第一版是 B 先试还是 A 先试？——**A 根本没进候选列表**，见下面注释。
            # 结果是 15 分钟只下到 15 张，看起来像「网络不通」。
            #
            # 另外白名单只放 1280 / 1920：2560 直接 400。对方在 429 的响应体里
            # 就明确写着「instead use thumbnail images in sizes listed on
            # https://w.wiki/GHai」——照做才是对的。
            #
            # 因此成品长边是 1920 而不是 2560。取舍见《需求规格书》FR-4.2：
            # 休息画面是一层被深色渐变压过的全屏背景图，1920 在观感上够用。
            urls = []
            thumb = sized_thumb_url(candidate.get("thumb_url"), args.max_edge)
            if thumb:
                # ⚠️ 这里曾经写成 `if thumb != candidate["thumb_url"]: append`，
                # 想表达「尺寸被改写过了才用」。但 API 回来的 thumb_url
                # 本来就是 `/1920px-`，改写后字符串不变 → 条件为假 →
                # **缩略图被整条跳过**，只剩原图。判据本身是错的：
                # 该问的是「它是不是一个缩略图」，而不是「它有没有被改动」。
                urls.append(thumb)
            original = candidate.get("original_url")
            if original and original not in urls:
                urls.append(original)
            if args.prefer_original:
                urls.reverse()

            # ⚠️ **直接下到目标路径，不产生任何临时文件。**
            #
            # 原写法是下到 `_raw_<key>.jpg`，处理完再 `os.remove(raw)`。
            # 但本环境有一个批量删除守卫：**一个 turn 内删除超过 50 个文件
            # 会要求人工确认并直接中止进程**（scope=turn，所以逐个删也躲不掉）。
            # 325 张必然在第 51 张被杀掉，而症状是「脚本静默中断」——
            # 看起来像网络问题或编译失败，极具误导性。已实测踩过。
            #
            # `download()` 是覆盖写（`open(path, "wb")`），且「已存在且非空则
            # 跳过」，所以直接下到 target 是安全的：重跑仍然是增量式的。
            got = None
            for url in urls:
                if download(opener, url, target):
                    got = url
                    break
            if not got:
                continue
            # 每张之间留间隔。批量拉图是最容易触发 429 的操作，
            # 限流之后再退避的成本远高于这里主动慢一点。
            time.sleep(args.pause)

            try:
                with Image.open(target) as image:
                    image = ImageOps.exif_transpose(image).convert("RGB")
                    if max(image.size) > args.max_edge:
                        ratio = args.max_edge / max(image.size)
                        image = image.resize(
                            (round(image.width * ratio), round(image.height * ratio)),
                            Image.LANCZOS)
                    # 数据读进内存，with 块一结束文件句柄即释放 ——
                    # 否则下面原地覆盖同一个路径会读到半截文件。
                    image.load()
                # ⚠️ quality=72 是**量出来的**，不是拍的（2026-10-13）。
                # 抽样 40 张实测（1920px 长边）：
                #   q88 → 694 KB/张、413 MB       （原设定）
                #   q80 → 584 KB/张、347 MB  省 15%
                #   q72 → 416 KB/张、247 MB  省 40%   ← 选它
                #   q62 → 384 KB/张、228 MB  省 44%（收益已饱和，不值）
                # 质量代价：与 q88 的差值 RMS 只有 1.5–3.9 / 255，
                # **放大 8 倍才看得出淡纹理**，1:1 看不可见。
                #
                # 另一条同样重要的结论：**降分辨率的代价远大于降质量** ——
                # 1600px q80 省 47% 但 PSNR 掉到 29.9，而 1920px q72 省 40% 还有 32.5。
                # 而且 Retina 屏（物理 2880px 宽）本来就在把 1920px 放大 1.5 倍用，
                # 再降分辨率是雪上加霜。**所以保持长边、只降质量。**
                image.save(target, "JPEG", quality=72, optimize=True,
                           progressive=True)
                size = os.path.getsize(target)
                final_w, final_h = image.size
            except Exception as error:                    # noqa: BLE001
                print(f"  ! 处理失败 {key}：{error}", file=sys.stderr)
                continue

            manifest.append(_manifest_entry(
                category, position, name, candidate, item, final_w, final_h, size))
            print(f"  {name}  {final_w}x{final_h}  {size // 1024} KB  {candidate['license']}")

    if missing:
        print(f"\n! keep.json 里有 {len(missing)} 条匹配不到候选：", file=sys.stderr)
        for name in missing:
            print(f"    {name}", file=sys.stderr)

    path = os.path.join(out_dir, "manifest.json")
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, ensure_ascii=False, indent=2, sort_keys=True)
    total = sum(item["byteSize"] for item in manifest)
    print(f"\n共 {len(manifest)} 张，合计 {total / 1024 / 1024:.1f} MB")
    print(f"manifest: {path}")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--proxy", default="http://127.0.0.1:7899",
                        help="HTTP 代理；本机直连不通 Wikimedia 时需要")
    parser.add_argument("--out", default=os.path.expanduser("~/eg-assets"))
    sub = parser.add_subparsers(dest="command", required=True)

    search = sub.add_parser("search")
    search.add_argument("--per-category", type=int, default=20,
                        help="每类最多保留多少候选（去重之后才截断）")
    search.add_argument("--only", default="",
                        help="只跑这些类别（逗号分隔），其余沿用已有 candidates.json")
    search.set_defaults(func=cmd_search)

    pools = sub.add_parser("pools",
                           help="改从 Commons 的评审质量池取候选（产出与 search 同构）")
    pools.add_argument("--per-pool", type=int, default=100,
                       help="每个质量池最多取多少条原始成员")
    pools.add_argument("--per-category", type=int, default=20,
                       help="每类最多保留多少候选（去重之后才截断）")
    pools.add_argument("--only", default="",
                       help="只跑这些类别（逗号分隔），其余沿用已有 candidates.json")
    pools.set_defaults(func=cmd_pools)

    sheet = sub.add_parser("sheet")
    sheet.set_defaults(func=cmd_sheet)

    finalize = sub.add_parser("finalize")
    finalize.add_argument("--keep", required=True)
    finalize.add_argument("--max-edge", type=int, default=1920,
                          help="成品长边。默认 1920 —— 这是 Wikimedia 缩略图白名单"
                               "允许的最大尺寸（1280/1920），原图接口对批量下载限流很狠")
    finalize.add_argument("--prefer-original", action="store_true",
                          help="优先下原图（限流不严重时才用；见 --max-edge 的说明）")
    finalize.add_argument("--pause", type=float, default=1.5,
                          help="每张之间的间隔秒数，用于避开 Wikimedia 限流")
    finalize.set_defaults(func=cmd_finalize)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
