# Up Next

Your next meeting in the menu bar, with a countdown and one-click join. It
finds the video link in the location, URL or notes (Zoom, Meet, Teams, Webex
and a dozen more), reminds you a few minutes before, and can open the call for
you when it starts.

- **Needs:** your calendars in Calendar.app, through the host, which asks for
  access once, and permission to add events (for Add Calendar Event). No
  network.
- **Surfaces:** menu bar, panel, window, widget, settings. Hotkey ⌃⌥J joins
  the next call.
- **Settings:** calendars to hide, all-day and declined events, only meetings
  with a link or with other people, the reminder lead time, auto-join (the
  meeting you're in, never a tentative or unanswered invite), a full-screen
  alert, how the title shows in the menu bar, and opening calls in their apps.
- **Commands:** Join Next Meeting, Copy Next Meeting Link, Today's
  Meetings, Add Calendar Event ("Lunch with Sam tomorrow 1pm for 45m",
  "Offsite fri" for all day; it shows the event and lets you pick the
  calendar) and Snooze Meeting Reminder. Give them a hotkey or an alias in
  Stackbar's Settings, or run them from Spotlight, Shortcuts or a `stackbar://`
  link.
- **Reminders and alerts** have Join and Snooze 5 Min buttons. A Join from
  either counts as joining, so auto-join won't open that call again.
- **Hide from countdown:** a meeting's row action keeps it out of the
  countdown, reminders and auto-join, and Show Again brings it back.
- **Agent tools:** `next_meeting`, `agenda` and `join_next`, off until you turn
  them on in Settings → Agents.
- **Requires:** Stackbar 0.27.0 or later.

## Highlights

### Join from the menu bar
The menu bar counts down to your next meeting. One click, or ⌃⌥J from
anywhere, opens the call. Up Next finds the link in the location, URL or notes
for Zoom, Meet, Teams, Webex and a dozen more.

### Never miss the start
It reminds you a few minutes before, can show a full-screen alert, and can
open the call for you when it starts.

### See your whole week
The window lays out today and the week's meeting load, so you can see a
crowded afternoon coming.
<!-- preview: week -->

### On your desktop too
A widget keeps what's next in view without opening anything.
<!-- preview: widget -->

## What's new in 1.7.0

- Join on time opens only the meeting you're in, in the Zoom or Teams app if you chose that, and never a tentative one.
- Joining from a reminder or alert counts, so auto-join won't open that call again, even after a restart.
- Add Calendar Event understands "at 5 pm", "at 1" (1 pm), "at 12", "for 30 minutes", "for 3 days" (an all-day event spanning them), "10.30am" and "friday" anywhere in the text. It shows the event before adding it, with a choice of calendar, and adds it once.
- ⌃⌥J joins the next call.
- Agent tools are off until you allow them.
- Two meetings at once get one full-screen alert.
- Waking or launching just before a meeting gives one reminder, not two.
- Join buttons only for real meeting-service addresses (Zoom, Meet, Teams, Webex and the rest), matched by host and path, so a look-alike link gets none. Outlook Safe Links and meeting links written without https work too.
- Join buttons refuse addresses whose host hides a slash, dot or other odd character in encoded form, so a look-alike address gets none.
- The add-event preview shows the day a timed event ends, when that's a different day.
- Today's Meetings: faster search that also matches calendar and place, and timed meetings are listed before all-day ones.
- A Join button on the widget.
- Hide a meeting from the countdown, and show it again from its row.
- Snoozing a meeting that's no longer on your calendar says so, instead of snoozing another one.
- Clearer messages when Up Next can't read or add to your calendar: a permission problem says which setting to change.
- Fixes for daylight-saving days and meetings past midnight.

## What's new in 1.6.1

- Reminders, auto-join and alerts no longer repeat after weeks of uptime.
- An http:// meeting link that comes before an https:// one is found.
- The panel renders faster with a busy calendar.

## What's new in 1.6.0

- Add Calendar Event: type "Dentist fri 9:30" in the palette and it goes in your calendar.
- Snooze 5 Min on meeting reminders.

## What's new in 1.5.0

- Step through the week: chips under the meeting pick any of the next seven days.
- "Free until 14:30" in the header while you're between meetings.
- Meetings that clash with another are flagged, and the row says which.
- A second, quieter nudge as a meeting starts, with a Join button.

## What's new in 1.4.1

- Its store screenshots no longer show a meeting under both Today and Tomorrow.

## What's new in 1.4.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.3.1

- Its own icon and colour in the Store and in Settings.
