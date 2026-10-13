"""从可核查的图源元数据生成图片介绍（FR-11），写回素材库 manifest。

红线（用户原话）：「但不要虚假的。」
⇒ 中文侧**不允许出现任何臆测翻译**。允许的只有三类可核查组件：
   ① GPS 逆地理编码（Nominatim / OpenStreetMap）返回的中文国/地区名；
   ② 一份**人工核对**的「英文地名 → 中文」对照表（见 REGION）；
   ③ 人工标注的类别名（说不出「哪儿」时退到「什么场景」）。
   都不命中时，中文侧保留原文地名 —— 宁可中英混排，也不编一个译名。

英文侧 = 从 ImageDescription / 文件名里提取的短语（原文，不改写、不润色）。
用户要的是「哪里的风景**或者场景**」，所以**内容描述句是合格的介绍**；
只剔除三类明显不合格的东西：样板句（"This is a photo of…"）、
摄影师署名（"Johannes Plenio 2017-05-24"）、文件噪声（相机编号、裸日期）。

每条介绍都会记下 `captionSource`（用了哪些依据字段），
它和 `caption-source.json` 一起构成「介绍可回溯」的证据链。

用法：
    python3 Tools/i18n/build_captions.py            # 只打印报告与抽样
    python3 Tools/i18n/build_captions.py --apply    # 写回 manifest.json
"""
import json, os, re, sys, unicodedata
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
SCENES = os.path.join(ROOT, "Assets", "Scenes")
SRC = os.path.join(SCENES, "caption-source.json")   # 可审计的来源数据（进版本库）
MAN = os.path.join(SCENES, "manifest.json")         # 产物：介绍写回这里

HAN = re.compile(r"[\u4e00-\u9fff]")

# Nominatim 的 zh-Hans 偶尔仍返回繁体（实测 124 个州名里混进 1 条「西北區」）。
# 只收「简体文本里绝不会出现的字」，逐字全局替换是安全的。
ZH_FIX = str.maketrans({
    "區": "区", "縣": "县", "國": "国", "島": "岛", "灣": "湾", "東": "东",
    "鎮": "镇", "鄉": "乡", "陽": "阳", "爾": "尔", "亞": "亚", "維": "维",
    "龍": "龙", "內": "内", "蘭": "兰", "蘇": "苏", "廣": "广", "寧": "宁",
    "貴": "贵", "雲": "云", "遼": "辽", "齊": "齐", "魯": "鲁", "晉": "晋",
    "閩": "闽", "粵": "粤", "贛": "赣", "滬": "沪", "陝": "陕", "萬": "万",
    "豐": "丰", "澤": "泽", "莊": "庄", "邊": "边", "關": "关", "門": "门",
})

