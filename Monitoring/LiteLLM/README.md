# LiteLLM

Tokens, spend and budget from your own [LiteLLM](https://docs.litellm.ai)
proxy, with charts. The panel has:

- **Tiles** for today, the last 7 days and the last 30 days, with tokens,
  spend, active days and the daily average.
- **Budget**: spend against your key's budget and when it resets.
- **Activity**: six months of daily tokens as a heatmap.
- **Trend**: a week as bars, or a month or six months as an area chart, in
  tokens or spend.
- **Models**: the top five models over 30 days, with each one's share.
- **Today's requests**: the success rate, how much input came from the
  cache, and what caching saved.

The menu bar shows today's spend, today's tokens or the share of the budget
used (you choose in Settings), and it turns orange at 75% of the budget and
red at 90%.

- **Needs:** two secrets. `LITELLM_PROXY_URL` is your proxy's base URL, like
  `https://litellm.example.com`, and the plugin can reach that host and no
  other. `LITELLM_API_KEY` is a LiteLLM key. Both are kept in the Keychain.
  Nothing is contacted until you enter the URL.
- **Calls:** `/user/info` and `/user/daily/activity`, every two minutes for
  the last 30 days and every six hours for the six months before that.
- **Surfaces:** menu bar, panel, window, widget, settings.
- **Settings:** what the menu bar shows, and notifications at 90% and 100% of
  the budget.
- **Agent tool:** `usage_summary`.

Ported from vee-plugins' `litellm-cost`.

## What's new in 1.4.0

- A LiteLLM Spend command in the palette shows today, 7 and 30 days, and the budget.

## What's new in 1.3.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.2.1

- Its own icon and colour in the Store and in Settings.
