"""Shared settings for Ask AI's own browser: a CloakBrowser profile that stays
signed in to the chat sites, so a capture can be sent without a visible tab.

Runs on a Python with the cloakbrowser package (bin/ask-ai-python finds it).
Prefers CloakBrowser's free build, which needs no licence key and so never
takes the one session a free Pro key allows.
"""

import json
import os
import secrets
from pathlib import Path

HOME = Path.home()
DATA = Path(os.environ.get("XDG_DATA_HOME", HOME / ".local/share")) / "ask-ai"
PROFILE = DATA / "profile"
SEED_FILE = DATA / "fingerprint-seed"
CONFIG = Path(os.environ.get("XDG_CONFIG_HOME", HOME / ".config")) / "ask-ai" / "config.json"
PLUGIN = Path(__file__).resolve().parent.parent


def free_build() -> Path | None:
    """The newest free CloakBrowser build already downloaded, if any. Without
    one, CloakBrowser downloads its default build on first launch."""
    def version(path: Path):
        return tuple(int(n) for n in path.parent.name.removeprefix("chromium-").split(".") if n.isdigit())
    builds = [p for p in (HOME / ".cloakbrowser").glob("chromium-*/chrome") if not p.parent.name.endswith("-pro")]
    return max(builds, key=version) if builds else None


if (build := free_build()) is not None:
    os.environ.setdefault("CLOAKBROWSER_BINARY_PATH", str(build))
os.environ.setdefault("CLOAKBROWSER_SUPPRESS_FONT_WARNING", "1")

WINDOW = (1280, 860)


def fingerprint_seed() -> str:
    """One identity for this profile, kept across launches: a signed-in
    account whose browser changes fingerprint every start gets challenged."""
    DATA.mkdir(parents=True, exist_ok=True)
    if not SEED_FILE.exists():
        SEED_FILE.write_text(str(10000 + secrets.randbelow(90000)))
    return SEED_FILE.read_text().strip()


def chat_sites() -> list[dict]:
    """The AIs from the user's config (falling back to the shipped default)."""
    for path in (CONFIG, PLUGIN / "config.default.json"):
        try:
            targets = json.loads(path.read_text()).get("targets", [])
        except (OSError, ValueError):
            continue
        sites = [t for t in targets if isinstance(t, dict) and str(t.get("url", "")).startswith("https://")]
        if sites:
            return sites
    return []


def launch_args(extra: list[str] | None = None) -> list[str]:
    return [f"--fingerprint={fingerprint_seed()}", f"--window-size={WINDOW[0]},{WINDOW[1]}", *(extra or [])]