# ---------------------------------------------------------------------------
# 人工核对的地名对照表。
# 只收「有把握」的条目。少收只是退回原文地名；**误收就是造假**。
# 匹配时按长度降序，先匹配长词（避免 "Africa" 抢走 "South Africa"）。
# ---------------------------------------------------------------------------
REGION = [
    ("Antarctica", "南极洲"), ("Scandinavia", "斯堪的纳维亚"),
    # —— 欧洲 ——
    ("United Kingdom", "英国"), ("Great Britain", "英国"), ("Britain", "英国"),
    ("Scotland", "苏格兰"), ("Wales", "威尔士"), ("England", "英格兰"),
    ("Northern Ireland", "北爱尔兰"), ("Ireland", "爱尔兰"),
    ("France", "法国"), ("Germany", "德国"), ("Italy", "意大利"),
    ("Spain", "西班牙"), ("Portugal", "葡萄牙"), ("Netherlands", "荷兰"),
    ("Belgium", "比利时"), ("Switzerland", "瑞士"), ("Austria", "奥地利"),
    ("Norway", "挪威"), ("Sweden", "瑞典"), ("Finland", "芬兰"),
    ("Denmark", "丹麦"), ("Iceland", "冰岛"), ("Poland", "波兰"),
    ("Czech Republic", "捷克"), ("Czechia", "捷克"), ("Slovakia", "斯洛伐克"),
    ("Hungary", "匈牙利"), ("Romania", "罗马尼亚"), ("Bulgaria", "保加利亚"),
    ("Greece", "希腊"), ("Croatia", "克罗地亚"), ("Slovenia", "斯洛文尼亚"),
    ("Serbia", "塞尔维亚"), ("Ukraine", "乌克兰"), ("Russia", "俄罗斯"),
    ("Turkey", "土耳其"), ("Türkiye", "土耳其"),
    ("Estonia", "爱沙尼亚"), ("Latvia", "拉脱维亚"), ("Lithuania", "立陶宛"),
    ("Albania", "阿尔巴尼亚"), ("Montenegro", "黑山"), ("Malta", "马耳他"),
    ("Cyprus", "塞浦路斯"), ("Luxembourg", "卢森堡"),
    # —— 欧洲的著名地区 ——
    ("Scottish Highlands", "苏格兰高地"), ("Highlands of Scotland", "苏格兰高地"),
    ("Lake District", "英国湖区"), ("Cornwall", "康沃尔"),
    ("Bavaria", "巴伐利亚"), ("Black Forest", "黑森林"),
    ("Provence", "普罗旺斯"), ("Tuscany", "托斯卡纳"),
    ("Andalusia", "安达卢西亚"), ("Catalonia", "加泰罗尼亚"),
    ("Corsica", "科西嘉"), ("Sardinia", "撒丁岛"), ("Sicily", "西西里岛"),
    ("Crete", "克里特岛"), ("Santorini", "圣托里尼"),
    ("Canary Islands", "加那利群岛"), ("Madeira", "马德拉"),
    ("Azores", "亚速尔群岛"), ("Svalbard", "斯瓦尔巴"),
    ("Alps", "阿尔卑斯山"), ("Dolomites", "多洛米蒂山"),
    ("Pyrenees", "比利牛斯山"), ("Carpathians", "喀尔巴阡山"),
    # —— 亚洲 ——
    ("China", "中国"), ("Japan", "日本"), ("South Korea", "韩国"),
    ("Mongolia", "蒙古"), ("India", "印度"), ("Nepal", "尼泊尔"),
    ("Bhutan", "不丹"), ("Tibet", "中国西藏"), ("Xinjiang", "中国新疆"),
    ("Yunnan", "中国云南"), ("Sichuan", "中国四川"), ("Guilin", "中国桂林"),
    ("Pakistan", "巴基斯坦"), ("Afghanistan", "阿富汗"), ("Iran", "伊朗"),
    ("Iraq", "伊拉克"), ("Israel", "以色列"), ("Jordan", "约旦"),
    ("Lebanon", "黎巴嫩"), ("Saudi Arabia", "沙特阿拉伯"),
    ("United Arab Emirates", "阿联酋"), ("Oman", "阿曼"), ("Yemen", "也门"),
    ("Armenia", "亚美尼亚"), ("Azerbaijan", "阿塞拜疆"),
    ("Kazakhstan", "哈萨克斯坦"), ("Uzbekistan", "乌兹别克斯坦"),
    ("Kyrgyzstan", "吉尔吉斯斯坦"), ("Tajikistan", "塔吉克斯坦"),
    ("Turkmenistan", "土库曼斯坦"),
    ("Sri Lanka", "斯里兰卡"), ("Bangladesh", "孟加拉国"),
    ("Myanmar", "缅甸"), ("Thailand", "泰国"), ("Laos", "老挝"),
    ("Cambodia", "柬埔寨"), ("Vietnam", "越南"), ("Malaysia", "马来西亚"),
    ("Singapore", "新加坡"), ("Indonesia", "印度尼西亚"),
    ("Philippines", "菲律宾"), ("Brunei", "文莱"),
    ("Hong Kong", "中国香港"), ("Macau", "中国澳门"), ("Taiwan", "中国台湾"),
    # —— 亚洲的著名地区 ——
    ("Himalayas", "喜马拉雅山"), ("Everest", "珠穆朗玛峰"),
    ("Mount Fuji", "富士山"), ("Hokkaido", "北海道"), ("Honshu", "本州"),
    ("Bali", "巴厘岛"), ("Java", "爪哇"), ("Borneo", "婆罗洲"),
    ("Halong Bay", "下龙湾"), ("Angkor", "吴哥"),
    ("Mekong", "湄公河"), ("Gobi", "戈壁"),
    # —— 非洲 ——
    ("Egypt", "埃及"), ("Morocco", "摩洛哥"), ("Algeria", "阿尔及利亚"),
    ("Tunisia", "突尼斯"), ("Libya", "利比亚"), ("Sudan", "苏丹"),
    ("Ethiopia", "埃塞俄比亚"), ("Kenya", "肯尼亚"), ("Tanzania", "坦桑尼亚"),
    ("Uganda", "乌干达"), ("Rwanda", "卢旺达"), ("Nigeria", "尼日利亚"),
    ("Ghana", "加纳"), ("Senegal", "塞内加尔"), ("Mali", "马里"),
    ("Cameroon", "喀麦隆"), ("Angola", "安哥拉"), ("Zambia", "赞比亚"),
    ("Zimbabwe", "津巴布韦"), ("Botswana", "博茨瓦纳"), ("Namibia", "纳米比亚"),
    ("South Africa", "南非"), ("Mozambique", "莫桑比克"),
    ("Madagascar", "马达加斯加"), ("Mauritius", "毛里求斯"),
    ("Seychelles", "塞舌尔"), ("Cape Verde", "佛得角"),
    ("Sahara", "撒哈拉沙漠"), ("Kilimanjaro", "乞力马扎罗山"),
    ("Victoria Falls", "维多利亚瀑布"),
    # —— 美洲 ——
    ("United States", "美国"), ("USA", "美国"),
    ("Canada", "加拿大"), ("Mexico", "墨西哥"), ("Cuba", "古巴"),
    ("Jamaica", "牙买加"), ("Guatemala", "危地马拉"),
    ("Costa Rica", "哥斯达黎加"), ("Panama", "巴拿马"),
    ("Colombia", "哥伦比亚"), ("Venezuela", "委内瑞拉"),
    ("Ecuador", "厄瓜多尔"), ("Peru", "秘鲁"), ("Bolivia", "玻利维亚"),
    ("Brazil", "巴西"), ("Chile", "智利"), ("Argentina", "阿根廷"),
    ("Uruguay", "乌拉圭"), ("Paraguay", "巴拉圭"),
    ("Hawaii", "美国夏威夷"), ("Alaska", "美国阿拉斯加"),
    ("California", "美国加利福尼亚州"), ("Arizona", "美国亚利桑那州"),
    ("Utah", "美国犹他州"), ("Colorado", "美国科罗拉多州"),
    ("Wyoming", "美国怀俄明州"), ("Montana", "美国蒙大拿州"),
    ("Washington", "美国华盛顿州"), ("Oregon", "美国俄勒冈州"),
    ("Nevada", "美国内华达州"), ("New Mexico", "美国新墨西哥州"),
    ("New York", "美国纽约州"), ("Florida", "美国佛罗里达州"),
    ("Texas", "美国得克萨斯州"), ("Yosemite", "优胜美地"),
    ("Yellowstone", "黄石"), ("Grand Canyon", "大峡谷"),
    ("Death Valley", "死亡谷"), ("Antelope Canyon", "羚羊峡谷"),
    ("Monument Valley", "纪念碑谷"), ("Sierra Nevada", "内华达山脉"),
    ("Rocky Mountains", "落基山脉"), ("Great Smoky Mountains", "大烟山"),
    ("Olympic National Park", "奥林匹克国家公园"),
    ("Zion", "锡安"), ("Bryce Canyon", "布莱斯峡谷"), ("Arches", "拱门"),
    ("Banff", "班夫"), ("Patagonia", "巴塔哥尼亚"),
    ("Torres del Paine", "百内国家公园"), ("Andes", "安第斯山"),
    ("Atacama", "阿塔卡马沙漠"), ("Machu Picchu", "马丘比丘"),
    ("Iguazu", "伊瓜苏"), ("Niagara", "尼亚加拉"),
    ("Greenland", "格陵兰"), ("Bahamas", "巴哈马"),
    # —— 大洋洲 ——
    ("Australia", "澳大利亚"), ("New Zealand", "新西兰"),
    ("Fiji", "斐济"), ("Papua New Guinea", "巴布亚新几内亚"),
    ("Samoa", "萨摩亚"), ("Tonga", "汤加"), ("Vanuatu", "瓦努阿图"),
    ("Solomon Islands", "所罗门群岛"), ("New Caledonia", "新喀里多尼亚"),
    ("French Polynesia", "法属波利尼西亚"),
    ("Tasmania", "塔斯马尼亚"), ("Great Barrier Reef", "大堡礁"),
    ("Milford Sound", "米尔福德峡湾"), ("Uluru", "乌鲁鲁"),
]

