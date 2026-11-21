"""Open Ask AI's browser profile in a visible window, one tab per chat site,
so the user can sign in. Exits when the window is closed; the sign-ins stay
in the profile for the hidden browser to use.

Usage: bin/ask-ai-login (or: <python with cloakbrowser> login.py)
"""

import asyncio

from common import PROFILE, chat_sites, launch_args

from cloakbrowser import launch_persistent_context_async


async def main() -> None:
    PROFILE.mkdir(parents=True, exist_ok=True)
    ctx = await launch_persistent_context_async(str(PROFILE), headless=False, args=launch_args())
    closed = asyncio.Event()
    ctx.on("close", lambda *_: closed.set())

    pages = list(ctx.pages)
    for i, site in enumerate(chat_sites()):
        page = pages[i] if i < len(pages) else await ctx.new_page()
        try:
            await page.goto(site["url"], wait_until="commit", timeout=30000)
        except Exception as error:  # a slow site shouldn't stop the others
            print(f"{site['name']}: {error}", flush=True)
    if ctx.pages:
        await ctx.pages[0].bring_to_front()

    print("Sign in, then close the window.", flush=True)
    await closed.wait()


asyncio.run(main())
