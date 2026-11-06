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
  when you choose DeepL. Translate Text on Screen reads the screen where
  you drag (macOS asks for Screen Recording once).
- **Surfaces:** panel, settings. No menu-bar item.
- **Settings:** the engine, the language to translate into and the second
  language, and DeepL's formality.
- **Commands:** Translate Selection, Translate Text on Screen (drag over
  any text, even in an image or a video; the translation is copied),
  Translate Selection in Google Translate.
- **Requires:** Stackbar 0.26.0 or later.

## What's new in 1.6.0

- Translate Text on Screen: drag over any text, even text in a picture, and the translation is copied.

## What's new in 1.5.0

- Translate what you typed: when nothing in the palette matches, Translate offers to translate the text.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