_region_sorted = sorted(REGION, key=lambda kv: -len(kv[0]))
REGION_RE = re.compile(
    r"(?<![A-Za-z])(" + "|".join(re.escape(k) for k, _ in _region_sorted) + r")(?![A-Za-z])")
REGION_MAP = dict(REGION)

PLACE_HINT = re.compile(
    r"\b(Lake|Loch|Fjord|River|Creek|Stream|Waterfall|Falls|Cascade|Beach|Bay|Cove|"
    r"Harbour|Harbor|Island|Isle|Peninsula|Cape|Point|Cliff|Rock|Mountain|Mount|Mt|Peak|"
    r"Range|Ridge|Valley|Canyon|Gorge|Glacier|Iceberg|Desert|Dune|Forest|Wood|Meadow|"
    r"Prairie|Grassland|Highland|Plateau|Mesa|Volcano|Crater|Caldera|Coast|Coastal|"
    r"National Park|Nature Reserve|Reservoir|Bog|Marsh|Wetland|Field|Farm|Terrace|"
    r"View|Panorama|Landscape|Sunrise|Sunset|Sky|Star|Galaxy|Aurora|Mist|Fog|Snow)\b", re.I)

# 明显不是「介绍」的内容：样板句 / 署名 / 来源声明
JUNK = re.compile(
    r"(uploaded with|commonist|own work|self[- ]?(made|photographed)|no machine[- ]readable|"
    r"this file was|description\s*[:=]|cc[- ]by|creative commons|camera location|"
    r"photo(graph)? by|photograph(ed)? by|source\s*[:=]|originally posted to|"
    r"this is a photo|natural heritage|heritage (monument|site)|"
    r"\bnumber\s*\d+\b|\btaken (by|with)\b|"
    r"^\s*keywords\s*[:：]|^\s*(subject|category|tags)\s*[:：]|"
    r"^\s*note\s*[:：]|panorama consisting of|\bstiched\b|\bthis (image|photo) is a\b|"
    r"\buser\b\s*:|\bauthor\b\s*:|^\W*$|"
    # Wiki Loves Monuments / WLE 的模板句。**必须按「框架」挡，不能按名词挡** ——
    # "nature reserve" / "natural monument" 本身是合法词，只有包在
    # "This media shows the … with the ID …" 这个框架里才是零信息量的样板。
    # ⚠️ 实测漏网 2 条（`builtin-wm-lake-23`、`builtin-wm-forest-11`），
    #    它们的名称真的被渲染成了 "This media shows the natural monument in Carinthia"。
    #    ⚠️ 注意末尾那个 `)` 在字符串**里面** —— 它闭合的是正则的整个分组，
    #    不是 `re.compile(` 的括号。改写这一行时最容易把它漏掉。
    r"this media shows|\bwith the ID\b|\bidentified by the ID\b|\blisted on the\b)", re.I)

# 文件噪声
NOISE = [
    (re.compile(r"\bWMID\d+\b"), ""),
    (re.compile(r"\s*--\s*\d{4}\s*--\s*[\d\-]+"), ""),
    (re.compile(r",?\s*\d{4}-\d{2}-\d{2},?\s*DD\s*\d+"), ""),
    (re.compile(r"\b(ARG|AUT|GER|POL|UKR|CZE)-\d{4}-"), ""),
    (re.compile(r"\(\s*(DSCF?|IMG|DSC|PIC)[-_]?\d{2,5}\s*\)"), ""),
    (re.compile(r"\b(DSCF?|IMG|DSC)[-_]?\d{4,5}\b"), ""),
    (re.compile(r"\s*\bcf\d{2}\b"), ""),
    (re.compile(r"\s*\(actm\.?\)"), ""),
    (re.compile(r"\s*\(\s*(ver|v)\s*\d+\s*\)"), ""),
    (re.compile(r"\s*\(\s*\d+\s*bis\s*\)"), ""),
    (re.compile(r"\b\d{8}\s+\d{4}\s+\d{4}\b"), ""),
    (re.compile(r"\b\d{4}-\d{2}-\d{2}\b"), ""),
    (re.compile(r"\bImage\s+\d+\b"), ""),
    (re.compile(r"\s+edit\s+filtered\b", re.I), ""),
    (re.compile(r"\s*[\(（]\s*(Unsplash|Pexels|Flickr|Pixabay|Wikimedia Commons)\s*[\)）]", re.I), ""),
    (re.compile(r"\s*[\(（]\s*[0-9a-f]{8}-[0-9a-f\-]{20,}\s*[\)）]"), ""),
    (re.compile(r"\s*\(\s*\d{2,6}\s*\)\s*$"), ""),        # 尾部 (70602)
    (re.compile(r"^\s*\d{1,2}[\s.\-–]+"), ""),           # 前导序号
    # "Alt Text: …" / "Photo: Kelly Rigby" —— 前缀是元数据标签，后面才是内容。
    # 剥掉前缀而不是整条丢掉：内容往往还能用，只是被标签挡住了。
    (re.compile(r"^\s*(alt text|photo|photograph|image|description|keywords|subject|tags|caption)"
                r"\s*[:：]\s*", re.I), ""),
    (re.compile(r"\s+\d{1,4}$"), ""),                    # 尾部序号
    (re.compile(r"\blocation\s*[:：]\s*", re.I), ""),       # "Teich Alibay Location: Ukraine, Krym"
    # "Aerial image of Stromboli" —— 前缀是元数据标签，后面的地名才是内容。
    # ⚠️ 第一版把整条 "image of" 当垃圾句丢掉了，于是这 6 条退到了类别名。
    (re.compile(r"^\s*(aerial\s+)?(image|picture|photo|view|panorama)\s+of\s+(the\s+)?", re.I), ""),
    (re.compile(r"\s*[-–—]\s*(Flickr|Unsplash|Pexels|Pixabay)\s*[-–—]\s*\S+\s*$", re.I), ""),
    (re.compile(r"^\s*\(\s*\d{1,3}\s*\)\s*"), ""),        # "(35) Tree at …"
    (re.compile(r"^\s*#\S+\s+"), ""),                         # "#mypubliclandsroadtrip stops at …"
    (re.compile(r"^\s*\d{2,4}\s*[-–]\s*\d{2,4}\s+"), ""),  # "224-5003 Smotrych Canyon"
    (re.compile(r"(?<=[A-Za-z])_(?=[A-Za-z])"), " "),        # Parc_national -> Parc national
]

