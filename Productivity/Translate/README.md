# Translate

Translates the text you selected. Run **Translate Selection** from the
palette, or give it a hotkey in Settings > Commands. When an app doesn't
share its selection, it uses what you last copied.

- **Engines:**
  - **Automatic**, the default, translates in place with no setup. It
    uses Apple's translation on your Mac when that language pair is
    downloaded (System Settings > General > Language & Region > Translation
    Languages), so nothing leaves the Mac. Otherwise it sends the text to
    Google Translate's keyless endpoint, the one Google's own browser
    extension uses. Google doesn't document that endpoint, so it may change
    or be rate limited.
  - **DeepL:** translates in place with your DeepL API key; the free plan
    covers 500,000 characters a month.
  - **Browser:** opens translate.google.com with the text filled in.

  In place, you can paste the result over the selection (your clipboard
  comes back afterwards) or copy it, and the result says which engine did it.
  Text that is already in your target language is translated into your second
  language instead, so one command goes both ways.
- **Needs:** the selection (`.context`), the clipboard (as a fallback, and
  to paste), `translate.googleapis.com`, `api-free.deepl.com` and
  `api.deepl.com`, and the secret `DEEPL_API_KEY`, which is asked for only
  when you choose DeepL.
- **Surfaces:** panel, settings. No menu-bar item.
- **Settings:** the engine, the language to translate into and the second
  language, and DeepL's formality.
- **Commands:** Translate Selection, Translate Selection in Google Translate.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
