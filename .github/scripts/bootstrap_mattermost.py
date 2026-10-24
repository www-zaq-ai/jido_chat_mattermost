"""Create disposable integration fixtures on a fresh, isolated Mattermost server."""

import argparse
import json
import os
import secrets
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def request(base_url, path, *, data=None, token=None, content_type=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if data is not None and content_type is None:
        data = json.dumps(data).encode()
        content_type = "application/json"
    if content_type:
        headers["Content-Type"] = content_type
    req = Request(base_url + "/api/v4" + path, data=data, headers=headers)
    with urlopen(req, timeout=10) as response:
        return json.load(response), response.headers


def wait_ready(base_url, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            result, _ = request(base_url, "/system/ping")
            if result.get("status") == "OK":
                return
        except (OSError, ValueError):
            pass
        time.sleep(2)
    raise RuntimeError("Mattermost did not become ready before the deadline")


def bootstrap(base_url):
    # The first account on the empty CI server becomes its administrator.
    suffix = secrets.token_hex(6)
    username = f"ci-{suffix}"
    password = secrets.token_urlsafe(32) + "aA1!"
    request(
        base_url,
        "/users",
        data={"email": f"{username}@example.com", "username": username, "password": password},
    )
    _, headers = request(
        base_url, "/users/login", data={"login_id": username, "password": password}
    )
    token = headers.get("Token")
    if not token:
        raise RuntimeError("Mattermost login did not return a session token")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::add-mask::{token}", flush=True)

    team, _ = request(
        base_url,
        "/teams",
        token=token,
        data={"name": f"ci-{suffix}", "display_name": "CI fixtures", "type": "O"},
    )
    channel, _ = request(
        base_url,
        "/channels",
        token=token,
        data={
            "team_id": team["id"],
            "name": "integration-tests",
            "display_name": "Integration tests",
            "type": "O",
        },
    )

    boundary = secrets.token_hex(24)
    multipart = (
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="channel_id"\r\n\r\n'
        f'{channel["id"]}\r\n'
        f"--{boundary}\r\n"
        'Content-Disposition: form-data; name="files"; filename="fixture.txt"\r\n'
        "Content-Type: text/plain\r\n\r\n"
        "Mattermost CI attachment\n\r\n"
        f"--{boundary}--\r\n"
    ).encode()
    uploaded, _ = request(
        base_url,
        "/files",
        token=token,
        data=multipart,
        content_type=f"multipart/form-data; boundary={boundary}",
    )
    file_id = uploaded["file_infos"][0]["id"]
    # Attach the file to a post so the download test uses a complete fixture.
    request(
        base_url,
        "/posts",
        token=token,
        data={"channel_id": channel["id"], "message": "CI attachment", "file_ids": [file_id]},
    )
    return {
        "MATTERMOST_URL": base_url,
        "MATTERMOST_TOKEN": token,
        "MATTERMOST_CHANNEL_ID": channel["id"],
        "MATTERMOST_FILE_ID": file_id,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--env-file", default=os.environ.get("GITHUB_ENV"))
    args = parser.parse_args()
    if not args.env_file:
        parser.error("--env-file or GITHUB_ENV is required")

    try:
        base_url = args.url.rstrip("/")
        wait_ready(base_url, args.timeout)
        fixtures = bootstrap(base_url)
        descriptor = os.open(args.env_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(descriptor, "a", encoding="utf-8") as env_file:
            for key, value in fixtures.items():
                env_file.write(f"{key}={value}\n")
        print("Mattermost integration fixtures are ready.")
    except HTTPError as error:
        # Never print response bodies or request details: they may contain credentials.
        print(f"Mattermost bootstrap failed with HTTP {error.code}.", file=sys.stderr)
        return 1
    except (URLError, TimeoutError, ValueError, KeyError, IndexError, OSError, RuntimeError):
        print("Mattermost bootstrap failed; check service readiness and configuration.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