STOP_TAIL = {"the", "a", "an", "of", "in", "on", "at", "with", "and", "to", "from",
             "near", "for", "by", "over", "under", "along", "into", "its", "their",
             "this", "that", "is", "are", "was", "as", "or", "but", "&",
             # 截断后悬在末尾的行政单位词，读起来像句子没说完
             "commune", "region", "province", "district", "county", "municipality",
             "department", "municipal", "located", "situated", "view", "seen"}

MAXLEN = 56
SENT = re.compile(r"(?<=[.!?。！？])\s+")


def drop_plus_segments(s):
    """剥掉 "+" 分隔的署名与内部编号。

    实测样例：`Dawu Mt+Hunag Chung Yu黃中佑+17755.jpg` —— 文件名把地名、
    摄影师中文名、内部编号用 "+" 串在一起。整条抄进英文侧就会出现汉字，
    而地名只有第一段。判据：纯数字段、以及「首段没有汉字但该段有汉字」的段。
    """
    if "+" not in s:
        return s
    parts = s.split("+")
    keep = [parts[0]]
    for seg in parts[1:]:
        if re.fullmatch(r"[\s\d]*", seg):
            continue                                    # 纯编号
        if HAN.search(seg) and not HAN.search(parts[0]):
            continue                                    # 署名里的中文名
        keep.append(seg)
    return "+".join(keep)


def tidy(s):
    s = drop_plus_segments(unicodedata.normalize("NFC", s or ""))
    s = re.sub(r"\s+", " ", s).strip()
    for pat, rep in NOISE:
        s = pat.sub(rep, s)
    s = re.sub(r"\(\s+", "(", s)                     # "( Khone Phapeng )" -> "(Khone Phapeng)"
    s = re.sub(r"\s+\)", ")", s)
    s = re.sub(r"\(\s*[-–—]\s*\)", " ", s)           # 空括号里的占位符
    s = re.sub(r"\s+([,;:.!?])", r"\1", s)          # "Dagestan , Russia ." -> "Dagestan, Russia."
    s = re.sub(r"\s*[,;:]\s*$", "", s)
    s = re.sub(r"^[\s,;:\-–—]+", "", s)
    s = re.sub(r"\s{2,}", " ", s)
    return s.strip(" ,;:-–—")


def trim_tail(s):
    s = s.strip(" ,;:-–—")
    while True:
        parts = s.rsplit(" ", 1)
        if len(parts) == 2 and parts[1].lower().strip(".,;:") in STOP_TAIL:
            s = parts[0].strip(" ,;:-–—")
        else:
            return s


# 截断时优先落在这几种边界上，**但只在必要时才回退**（见 shorten）。
#
# 教训（三次迭代）：
#   ① 只认逗号/分号 → "Where the Libyan Desert extends into Egypt and no longer"
#      这种没有逗号的句子被硬切在词边界上，末尾悬着 "and no longer"。
#   ② 加上连词/介词边界，但**取最靠后的一个** → 走向另一个极端：句子靠前处有
#      一个边界（"In the foreground, "）、之后很长一段没有边界，于是被切得极早。
#      实测 45/626 条内容被砍掉（"…with reflections of majestic Nanga Parbat"
#      → "…with reflections"）。
#   ③ 现在的做法：**默认按词边界切（保住内容），只有当切剩的尾巴读不完整时
#      才回退到上一个边界**。判据在 tail_is_broken()。这样只会在「本来就有缺陷」
#      的条目上产生差异，**不会拿好条目换坏条目**。
CUT_BOUNDARY = (", ", "; ", " – ", " - ", " · ",
                " and ", " with ", " where ", " which ", " that ",
                " from ", " into ", " across ", " over ", " along ",
                " near ", " at ", " in ", " on ", " of ")

# 尾巴以这些词开头 = 边界后起了一个新分句/从句，却只说了一半。
#
# ⚠️ **刻意不收 and / or / nor / for。** 并列连词连接的是**两个完整单位**
#    （"Autumn colours and stream beside Tosh-Kutla trail"、"Colorful sky with
#    luminous pink and gray clouds"），切在 " and " 上会把好介绍砍短 ——
#    实测误砍 14 条。而从句引导词后面必须跟主谓，切在那里才是真半截。
CLAUSE_HEAD = {"but", "as", "where", "which", "that", "who", "whose",
               "when", "while", "if", "then", "than", "because",
               "although", "though", "yet", "so"}

# 功能词：冠词、介词、连词、代词、系动词，以及罗曼语系冠词（"…, called les"）。
# ⚠️ 只用于「尾巴读不读得完整」的判定，**不是**用来删词的。
FUNC_WORD = CLAUSE_HEAD | {
    "the", "a", "an", "of", "in", "on", "at", "with", "to", "from", "near",
    "by", "over", "under", "along", "into", "onto", "across", "between",
    "through", "during", "after", "before", "within", "without", "against",
    "its", "their", "his", "her", "our", "your", "this", "these", "those",
    "is", "are", "was", "were", "be", "been", "being", "am",
    "have", "has", "had", "do", "does", "did",
    "&", "les", "los", "las",
    # 方位介词：切在它们后面同样读不完（"… and tea plantations above"）
    "above", "below", "behind", "beside", "beyond", "toward", "towards",
    "upon", "among", "amongst", "around", "inside", "outside", "off",
    "past", "via", "despite", "except", "beneath", "underneath", "atop",
}

# 只可能出现在词尾的「半截词」：单个小写分词（"…, sinking"）。
# ⚠️ 必须区分大小写 —— 地名里一堆 -ing（"Wyoming"、"Kvorning"）会被误判。
# ⚠️ 只收 -ing，**不收 -ed** —— 过去式动词（"three eruptions have occurred"）
#    是完整句子，判成半截词会把好介绍砍短。代价是 "…, photographed" 这类
#    被动分词尾巴漏判（实测 4 条），比误砍一批好介绍划算。
PARTICIPLE = re.compile(r"[a-z]{4,}ing\Z")


