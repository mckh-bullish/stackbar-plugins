# Translate

Translates the text you selected. Run **Translate Selection** from the
palette, or give it a hotkey in Settings > Commands. When an app doesn't
share its selection, it uses what you last copied.

- **Engines:**
  - **Google Translate (browser)**, the default: opens translate.google.com
    with the text filled in. No account or key.
  - **DeepL:** translates in place, so you can paste the result over the
    selection (your clipboard comes back afterwards) or copy it. It needs a
    DeepL API key; the free plan covers 500,000 characters a month. Text that
    is already in your target language is translated into your second
    language instead, so one command goes both ways.
- **Needs:** the selection (`.context`), the clipboard (as a fallback, and
  to paste), `api-free.deepl.com` and `api.deepl.com`, and the secret
  `DEEPL_API_KEY`, which is asked for only when you choose DeepL.
- **Surfaces:** panel, settings. No menu-bar item.
- **Settings:** the engine, the language to translate into and the second
  language, and DeepL's formality.
- **Commands:** Translate Selection, Translate Selection in Google Translate.
