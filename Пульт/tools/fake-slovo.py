#!/usr/bin/python3
# -*- coding: utf-8 -*-
"""Стенд: несправжнє «Слово» для заміру мережі пульта й планшета.

Відповідає тим самим каналом, що й «Слово» (`/api/state` довгим опитом, указка,
наближення, сторінки, фото, картинка залу), але не оголошує себе в мережі
(ні Bonjour, ні розсилки на 8104) — тож його не знайде ні пульт у залі, ні
справжнє «Слово», і його можна запускати, коли «Слово» власника відкрите.

Рахує кожен запит за родом і щосекунди пише рядок: скільки указки, опитів,
картинок залу, мініатюр, байтів. Цього досить, щоб звірити дві збірки на
одному й тому самому жесті.

    tools/fake-slovo.py [--port 18199] [--log підсумок.json]

З емулятора — адреса 10.0.2.2:18199.
"""
import io
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

try:
    from PIL import Image, ImageDraw
except ImportError:
    Image = None

PORT = int(sys.argv[sys.argv.index("--port") + 1]) if "--port" in sys.argv else 18199
LOG = sys.argv[sys.argv.index("--log") + 1] if "--log" in sys.argv else None
# --old — як «Слово» 1.4.3: команд picture-remove, pictures-clear, deck-remove і decks-clear не знає (404).
OLD = "--old" in sys.argv
# --empty — нічого не відкрито: ні файлів, ні фото (порожній стан списку «Слайди»).
EMPTY = "--empty" in sys.argv

lock = threading.Condition()
state = {
    "seq": 1, "hallSeq": 1, "mode": "presentation", "live": True, "black": False,
    "page": 0, "deck": 0, "picture": 0, "pointer": None, "zoom": [1.0, 0.5, 0.5],
    # Що в залі: змінюється лише показом (`live` у команді чи «Показати»), не вибором.
    "shown": "стенд",
}
# Файли презентацій: [назва, сторінок]. Сторінки мають наскрізні номери, як у «Слові».
DECKS = [["Стенд-перевірка.pdf", 12], ["Оголошення.pptx", 5]]
PICTURES = ["IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg", "Схема.png"]
if EMPTY:
    DECKS, PICTURES = [], []
counts = {}
# Каталог загальної бази для стенду «Модулі й доповнення».
CATALOG = [
    {"id": "bible/ubt2020", "kind": "bible", "title": "Українська Біблія 2020", "subtitle": "uk", "size": 4200000, "version": "3", "language": "uk"},
    {"id": "bible/kulish", "kind": "bible", "title": "Біблія Куліша", "subtitle": "uk", "size": 3900000, "version": "2", "language": "uk"},
    {"id": "bible/kjv", "kind": "bible", "title": "King James Version", "subtitle": "en", "size": 4500000, "version": "1", "language": "en"},
    {"id": "songbook/bel", "kind": "songbook", "title": "Пісні Відродження", "subtitle": "1015 пісень", "size": 900000, "version": "5", "language": "uk"},
    {"id": "songbook/youth", "kind": "songbook", "title": "Молодіжний збірник", "subtitle": "320 пісень", "size": 300000, "version": "2", "language": "uk"},
]
INSTALLED = {"bible/kulish"}
RESOURCE_WORK = {"busy": False, "title": "", "done": 0, "total": 0, "percent": 0, "installed": [], "failures": [], "finished": False}
totals = {}
pointer_wake = [0.0, False]


def count(kind, amount=1):
    with lock:
        counts[kind] = counts.get(kind, 0) + amount
        totals[kind] = totals.get(kind, 0) + amount


def bump(hall=True):
    with lock:
        state["seq"] += 1
        if hall:
            state["hallSeq"] += 1
        lock.notify_all()


def pointer_changed():
    """Як у «Слові»: указка будить телефони не частіше ніж раз на 80 мс, з «хвостом»."""
    now = time.time()
    if now - pointer_wake[0] >= 0.08:
        pointer_wake[0] = now
        bump(hall=False)
        return
    if pointer_wake[1]:
        return
    pointer_wake[1] = True

    def later():
        time.sleep(max(0, 0.08 - (time.time() - pointer_wake[0])))
        pointer_wake[1] = False
        pointer_wake[0] = time.time()
        bump(hall=False)
    threading.Thread(target=later, daemon=True).start()