def tail_is_broken(tail):
    """判断「边界之后、切点之前」的这段尾巴是否读不完整。

    判据刻意保守：**误判的代价是把一句好介绍砍短，漏判只是留一句略生硬的介绍。**
    所以只认两种形态 —— 边界后起了一个新分句却只说了一半（"… and no longer"、
    "…, but Lake"），以及尾巴停在功能词上（"…, border between"）。
    """
    toks = [t for t in tail.split() if t.strip(",;:.-–—")]
    if not toks:
        return True                                        # 边界正好落在切点上
    first = toks[0].strip(",;:.-–—").lower()
    last = toks[-1].strip(",;:.-–—").lower()
    if first in CLAUSE_HEAD:                               # ① 起了一半的新分句
        return True
    if last in FUNC_WORD:                                  # ② 停在功能词上
        return True
    if len(toks) == 1 and PARTICIPLE.fullmatch(toks[0]):     # ③ 只剩一个小写分词
        return True
    return False


def shorten(s, limit=MAXLEN):
    """默认按词边界切（保住内容），只在尾巴读不完整时回退到上一个边界。

    两个容易写错的地方，都踩过：
    ① **回退要迭代。** "Watzmann at night with a starry sky, photographed from the"
       最近边界是 " from "，回退一次得到 "…, photographed"（照样悬垂），
       必须再回退一次到 ", "。
    ② **判断前要先把切点收干净。** 词边界会把 "…plants in bloom" 切成 "…plants in"，
       若不先 trim_tail 就去判尾巴，会看到尾巴停在功能词 "in" 上、误判为半截，
       于是把 "A summer Alpine meadow, full of Gentiana lutea plants" 砍成
       "A summer Alpine meadow, full"。所以每轮都先算 core = trim_tail(head[:cut])。
    """
    s = tidy(s)
    if len(s) <= limit:
        return re.sub(r"[.。]$", "", s) if len(s) <= limit - 12 else s
    head = s[:limit + 1]
    cut = head.rfind(" ")                             # 默认：词边界，尽量保住内容
    if cut < 14:
        return trim_tail(s[:limit])

    for _ in range(8):                                # 回退次数上限，防病态输入
        core = trim_tail(head[:cut])                  # 先把悬在末尾的功能词收掉
        if not core:
            break
        bnd = -1
        for sep in CUT_BOUNDARY:
            pos = head.rfind(sep, 0, len(core))
            if pos > bnd:
                bnd = pos
        if bnd < 14:
            break
        if not tail_is_broken(head[bnd:len(core)]):    # 尾巴带着边界词一起看
            break
        cut = bnd
    return trim_tail(head[:cut])



def is_junk(s, artist):
    t = tidy(s)
    if not t or len(t) < 3:
        return True
    if JUNK.search(t):
        return True
    a = (artist or "").strip()
    if a and a.lower() in t.lower() and len(t) - len(a) <= 10:
        return True                       # 整条就是摄影师署名
    if is_person_name(t, a):
        return True
    # 只要求「含字母」，不限文字系统 —— 第一版写死拉丁+汉字，
    # 把乌克兰语标题「Масив Близниці」整条判成了空内容。
    if not re.search(r"[^\W\d_]", t, re.UNICODE):
        return True
    return False


ZH2ENS = {}
for _en, _zh in REGION:
    ZH2ENS.setdefault(_zh, []).append(_en)


def strip_region_zh(phrase, region_zh):
    """GPS 分支只知道中文地区名，这里反查出英文写法再剥一遍。"""
    for en in ZH2ENS.get(region_zh, []):
        phrase = strip_region(phrase, en)
    return phrase


def is_person_name(t, artist):
    """「Johannes Plenio 2017-05-24」这种 —— 剥掉日期后剩下的词全在作者名里。

    ⚠️ 第一版只查「整条等于作者名」，于是 desc="Johannes Plenio 2017-05-24"
    而 artist="Johannes Plenio jplenio" 就漏过了，界面上直接显示摄影师名字。
    """
    if not artist:
        return False
    core = re.sub(r"\b(19|20)\d{2}([-/.]\d{1,2}){0,2}\b", " ", t)
    core = re.sub(r"[^\w\u4e00-\u9fff'’\- ]+", " ", core)
    toks = [w for w in core.split() if len(w) > 1]
    if not toks or len(toks) > 4:
        return False
    atoks = set(re.findall(r"[\w'’\-]+", artist.lower()))
    return all(w.lower() in atoks for w in toks)


# ---------------------------------------------------------------------------
# 署名清洗。
#
# Commons 的 `Artist` 字段不是「人名」，而是**一段自由文本**。实测 626 条里
# 62 条带噪声：整段授权话术（"Feel free to use my photos, but please mention me
# as the author…"，120 字）、派生作品样板（"Original: X\nderivative work: Y"）、
# 括号注释（"(7.5 million views +)"、"(talk · contribs)"、"(category)"）、
# 网址（"www.mikepeel.net"）、"User:" 前缀。
#
# 出处行只有 12pt 一行，塞不进 120 字。这里做一次「取人名」——
# **原始值不丢**：它保留在 `caption-source.json`（进版本库、可审计），
# 以及 manifest 的历史提交里。改的只是展示用的这个字段。
#
# ⚠️ 判据是「哪几种噪声要剥」，不是「名字长什么样」—— 后者没有词表可言。
# ---------------------------------------------------------------------------
ARTIST_BOILER = re.compile(
    r"feel free to use|this (work|photo|image|file) (was|is) taken|"
    r"if you want|please (mention|credit|attribute)|licen[cs]e|"
    r"derivative work|^\s*original\s*[:：]|attribution|reuse|"
    r"all rights reserved|public domain|cc[- ]by", re.I)

# 句子里自带「署名是谁」的几种写法 —— 先把人名抠出来，比逐条剥噪声可靠得多。
# ⚠️ 名字允许含点（"Timothy A. Gonsalves"）；第一版没收点，只抠到 "Timothy"。
NAME = r"([A-Z][\w'’\-.]*(?:\s+[A-Z][\w'’\-.]*){0,3})"
ARTIST_EXTRACT = (
    re.compile(r"\btaken by\s+" + NAME),
    re.compile(r"\bphoto(?:graph)?\s+by\s+" + NAME, re.I),
    re.compile(r"photograph(?:er|y)?\s*[:：]\s*([^\n,;]+)", re.I),
    re.compile(r"^\s*credit\s*[:：]\s*([^\n,;]+)", re.I),
)


