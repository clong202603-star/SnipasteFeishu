"""拉取抖音关注者，把肖像和名字写进仓库自述文件。

密钥只从环境变量读取，不写进仓库：
  DOUYIN_COOKIE
  DOUYIN_SEC_UID 或 DOUYIN_UNIQUE_ID

用法：python3 followers/update_followers.py
自检：python3 followers/update_followers.py --self-test
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
AVATARS = ROOT / "avatars"
DAYS = ROOT / "days"
README = REPO / "README.md"
MARKER_START = "<!-- contributors:start -->"
MARKER_END = "<!-- contributors:end -->"
UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
)


class FollowersError(RuntimeError):
    pass


def _cookie() -> str:
    parts = []
    for seg in os.environ.get("DOUYIN_COOKIE", "").split(";"):
        seg = seg.strip()
        if not seg or "=" not in seg:
            continue
        name = seg.split("=", 1)[0].strip()
        if name in {"douyin.com", "www.douyin.com"}:
            continue
        parts.append(seg)
    cookie = "; ".join(parts)
    if "sessionid=" not in cookie:
        raise FollowersError("DOUYIN_COOKIE has no sessionid. Sign in again and replace the secret.")
    return cookie


def _headers(cookie: str) -> dict[str, str]:
    return {"User-Agent": UA, "Referer": "https://www.douyin.com/", "Cookie": cookie}


def _get_json(url: str, cookie: str) -> dict:
    req = urllib.request.Request(url, headers=_headers(cookie))
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "ignore")[:180]
        raise FollowersError(f"Douyin HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise FollowersError(f"Could not reach Douyin: {exc.reason}") from exc
    if not raw.strip():
        raise FollowersError("Douyin returned an empty body. The caller IP is likely blocked.")
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise FollowersError("Douyin did not return JSON") from exc


def _limit() -> int:
    raw = os.environ.get("DOUYIN_FOLLOWER_LIMIT", "2000").strip() or "2000"
    try:
        value = int(raw)
    except ValueError as exc:
        raise FollowersError("DOUYIN_FOLLOWER_LIMIT must be a number") from exc
    if value < 1:
        raise FollowersError("DOUYIN_FOLLOWER_LIMIT must be at least 1")
    return value


def resolve_sec_uid(cookie: str) -> str:
    sec = os.environ.get("DOUYIN_SEC_UID", "").strip()
    marker = "MS4wLjAB"
    start = sec.find(marker)
    if start >= 0:
        token = []
        for char in sec[start:]:
            if char.isalnum() or char in "_-":
                token.append(char)
            else:
                break
        return "".join(token)
    unique = os.environ.get("DOUYIN_UNIQUE_ID", "").strip().lstrip("@")
    if not unique:
        raise FollowersError("Set DOUYIN_SEC_UID or DOUYIN_UNIQUE_ID")
    url = "https://www.iesdouyin.com/web/api/v2/user/info/?" + urllib.parse.urlencode(
        {"unique_id": unique}
    )
    data = _get_json(url, cookie)
    found = ((data.get("user_info") or {}) if data.get("status_code") == 0 else {}).get("sec_uid") or ""
    if not found.startswith(marker):
        raise FollowersError(f"No account found for Douyin ID {unique}. Set DOUYIN_SEC_UID from the profile URL.")
    return found


def fetch_followers(sec_uid: str, cookie: str, limit: int) -> list[dict]:
    found: list[dict] = []
    max_time = 0
    seen_cursors = {0}
    while len(found) < limit:
        query = urllib.parse.urlencode(
            {
                "device_platform": "webapp",
                "aid": "6383",
                "channel": "channel_pc_web",
                "sec_user_id": sec_uid,
                "count": "20",
                "max_time": str(max_time),
                "min_time": "0",
                "offset": "0",
                "source_type": "1",
                "gps_access": "0",
                "address_book_access": "0",
            }
        )
        data = _get_json(f"https://www.douyin.com/aweme/v1/web/user/follower/list/?{query}", cookie)
        code = data.get("status_code")
        if code == 8:
            raise FollowersError("Douyin says the session is logged out. Replace the DOUYIN_COOKIE secret.")
        if code not in (0, None):
            raise FollowersError(f"Douyin refused the contributor list ({code} {data.get('status_msg') or ''})".strip())
        page = data.get("followers") or []
        if not isinstance(page, list):
            raise FollowersError("The contributor list format changed")
        found.extend(item for item in page if isinstance(item, dict))
        if not data.get("has_more") or not page:
            break
        cursor = data.get("min_time")
        try:
            cursor = int(cursor)
        except (TypeError, ValueError):
            break
        if cursor in seen_cursors:
            break
        seen_cursors.add(cursor)
        max_time = cursor
    return found[:limit]


def _avatar_url(user: dict) -> str:
    for key in ("avatar_thumb", "avatar_medium", "avatar_larger"):
        urls = ((user.get(key) or {}) if isinstance(user.get(key), dict) else {}).get("url_list") or []
        for url in urls:
            if isinstance(url, str) and url.startswith("http"):
                return url
    return ""


def _file_key(user: dict) -> str:
    raw = str(user.get("sec_uid") or user.get("uid") or user.get("nickname") or "")
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:20]


def _download(url: str, dest: Path) -> bool:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Referer": "https://www.douyin.com/"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            blob = resp.read(2_000_001)
    except (urllib.error.URLError, TimeoutError, OSError):
        return False
    if not blob or len(blob) > 2_000_000:
        return False
    dest.write_bytes(blob)
    return True


def collect(users: list[dict]) -> list[dict]:
    """只保留昵称和头像文件。头像用哈希命名，名单里不出现账号 id。"""
    AVATARS.mkdir(parents=True, exist_ok=True)
    rows = []
    for user in users:
        nickname = str(user.get("nickname") or "").strip() or "Unnamed"
        key = _file_key(user)
        dest = AVATARS / f"{key}.jpg"
        avatar = f"avatars/{key}.jpg"
        if not dest.is_file():
            url = _avatar_url(user)
            if not url or not _download(url, dest):
                avatar = ""
        rows.append({"nickname": nickname, "avatar": avatar})
    return rows


def _cell(nickname: str) -> str:
    return nickname.replace("|", "\\|").replace("\n", " ").strip() or "Unnamed"


def markdown_table(rows: list[dict], *, image_prefix: str) -> str:
    lines = ["| Portrait | Name |", "| --- | --- |"]
    for row in rows:
        avatar = row.get("avatar") or ""
        if avatar:
            image = f"![]({image_prefix}{Path(avatar).name})"
        else:
            image = ""
        lines.append(f"| {image} | {_cell(row.get('nickname') or '')} |")
    return "\n".join(lines)


def _roster_block(day: str, rows: list[dict]) -> str:
    if rows:
        body = f"Current roster on {day}: {len(rows)} contributors.\n\n"
        body += markdown_table(rows, image_prefix="followers/avatars/")
    else:
        body = f"No contributors were returned on {day}."
    return f"{MARKER_START}\n{body}\n{MARKER_END}"


def write_root_roster(day: str, rows: list[dict]) -> None:
    text = README.read_text(encoding="utf-8")
    if MARKER_START not in text or MARKER_END not in text:
        raise FollowersError("README.md is missing the contributors markers")
    pre, rest = text.split(MARKER_START, 1)
    _, post = rest.split(MARKER_END, 1)
    README.write_text(pre + _roster_block(day, rows) + post, encoding="utf-8")


def write_lists(day: str, rows: list[dict]) -> None:
    DAYS.mkdir(parents=True, exist_ok=True)
    body = f"# Contributors on {day}\n\n{len(rows)} people. Portrait and name only.\n\n"
    body += markdown_table(rows, image_prefix="../avatars/") + "\n"
    (DAYS / f"{day}.md").write_text(body, encoding="utf-8")
    latest = f"# Contributors ({day})\n\n{len(rows)} people. Portrait and name only.\n\n"
    latest += markdown_table(rows, image_prefix="avatars/") + "\n"
    (ROOT / "latest.md").write_text(latest, encoding="utf-8")
    public = [{"nickname": row["nickname"], "avatar": row["avatar"]} for row in rows]
    (DAYS / f"{day}.json").write_text(json.dumps(public, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    (ROOT / "latest.json").write_text(json.dumps(public, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    dates = sorted((path.stem for path in DAYS.glob("*.md")), reverse=True)
    index = [
        "# Contributors",
        "",
        "Daily archive. The current roster, with portraits and names, is rendered in the repository README.",
        "",
    ]
    for date in dates:
        count = 0
        data_path = DAYS / f"{date}.json"
        if data_path.is_file():
            try:
                count = len(json.loads(data_path.read_text(encoding="utf-8")))
            except json.JSONDecodeError:
                count = 0
        index.append(f"- [{date}](days/{date}.md) ({count})")
    index.append("")
    (ROOT / "README.md").write_text("\n".join(index), encoding="utf-8")
    write_root_roster(day, rows)


def _self_test() -> None:
    table = markdown_table(
        [{"nickname": "甲|乙", "avatar": "avatars/abc.jpg"}, {"nickname": "丙", "avatar": ""}],
        image_prefix="avatars/",
    )
    assert "甲\\|乙" in table
    assert "![](avatars/abc.jpg)" in table
    assert table.splitlines()[-1] == "|  | 丙 |"
    print("ok")


def main() -> None:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        _self_test()
        return
    if len(sys.argv) != 1:
        raise SystemExit("Usage: python3 followers/update_followers.py")
    cookie = _cookie()
    sec_uid = resolve_sec_uid(cookie)
    users = fetch_followers(sec_uid, cookie, _limit())
    day = datetime.now(ZoneInfo("Asia/Shanghai")).date().isoformat()
    rows = collect(users)
    write_lists(day, rows)
    missing = sum(1 for row in rows if not row["avatar"])
    print(json.dumps({"ok": True, "day": day, "count": len(rows), "avatars_missing": missing}, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except FollowersError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), flush=True)
        raise SystemExit(1) from exc
