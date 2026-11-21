"""Where things are on each chat site. Selectors are lists tried in order:
sites rename things, and the first that matches wins.

composer   the box you type into
send       the send button (Enter is the fallback)
stop       shown while an answer is being written
answer     one AI reply; the last one is the answer
attached   a sign that an image is attached to the message being written
           (a new <img> on the page counts too)
uploading  shown while the image is still uploading (sending then drops it)
signed_out a sign that the page wants a sign-in instead
"""

from dataclasses import dataclass, field
from urllib.parse import urlparse


@dataclass
class Site:
    name: str
    composer: list[str]
    answer: list[str]
    send: list[str] = field(default_factory=list)
    stop: list[str] = field(default_factory=list)
    attached: list[str] = field(default_factory=list)
    signed_out: list[str] = field(default_factory=list)
    signed_out_paths: list[str] = field(default_factory=list)
    uploading: list[str] = field(default_factory=list)  # shown while the image uploads
    settle: float = 0.0  # extra seconds after attaching, for sites whose upload has no visible end


SITES = {
    # Checked 21 Nov 2026: paste attaches; Send/Stop are labelled buttons.
    "chatgpt.com": Site(
        name="ChatGPT",
        composer=["div.ProseMirror[contenteditable='true']", "div[contenteditable='true'][aria-label]", "#prompt-textarea"],
        send=["button[aria-label='Send']", "#composer-submit-button", "button[data-testid='send-button']"],
        stop=["button[aria-label='Stop']", "button[data-testid='stop-button']"],
        answer=["[class*='DilResponseRoot']", "[data-message-author-role='assistant'] .markdown",
                "[data-message-author-role='assistant']"],
        attached=["button[aria-label^='Remove ']", "[role='button'].composer-attachment-surface"],
        signed_out=["[data-testid='login-button']"],
    ),
    # Checked 21 Nov 2026: answers in [data-testid=assistant-message].
    "claude.ai": Site(
        name="Claude",
        composer=["div[contenteditable='true'].ProseMirror", "[data-testid='chat-input']", "div[contenteditable='true']"],
        send=["button[aria-label='Send message']", "button[aria-label='Send Message']"],
        stop=["button[aria-label='Stop response']", "button[aria-label='Stop Response']"],
        answer=["[data-testid='assistant-message']", ".font-claude-response"],
        attached=["[data-testid='file-thumbnail']", "[data-testid*='attachment']", "img[alt*='Uploaded']"],
        signed_out_paths=["/login"],
    ),
    # Checked 21 Nov 2026: paste attaches (after the one-time image notice is
    # accepted); "Send message" / "Stop response" buttons.
    "gemini.google.com": Site(
        name="Gemini",
        composer=["rich-textarea .ql-editor", "div[contenteditable='true']"],
        send=["button.send-button", "button[aria-label='Send message']"],
        stop=["button[aria-label='Stop response']", "button.stop"],
        answer=["model-response message-content .markdown", "message-content .markdown", "model-response"],
        attached=["uploader-file-preview", ".file-preview-container img", "img[data-test-id*='uploaded']"],
        # Its send button stays enabled while this spins; sending then drops the image.
        uploading=[".gem-attachment-loading-container", "uploader-file-preview [role='progressbar']"],
        settle=0.8,  # and it needs a moment after the spinner before a send keeps the image
        signed_out=["a[href*='ServiceLogin']", "a[aria-label='Sign in']"],
    ),
    # Checked 21 Nov 2026: paste attaches; no labelled send button, Enter sends.
    "chat.deepseek.com": Site(
        name="DeepSeek",
        composer=["textarea#chat-input", "textarea"],
        answer=[".ds-assistant-message-main-content", ".ds-markdown"],
        signed_out_paths=["/sign_in"],
        settle=2.0,
    ),
}


def for_url(url: str) -> Site | None:
    host = urlparse(url).hostname or ""
    for domain, site in SITES.items():
        if host == domain or host.endswith("." + domain):
            return site
    return None
