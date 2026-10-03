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


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def detect_language(text):
    """按字符占比猜源语言，决定语言包方向。"""
    cjk = 0
    latin = 0
    for ch in text:
        code = ord(ch)
        if 0x4E00 <= code <= 0x9FFF or 0x3040 <= code <= 0x30FF:
            cjk += 1
        elif ch.isascii() and ch.isalpha():
            latin += 1
    if cjk > latin:
        return "zh"
    if latin > 0:
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


def main():
    request_line = sys.stdin.readline()
    if not request_line.strip():
        return 1
    request = json.loads(request_line)
    image_path = request["image"]
    target = request.get("target", "zh")
    min_height = int(request.get("min_height", 8))
    # mode=ocr：只识别不翻译（翻译由编辑器调 API 完成）。
    mode = request.get("mode", "translate")

    emit({"event": "status", "message": "加载 OCR 模型…"})
    from rapidocr_onnxruntime import RapidOCR

    ocr = RapidOCR()

    emit({"event": "status", "message": "识别文字…"})
    result, _ = ocr(image_path)
    if not result:
        emit({"event": "done", "regions": []})
        return 0

    packs = {}
    if mode != "ocr":
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
    for box, text, confidence in result:
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
        elif source_lang is not None and source_lang != target:
            if direct is None and via_en is None:
                emit({"event": "status", "message": "加载翻译模型…"})
                direct, via_en = pick_pack(packs, source_lang, target)
                if direct is None and via_en is None:
                    emit({
                        "event": "error",
                        "message": f"没有 {source_lang}→{target} 的语言包"
                                   f"（已装：{', '.join(direct_pairs)}）",
                    })
                    return 2
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
