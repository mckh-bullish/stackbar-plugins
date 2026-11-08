# OpenRouter

What [OpenRouter](https://openrouter.ai) is costing you, in the menu bar. The
panel has:

- **Tiles** for today, this week and this month, from your API key.
- **Credits**: what is left of the credits you bought, with an Add Credits
  button once it runs low.
- **Limit**: the key's spending limit or the budget that stops it first,
  and when it resets. Free-tier keys also show today's free-model requests.
- **Last 30 days**: daily spend, tokens or requests as a chart.
- **Models**: where the last 30 days went, by spend.

The menu bar shows today's spend, the credits left or the share of the limit
used (you choose in Settings), and it turns orange at 75% of the limit and red
at 90% or when credits run low.

- **Needs:** `OPENROUTER_API_KEY`, any OpenRouter key, for today, this week,
  this month and the key's limit. Optionally `OPENROUTER_MANAGEMENT_KEY`, a
  [management key](https://openrouter.ai/settings/management-keys), for the
  credit balance, the daily chart and the models: OpenRouter only gives those
  to a management key. Both are kept in the Keychain, and the plugin reaches
  `openrouter.ai` and nothing else. Nothing is contacted until a key is set.
- **Calls:** `/api/v1/key` and `/api/v1/credits` every two minutes, and
  `/api/v1/activity` (the last 30 completed days) at most once an hour.
  Days are UTC days, as OpenRouter counts them.
- **Surfaces:** menu bar, panel, widget, settings.
- **Commands:** OpenRouter Spend lists today, this week and month, the
  credits, the limit and the top models; each row copies a summary.
- **Settings:** what the menu bar shows, notifications at 90% and 100% of the
  limit, and a notification when credits drop below an amount you pick
  (5 dollars to start).
- **Agent tool:** `usage_summary`.

## What's new in 1.0.0

- First release: spend, credits, limits and model mix for your OpenRouter account.