# 句子边界：句号前**至少两个小写字母**才算真句末。
# ⚠️ 直接按 ". " 切会把中间名缩写当句末 —— "Timothy A. Gonsalves" 被切成 "Timothy A"。
SENT_END = re.compile(r"(?<=[a-z]{2})\.\s+(?=[A-Z])")


def clean_artist(raw):
    """把自由文本的 Artist 字段收敛成一个能放进一行的人名。"""
    s = (raw or "").strip()
    if not s:
        return ""
    # ① 句子自带署名写法 → 直接抠人名
    for pat in ARTIST_EXTRACT:
        m = pat.search(s)
        if m:
            name = SENT_END.split(m.group(1))[0]
            return name.strip(" .,;:-–—[]")[:40]
    # ② 逐行看：丢掉整行都是授权话术的（派生作品样板常写成两行）
    lines = [ln.strip() for ln in s.splitlines() if ln.strip()]
    keep = [ln for ln in lines if not ARTIST_BOILER.search(ln)]
    if not keep:
        return ""
    s = SENT_END.split(keep[0])[0]
    # ③ 网址、"User:" 前缀、文件名前缀
    s = re.sub(r"\bhttps?://\S+|\bwww\.\S+", " ", s, flags=re.I)
    s = re.sub(r"^\s*User\s*[:：]\s*", "", s, flags=re.I)
    s = re.sub(r"^\s*\S+\.(jpe?g|png|tiff?|gif)\s*[:：]\s*", "", s, flags=re.I)
    # ④ 括号注释与方括号
    s = re.sub(r"\s*[\(（][^)）]{0,80}[\)）]", " ", s)
    s = re.sub(r"[\[\]]", "", s)
    # ⑤ "edit by X" —— X 是修图者，不是原作者
    s = re.sub(r"\s*[,;]?\s*edit(ed)?\s+by\s+.*$", "", s, flags=re.I)
    # ⑥ 残留的标签前缀、维基的 "talk"、末尾泛称
    s = re.sub(r"^\s*(original|derivative|photo(graph)?|credit|author)\s*[:：]?\s*",
               "", s, flags=re.I)
    s = re.sub(r"\btalk\b\s*[,;]?", "", s, flags=re.I)
    s = re.sub(r"\s*[-–—,/]?\s*(photo ?graphy|photo gallery|photographer)\s*$", "",
               s, flags=re.I)
    s = re.sub(r"\s{2,}", " ", s).strip(" ,;:-–—·/")
    if len(s) > 40:                      # 还是太长就不是人名了，宁可不显示
        return ""
    return s


def find_region(text):
    if not text:
        return None
    m = REGION_RE.search(text)
    return (m.group(1), REGION_MAP[m.group(1)]) if m else None


def strip_region(phrase, region_en):
    """只在**首尾或括号里**剥掉已用中文说过的地区名，绝不动句子中间的部分。
    （第一版从任意位置剥，把 "Karakoram ranges in Pakistan" 剥成了
    "Karakoram ranges in " —— 中段出现的地区名往往正是句子的宾语。）"""
    if not region_en:
        return phrase
    r = re.escape(region_en)
    out = re.sub(r"[\(（]\s*" + r + r"\s*[\)）]", " ", phrase, flags=re.I)
    out = re.sub(r"\b(in|at|near|from|of|,)\s+" + r + r"\s*(?=[:：,;.]|$)", "", out, flags=re.I)
    out = re.sub(r"[,\s]+" + r + r"\s*$", "", out, flags=re.I)
    out = re.sub(r"^\s*" + r + r"\s*[,;\-–—]\s*", "", out, flags=re.I)
    out = re.sub(r"\s*[,;]\s*$", "", out)
    out = re.sub(r"^[\s,;:\-–—]+", "", out)
    out = re.sub(r"\s*\(\s*\)\s*", " ", out)
    out = re.sub(r"\s{2,}", " ", out)
    return out.strip(" ,;:-–—")


def pick_phrase(desc, title, artist, region_en):
    """挑一句最像「介绍」的话。返回 (短语, 依据字段名)。"""
    if desc and not is_junk(desc, artist):
        sents = [x.strip() for x in SENT.split(desc) if x.strip() and not is_junk(x, artist)]
        if sents:
            def score(s):
                v = 0
                if region_en and region_en.lower() in s.lower():
                    v += 3
                if PLACE_HINT.search(s):
                    v += 2
                if s[:1].isupper():            # 小写开头多半是被截断的片段
                    v += 2
                if "," in s:
                    v += 1
                return v
            pick = max(sents, key=score)       # max 稳定：同分取最早的一句
            return shorten(pick), "ImageDescription"
    if title and not is_junk(title, artist):
        return shorten(title), "文件名"
    return "", ""


YEAR_RE = re.compile(r"(?<![0-9])((?:19|20)\d{2})(?![0-9])")


def shot_year(full_entry):
    """拍摄年份。`DateTimeOriginal` 有四种形态（"2019-09-22 13:18:55" /
    "Taken on 16 March 2024, 16:26:33" / "11 June 2013, 23:31:36" / "1830 date QS:…"），
    **不能用 [:10] 切片** —— 切片会把 "Taken on 16 March 2024" 变成 "Taken on 1"。
    """
    if not full_entry:
        return None
    m = YEAR_RE.search(full_entry.get("date", "") or "")
    return int(m.group(1)) if m else None


def clean_title(raw):
    """Commons 文件名 -> 可读标题。"""
    s = raw or ""
    if s.lower().startswith("file:"):
        s = s[5:]
    s = re.sub(r"\.(jpe?g|png|tiff?|gif)$", "", s, flags=re.I)
    return tidy(unquote(s).replace("_", " "))