def deck_range(deck):
    """Наскрізні номери сторінок файла."""
    if not 0 <= deck < len(DECKS):
        return range(0)
    start = sum(n for _, n in DECKS[:deck])
    return range(start, start + DECKS[deck][1])


def deck_of(page):
    for d in range(len(DECKS)):
        if page in deck_range(d):
            return d
    return 0


def sign(titles):
    """Відбиток назв (FNV-1a), як `picturesSign` у «Слові»."""
    value = 2166136261
    for title in titles:
        for byte in title.encode("utf-8"):
            value = ((value ^ byte) * 16777619) & 0xFFFFFFFF
        value = ((value ^ 1) * 16777619) & 0xFFFFFFFF
    return value


def show_current():
    """«Показати»: у зал — вибране (фото чи сторінка, за вкладкою програми). Під замком."""
    if state["mode"] == "pictures" and PICTURES:
        state["shown"] = PICTURES[min(state["picture"], len(PICTURES) - 1)]
    elif DECKS:
        state["shown"] = "Сторінка %d" % (state["page"] + 1)
    state["live"] = True


def state_json():
    s = state
    total = sum(n for _, n in DECKS)
    shown = deck_range(s["deck"])
    # Як справжнє «Слово»: сторінки лише вибраного файла, номери — наскрізні.
    pages = [{"index": i, "title": "Сторінка %d" % (i - shown.start + 1)} for i in shown]
    pointer = s["pointer"]
    json_state = {
        "seq": s["seq"], "hallSeq": s["hallSeq"], "app": "Slovo", "name": "Стенд", "mode": s["mode"],
        "live": s["live"], "black": s["black"], "blank": False,
        "slide": {"reference": "", "text": "", "secondary": []},
        "preview": {"reference": "", "text": ""},
        "presentation": {
            "decks": [{"index": i, "name": n, "count": c} for i, (n, c) in enumerate(DECKS)],
            "deck": s["deck"] if DECKS else -1, "pages": pages,
            "index": s["page"] if DECKS else -1, "local": s["page"] - shown.start if DECKS else -1,
            "count": len(shown), "total": total,
            "title": "Сторінка %d" % (s["page"] - shown.start + 1) if DECKS else "",
            "onWall": s["live"] and s["mode"] == "presentation",
        },
        "pointer": {"on": pointer is not None, "x": pointer[0] if pointer else 0.5, "y": pointer[1] if pointer else 0.5,
                    "colour": "#FFD91A", "size": 0.14, "opacity": 0.45, "source": "телефон" if pointer else ""},
        "zoom": {"on": s["zoom"][0] > 1.001, "zoom": s["zoom"][0], "x": s["zoom"][1], "y": s["zoom"][2],
                 "least": 1, "most": 6},
        "hall": {"kind": "still", "title": s["shown"]},
        "plan": [], "songBook": "",
        # Як «Слово» 1.4.4: список фото — завжди (число й відбиток назв).
        "pictures": {"count": len(PICTURES), "sign": sign(PICTURES)},
    }
    if s["mode"] == "pictures" and PICTURES:
        json_state["show"] = {"title": PICTURES[s["picture"]], "index": s["picture"], "count": len(PICTURES)}
    else:
        json_state["show"] = {"title": "Сторінка %d" % (s["page"] + 1), "index": s["page"], "count": total}
    return json_state


