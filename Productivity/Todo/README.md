# Todo

A calm to-do list for the menu bar, in a warm orange. Type a task the way you
would say it and the when comes out of the words: “Call the dentist tomorrow
at 2pm” becomes *Call the dentist*, due tomorrow at 2:00 PM. Today's tasks
(and any left over from earlier) sit on top, then tomorrow, then what is
coming up, then someday. A small ring in the header fills as today's tasks get
done.

- **Needs:** nothing. No network, files or secrets.
- **Surfaces:** menu bar, panel, widget, settings.
- **Typing dates:** today, tonight, tomorrow, the day after tomorrow, friday,
  this friday, next friday (the Friday of next week), this weekend, next week,
  next month, in 3 days, in 2 hours, in half an hour, Nov 5, 5 November, the
  12th, 2027-03-12. Times: 2pm, 2:30pm, 14:30, at 9, noon, this morning,
  this afternoon, this evening. Repeats: every day, every weekday, every
  monday, every week, every month, daily, weekly, monthly. A `!` on its own
  marks the task important. Words in "double quotes" are kept as they are.
- **In the panel:** tick the circle to finish a task; tick a done one to bring
  it back. Click a task to open it in place: rename it (a date in the new
  text reschedules it), move it to Today, Tomorrow, the weekend, next week
  or Someday, set a repeat, star it or delete it. Every add, tick, move and
  delete shows a banner with Undo. The eye button shows what you have done.
- **Repeats:** ticking off a repeating task records it as done and moves it
  to its next day.
- **Reminders:** a task with a time sends a notification when it is due, once.
  One the Mac slept through by more than half a day is let go quietly.
- **Menu bar:** a quiet count of what is due today, or the next task, the count
  of everything open, or just the icon. It never turns red.
- **Commands:** Add a Todo, Mark a Todo Done, Snooze a Todo (to a time you
  type, or an hour or a day later) and Today's Todos (a list to tick off from
  the palette). Run them from the palette, give them a hotkey, or call them
  from a Shortcut or a
  `stackbar://commands/io.navbytes.stackbar.plugins.todo/add?task=…` link.
- **Settings:** what the menu bar shows, reminders and their sound, a morning
  summary of the day at 7, 8, 9 or 10 AM, and how long done tasks are kept.
- **Agent tools:** `tasks` lists open tasks with their dates; `add` adds one
  from plain words.
- **Requires:** Stackbar 0.14.0 or later.

## What's new in 1.0.0

- First release: a calm to-do list that understands dates as you type them.
