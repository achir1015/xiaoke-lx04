# -*- coding: utf-8 -*-
"""病房助理工作站：從 portal_items.json 產生 App 要用的資產。
  - assets/tools.json ：精簡工具清單（給 App 選單與內建 web server）
  - assets/qr/NN.png  ：每個工具網址的 QR 碼（白底黑點，segno 產生）
改工具就改 portal_items.json，再執行：python build_portal_assets.py
"""
import json
import os

import segno

ROOT = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(ROOT, "portal_items.json")
ASSETS = os.path.join(ROOT, "assets")
QR_DIR = os.path.join(ASSETS, "qr")


def main():
    items = json.load(open(SRC, encoding="utf-8"))
    os.makedirs(QR_DIR, exist_ok=True)
    for f in os.listdir(QR_DIR):
        if f.endswith(".png"):
            os.remove(os.path.join(QR_DIR, f))

    out = []
    for it in items:
        i = int(it["id"])
        out.append({
            "id": i,
            "name": it.get("short") or it["name"],
            "full": it["name"],
            "cat": it.get("cat", ""),
            "url": it["url"],
        })
        # QR：ECC 低、純黑白、無邊框（App 自己留白邊），放大到清晰
        segno.make(it["url"], error="l").save(
            os.path.join(QR_DIR, "%02d.png" % i), scale=6, border=0, dark="#000000", light="#ffffff")

    json.dump(out, open(os.path.join(ASSETS, "tools.json"), "w", encoding="utf-8"),
              ensure_ascii=False, separators=(",", ":"))
    cats = list(dict.fromkeys(x["cat"] for x in out))
    print("工具 %d 個、類別 %d 種：%s" % (len(out), len(cats), " / ".join(cats)))
    print("QR 碼輸出到", QR_DIR)


if __name__ == "__main__":
    main()
