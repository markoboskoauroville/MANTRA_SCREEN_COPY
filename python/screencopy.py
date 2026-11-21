#!/usr/bin/env python3
"""Python 3 client for Screen Copy (Mantra)'s local control API."""

import argparse
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path


PORT_FILE = Path.home() / ".mantra" / "ports" / "screen-copy"
DEFAULT_PORT = 8883


class ScreenCopyError(Exception):
    pass


class ScreenCopyNotRunning(ScreenCopyError):
    pass


def control_port():
    try:
        port = int(PORT_FILE.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return DEFAULT_PORT
    return port if 1 <= port <= 65535 else DEFAULT_PORT


def _request(method, endpoint, body=None):
    port = control_port()
    url = f"http://127.0.0.1:{port}{endpoint}"
    data = None
    headers = {"Connection": "close"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=5) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            detail = json.loads(raw.decode("utf-8"))
            message = detail.get("error", f"HTTP {error.code}")
        except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
            message = f"HTTP {error.code}"
        raise ScreenCopyError(message) from error
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as error:
        reason = getattr(error, "reason", error)
        raise ScreenCopyNotRunning(
            f"Screen Copy is not running on 127.0.0.1:{port} ({reason})"
        ) from error
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ScreenCopyError("Screen Copy returned invalid JSON") from error


def _target(tab=None, serial=None):
    if tab is not None and serial is not None:
        raise ValueError("provide tab or serial, not both")
    result = {}
    if tab is not None:
        result["tab"] = tab
    if serial is not None:
        result["serial"] = serial
    return result


def tabs():
    return _request("GET", "/tabs")


def status():
    return _request("GET", "/status")


def record_start(name, tab=None, serial=None):
    body = _target(tab, serial)
    body["name"] = name
    return _request("POST", "/record/start", body)


def record_pause(tab=None, serial=None):
    return _request("POST", "/record/pause", _target(tab, serial))


def record_resume(tab=None, serial=None):
    return _request("POST", "/record/resume", _target(tab, serial))


def record_stop(tab=None, serial=None):
    return _request("POST", "/record/stop", _target(tab, serial))


def record_next(name=None, tab=None, serial=None):
    body = _target(tab, serial)
    if name is not None:
        body["name"] = name
    return _request("POST", "/record/next", body)


def record_rename(from_name, to_name, tab=None, serial=None):
    body = _target(tab, serial)
    body.update({"from": from_name, "to": to_name})
    return _request("POST", "/record/rename", body)


def record_monitor(on, tab=None, serial=None):
    body = _target(tab, serial)
    body["on"] = bool(on)
    return _request("POST", "/record/monitor", body)


def tab_select(tab):
    return _request("POST", "/tab/select", {"tab": tab})


def select_tab(tab):
    return tab_select(tab)


def tap(x, y):
    return _request("POST", "/tap", {"x": x, "y": y})


def key(code):
    return _request("POST", "/key", {"code": code})


def text(value):
    return _request("POST", "/text", {"text": value})


def add_target(parser):
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--tab", type=int)
    target.add_argument("--serial")


def build_parser():
    parser = argparse.ArgumentParser(prog="screencopy")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("tabs")
    commands.add_parser("status")

    record = commands.add_parser("record")
    record_commands = record.add_subparsers(dest="record_command", required=True)
    start = record_commands.add_parser("start")
    add_target(start)
    start.add_argument("--name", required=True)
    for action in ("pause", "resume", "stop"):
        add_target(record_commands.add_parser(action))
    next_parser = record_commands.add_parser("next")
    add_target(next_parser)
    next_parser.add_argument("--name")
    rename = record_commands.add_parser("rename")
    add_target(rename)
    rename.add_argument("--from", dest="from_name", required=True)
    rename.add_argument("--to", dest="to_name", required=True)

    monitor = commands.add_parser("monitor")
    monitor.add_argument("setting", choices=("on", "off"))
    add_target(monitor)

    tab = commands.add_parser("tab")
    tab_commands = tab.add_subparsers(dest="tab_command", required=True)
    tab_select = tab_commands.add_parser("select")
    tab_select.add_argument("number", type=int)

    tap_parser = commands.add_parser("tap")
    tap_parser.add_argument("x", type=int)
    tap_parser.add_argument("y", type=int)

    key_parser = commands.add_parser("key")
    key_parser.add_argument("code", type=int)

    text_parser = commands.add_parser("text")
    text_parser.add_argument("value")
    return parser


def run(args):
    if args.command == "tabs":
        return tabs()
    if args.command == "status":
        return status()
    if args.command == "record":
        if args.record_command == "start":
            return record_start(args.name, args.tab, args.serial)
        if args.record_command == "pause":
            return record_pause(args.tab, args.serial)
        if args.record_command == "resume":
            return record_resume(args.tab, args.serial)
        if args.record_command == "stop":
            return record_stop(args.tab, args.serial)
        if args.record_command == "next":
            return record_next(args.name, args.tab, args.serial)
        if args.record_command == "rename":
            return record_rename(args.from_name, args.to_name, args.tab, args.serial)
    if args.command == "monitor":
        return record_monitor(args.setting == "on", args.tab, args.serial)
    if args.command == "tab":
        return tab_select(args.number)
    if args.command == "tap":
        return tap(args.x, args.y)
    if args.command == "key":
        return key(args.code)
    if args.command == "text":
        return text(args.value)
    raise ScreenCopyError("unknown command")


def main():
    args = build_parser().parse_args()
    try:
        result = run(args)
    except ScreenCopyNotRunning as error:
        print(f"screencopy: {error}", file=sys.stderr)
        return 2
    except (ScreenCopyError, ValueError) as error:
        print(f"screencopy: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
