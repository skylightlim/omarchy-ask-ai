"""Ask AI's hidden browser: CloakBrowser on a private, invisible X screen,
signed in through the profile login.py set up. It waits for jobs on a Unix
socket, one JSON line each:

  {"url": ..., "ai": ..., "image": "<png>", "prompt": ..., "out": "<job.json>"}

and for each one opens a new chat, attaches the image, types the prompt,
sends, and writes the answer to the job file as it is written:

  {"status": "sending|thinking|writing|done|error", "ai", "text", "url", "error"}

It exits after IDLE seconds without a job, giving the memory back.

Started by bin/ask-ai-ask; by hand: <python with cloakbrowser> askd.py
"""

import asyncio
import base64
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import sites
from common import PROFILE, launch_args

from cloakbrowser import launch_persistent_context_async

RUNTIME = Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/ask-ai-{os.getuid()}")) / "ask-ai"
SOCKET = RUNTIME / "askd.sock"
DISPLAY = ":97"
IDLE = 30 * 60
PAGE_JS = (Path(__file__).parent / "page.js").read_text()


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


class Progress:
    """The job file the answer card follows. Written in place: the card
    ignores a half-written file and reads the next write."""

    def __init__(self, path: str, ai: str):
        self.path = Path(path)
        self.state = {"status": "starting", "ai": ai, "text": "", "url": "", "error": ""}

    def update(self, status=None, **fields):
        if status:
            self.state["status"] = status
        self.state.update(fields)
        self.state["updated"] = time.time()
        with open(self.path, "w") as f:
            f.write(json.dumps(self.state))


class Failure(Exception):
    """A problem worth showing on the card as it is."""


async def first(page, selectors, state="visible", timeout=15000):
    """The first of selectors to appear, as a locator."""
    deadline = time.monotonic() + timeout / 1000
    while time.monotonic() < deadline:
        for selector in selectors:
            locator = page.locator(selector).last
            try:
                if await locator.count() and (state != "visible" or await locator.is_visible()):
                    return locator
            except Exception:
                pass
        await asyncio.sleep(0.15)
    return None


async def count(page, selectors):
    for selector in selectors:
        try:
            n = await page.locator(selector).count()
        except Exception:
            n = 0
        if n:
            return selector, n
    return selectors[0] if selectors else "", 0


async def signed_out(page, site):
    path = page.url.split("?", 1)[0]
    if any(p in path for p in site.signed_out_paths):
        return True
    for selector in site.signed_out:
        try:
            if await page.locator(selector).count():
                return True
        except Exception:
            pass
    return False


async def attach(page, site, composer, image: Path):
    """Paste the image into the composer; if no attachment shows, use the
    page's file input. Returns once something is attached, or raises."""
    data = base64.b64encode(image.read_bytes()).decode()
    await page.evaluate(PAGE_JS)
    images_before = await page.locator("img").count()
    await composer.click()
    await page.evaluate(
        "([sel, b64]) => window.__askAi.pasteImage(document.querySelector(sel) || document.activeElement, b64, 'image/png', 'screenshot.png')",
        [await selector_of(composer), data])
    if await attached(page, site, images_before, 4):
        return
    if await page.locator("[role='dialog'], [role='alertdialog']").count():
        raise Failure(f"{site.name} is asking for a one-time OK first. Open Sign in to AIs in the bar panel and accept it.")
    inputs = page.locator("input[type='file']")
    for i in range(await inputs.count()):
        accept = (await inputs.nth(i).get_attribute("accept")) or ""
        if not accept or "image" in accept or "png" in accept:
            await inputs.nth(i).set_input_files(str(image))
            if await attached(page, site, images_before, 6):
                return
    raise Failure(f"{site.name} didn't take the image.")


