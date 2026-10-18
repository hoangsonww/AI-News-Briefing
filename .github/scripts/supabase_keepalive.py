#!/usr/bin/env python3
"""Create and verify real database activity for configured Supabase projects."""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone


TABLE = "keepalive"
REQUEST_TIMEOUT_SECONDS = 30
MAX_ATTEMPTS = 3


@dataclass(frozen=True)
class Project:
    name: str
    env_prefix: str
    url: str
    key: str


PROJECTS = (
    ("boxed-inventory-tracker", "SUPABASE_BOXED_INVENTORY_TRACKER"),
    ("MPMagic App", "SUPABASE_MPMAGIC_APP"),
    ("SymptomSync (Team 16 final project)", "SUPABASE_SYMPTOMSYNC"),
    ("DevVerse", "SUPABASE_DEVVERSE"),
    ("petswipe-appit", "SUPABASE_PETSWIPE_APPIT"),
    ("task-manager-react-native", "SUPABASE_TASK_MANAGER_REACT_NATIVE"),
    ("CollabNote App", "SUPABASE_COLLABNOTE_APP"),
    ("oriole-social-app", "SUPABASE_ORIOLE_SOCIAL_APP"),
)


class KeepaliveError(RuntimeError):
    """A safe-to-log keepalive failure."""


def load_projects() -> list[Project]:
    projects: list[Project] = []
    missing: list[str] = []

    for name, prefix in PROJECTS:
        url_name = f"{prefix}_URL"
        key_name = f"{prefix}_SECRET_KEY"
        url = os.environ.get(url_name, "").strip().rstrip("/")
        key = os.environ.get(key_name, "").strip()

        if not url:
            missing.append(url_name)
        if not key:
            missing.append(key_name)
        if not url or not key:
            continue

        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
            raise KeepaliveError(
                f"{name}: {url_name} must be a plain HTTPS project URL"
            )

        projects.append(Project(name=name, env_prefix=prefix, url=url, key=key))

    if missing:
        raise KeepaliveError(
            "Missing required GitHub Actions secrets: " + ", ".join(missing)
        )

    return projects


def request_json(
    project: Project,
    *,
    method: str,
    query: str,
    payload: dict[str, object] | None = None,
    return_representation: bool = False,
) -> object:
    endpoint = f"{project.url}/rest/v1/{TABLE}?{query}"
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {
        # Current Supabase secret keys are API keys, not JWT bearer tokens.
        "apikey": project.key,
        "Accept": "application/json",
        "User-Agent": "github-actions-supabase-activity-monitor/1.0",
    }
    if body is not None:
        headers["Content-Type"] = "application/json"
    if return_representation:
        headers["Prefer"] = "return=representation"

    request = urllib.request.Request(
        endpoint,
        data=body,
        headers=headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(
            request, timeout=REQUEST_TIMEOUT_SECONDS
        ) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")[:500]
        raise KeepaliveError(f"HTTP {error.code}: {detail}") from error
    except urllib.error.URLError as error:
        raise KeepaliveError(f"network error: {error.reason}") from error
    except TimeoutError as error:
        raise KeepaliveError("request timed out") from error

    try:
        return json.loads(raw)
    except json.JSONDecodeError as error:
        raise KeepaliveError("Supabase returned invalid JSON") from error


def perform_activity(project: Project) -> str:
    # A microsecond-resolution value also acts as a run-specific verification token.
    timestamp = datetime.now(timezone.utc).isoformat(timespec="microseconds")

    updated = request_json(
        project,
        method="PATCH",
        query="id=eq.1&select=id,last_ping",
        payload={"last_ping": timestamp},
        return_representation=True,
    )
    if not isinstance(updated, list) or len(updated) != 1:
        raise KeepaliveError(
            "update did not return exactly one row; run the setup SQL for this project"
        )
    if updated[0].get("id") != 1:
        raise KeepaliveError("update returned an unexpected row")

    selected = request_json(
        project,
        method="GET",
        query="id=eq.1&select=id,last_ping",
    )
    if not isinstance(selected, list) or len(selected) != 1:
        raise KeepaliveError("verification read did not return exactly one row")

    try:
        expected = datetime.fromisoformat(timestamp).astimezone(timezone.utc)
        actual = datetime.fromisoformat(selected[0]["last_ping"]).astimezone(timezone.utc)
    except (KeyError, TypeError, ValueError) as error:
        raise KeepaliveError("verification read returned an invalid timestamp") from error

    if selected[0].get("id") != 1 or actual != expected:
        raise KeepaliveError("verification read did not match this run's update")

    return timestamp


def ping_with_retries(project: Project) -> str:
    last_error: KeepaliveError | None = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            return perform_activity(project)
        except KeepaliveError as error:
            last_error = error
            if attempt < MAX_ATTEMPTS:
                time.sleep(2 ** (attempt - 1))

    assert last_error is not None
    raise last_error


def main() -> int:
    try:
        projects = load_projects()
    except KeepaliveError as error:
        print(f"Configuration error: {error}", file=sys.stderr)
        return 2

    print(f"Running database activity checks for {len(projects)} Supabase projects...")
    failures: list[tuple[str, str]] = []

    with ThreadPoolExecutor(max_workers=min(4, len(projects))) as executor:
        futures = {executor.submit(ping_with_retries, project): project for project in projects}
        for future in as_completed(futures):
            project = futures[future]
            try:
                timestamp = future.result()
                print(f"PASS  {project.name}: write and verification read at {timestamp}")
            except KeepaliveError as error:
                failures.append((project.name, str(error)))
                print(f"FAIL  {project.name}: {error}", file=sys.stderr)
            except Exception as error:  # Keep unexpected errors isolated per project.
                failures.append((project.name, type(error).__name__))
                print(
                    f"FAIL  {project.name}: unexpected {type(error).__name__}",
                    file=sys.stderr,
                )

    print(f"Completed: {len(projects) - len(failures)} passed, {len(failures)} failed.")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
