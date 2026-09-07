#!/usr/bin/env python3
"""
niu_cloud.py -- the few NIU cloud calls the scooter CLI needs.

The BLE password that authenticates a phone to a NIU vehicle is not printed
anywhere; the app fetches it from NIU's cloud for a vehicle bound to your
account.  This module logs in the way the Android app does and pulls it:

  POST account-fk.niu.com/v3/api/oauth2/token   account, password=md5(pw), grant_type=password, scope=base, app_id
  GET  app-api-fk.niu.com/v5/scooter/list       header token: <access_token>
  GET  app-api-fk.niu.com/v5/scooter/detail/<sn>
  GET  app-api-fk.niu.com/v5/ble/bleinfo?sn=<sn>   -> bleMac, blePassword, bleAes, bleSign, bleName, bus_protocol_type

Every reply is {"status": 0, "desc": ..., "data": ...}; status != 0 is an error.
"-fk" hosts are the overseas region; the domestic region uses app-api.niu.com.

Credentials live in secrets/ (gitignored), see secrets/README.md.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SECRETS = os.path.join(HERE, "secrets")
SESSION_FILE = os.path.join(SECRETS, "session.json")
SCOOTER_FILE = os.path.join(SECRETS, "scooter.json")

ACCOUNT_HOST = "https://account-fk.niu.com/"
API_HOST = "https://app-api-fk.niu.com/"
APP_IDS = ("niu_8xt1afu6", "niu_ktdrr960")  # overseas release, then domestic release
USER_AGENT = ("manager/5.12.2 (android; Pixel 8 14);lang=en-US;clientIdentifier=Overseas;"
              "timezone=America/Chicago;model=google_Pixel 8;deviceName=Pixel 8;ostype=android")


class CloudError(Exception):
    pass


def _headers(token: str | None = None, json_body: bool = False) -> dict:
    h = {"User-Agent": USER_AGENT, "X-No-Encrypt": "1", "Accept": "application/json"}
    if token:
        h["token"] = token
    if json_body:
        h["Content-Type"] = "application/json"
    return h


def _call(method: str, url: str, token: str | None = None, form: dict | None = None,
          query: dict | None = None, timeout: int = 30) -> dict:
    if query:
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=_headers(token))
    if form is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        try:
            j = json.loads(body)
        except ValueError:
            raise CloudError(f"HTTP {e.code} from {url}: {body[:200]}") from None
        raise CloudError(f"HTTP {e.code}: {j.get('desc') or j.get('message') or body[:200]}") from None
    try:
        j = json.loads(body)
    except ValueError:
        raise CloudError(f"non-JSON reply from {url}: {body[:200]}") from None
    if j.get("status", 0) != 0:
        raise CloudError(f"NIU says: {j.get('desc') or j} (status {j.get('status')})")
    return j.get("data")


# ----------------------------------------------------------------------------- session

def load_json(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None


def save_json(path: str, obj: dict) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=1, sort_keys=True)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def login(account: str, password: str, app_id: str | None = None) -> dict:
    """Password login; the app sends md5(password). Tries both app ids unless one is given."""
    last = None
    for aid in ([app_id] if app_id else APP_IDS):
        form = {"account": account, "password": hashlib.md5(password.encode("utf-8")).hexdigest(),
                "grant_type": "password", "scope": "base", "app_id": aid}
        try:
            data = _call("POST", ACCOUNT_HOST + "v3/api/oauth2/token", form=form)
        except CloudError as e:
            last = e
            continue
        tok = (data or {}).get("token") or {}
        if not tok.get("access_token"):
            last = CloudError(f"login reply had no token: {data}")
            continue
        sess = {"account": account, "app_id": aid, "token": tok["access_token"],
                "refresh_token": tok.get("refresh_token", ""),
                "expires_at": int(time.time()) + int(tok.get("token_expires_in") or 0),
                "user": {k: (data.get("user") or {}).get(k) for k in ("id", "name", "email", "mobile", "country_code")}}
        save_json(SESSION_FILE, sess)
        return sess
    raise last or CloudError("login failed")


def refresh(sess: dict) -> dict:
    form = {"refresh_token": sess["refresh_token"], "grant_type": "refresh_token", "scope": "base",
            "app_id": sess.get("app_id", APP_IDS[0])}
    data = _call("POST", ACCOUNT_HOST + "v3/api/oauth2/token", form=form)
    tok = (data or {}).get("token") or {}
    if not tok.get("access_token"):
        raise CloudError(f"refresh reply had no token: {data}")
    sess.update(token=tok["access_token"], refresh_token=tok.get("refresh_token", sess["refresh_token"]),
                expires_at=int(time.time()) + int(tok.get("token_expires_in") or 0))
    save_json(SESSION_FILE, sess)
    return sess


def session() -> dict:
    sess = load_json(SESSION_FILE)
    if not sess or not sess.get("token"):
        raise CloudError("not logged in; run: kqi login you@example.com")
    if sess.get("expires_at", 0) and sess["expires_at"] < time.time() + 3600 and sess.get("refresh_token"):
        try:
            sess = refresh(sess)
        except CloudError:
            pass
    return sess


# ----------------------------------------------------------------------------- vehicle data

def scooters(token: str) -> list[dict]:
    data = _call("GET", API_HOST + "v5/scooter/list", token=token)
    if isinstance(data, dict):
        data = data.get("items") or data.get("list") or []
    return data or []


def detail(token: str, sn: str) -> dict:
    return _call("GET", API_HOST + "v5/scooter/detail/" + urllib.parse.quote(sn), token=token) or {}


def bleinfo(token: str, sn: str) -> dict:
    return _call("GET", API_HOST + "v5/ble/bleinfo", token=token, query={"sn": sn}) or {}


def secret_by_mac(token: str, mac: str) -> dict:
    """Kick scooters (KQi) hand out their BLE secret by MAC, no binding needed."""
    return _call("GET", API_HOST + "v5/device/bluetooth_secret", token=token, query={"mac": mac}) or {}


def device_info_by_mac(token: str, mac: str) -> list:
    d = _call("GET", API_HOST + "v5/users_bind/get_device_info_by_mac", token=token, query={"mac_list": mac})
    if isinstance(d, dict):
        d = d.get("items") or []
    return d or []


# ----------------------------------------------------------------------------- OTA / firmware

# Controller types the KQi cloud tracks for a kick scooter.  The app derives
# these from the vehicle's status fields (foc_s_ver -> FOC, db_sw_ver -> DB,
# bms_s_ver -> BMS, plus the light and Bluetooth units); see OtaDeviceType in
# the decompiled app.  checkupdate happily reports on any subset.
OTA_DEVICE_TYPES = ("FOC", "DB", "BMS", "LCU", "ECU_BT")


def ota_checkupdate(token: str, sn: str, devices: list[dict], timeout: int = 30) -> dict:
    """POST v5/ota/checkupdate. devices = [{devicetype, soft_version, hard_version}].

    The server compares each claimed soft_version against the newest release it
    has for that controller and, when something newer exists AND the claimed
    version is a real prior release, fills in a download url + md5 + size.  It
    also echoes the controller's *installed* version for any type you send with
    an unknown version, which is how we learn what is actually on the scooter.
    Returns the reply's `data` object (with an `items` list).
    """
    body = json.dumps({"sn": sn, "devices": devices}).encode("utf-8")
    req = urllib.request.Request(API_HOST + "v5/ota/checkupdate", data=body,
                                 method="POST", headers=_headers(token, json_body=True))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            txt = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        txt = e.read().decode("utf-8", errors="replace")
        try:
            j = json.loads(txt)
        except ValueError:
            raise CloudError(f"HTTP {e.code} from ota/checkupdate: {txt[:200]}") from None
        raise CloudError(f"HTTP {e.code}: {j.get('desc') or txt[:200]}") from None
    try:
        j = json.loads(txt)
    except ValueError:
        raise CloudError(f"non-JSON reply from ota/checkupdate: {txt[:200]}") from None
    if j.get("status", 0) != 0:
        raise CloudError(f"NIU says: {j.get('desc') or j} (status {j.get('status')})")
    return j.get("data") or {}


def ota_installed_versions(token: str, sn: str) -> dict:
    """Read the installed firmware version of every controller the cloud tracks.

    checkupdate echoes back your claimed version for any controller you send, so
    to learn the *installed* versions we send an empty device list: the server
    then volunteers its full known set (FOC, DB, BMS, LCU, ECU_BT on a KQi Air)
    with the real versions.  Returns {devicetype: {version, name,
    trans_encryption}}."""
    data = ota_checkupdate(token, sn, [])
    out: dict = {}
    for it in data.get("items", []):
        v = it.get("soft_version") or ""
        if v and v != "0.0.0":
            out[it["devicetype"]] = {"version": v, "name": it.get("devicetype_name", ""),
                                     "trans_encryption": it.get("trans_encryption", 0)}
    return out


def _prior_versions(ver: str, span: int = 40):
    """NIU version tags end in a decimal counter (KAB2FV20 -> 20).  Yield the
    counter decremented, keeping the tag's width, down to 0.  checkupdate only
    offers an image when the claimed version is a *real* earlier release, so we
    walk down from installed-1 until one is recognised."""
    m = re.match(r"^(.*?)(\d+)$", ver)
    if not m:
        return
    pre, digits = m.group(1), m.group(2)
    num, width = int(digits), len(digits)
    for n in range(num - 1, max(-1, num - span - 1), -1):
        yield f"{pre}{n:0{width}d}"


def ota_find_image(token: str, sn: str, devicetype: str, installed_version: str) -> dict | None:
    """Sweep claimed versions below `installed_version` until checkupdate hands
    back a download url for `devicetype`.  Returns {claimed, version, url, size,
    md5} or None if the cloud has no published image for it."""
    for claim in _prior_versions(installed_version):
        data = ota_checkupdate(token, sn, [{"devicetype": devicetype,
                                            "soft_version": claim, "hard_version": ""}])
        for it in data.get("items", []):
            if it.get("devicetype") == devicetype and it.get("url"):
                return {"claimed": claim, "version": it.get("soft_version", ""),
                        "url": it["url"], "size": int(it.get("size", 0)), "md5": it.get("md5", "")}
    return None


def ota_download(url: str, timeout: int = 60) -> bytes:
    """Fetch a firmware image from NIU's fota CDN (http://fota.niu.com/...)."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def load_scooter() -> dict:
    sc = load_json(SCOOTER_FILE)
    if not sc or not sc.get("ble", {}).get("mac"):
        raise CloudError("no scooter credentials; run: kqi setup")
    return sc


def save_scooter(sc: dict) -> None:
    save_json(SCOOTER_FILE, sc)
