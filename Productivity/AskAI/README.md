# Ask AI

Ask an AI model from the palette with your own key. Type a question and press
**Tab** (Stackbar 0.36 and later; you can change what Tab does in Settings ›
Command Palette), or pick **Ask AI** under the results for any text. Type
again in the answer view to ask a follow-up with the conversation so far.
Return copies an answer and ⌘P pastes it into the app you were in.

- **Commands:**
  - **Ask AI:** a question, with follow-ups. Also offered under the
    palette's results for anything you type.
  - **Fix Spelling and Grammar**, **Improve Writing** and **Make Shorter**
    replace the selected text with the result (your clipboard comes back
    afterwards).
  - **Summarize Selection** and **Explain Selection** show the answer in the
    palette, with follow-ups.
  - The panel has a question box and the last answer.
- **Providers:** Anthropic is the default, with Claude Opus 5.5 at low effort
  for quick answers; name another model in Settings, such as
  `claude-haiku-5-5` for cheaper ones. OpenAI, OpenRouter (`openrouter/auto`
  picks a model per question) and Ollama on your own Mac (no key, nothing sent
  anywhere) are the others. Answers arrive whole rather than word by word.
- **Needs:** the selection (`.context`), the clipboard (to paste results),
  `api.anthropic.com`, `api.openai.com`, `openrouter.ai` and `localhost`
  (Ollama), and one of the secrets `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` or
  `OPENROUTER_API_KEY`, asked for only for the provider you use. Your
  question, the conversation and, for the text commands, the selected text go
  to that provider.
- **Surfaces:** panel, settings. No menu-bar item.
- **Settings:** the provider and its model.

## What's new in 1.0.0

- First version: Ask AI with follow-ups and Tab from the palette, five
  commands on selected text, and Anthropic, OpenAI, OpenRouter or Ollama.