async def attached(page, site, images_before: int, seconds: float) -> bool:
    """An attachment shows: the site's own sign, or a new image on the page."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if await first(page, site.attached, state="attached", timeout=1) if site.attached else None:
            return True
        if await page.locator("img").count() > images_before:
            return True
        await asyncio.sleep(0.15)
    return False


async def uploaded(page, site, seconds: float = 30):
    """Wait for the site's upload indicator to go, so the image goes with the
    message. A slow upload past the limit is reported rather than sent without."""
    if not site.uploading:
        return
    # The indicator shows up a moment after the preview: done means seen and
    # then gone, or never seen in 1.5 s.
    start = time.monotonic()
    seen = False
    while time.monotonic() - start < seconds:
        if await first(page, site.uploading, state="attached", timeout=1):
            seen = True
        elif seen or time.monotonic() - start > 1.5:
            return
        await asyncio.sleep(0.15)
    raise Failure(f"{site.name} is still uploading the image after {int(seconds)} s.")


async def selector_of(locator) -> str:
    """A CSS selector string for a locator found by first()."""
    return await locator.evaluate(
        "el => { if (el.id) return '#' + CSS.escape(el.id);"
        " el.setAttribute('data-ask-ai', '1'); return '[data-ask-ai]'; }")


async def send(page, site, composer):
    """Click send once it's enabled (an upload in progress disables it);
    Enter if the site has no button we know."""
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        button = await first(page, site.send, timeout=500)
        if button:
            disabled = await button.evaluate(
                "b => b.disabled || b.getAttribute('aria-disabled') === 'true'")
            if not disabled:
                await button.click()
                return
        elif not site.send or time.monotonic() > deadline - 55:
            await composer.press("Enter")
            return
        await asyncio.sleep(0.2)
    raise Failure(f"{site.name} never let the message send.")


async def stream_answer(page, site, before: int, progress: Progress):
    """Follow the new reply until it stops changing and the stop button is
    gone; write each change to the job file."""
    deadline = time.monotonic() + 60
    selector = ""
    while time.monotonic() < deadline:
        selector, n = await count(page, site.answer)
        if n > before:
            break
        await asyncio.sleep(0.2)
    else:
        raise Failure(f"{site.name} didn't answer within a minute.")

    text, changed, deadline = "", time.monotonic(), time.monotonic() + 300
    while time.monotonic() < deadline:
        try:
            now = await page.locator(selector).last.evaluate("el => window.__askAi.toMarkdown(el)")
        except Exception:
            now = text
        if now != text:
            text, changed = now, time.monotonic()
            progress.update("writing", text=text, url=page.url)
        stopping = await first(page, site.stop, timeout=1) if site.stop else None
        quiet = time.monotonic() - changed
        if text and not stopping and quiet > (1.0 if site.stop else 2.5):
            return text
        await asyncio.sleep(0.25)
    return text


class Daemon:
    def __init__(self):
        self.ctx = None
        self.xvfb = None
        self.warm = {}  # url -> a new-chat page already loaded, for the next question
        self.lock = asyncio.Lock()
        self.last_job = time.monotonic()

    async def start_browser(self):
        if not Path(f"/tmp/.X11-unix/X{DISPLAY[1:]}").exists():
            self.xvfb = subprocess.Popen(["Xvfb", DISPLAY, "-screen", "0", "1920x1080x24", "-nolisten", "tcp"],
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            for _ in range(50):
                if Path(f"/tmp/.X11-unix/X{DISPLAY[1:]}").exists():
                    break
                await asyncio.sleep(0.1)
        os.environ["DISPLAY"] = DISPLAY
        os.environ.pop("WAYLAND_DISPLAY", None)
        os.environ["XDG_SESSION_TYPE"] = "x11"
        self.ctx = await launch_persistent_context_async(
            str(PROFILE), headless=False, args=launch_args(["--ozone-platform=x11"]))
        log("browser up")

    async def warm_up(self, url: str):
        """Load a new chat in the background, so the next question to this AI
        skips the page load."""
        if url in self.warm:
            return
        page = await self.ctx.new_page()
        try:
            await page.goto(url, wait_until="domcontentloaded", timeout=30000)
            self.warm[url] = page
        except Exception:
            await page.close()

    async def take_page(self, url: str):
        page = self.warm.pop(url, None)
        if page and not page.is_closed():
            return page
        page = await self.ctx.new_page()
        await page.goto(url, wait_until="domcontentloaded", timeout=30000)
        return page

    async def run(self, job: dict):
        progress = Progress(job["out"], job.get("ai", ""))
        site = sites.for_url(job.get("url", ""))
        if not site:
            progress.update("error", error="Ask AI doesn't know this site yet.")
            return
        progress.update("sending")
        try:
            page = await self.take_page(job["url"])
        except Exception as error:
            progress.update("error", error=f"{site.name} didn't load: {type(error).__name__}")
            return
        try:
            composer = await first(page, site.composer, timeout=20000)
            if await signed_out(page, site):
                raise Failure(f"Not signed in to {site.name}. Use Sign in to AIs in the bar panel.")
            if not composer:
                raise Failure(f"{site.name}'s page didn't load its chat box.")
            _, before = await count(page, site.answer)
            await attach(page, site, composer, Path(job["image"]))
            await uploaded(page, site)
            if site.settle:
                await asyncio.sleep(site.settle)
            if job.get("prompt"):
                await composer.click()
                await page.keyboard.insert_text(job["prompt"])
            await send(page, site, composer)
            progress.update("thinking", url=page.url)
            text = await stream_answer(page, site, before, progress)
            progress.update("done", text=text, url=page.url)
            log("done", site.name, len(text), "chars")
        except Failure as failure:
            progress.update("error", error=str(failure), url=page.url)
            log("failed", site.name, failure)
        except Exception as error:
            progress.update("error", error=f"{site.name}: {type(error).__name__}", url=page.url)
            log("error", site.name, repr(error))
        finally:
            await page.close()
            asyncio.create_task(self.warm_up(job["url"]))

    async def handle(self, reader, writer):
        try:
            line = await reader.readline()
            job = json.loads(line)
            writer.write(b"accepted\n")
            await writer.drain()
        except Exception:
            writer.write(b"bad job\n")
            return
        finally:
            writer.close()
        self.last_job = time.monotonic()
        async with self.lock:
            await self.run(job)
        self.last_job = time.monotonic()

    async def main(self):
        RUNTIME.mkdir(parents=True, exist_ok=True)
        if SOCKET.exists():
            try:
                _, w = await asyncio.open_unix_connection(str(SOCKET))
                w.close()
                log("already running")
                return
            except OSError:
                SOCKET.unlink()
        await self.start_browser()
        server = await asyncio.start_unix_server(self.handle, path=str(SOCKET))
        os.chmod(SOCKET, 0o600)
        log("listening on", SOCKET)
        # Stopped (by Sign in to AIs, or a logout): close the browser and the
        # X screen properly rather than leave them running.
        stop = asyncio.Event()
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            asyncio.get_running_loop().add_signal_handler(sig, stop.set)
        try:
            while not stop.is_set() and (time.monotonic() - self.last_job < IDLE or self.lock.locked()):
                try:
                    await asyncio.wait_for(stop.wait(), 10)
                except asyncio.TimeoutError:
                    pass
        finally:
            log("stopping" if stop.is_set() else "idle, stopping")
            server.close()
            SOCKET.unlink(missing_ok=True)
            await self.ctx.close()
            if self.xvfb:
                self.xvfb.terminate()


if __name__ == "__main__":
    asyncio.run(Daemon().main())