# ============================ 小字介绍（FR-11.9） ============================
#
# 用户要求：主行是「名称」，下面再加一行**小字介绍**。
#
# 难点不是排版，是**写什么**。Commons 上没有「背后的故事」—— 元数据就是
# 地名 + 类别 + 拍摄时间。所以这一行只能由**可核查组件重组**而成，
# 每个组件都能追到它的出处，**一个字的推断都不做**。
#
# 三条硬规则：
#   ① 组件是「**类别 → 时间**」，用 ` · ` 连接。**地区不进来** ——
#      中文主行本身就是「`<地区> · <原文名称>`」，地区再进小字行就是三行说同一件事；
#   ② 因此主行**不再用类别兜底**（原来找不到地区时会拿类别当前缀）。
#      类别从主行挪到小字行，中文锚点仍然在，只是换了一行 ——
#      换来的是「类别」与「地区」各出现一次，不再互相重复；
#   ③ **时间只在月份已知时才输出** —— 年份已经印在出处行里，
#      只报年份是纯重复，只会让版面显得啰嗦。
#
# 组件缺失就少一个（类别总是有），全缺则该行整行不显示（界面不得因此错位）。

CAT_ZH = {"mountain": "山峦", "ocean": "海洋", "forest": "森林", "lake": "湖泊",
          "desert": "沙漠", "snow": "雪原", "starfield": "星空",
          "grassland": "草原", "canyon": "峡谷", "aerial": "高空俯瞰",
          "custom": "我的图片"}
CAT_EN = {"mountain": "Mountains", "ocean": "Ocean", "forest": "Forest",
          "lake": "Lake", "desert": "Desert", "snow": "Snow",
          # 小字行里 "Night sky" 比 "Starfield" 读着像人话（Starfield 是程序内部的类别名）
          "starfield": "Night sky", "grassland": "Grassland",
          "canyon": "Canyon", "aerial": "Aerial view", "custom": "My Images"}

MONTH_NAMES = ["January", "February", "March", "April", "May", "June",
               "July", "August", "September", "October", "November", "December"]
_MONTH_LOOKUP = {n.lower(): i + 1 for i, n in enumerate(MONTH_NAMES)}
_MONTH_RE = re.compile("|".join(MONTH_NAMES), re.I)
_ISO_YM_RE = re.compile(r"\b((?:19|20)\d{2})-(\d{2})\b")


def shot_month(text):
    """从 `DateTimeOriginal` 解出月份；解不出返回 None —— **不猜**。

    ⚠️ 形态至少有六种，实测：
      `2014-07-23 13:54:12` / `Taken on 22 June 2017, 10:55` / `11 June 2013, 23:31:36`
      / `17 November 2015, 15:25:00 (upload date)` / `2025-11-15` / `1830 date QS:…`
    所以先试 ISO 的「年-月」，再退到英文月名；两者都没有就是 None。
    """
    if not text:
        return None
    m = _ISO_YM_RE.search(text)
    if m and 1 <= int(m.group(2)) <= 12:
        return int(m.group(2))
    m = _MONTH_RE.search(text)
    return _MONTH_LOOKUP[m.group(0).lower()] if m else None


def make_blurb(cat, year, month, main_text, lang):
    """把可核查组件拼成小字介绍。返回 (文本, 用了哪些组件)。

    组件只有两个：**类别**（人工标注）与**时间**（`DateTimeOriginal`）。
    地区刻意不进这里 —— 它在主行上。

    `main_text` 是该语言的主行文本。**类别词只要已经出现在主行里就跳过** ——
    否则会纯重复。实测两类：① Apple 那批通用名壁纸，名称本身就是类别词
    （`湖泊` / `雪原` / `沙漠 · 沙丘` / `雾中森林`）；② 名称里已经写了类别
    （`Lake Mystery, Canterbury` 里的 "Lake"、`Barron Canyon` 里的 "Canyon"）。
    跳过之后若没有别的组件，这一行就整行不显示 —— 那几张素材确实没有更多可核查信息。
    """
    parts, used = [], []

    word = (CAT_ZH if lang == "zh" else CAT_EN).get(cat, "")
    if word and word.lower() not in (main_text or "").lower():
        parts.append(word)
        used.append("类别")

    if year and month:                      # 规则 ③：只有年份时不输出
        parts.append(f"{year} 年 {month} 月" if lang == "zh"
                     else f"{MONTH_NAMES[month - 1]} {year}")
        used.append("时间")

    return " · ".join(parts), used


def build():
    """返回 {id: {captionEn, captionZh, captionSource, shotYear}}。"""
    src = json.load(open(SRC, encoding="utf-8"))
    man = json.load(open(MAN, encoding="utf-8"))
    by_id = {a["id"]: a for a in man}

    cat_zh, cat_en = CAT_ZH, CAT_EN

    out, stats = {}, {"gps": 0, "kw": 0, "none": 0}
    for aid, a in by_id.items():
        cat = a["category"]

        row = src.get(aid) or {}
        desc = row.get("desc", "") or ""
        title = clean_title(row.get("title", ""))
        artist = row.get("artist", "") or a.get("photographer") or ""
        pcats = row.get("cats") or []

        region_en = region_zh = ""
        srcs = []

        if row.get("country"):
            region_zh = row["country"]
            st = row.get("state") or ""
            if st and HAN.search(st):
                region_zh = f"{region_zh} {st}"
            srcs.append("GPS 反查")
            stats["gps"] += 1
        else:
            blob = " ".join(filter(None, [desc, title, " ".join(pcats)]))
            hit = find_region(blob)
            if hit:
                region_en, region_zh = hit
                srcs.append("元数据地名")
                stats["kw"] += 1
            else:
                stats["none"] += 1

        phrase, used = pick_phrase(desc, title, artist, region_en)
        if phrase:
            srcs.insert(0, used)
        else:
            phrase = cat_en.get(cat, cat)
            srcs.insert(0, "类别兜底")

        rest = strip_region(phrase, region_en) or phrase
        if region_zh:
            rest = strip_region_zh(rest, region_zh) or rest
            region_zh = region_zh.translate(ZH_FIX)
        elif not used:
            # 完全没抓到短语时才退到类别名 —— 否则主行会是空的。
            # ⚠️ 这里**不再**把类别当主行前缀。原实现是「找不到地区就拿类别当前缀，
            # 保证中文侧永远有个中文锚点」；现在类别改由**小字行**承担（FR-11.9），
            # 中文锚点仍在，只是换了一行 —— 换来的是「地区」与「类别」各出现一次。
            phrase = cat_en.get(cat, phrase)
            rest = cat_zh.get(cat, rest)
            srcs.append("类别兜底")

        cap_en = phrase
        cap_zh = f"{region_zh} · {rest}" if region_zh else rest
        year = shot_year(row)
        month = shot_month(row.get("date") or "")
        blurb_en, bu_en = make_blurb(cat, year, month, cap_en, "en")
        blurb_zh, bu_zh = make_blurb(cat, year, month, cap_zh, "zh")

        out[aid] = dict(captionEn=cap_en, captionZh=cap_zh,
                        captionSource="+".join(srcs),
                        shotYear=year,
                        blurbEn=blurb_en, blurbZh=blurb_zh,
                        blurbSource="+".join(bu_zh or bu_en),
                        creditName=clean_artist(a.get("photographer")))
    return out, stats


