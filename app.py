#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dae-ui: dae 的轻量面板（仅三个功能：导入订阅 / 自定义策略组 / 切换节点）

架构原则（吸取 daed 的教训）：
  面板与 dae 是两个独立进程。面板只负责“生成 .dae 配置 -> dae validate 校验
  -> systemctl reload 热重载”，面板自身崩溃不影响 dae 转发流量。

配置布局（dae 官方 include 机制）：
  /etc/dae/config.dae          入口：include + global + dns（面板生成）
  /etc/dae/config.d/panel.dae  subscription / node / group / routing（面板生成）

切换节点的实现：手动模式下，面板把被选中的节点链接以固定 tag 写入 node 段，
策略组用 filter: name(<tag>) + policy: fixed(0) 精确引用，不依赖订阅内部排序。
自动模式用 subtag + name(keyword:) 过滤 + policy: min_moving_avg 按延迟选优。

仅使用 Python 标准库。
"""

import base64
import binascii
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# ---------------------------------------------------------------- paths
APP_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.environ.get("DAEUI_DATA_DIR", os.path.join(APP_DIR, "data"))
DAE_CONF_DIR = os.environ.get("DAEUI_CONF_DIR", "/etc/dae")
DAE_BIN = os.environ.get("DAEUI_DAE_BIN", "/usr/bin/dae")
PORT = int(os.environ.get("DAEUI_PORT", "9623"))

PANEL_VERSION = "1.5.0"

SUBS_FILE = os.path.join(DATA_DIR, "subs.json")
GROUPS_FILE = os.path.join(DATA_DIR, "groups.json")
SETTINGS_FILE = os.path.join(DATA_DIR, "settings.json")
NODES_FILE = os.path.join(DATA_DIR, "nodes.json")

NODE_SCHEMES = (
    "vless://", "vmess://", "trojan://", "ss://", "ssr://", "hysteria2://",
    "hy2://", "tuic://", "juicity://", "anytls://", "socks5://", "socks://",
    "http://", "https://",
)
TAG_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,31}$")
DEFAULT_EXCLUDES = ["剩余", "到期", "过期", "官网", "流量", "ExpireAt", "Traffic", "RESET"]

DEFAULT_GROUP = {
    "id": "proxy", "name": "默认组", "mode": "auto", "kind": "proxy",
    "subs": [], "include": [], "exclude": list(DEFAULT_EXCLUDES),
    "domains": [], "geosites": [], "suffixes": [], "ports": [], "node": None,
}


def clean_domain(x):
    d = str(x).strip().lower()
    d = re.sub(r"^https?://", "", d)
    d = d.split("/")[0].split(":")[0].strip(".")
    if d.startswith("*."):
        d = d[2:]
    return d if re.match(r"^[a-z0-9_\-]+(\.[a-z0-9_\-]+)+$", d) else ""


# ---------------------------------------------------------------- storage
def _load(path, default):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def _save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def load_subs():
    return _load(SUBS_FILE, [])


def load_groups():
    data = _load(GROUPS_FILE, None)
    if not data or "groups" not in data or not data["groups"]:
        return {"groups": [dict(DEFAULT_GROUP)]}
    if not any(g.get("id") == "proxy" for g in data["groups"]):
        data["groups"].insert(0, dict(DEFAULT_GROUP))
    return data


def load_settings():
    s = _load(SETTINGS_FILE, {})
    return {"lan_interface": str(s.get("lan_interface", "")).strip()}


def load_nodes():
    return _load(NODES_FILE, {})


# ---------------------------------------------------------------- subscription parsing
def _b64decode_text(s):
    s = re.sub(r"\s+", "", s)
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s, altchars=b"-_", validate=False).decode("utf-8", "replace")


def _extract_links(text):
    lines = [ln.strip() for ln in text.replace("\r", "\n").split("\n")]
    links = [ln for ln in lines if ln.startswith(NODE_SCHEMES)]
    if links:
        return links
    # maybe the whole body is base64
    try:
        decoded = _b64decode_text(text)
        lines = [ln.strip() for ln in decoded.replace("\r", "\n").split("\n")]
        return [ln for ln in lines if ln.startswith(NODE_SCHEMES)]
    except (binascii.Error, ValueError):
        return []


def _node_name(link):
    proto = link.split("://", 1)[0]
    name = ""
    if proto == "vmess":
        try:
            payload = link[len("vmess://"):].split("#")[0].split("?")[0]
            obj = json.loads(_b64decode_text(payload))
            name = str(obj.get("ps") or "")
            if not name:
                name = "%s:%s" % (obj.get("add", ""), obj.get("port", ""))
        except Exception:
            name = ""
    if not name and "#" in link:
        name = urllib.parse.unquote(link.split("#", 1)[1]).strip()
    if not name:
        try:
            host = urllib.parse.urlparse(link).hostname or ""
            port = urllib.parse.urlparse(link).port
            name = "%s:%s" % (host, port) if host else link[:40]
        except Exception:
            name = link[:40]
    return name or link[:40]


def fetch_subscription(url):
    """Return (nodes, error). nodes: [{name, proto, link}] in subscription order."""
    req = urllib.request.Request(url, headers={"User-Agent": "dae-ui/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            raw = resp.read(32 * 1024 * 1024)
    except Exception as e:
        return [], "拉取失败: %s" % e
    text = raw.decode("utf-8", "replace")
    links = _extract_links(text)
    if not links:
        return [], "未解析到节点（仅支持链接列表/Base64 订阅，不支持 Clash YAML）"
    nodes, seen = [], set()
    for ln in links:
        if ln in seen:
            continue
        seen.add(ln)
        nodes.append({
            "name": _node_name(ln),
            "proto": ln.split("://", 1)[0],
            "link": ln,
        })
    return nodes, None


def refresh_subscriptions(tags=None):
    subs = load_subs()
    cache = load_nodes()
    for s in subs:
        if tags and s["tag"] not in tags:
            continue
        nodes, err = fetch_subscription(s["url"])
        cache[s["tag"]] = {
            "fetched_at": int(time.time()),
            "nodes": nodes,
            "error": err,
        }
    _save(NODES_FILE, cache)
    return cache


# ---------------------------------------------------------------- geosite categories
_GEOSITE_CACHE = None


def geosite_categories():
    """Real category codes from the geosite.dat dae uses (uppercase codes in the file)."""
    global _GEOSITE_CACHE
    if _GEOSITE_CACHE is not None:
        return _GEOSITE_CACHE
    paths = [
        os.environ.get("DAEUI_GEOSITE", ""),
        "/usr/share/dae/geosite.dat",
        "/usr/local/share/dae/geosite.dat",
        os.path.join(DAE_CONF_DIR, "geosite.dat"),
        os.path.normpath(os.path.join(os.path.dirname(DAE_BIN), "..", "share", "dae", "geosite.dat")),
    ]
    cats = []
    for p in paths:
        if p and os.path.isfile(p):
            try:
                with open(p, "rb") as f:
                    data = f.read()
                found = set()
                for m in re.finditer(rb"(?<![A-Za-z0-9_\-])[A-Z][A-Z0-9_\-]{1,60}(?![A-Za-z0-9_\-])", data):
                    found.add(m.group(0).decode().lower())
                if len(found) > 100:
                    cats = sorted(found)
                    break
            except Exception:
                continue
    _GEOSITE_CACHE = cats
    return cats


# ---------------------------------------------------------------- config generation
def q(s):
    """Quote a string for .dae single-quoted syntax."""
    return "'" + str(s).replace("\\", "\\\\").replace("'", "\\'") + "'"


def group_conf_name(g):
    return "proxy" if g["id"] == "proxy" else "g_" + g["id"]


def pin_tag(g):
    return "pin_" + g["id"]


def _auto_filter_lines(g, all_tags):
    wanted = [t for t in (g.get("subs") or []) if t in all_tags]
    sub_part = ""
    if wanted and len(wanted) < len(all_tags):
        sub_part = "subtag(%s)" % ", ".join(wanted)
    excludes = [e for e in (g.get("exclude") or []) if str(e).strip()]
    includes = [k for k in (g.get("include") or []) if str(k).strip()]
    lines = []
    bases = includes if includes else [None]
    for kw in bases:
        parts = []
        if sub_part:
            parts.append(sub_part)
        if kw:
            parts.append("name(keyword: %s)" % q(kw))
        for ex in excludes:
            parts.append("!name(keyword: %s)" % q(ex))
        lines.append(" && ".join(parts) if parts else None)
    return lines


def generate_configs():
    """Write /etc/dae/config.dae and config.d/panel.dae. Return (ok, message)."""
    subs = load_subs()
    groups = load_groups()["groups"]
    settings = load_settings()
    cache = load_nodes()
    all_tags = [s["tag"] for s in subs]

    total_sources = len(subs)
    pins = {}  # tag -> link
    for g in groups:
        if g.get("kind") != "direct" and g.get("mode") == "manual" \
                and g.get("node") and g["node"].get("link"):
            pins[pin_tag(g)] = g["node"]["link"]
    if total_sources == 0 and not pins:
        return False, "还没有任何订阅或节点，先添加订阅。"

    # ---------------- panel.dae: subscription / node / group / routing
    out = []
    if subs:
        out.append("subscription {")
        for s in subs:
            out.append("    %s: %s" % (s["tag"], q(s["url"])))
        out.append("}")
        out.append("")
    if pins:
        out.append("node {")
        for tag, link in pins.items():
            out.append("    %s: %s" % (tag, q(link)))
        out.append("}")
        out.append("")

    out.append("group {")
    for g in groups:
        if g.get("kind") == "direct":
            continue
        name = group_conf_name(g)
        out.append("    %s {" % name)
        if g.get("mode") == "manual" and g["id"] in [x["id"] for x in groups] \
                and g.get("node") and g["node"].get("link"):
            out.append("        filter: name(%s)" % pin_tag(g))
            out.append("        policy: fixed(0)")
        else:
            for ln in _auto_filter_lines(g, all_tags):
                if ln:
                    out.append("        filter: %s" % ln)
            out.append("        policy: min_moving_avg")
        out.append("    }")
    out.append("}")
    out.append("")

    def matcher_rules(g, target):
        lines = []
        for cat in g.get("geosites") or []:
            lines.append("    domain(geosite:%s) -> %s" % (cat, target))
        for d in g.get("suffixes") or []:
            lines.append("    domain(suffix: %s) -> %s" % (q(d), target))
        for d in g.get("domains") or []:
            d = str(d).strip()
            if d:
                lines.append("    domain(keyword: %s) -> %s" % (q(d), target))
        ports = g.get("ports") or []
        if ports:
            lines.append("    dport(%s) -> %s" % (", ".join(str(p) for p in ports), target))
        return lines

    out.append("routing {")
    out.append("    pname(NetworkManager) -> direct")
    out.append("    dip(224.0.0.0/3, 'ff00::/8') -> direct")
    out.append("    dip(geoip:private) -> direct")
    out.append("    l4proto(udp) && dport(443) -> block")
    # Direct groups first: an explicit direct rule wins over proxy groups.
    for g in groups:
        if g["id"] != "proxy" and g.get("kind") == "direct":
            out.extend(matcher_rules(g, "direct"))
    for g in groups:
        if g["id"] == "proxy" or g.get("kind") == "direct":
            continue
        out.extend(matcher_rules(g, group_conf_name(g)))
    out.append("    dip(geoip:cn) -> direct")
    out.append("    domain(geosite:cn) -> direct")
    out.append("    fallback: proxy")
    out.append("}")
    panel_dae = "\n".join(out) + "\n"

    # ---------------- config.dae: entry + global + dns
    lan = settings.get("lan_interface", "")
    g_lines = [
        "global {",
        "    tproxy_port: 12345",
        "    log_level: info",
        "    wan_interface: auto",
    ]
    if lan:
        g_lines.append("    lan_interface: %s" % lan)
    g_lines += [
        "    auto_config_kernel_parameter: true",
        "    tcp_check_url: 'http://cp.cloudflare.com,1.1.1.1,2606:4700:4700::1111'",
        "    udp_check_dns: 'dns.google:53,8.8.8.8,2001:4860:4860::8888'",
        "    check_interval: 30s",
        "    check_tolerance: 50ms",
        "    dial_mode: domain",
        "    sniffing_timeout: 30ms",
        "}",
    ]
    entry = "\n".join([
        "# Generated by dae-ui. Do not edit panel.dae by hand.",
        "include {",
        "    config.d/*.dae",
        "}",
        "",
        "\n".join(g_lines),
        "",
        "dns {",
        "    upstream {",
        "        alidns: 'udp://dns.alidns.com:53'",
        "        googledns: 'tcp+udp://dns.google:53'",
        "    }",
        "    routing {",
        "        request {",
        "            qname(geosite:cn) -> alidns",
        "            fallback: googledns",
        "        }",
        "        response {",
        "            upstream(googledns) -> accept",
        "            ip(geoip:private) && !qname(geosite:cn) -> googledns",
        "            fallback: accept",
        "        }",
        "    }",
        "}",
        "",
    ])

    os.makedirs(os.path.join(DAE_CONF_DIR, "config.d"), exist_ok=True)
    entry_path = os.path.join(DAE_CONF_DIR, "config.dae")
    panel_path = os.path.join(DAE_CONF_DIR, "config.d", "panel.dae")
    with open(entry_path, "w", encoding="utf-8") as f:
        f.write(entry)
    with open(panel_path, "w", encoding="utf-8") as f:
        f.write(panel_dae)
    # dae refuses config files that are group-writable or world-accessible.
    for p in (entry_path, panel_path):
        os.chmod(p, 0o640)
    _ = cache  # cache used by UI; generation relies on stored group node links
    return True, "配置已生成"


def run_cmd(args, timeout=60):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except Exception as e:
        return -1, str(e)


def dae_active():
    rc, out = run_cmd(["systemctl", "is-active", "dae"], timeout=10)
    return out.strip() == "active"


def apply_config():
    ok, msg = generate_configs()
    if not ok:
        return {"ok": False, "step": "generate", "message": msg}
    rc, out = run_cmd([DAE_BIN, "validate", "-c", os.path.join(DAE_CONF_DIR, "config.dae")], timeout=120)
    if rc != 0:
        return {"ok": False, "step": "validate", "message": "dae validate 未通过", "output": out[-3000:]}
    reloaded = None
    note = ""
    if dae_active():
        rc2, out2 = run_cmd(["systemctl", "reload", "dae"], timeout=60)
        if rc2 == 0:
            reloaded = True
        else:
            rc3, out3 = run_cmd([DAE_BIN, "reload"], timeout=60)
            reloaded = rc3 == 0
            note = (out2 + out3)[-1000:]
        if not reloaded:
            return {"ok": False, "step": "reload", "message": "校验通过但重载失败，可在面板重启 dae", "output": note}
    else:
        note = "dae 未运行，配置已就绪，启动 dae 后生效"
    return {"ok": True, "step": "done", "reloaded": reloaded, "message": note or "已热重载"}


# ---------------------------------------------------------------- validation of incoming state
def sanitize_state(payload):
    subs_in = payload.get("subs") or []
    subs, seen = [], set()
    for s in subs_in:
        tag = str(s.get("tag", "")).strip()
        url = str(s.get("url", "")).strip()
        if not TAG_RE.match(tag):
            return None, "订阅标签不合法（字母开头，仅字母/数字/下划线）：%s" % tag
        if tag in seen:
            return None, "订阅标签重复：%s" % tag
        if not (url.startswith("http://") or url.startswith("https://") or url.startswith("file://")):
            return None, "订阅地址不合法：%s" % tag
        seen.add(tag)
        subs.append({"tag": tag, "url": url})

    groups_in = payload.get("groups") or []
    groups = []
    for g in groups_in:
        gid = str(g.get("id", "")).strip()
        if gid != "proxy" and not re.match(r"^[A-Za-z0-9]{4,16}$", gid):
            return None, "策略组 id 不合法"
        node = g.get("node")
        if node is not None:
            if not isinstance(node, dict) or not node.get("link"):
                node = None
            else:
                node = {
                    "sub": str(node.get("sub", "")),
                    "name": str(node.get("name", "")),
                    "link": str(node.get("link", "")),
                }
        groups.append({
            "id": gid,
            "name": str(g.get("name", "")).strip() or gid,
            "kind": "direct" if (g.get("kind") == "direct" and gid != "proxy") else "proxy",
            "mode": "manual" if g.get("mode") == "manual" else "auto",
            "subs": [str(t) for t in (g.get("subs") or []) if TAG_RE.match(str(t))],
            "include": [str(x).strip() for x in (g.get("include") or []) if str(x).strip()],
            "exclude": [str(x).strip() for x in (g.get("exclude") or []) if str(x).strip()],
            "domains": [str(x).strip() for x in (g.get("domains") or []) if str(x).strip()],
            "geosites": [str(x).strip().lower() for x in (g.get("geosites") or [])
                         if re.match(r"^[A-Za-z0-9_.\-]+$", str(x).strip())],
            "suffixes": [d for d in (clean_domain(x) for x in (g.get("suffixes") or [])) if d],
            "ports": sorted({int(p) for p in (g.get("ports") or [])
                             if str(p).strip().isdigit() and 1 <= int(p) <= 65535}),
            "node": node,
        })
    if not any(g["id"] == "proxy" for g in groups):
        groups.insert(0, dict(DEFAULT_GROUP))

    settings_in = payload.get("settings") or {}
    lan = str(settings_in.get("lan_interface", "")).strip()
    if lan and not re.match(r"^[A-Za-z0-9_.\-]+$", lan):
        return None, "网卡名不合法"
    return {"subs": subs, "groups": groups, "settings": {"lan_interface": lan}}, None


# ---------------------------------------------------------------- http api
class Handler(BaseHTTPRequestHandler):
    server_version = "dae-ui/1.0"

    def log_message(self, fmt, *args):  # log API calls to journal, keep the rest quiet
        try:
            if "/api/" in (self.path or ""):
                sys.stderr.write("dae-ui api: %s %s\n" % (self.command, self.path))
        except Exception:
            pass

    def _json(self, data, code=200):
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
        except Exception:
            return {}

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path in ("/", "/index.html"):
            fp = os.path.join(APP_DIR, "static", "index.html")
            try:
                with open(fp, "rb") as f:
                    body = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception as e:
                self._json({"ok": False, "message": str(e)}, 500)
            return
        if path == "/api/geosite":
            cats = geosite_categories()
            self._json({"ok": bool(cats), "categories": cats, "count": len(cats)})
            return
        if path == "/api/state":
            rc, ver = run_cmd([DAE_BIN, "--version"], timeout=10)
            self._json({
                "panel_version": PANEL_VERSION,
                "subs": load_subs(),
                "groups": load_groups()["groups"],
                "settings": load_settings(),
                "nodes": load_nodes(),
                "dae": {
                    "active": dae_active(),
                    "version": (ver.strip().splitlines() or [""])[0] if rc == 0 else "",
                },
            })
            return
        if path == "/api/logs":
            rc, out = run_cmd(["journalctl", "-u", "dae", "-n", "120", "--no-pager"], timeout=15)
            self._json({"ok": rc == 0, "logs": out[-12000:]})
            return
        self._json({"ok": False, "message": "接口不存在: %s" % path}, 404)

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        payload = self._body()
        if path == "/api/save":
            clean, err = sanitize_state(payload)
            if err:
                self._json({"ok": False, "message": err})
                return
            _save(SUBS_FILE, clean["subs"])
            _save(GROUPS_FILE, {"groups": clean["groups"]})
            _save(SETTINGS_FILE, clean["settings"])
            self._json({"ok": True})
            return
        if path == "/api/fetch_sub":
            tag = str(payload.get("tag", "")).strip()
            url = str(payload.get("url", "")).strip()
            if not TAG_RE.match(tag):
                self._json({"ok": False, "message": "标签不合法"})
                return
            nodes, err = fetch_subscription(url)
            cache = load_nodes()
            cache[tag] = {"fetched_at": int(time.time()), "nodes": nodes, "error": err}
            _save(NODES_FILE, cache)
            self._json({"ok": err is None, "count": len(nodes), "message": err or "", "nodes": nodes})
            return
        if path == "/api/refresh":
            cache = refresh_subscriptions()
            total = sum(len(v.get("nodes") or []) for v in cache.values())
            errs = {k: v.get("error") for k, v in cache.items() if v.get("error")}
            self._json({"ok": not errs, "total": total, "errors": errs, "nodes": cache})
            return
        if path == "/api/apply":
            self._json(apply_config())
            return
        if path == "/api/service":
            action = str(payload.get("action", ""))
            if action not in ("start", "stop", "restart"):
                self._json({"ok": False, "message": "动作不合法"})
                return
            if action in ("start", "restart"):
                # Ensure a generated+validated config exists first; otherwise
                # systemd fails opaquely with "control process exited".
                res = apply_config()
                if not res.get("ok") and res.get("step") != "reload":
                    self._json({
                        "ok": False,
                        "message": "启动前应用配置失败：" + str(res.get("message", "")),
                        "output": res.get("output", ""),
                    })
                    return
            rc, out = run_cmd(["systemctl", action, "dae"], timeout=90)
            self._json({"ok": rc == 0, "active": dae_active(), "output": out[-1500:]})
            return
        self._json({"ok": False, "message": "接口不存在: %s" % path}, 404)


def main():
    os.makedirs(DATA_DIR, exist_ok=True)
    if "--gen-config" in sys.argv:
        ok, msg = generate_configs()
        print(msg)
        sys.exit(0 if ok else 1)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("dae-ui listening on :%d (data: %s, dae conf: %s)" % (PORT, DATA_DIR, DAE_CONF_DIR))
    srv.serve_forever()


if __name__ == "__main__":
    main()
