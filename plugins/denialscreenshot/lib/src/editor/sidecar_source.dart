// 由 tools 生成：把 sidecar/translate.py 内嵌进插件，避免依赖打包资源。
// 源文件：compositor/src/dart_shell/screenshot_tool/sidecar/translate.py

/// 翻译 sidecar 的 Python 源码。
const String translateSidecarSource = r'''
#!/usr/bin/env python3
"""denial-screenshots 翻译 sidecar。

stdin/stdout 走 JSON 行协议（编辑器为父进程）：

    请求一行： {"image": "/tmp/xxx.png", "target": "zh"}
    进度多行： {"event": "status", "message": "..."}
    结果一行： {"event": "done", "regions": [
                   {"rect": [x, y, w, h], "source": "原文",
                    "translated": "译文", "bg": [r,g,b], "fg": [r,g,b]}]}

OCR 用 RapidOCR（ONNX，CPU）；翻译直接用 Argos 语言包里的
ctranslate2 模型 + sentencepiece 推理——绕开 argostranslate 的高层
API（它的分句器 stanza 要联网拉资源，且截图短句不需要分句）。
语言包从 ~/.local/share/denial-screenshots/models/<from>_<to>/
读取，由安装向导从 HF 镜像下载解压。颜色用 PIL 采样。
"""

import glob
import json
import os
import statistics
import sys

# 子进程的 stdout 编码随启动环境 locale 变化（C/latin-1 环境会把中文写坏
# 成乱码），强制 UTF-8 保证与 Dart 端 utf8.decoder 对齐。
try:
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
except (AttributeError, ValueError):
    pass

from PIL import Image

MODELS_DIR = os.path.expanduser(
    "~/.local/share/denial-screenshots/models")
DEFAULT_MODELS_DIR = MODELS_DIR


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def detect_language(text):
    """按「词数」猜源语言，决定翻译方向。

    一个 CJK 字符≈一个词，拉丁要按空格切成词才可比。旧版直接拿拉丁字母数
    和 CJK 字数比，导致「中文里夹几个英文词」的行被误判成英文，进而被
    zh→zh「翻译」（M2M 尤其明显，表现为中文译中文）。改成词数比较后，中文
    为主的行会正确判为 zh、目标为中文时直接跳过。"""
    cjk = 0
    latin_words = 0
    in_word = False
    for ch in text:
        code = ord(ch)
        if 0x4E00 <= code <= 0x9FFF or 0x3040 <= code <= 0x30FF:
            cjk += 1
            in_word = False
        elif ch.isascii() and ch.isalpha():
            if not in_word:
                latin_words += 1
                in_word = True
        else:
            in_word = False
    if cjk > 0 and cjk >= latin_words:
        return "zh"
    if latin_words > 0:
        return "en"
    return None


class PackTranslator:
    """一个语言包 = 一个 ctranslate2 模型 + 一个 sentencepiece 分词器。

    Argos 包目录布局：model/（ctranslate2）+ sentencepiece.model，
    metadata.json 记录 from_code/to_code。
    """

    def __init__(self, package_dir):
        import ctranslate2
        import sentencepiece as spm

        with open(os.path.join(package_dir, "metadata.json")) as f:
            metadata = json.load(f)
        self.from_code = metadata["from_code"]
        self.to_code = metadata["to_code"]
        self._translator = ctranslate2.Translator(
            os.path.join(package_dir, "model"), device="cpu")
        self._sp = spm.SentencePieceProcessor(
            model_file=os.path.join(package_dir, "sentencepiece.model"))

    def translate(self, text):
        tokens = self._sp.encode(text, out_type=str)
        if not tokens:
            return text
        result = self._translator.translate_batch(
            [tokens], max_batch_size=32)
        hypotheses = result[0].hypotheses
        if not hypotheses:
            return text
        # sentencepiece 的下划线占位符偶尔漏到输出里，统一清掉。
        return self._sp.decode(hypotheses[0]).replace("\u2581", " ").strip()


# 单模型多语言翻译（M2M-100 418M，ctranslate2 int8）：一个模型覆盖所有
# 语种，靠 target_prefix 指定目标语言，天然适合「源语言未知/混杂」的截图，
# 这是逐语对的 Argos 语言包做不到的。代价：418M 模型 CPU 上每句约 0.4-0.6s，
# 且英→中方向偏弱（常中英夹杂）——所以默认仍是 Argos，M2M 作为可选多语言档。
_M2M_LANGS = {
    "en", "fr", "zh", "ja", "ru", "es", "de", "it", "hi", "nl", "pt", "fa",
}
_M2M_CACHE = {}


def _m2m_base():
    """解析 M2M 模型目录，兼容两种布局：
    - `MODELS_DIR/mt/m2m100`（选到含 `mt/` 的上级，如默认下载目录）
    - `MODELS_DIR/m2m100`（直接选到 `mt` 这一层）
    返回第一个含 `model.bin` 的；都没有返回 None。load_m2m 与 discover_dir
    共用它，保证「校验」和「加载」认同一套布局。"""
    for base in (os.path.join(MODELS_DIR, "mt", "m2m100"),
                 os.path.join(MODELS_DIR, "m2m100")):
        if os.path.exists(os.path.join(base, "model.bin")):
            return base
    return None


def load_m2m():
    """加载 M2M 模型（见 _m2m_base 的两种布局），进程内复用。没就绪返回 None。

    缓存 key 用解析后的 base 目录：自选本地模型目录会重设 MODELS_DIR，
    若只按 "m2m100" 缓存，切目录后仍会复用上一个目录的模型。
    """
    base = _m2m_base()
    if base is None:
        return None
    if base in _M2M_CACHE:
        return _M2M_CACHE[base]
    import ctranslate2
    import sentencepiece as spm

    translator = ctranslate2.Translator(base, device="cpu")
    sp = spm.SentencePieceProcessor(
        model_file=os.path.join(base, "sentencepiece.bpe.model"))
    _M2M_CACHE[base] = (translator, sp)
    return _M2M_CACHE[base]


def m2m_translate(translator, sp, text, target):
    """按目标语言码翻译一句；目标码不在受监督集合里就退回英文，
    避免 CT2 因未知 __xx__ token 报错。"""
    tokens = sp.encode(text, out_type=str)
    if not tokens:
        return text
    if target not in _M2M_LANGS:
        target = "en"
    result = translator.translate_batch(
        [tokens], target_prefix=[[f"__{target}__"]], max_decoding_length=256)
    hypotheses = result[0].hypotheses
    if not hypotheses:
        return text
    # CT2 会把强制的 __xx__ 前缀原样回显在首个 token，去掉再解码。
    hyp = [t for t in hypotheses[0]
           if not (t.startswith("__") and t.endswith("__"))]
    return sp.decode(hyp).replace("▁", " ").strip()


def discover_dir():
    """只扫描、不加载权重：统计当前 MODELS_DIR 下可用的 Argos 语言包数与
    M2M 是否就绪。判据与 load_packs / load_m2m 的发现路径完全一致，目录选择器
    用它当场校验——校验和加载共用同一套发现逻辑，绝不会「校验过、运行挂」。

    Argos 包要凑齐 metadata.json + model/model.bin + sentencepiece.model 才算
    可用（缺任一，PackTranslator 构造即失败）；M2M 要 model.bin +
    sentencepiece.bpe.model（缺 sp，m2m 翻译会崩）。
    """
    argos = 0
    candidates = glob.glob(os.path.join(MODELS_DIR, "*"))
    candidates += glob.glob(os.path.join(MODELS_DIR, "*", "*"))
    for package_dir in candidates:
        if not os.path.isdir(package_dir):
            continue
        if not os.path.exists(
                os.path.join(package_dir, "metadata.json")):
            continue
        if not os.path.exists(
                os.path.join(package_dir, "model", "model.bin")):
            continue
        if not os.path.exists(
                os.path.join(package_dir, "sentencepiece.model")):
            continue
        argos += 1
    m2m_base = _m2m_base()
    m2m = (m2m_base is not None and
           os.path.exists(
               os.path.join(m2m_base, "sentencepiece.bpe.model")))
    return argos, m2m


def load_packs():
    """扫描模型目录（含一层子目录），按语言对建索引。"""
    packs = {}
    candidates = glob.glob(os.path.join(MODELS_DIR, "*"))
    candidates += glob.glob(os.path.join(MODELS_DIR, "*", "*"))
    for package_dir in candidates:
        metadata_path = os.path.join(package_dir, "metadata.json")
        if not os.path.isdir(package_dir) or not os.path.exists(metadata_path):
            continue
        try:
            pack = PackTranslator(package_dir)
        except (OSError, RuntimeError, ValueError) as error:
            emit({
                "event": "status",
                "message": f"跳过语言包 {package_dir}: {error}",
            })
            continue
        packs[(pack.from_code, pack.to_code)] = pack
    return packs


def pick_pack(packs, source, target):
    """优先直连语言对，其次经英语中转。"""
    if (source, target) in packs:
        return packs[(source, target)], None
    if (source, "en") in packs and ("en", target) in packs:
        return packs[(source, "en")], packs[("en", target)]
    return None, None


def sample_colors(image, box):
    """返回 (背景色, 文字色)，均为 [r,g,b]。

    背景 = 文字块四周一圈像素的中位数；文字色 = 块内与背景欧氏距离
    最远的采样像素，保证换算后可读。
    """
    x, y, w, h = box
    width, height = image.size
    x0 = max(0, x)
    y0 = max(0, y)
    x1 = min(width, x + w)
    y1 = min(height, y + h)
    if x1 <= x0 or y1 <= y0:
        return [255, 255, 255], [0, 0, 0]

    rgb = image.convert("RGB")
    ring = []
    for px in range(x0, x1):
        ring.append(rgb.getpixel((px, y0)))
        ring.append(rgb.getpixel((px, y1 - 1)))
    for py in range(y0, y1):
        ring.append(rgb.getpixel((x0, py)))
        ring.append(rgb.getpixel((x1 - 1, py)))
    bg = [int(statistics.median(channel)) for channel in zip(*ring)]

    inner = [
        rgb.getpixel((px, py))
        for py in range(y0, y1, 2)
        for px in range(x0, x1, 2)
    ]
    if not inner:
        return bg, [0, 0, 0]

    def distance(pixel):
        return sum((a - b) ** 2 for a, b in zip(pixel, bg))

    fg = max(inner, key=distance)
    return bg, [int(c) for c in fg]


# 常驻进程按模型 key 缓存 OCR 实例：onnx 加载是识别最耗时的一步，避免
# 每次请求重复载入。回退内置模型的请求不缓存，避免下载完成后仍用旧模型。
_OCR_CACHE = {}

# 自带离线、无需下载的模型：builtin = 统一包内置 PP-OCRv6 small；
# v3 = 老包 rapidocr_onnxruntime 自带 PP-OCRv3（中英），它不跟统一包走。
_BUNDLED = {"builtin", "v3"}


def load_ocr(model_key):
    """按设置选择 OCR 模型；高精度模型没下载完就回退内置并提示。

    统一 rapidocr 包里 model_path 为空即走自带模型路由（命中包内文件则不
    联网），给了 det/rec 路径就直接加载——PP-OCR 的字符字典内嵌在 rec onnx
    的 metadata 里，所以指哪个版本的 rec 就用哪套字典，不会串台。
    v3 由遗留包 rapidocr_onnxruntime 提供（自带 ch_PP-OCRv3 det+rec，零下载）。
    返回 (ocr, note)，调用方统一用 run_ocr 取归一化结果。
    """
    if model_key in _OCR_CACHE:
        return _OCR_CACHE[model_key], ""

    if model_key == "v3":
        from rapidocr_onnxruntime import RapidOCR as RapidOCRLegacy

        ocr = RapidOCRLegacy()
        ocr._ds_key = "legacy"
        _OCR_CACHE[model_key] = ocr
        return ocr, ""

    from rapidocr import RapidOCR

    if model_key in _BUNDLED:
        ocr = RapidOCR()
        ocr._ds_key = "unified"
        _OCR_CACHE[model_key] = ocr
        return ocr, ""

    base = os.path.join(MODELS_DIR, "ocr", model_key)
    onnx = sorted(glob.glob(os.path.join(base, "*.onnx")))
    det = next((f for f in onnx if "det" in os.path.basename(f)), None)
    rec = next((f for f in onnx if "rec" in os.path.basename(f)), None)
    if not (det and rec):
        fallback = RapidOCR()
        fallback._ds_key = "unified"
        return fallback, "所选 OCR 模型还没下载完，这次先用内置模型"
    ocr = RapidOCR(params={"Det.model_path": det, "Rec.model_path": rec})
    ocr._ds_key = "unified"
    _OCR_CACHE[model_key] = ocr
    return ocr, ""


def run_ocr(ocr, image_path):
    """跑一次识别，把不同包的返回归一化成 (boxes, txts, scores)。

    统一 rapidocr 给 RapidOCROutput（.boxes/.txts/.scores，boxes 是
    [N,4,2]）；老包 rapidocr_onnxruntime 给 (list[[box,text,score]], elapse)。
    """
    if getattr(ocr, "_ds_key", "unified") == "legacy":
        result, _ = ocr(image_path)
        result = result or []
        boxes = [item[0] for item in result]
        txts = [item[1] for item in result]
        scores = [item[2] for item in result]
        return boxes, txts, scores
    output = ocr(image_path)
    if output is None or getattr(output, "txts", None) is None:
        return [], [], []
    boxes = list(output.boxes) if output.boxes is not None else []
    txts = list(output.txts)
    scores = list(output.scores) if output.scores is not None else []
    return boxes, txts, scores


def main():
    # 常驻进程：一条 stdin 一行请求，处理完继续读下一条；父进程关闭
    # stdin（或发 {"quit": true}）才退出。模型实例在进程内复用。
    for request_line in sys.stdin:
        line = request_line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        if request.get("quit"):
            return 0
        try:
            handle(request)
        except Exception as error:  # noqa: BLE001
            emit({"event": "error", "message": f"处理失败：{error}"})


def handle(request):
    global MODELS_DIR
    # 自选本地模型目录：每条请求按需重设 MODELS_DIR（load_packs/load_m2m 在
    # 调用时读它）。空则回退内置下载目录，保证常驻进程切回默认时不残留旧目录。
    models_dir = (request.get("models_dir") or "").strip()
    MODELS_DIR = os.path.expanduser(models_dir) if models_dir \
        else DEFAULT_MODELS_DIR

    target = request.get("target", "zh")
    min_height = int(request.get("min_height", 8))
    # mode=ocr：只识别不翻译；mode=texts：只翻译给定文本（OCR 结果由
    # 编辑器后台缓存复用，不重复识别）；默认 translate：OCR+翻译。
    mode = request.get("mode", "translate")
    # engine=argos（默认，逐语对语言包，中英最稳最快）| m2m100（单模型多
    # 语言，适合源语言未知/混杂的截图，但英→中偏弱）。
    engine = request.get("engine", "argos")

    # mode=validate_dir：只发现、不加载，供目录选择器当场校验本地翻译模型目录。
    if mode == "validate_dir":
        argos, m2m_ready = discover_dir()
        emit({
            "event": "done",
            "argos_packs": argos,
            "m2m": m2m_ready,
        })
        return 0

    m2m = None
    if engine == "m2m100" and mode != "ocr":
        emit({"event": "status", "message": "加载 M2M 多语言模型…"})
        m2m = load_m2m()
        if m2m is None:
            emit({
                "event": "error",
                "message": "M2M 多语言模型还没下载，请在设置中下载后再用",
            })
            return 2

    if mode == "texts":
        texts = request.get("texts", [])
        if m2m is not None:
            translator, sp = m2m
            translations = []
            for text in texts:
                if detect_language(text) == target:
                    translations.append({"translated": text, "skip": True})
                    continue
                translated = m2m_translate(translator, sp, text, target)
                translations.append({
                    "translated": translated or text,
                    "skip": False,
                })
            emit({"event": "done", "translations": translations})
            return 0
        packs = load_packs()
        if not packs:
            emit({
                "event": "error",
                "message": "未找到翻译语言包，请在设置中管理本地模型",
            })
            return 2
        translations = []
        pack_cache = {}
        for text in texts:
            source_lang = detect_language(text)
            if source_lang == target:
                # 原文就是目标语言：标记跳过，编辑器不盖无意义蒙版。
                translations.append({"translated": text, "skip": True})
                continue
            if source_lang is None:
                translations.append({"translated": text, "skip": False})
                continue
            if source_lang not in pack_cache:
                emit({"event": "status", "message": "加载翻译模型…"})
                pack_cache[source_lang] = pick_pack(packs, source_lang, target)
            first, second = pack_cache[source_lang]
            if first is None and second is None:
                emit({
                    "event": "error",
                    "message": f"没有 {source_lang}→{target} 的语言包",
                })
                return 2
            translated = text if first is None else first.translate(text)
            if second is not None and translated:
                translated = second.translate(translated)
            translations.append({
                "translated": translated or text,
                "skip": False,
            })
        emit({"event": "done", "translations": translations})
        return 0

    image_path = request["image"]

    emit({"event": "status", "message": "加载 OCR 模型…"})
    ocr, ocr_note = load_ocr(request.get("ocr_model", ""))
    if ocr_note:
        emit({"event": "status", "message": ocr_note})

    emit({"event": "status", "message": "识别文字…"})
    boxes, txts, scores = run_ocr(ocr, image_path)
    if not txts:
        emit({"event": "done", "regions": []})
        return 0

    packs = {}
    if mode != "ocr" and m2m is None:
        packs = load_packs()
        if not packs:
            emit({
                "event": "error",
                "message": "未找到翻译语言包，请在设置中管理本地模型",
            })
            return 2

    regions = []
    image = Image.open(image_path)
    direct = None
    via_en = None
    for box, text, confidence in zip(boxes, txts, scores):
        xs = [p[0] for p in box]
        ys = [p[1] for p in box]
        x = max(0, int(min(xs)))
        y = max(0, int(min(ys)))
        w = int(max(xs)) - x
        h = int(max(ys)) - y
        if w <= 0 or h < min_height or not text.strip():
            continue

        source_lang = detect_language(text)
        translated = None
        if mode == "ocr":
            translated = text
        elif source_lang == target:
            # 原文就是目标语言：跳过，不做"自己盖自己"的无意义蒙版。
            continue
        elif m2m is not None:
            translator, sp = m2m
            translated = m2m_translate(translator, sp, text, target)
        elif source_lang is not None and source_lang != target:
            if direct is None and via_en is None:
                emit({"event": "status", "message": "加载翻译模型…"})
                direct, via_en = pick_pack(packs, source_lang, target)
                if direct is None and via_en is None:
                    available = ", ".join(f"{k[0]}→{k[1]}" for k in packs)
                    emit({
                        "event": "error",
                        "message": f"没有 {source_lang}→{target} 的语言包"
                                   f"（已装：{available}）",
                    })
                    return
            first, second = direct, via_en
            translated = text if first is None else first.translate(text)
            if second is not None and translated:
                translated = second.translate(translated)
        if not translated:
            translated = text

        bg, fg = sample_colors(image, (x, y, w, h))
        regions.append({
            "rect": [x, y, w, h],
            "source": text,
            "translated": translated,
            "bg": bg,
            "fg": fg,
        })
        emit({
            "event": "region",
            "rect": [x, y, w, h],
            "source": text,
            "translated": translated,
        })

    emit({"event": "done", "regions": regions})
    return 0


if __name__ == "__main__":
    sys.exit(main())
''';