def dangling_tail(text):
    """英文介绍末尾是否悬着一个读不完整的词（介词/连词/冠词/半截分词）。

    这是**生成侧的质量指标**，只在这里报数 —— 不往 Swift 自检里搬：
    判据依赖下面这几张词表，抄一份到 Swift 就会漂移，
    而「一个永远通过的检查等于没有检查」。
    """
    if not text:
        return False
    raw = text.rsplit(" ", 1)[-1].strip(",;:.-–—")
    return raw.lower() in FUNC_WORD or bool(PARTICIPLE.fullmatch(raw))


def report(out, stats):
    print("=== 覆盖统计 ===")
    print("  ", stats, " 合计", len(out))
    print(f"   中文侧含汉字 : {sum(1 for v in out.values() if HAN.search(v['captionZh']))}/{len(out)}")
    print(f"   两语言不同   : {sum(1 for v in out.values() if v['captionEn'] != v['captionZh'])}/{len(out)}")
    print(f"   英文侧为空   : {sum(1 for v in out.values() if not v['captionEn'].strip())}")
    print(f"   中文侧为空   : {sum(1 for v in out.values() if not v['captionZh'].strip())}")
    print(f"   英文含汉字   : {sum(1 for v in out.values() if HAN.search(v['captionEn']))}")
    print(f"   英文超长     : {sum(1 for v in out.values() if len(v['captionEn']) > MAXLEN)}")
    print(f"   英文尾巴悬垂 : {sum(1 for v in out.values() if dangling_tail(v['captionEn']))}")
    print(f"   署名为空     : {sum(1 for v in out.values() if not v['creditName'])}"
          "（原始 Artist 自由文本见 caption-source.json）")
    print(f"   署名超 40 字 : {sum(1 for v in out.values() if len(v['creditName']) > 40)}")
    lens = [len(v["captionEn"]) for v in out.values() if v["captionEn"]]
    if lens:
        lens.sort()
        print(f"   英文长度     : 均值 {sum(lens)/len(lens):.1f} / 中位 {lens[len(lens)//2]} "
              f"/ 最短 {lens[0]} / 最长 {lens[-1]}")
    import collections
    print("\n=== 依据分布 ===")
    for k, v in collections.Counter(v["captionSource"] for v in out.values()).most_common():
        print(f"   {k:34s} {v}")

    # ---- 小字介绍（FR-11.9）----
    print("\n=== 小字介绍 ===")
    bl = [v["blurbZh"] for v in out.values()]
    print(f"   非空         : {sum(1 for b in bl if b)}/{len(bl)}")
    print(f"   两语言都非空 : {sum(1 for v in out.values() if v['blurbZh'] and v['blurbEn'])}")
    print(f"   两语言相同   : {sum(1 for v in out.values() if v['blurbZh'] and v['blurbZh'] == v['blurbEn'])}")
    print(f"   英文含汉字   : {sum(1 for v in out.values() if HAN.search(v['blurbEn']))}")
    print(f"   中文无汉字   : {sum(1 for v in out.values() if v['blurbZh'] and not HAN.search(v['blurbZh']))}")
    print(f"   最长（中文） : {max((len(b) for b in bl), default=0)}")
    print("   组件组合分布 :")
    for k, v in collections.Counter(x["blurbSource"] for x in out.values()).most_common():
        print(f"      {k or '（空）':16s} {v}")


def main():
    out, stats = build()
    report(out, stats)

    if "--apply" in sys.argv:
        man = json.load(open(MAN, encoding="utf-8"))
        n = 0
        for a in man:
            c = out[a["id"]]
            a["captionEn"] = c["captionEn"]
            a["captionZh"] = c["captionZh"]
            a["captionSource"] = c["captionSource"]
            # 小字介绍（FR-11.9）。空串就删键 —— 与 photographer 同理，
            # 免得界面把空串当成「有内容」而多渲染一行空行。
            for key, val in (("blurbEn", c["blurbEn"]), ("blurbZh", c["blurbZh"]),
                             ("blurbSource", c["blurbSource"])):
                if val:
                    a[key] = val
                else:
                    a.pop(key, None)
            # 署名为空就**删掉这个键**，别写空串 —— SceneAsset.photographer 是
            # String?，空串会被 credit() 当成「有名字」，出处行会变成 " · 2024"。
            if c["creditName"]:
                a["photographer"] = c["creditName"]
            else:
                a.pop("photographer", None)
            if c["shotYear"] is not None:
                a["shotYear"] = c["shotYear"]
            else:
                a.pop("shotYear", None)
            n += 1
        json.dump(man, open(MAN, "w", encoding="utf-8"), ensure_ascii=False,
                  indent=1, sort_keys=True)
        print(f"\n✓ 已写回 {n} 条 -> {MAN}")
    return 0


# ---------------------------------------------------------------------------
# ⛔️ 曾经这里有一张 17 条的人工核对表（`APPLE`），对应 macOS 随附的官方壁纸。
#
# 2026-10-13 全部移除，原因**不是质量而是授权**：
#   · 版权属 Apple Inc.，随 macOS 只授权给**本机**使用；
#   · 把 App 分发给别人 = 把 Apple 的素材一起发出去；
#   · 也就是说这 17 张让整个 App **不允许被分发** —— 这是所有商业化/开源路径的硬阻断。
# 同时移除了 `Tools/import_system_wallpapers.py`（它就是把它们收编进来的脚本）。
#
# 素材库因此从 626 张降到 609 张，**全部为 Commons 的自由授权**（CC BY / CC BY-SA / CC0 / PD）。
# 想在本机自用这 17 张的话，它们在 `/tmp/eg-removed-apple/`。
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    raise SystemExit(main())