def jpeg(width, ratio, label, hue):
    if Image is None:
        return b""
    height = max(2, int(width / ratio))
    image = Image.new("RGB", (width, height), hue)
    draw = ImageDraw.Draw(image)
    draw.rectangle([width * 0.08, height * 0.2, width * 0.92, height * 0.8], outline=(255, 255, 255), width=max(1, width // 120))
    draw.text((width * 0.12, height * 0.42), label, fill=(255, 255, 255))
    out = io.BytesIO()
    image.save(out, "JPEG", quality=82)
    return out.getvalue()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send(self, code, body, kind="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)
        count("bytes", len(data))
        self.close_connection = True

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path
        if path == "/api/state":
            count("state")
            since = int(q.get("since", "-1"))
            deadline = time.time() + 15
            with lock:
                while state["seq"] <= since and time.time() < deadline:
                    lock.wait(timeout=deadline - time.time())
                body = state_json()
            return self.send(200, body)
        if path == "/api/hall.jpg":
            count("hall")
            return self.send(200, jpeg(int(q.get("w", "960")), 16 / 9, "ЗАЛ", (20, 40, 90)), "image/jpeg")
        if path == "/api/page":
            count("page")
            width = int(q.get("w", "720"))
            index = int(q.get("index", "0"))
            if q.get("kind") == "pictures":
                if not 0 <= index < len(PICTURES):
                    return self.send(404, {"error": "нет такой страницы"})
                return self.send(200, jpeg(width, 4 / 3, PICTURES[index], (90, 60 + index * 30, 40)), "image/jpeg")
            return self.send(200, jpeg(width, 16 / 9, "Сторінка %d" % (index + 1), (30, 30 + index * 15 % 200, 120)), "image/jpeg")
        if path == "/api/pictures":
            count("other")
            with lock:
                current = state["picture"]
            return self.send(200, {"index": current, "count": len(PICTURES),
                                   "pages": [{"index": i, "title": t} for i, t in enumerate(PICTURES)]})
        count("other")
        if path == "/api/songs/books":
            return self.send(200, {"books": [{"id": "test", "title": "Стенд", "short": ""}], "current": "test"})
        if path == "/api/songs/list":
            return self.send(200, {"book": "test", "selected": -1, "songs": [{"index": 0, "number": 1, "title": "Пісня", "subtitle": ""}]})
        if path == "/api/bible/books":
            return self.send(200, {"translation": {"id": "t", "name": "Стенд"},
                                   "translations": [{"id": "t", "name": "Стенд"}, {"id": "k", "name": "Куліш"}],
                                   "books": [{"position": 0, "name": "Буття", "chapters": 50}]})
        # Модулі й доповнення: каталог загальної бази, як `/api/resources` у «Слові».
        if path == "/api/resources/sources":
            return self.send(200, {"sources": [{"id": "slovo", "name": "Слово: готові ресурси",
                                                "kinds": ["bible", "songbook", "backgrounds", "templates", "fonts", "web"]}]})
        if path == "/api/resources/progress":
            with lock:
                return self.send(200, dict(RESOURCE_WORK))
        if path == "/api/resources":
            kind = q.get("kind", "bible")
            items = [dict(it, installed=it["id"] in INSTALLED) for it in CATALOG if it["kind"] == kind]
            return self.send(200, {"source": "slovo", "name": "Слово: готові ресурси", "total": len(items),
                                   "shown": len(items), "items": items})
        return self.send(200, {})

    def do_POST(self):
        url = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw and url.path != "/api/upload" else {}
        except ValueError:
            body = {}
        name = url.path[len("/api/"):]
        if OLD and name in ("picture-remove", "pictures-clear", "deck-remove", "decks-clear"):
            count("other")
            return self.send(404, {"error": "немає такої команди: %s" % name})
        if name == "picture-remove":
            count("other")
            index = int(body.get("index", -1))
            with lock:
                known = 0 <= index < len(PICTURES)
                if known:
                    del PICTURES[index]
                    if state["picture"] >= len(PICTURES):
                        state["picture"] = max(0, len(PICTURES) - 1)
                    if not PICTURES and state["mode"] == "pictures":
                        state["mode"] = "presentation"
            if not known:
                return self.send(404, {"error": "немає такої сторінки"})
            bump()
            return self.send(200, {"ok": True, "count": len(PICTURES)})
        if name == "pictures-clear":
            count("other")
            with lock:
                del PICTURES[:]
                state["picture"] = 0
                if state["mode"] == "pictures":
                    state["mode"] = "presentation"
            bump()
            return self.send(200, {"ok": True, "count": 0})
        if name == "resource-install":
            count("other")
            wanted = list(body.get("ids", []))

            def work():
                for n, item in enumerate(wanted):
                    with lock:
                        RESOURCE_WORK.update(busy=True, title=item, done=n, total=len(wanted), percent=int(100 * n / len(wanted)))
                    time.sleep(1.5)
                with lock:
                    INSTALLED.update(wanted)
                    RESOURCE_WORK.update(busy=False, done=len(wanted), percent=100, installed=wanted, finished=True)
            with lock:
                RESOURCE_WORK.update(busy=True, title="читаю каталог", done=0, total=len(wanted), percent=0,
                                     installed=[], failures=[], finished=False)
            threading.Thread(target=work, daemon=True).start()
            return self.send(200, {"ok": True})
        if name == "deck-remove":
            # Як «Слово»: файл зі всіма сторінками; вибраним стає той, що став на його місце.
            count("other")
            index = int(body.get("index", -1))
            with lock:
                known = 0 <= index < len(DECKS)
                if known:
                    removed = deck_range(index)
                    del DECKS[index]
                    if state["deck"] == index:
                        state["deck"] = min(index, max(0, len(DECKS) - 1))
                        state["page"] = deck_range(state["deck"]).start if DECKS else 0
                    elif state["deck"] > index:
                        state["deck"] -= 1
                        state["page"] -= len(removed)
            if not known:
                return self.send(404, {"error": "немає такого файла"})
            bump()
            return self.send(200, {"ok": True, "count": len(DECKS)})
        if name == "decks-clear":
            count("other")
            with lock:
                del DECKS[:]
                state["deck"], state["page"] = 0, 0
            bump()
            return self.send(200, {"ok": True, "count": 0})
        if name == "pointer":
            count("pointer")
            with lock:
                state["pointer"] = (body.get("x", 0.5), body.get("y", 0.5))
            pointer_changed()
        elif name == "pointer-off":
            count("pointer")
            with lock:
                state["pointer"] = None
            pointer_changed()
        elif name == "zoom":
            count("zoom")
            with lock:
                state["zoom"] = [float(body.get("zoom", 1)), float(body.get("x", 0.5)), float(body.get("y", 0.5))]
            bump()
        else:
            count("other")
            with lock:
                # `live: false` — лише вибрати (у зал — «Показати»); без `live` — одразу в зал.
                live = body.get("live", True) is not False
                if name == "page":
                    # Як справжнє «Слово»: сторінка з того списку, що відкритий у програмі
                    # (після фото — з фото!), а з інших вкладок — перехід на презентацію.
                    if state["mode"] == "pictures":
                        state["picture"] = int(body.get("index", 0))
                    else:
                        state["mode"], state["page"] = "presentation", int(body.get("index", 0))
                        state["deck"] = deck_of(state["page"])
                    if live:
                        show_current()
                elif name == "show":
                    show_current()
                elif name == "deck":
                    index = int(body.get("index", 0))
                    if 0 <= index < len(DECKS):
                        state["mode"], state["deck"] = "presentation", index
                        if state["page"] not in deck_range(index):
                            state["page"] = deck_range(index).start
                elif name == "mode":
                    state["mode"] = str(body.get("text", state["mode"]))
                elif name == "picture":
                    state["mode"], state["picture"] = "pictures", int(body.get("index", 0))
                    if live:
                        show_current()
                elif name in ("next", "prev"):
                    step = 1 if name == "next" else -1
                    if state["mode"] == "pictures":
                        state["picture"] = max(0, min(len(PICTURES) - 1, state["picture"] + step))
                    else:
                        state["page"] = max(0, min(sum(n for _, n in DECKS) - 1, state["page"] + step))
                        state["deck"] = deck_of(state["page"])
                elif name == "black":
                    state["black"] = not state["black"]
            bump()
        return self.send(200, {"ok": True})


def reporter():
    started = time.time()
    while True:
        time.sleep(1)
        with lock:
            snapshot = dict(counts)
            counts.clear()
        line = " · ".join("%s %d" % (k, snapshot[k]) for k in ("pointer", "zoom", "state", "hall", "page", "other", "bytes") if snapshot.get(k))
        if line:
            print("%6.1f с  %s" % (time.time() - started, line), flush=True)
        if LOG:
            with open(LOG, "w", encoding="utf-8") as out:
                json.dump(totals, out, ensure_ascii=False)


if __name__ == "__main__":
    threading.Thread(target=reporter, daemon=True).start()
    print("несправжнє «Слово» на порту %d (з емулятора — 10.0.2.2:%d)" % (PORT, PORT), flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
