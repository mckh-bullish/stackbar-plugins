# Todo

A calm to-do list for the menu bar, in a warm orange. Type a task the way you
would say it and the when comes out of the words: “Call the dentist tomorrow
at 2pm” becomes *Call the dentist*, due tomorrow at 2:00 PM. Today's tasks
(and any left over from earlier) sit on top, then tomorrow, then what is
coming up, then someday. A small ring in the header fills as today's tasks get
done.

Tasks live in **Apple Reminders**, so they're on your iPhone, iPad and Watch
too, and Siri can add to them. Big tasks break into small steps.

- **Needs:** Reminders (`.reminders`). Stackbar asks macOS once. Say no, or
  pick “This Mac only” in Settings, and tasks stay on this Mac instead.
- **Lists:** your Reminders lists are Todo's categories. Pick one at the top
  of the panel to see just that list, type `#groceries` in a task to file it
  in Groceries, or move a task from its editor. New tasks go to the list on
  screen, or your default list. (Apple doesn't let apps use Reminders'
  sections, tags or subtasks, so those stay in the Reminders app.)
- **Steps:** open a task and choose *Break into steps*, then type a step and
  press Return for each one. Tap S, M or B to size a step. The task's row
  shows its next step (small ones first) with a circle to tick it, and how
  many are done; ticking the last one finishes the task. Type
  `Plan the offsite: book a venue; send invites` to add a task with its
  steps in one go. In Reminders, steps are a ☐ checklist at the end of the
  notes, so you see them on your phone too.
- **Brain dump:** paste or type several lines and each becomes a task.
- **Sync:** changes go to Reminders as you make them, and changes from your
  other devices come in as Reminders gets them. Only the fields you changed
  are written, so an edit here never undoes one made on your phone. It all
  works offline; macOS syncs Reminders when you're back online.
- **Surfaces:** menu bar, panel, widget, settings.
- **Typing dates:** today, tonight, tomorrow, the day after tomorrow, friday,
  this friday, next friday (the Friday of next week), this weekend, next week,
  next month, in 3 days, in 2 hours, in half an hour, Nov 5, 5 November, the
  12th, on 3rd, 2027-03-12, 14/11. Times: 2pm, 2:30pm, 14:30, at 9, by 5,
  noon, midnight, this morning, this afternoon, this evening, tomorrow night,
  friday night. Repeats: every day, every weekday, every
  monday, every week, every month, daily, weekly, monthly. A `!` on its own
  marks the task important. Words in "double quotes" are kept as they are.
- **In the panel:** tick the circle to finish a task; tick a done one to bring
  it back. Click a task to open it in place: rename it (a date in the new
  text reschedules it), move it to Today, Tomorrow, the weekend, next week
  or Someday, set a repeat, star it or delete it. Every add, tick, move and
  delete shows a banner with Undo. The eye button shows what you have done.
- **Repeats:** ticking off a repeating task records it as done and moves it
  to its next day.
- **Alerts:** in Reminders, a task with a time gets a Reminders alert, on
  every device, with Done and Snooze. On this Mac only, Todo sends one
  notification when it is due, with Done and Snooze 1 Hour buttons; one the
  Mac slept through by more than half a day is let go quietly.
- **One nudge:** optionally, one notification at a time you choose, only on
  days you haven't ticked anything off, naming a small step to start with.
- **No guilt:** nothing is ever “overdue” or red. Tasks from earlier days
  wait under *Still on your list*.
- **Menu bar:** a quiet count of what is due today, or the next task, the count
  of everything open, or just the icon. It never turns red.
- **Commands:** Add a Todo, Mark a Todo Done, Snooze a Todo (to a time you
  type, or an hour or a day later), Today's Todos (a list to tick off from
  the palette) and Search Todos (every open task, to tick off, snooze or move
  to today). Run them from the palette, give them a hotkey, or call them
  from a Shortcut or a
  `stackbar://commands/io.navbytes.stackbar.plugins.todo/add?task=…` link.
- **Settings:** where tasks live, what the menu bar shows, alerts and their
  sound, the nudge, a morning
  summary of the day at 7, 8, 9 or 10 AM, and how long done tasks are kept.
- **Agent tools:** `tasks` (off until you turn it on in Settings › Agents)
  lists open tasks with their dates; `add` adds one from plain words.
- **Requires:** Stackbar 0.35.0 or later.

## What's new in 2.3.0

- Clear done tasks now says outright that it needs no second press (Undo brings them back).
- Stackbar 0.35.0 now asks for the second press itself, the same way in the panel, the palette and every window, and VoiceOver reads the question.

## What's new in 2.2.0

- "This evening at 7", "tonight at 9", "tomorrow evening at 8" and "Friday night at 9" now mean the evening, and the words no longer stay in the task's title.
- Dates written with numbers work: "dentist 14/11" or "11/14" (and "on 3/4", in your Mac's date order).
- "by 5", "on the 3rd" or "on 3rd", and "by midnight" are understood.
- "at 8" typed in the afternoon means 8 tonight, not tomorrow morning.
- A due-task notification has Done and Snooze 1 Hour buttons.
- New Search Todos command: find any open task in the palette and tick it off, snooze it or move it to today.
- Agents can only read your tasks once you turn the tasks tool on in Settings › Agents, since they're private.
- The morning summary and the nudge no longer arrive hours late when your Mac was off at the time.

## What's new in 2.1.1

- A task Reminders refuses to save no longer makes every sync add the tasks before it to Reminders again, and no longer stops changes from your other devices arriving.
- A reminder that couldn't be deleted in Reminders stays deleted here instead of coming back 30 seconds later; the delete is retried.
- It no longer reads all of Reminders every 30 seconds: changes from your other devices still arrive at once, and the 30-second check now only syncs every five minutes.
- An edit that Reminders refuses to save is no longer replaced by Reminders' older copy on the next sync.
- After a failed sync it tries again on the next 30-second check instead of waiting five minutes; changing where tasks live also counts as a sync.
- A delete Reminders keeps refusing is given up after five tries, with a notice, instead of failing forever.

## What's new in 2.1.0

- When nothing in the palette matches what you typed, Add Task offers to add it.

## What's new in 2.0.0

- Tasks now live in Apple Reminders, so they're on your iPhone, iPad and Watch too. Your existing tasks move over the first time. Prefer them on this Mac only? Choose that in Settings.
- Reminders lists are your categories: filter the panel by list, or type #listname in a task.
- Break a task into small, medium and big steps; its row shows the next small step to tick.
- Paste several lines to add several tasks at once.
- An optional nudge, only on days you haven't ticked anything off yet.
- Calmer: nothing is overdue any more; earlier tasks wait under "Still on your list".

## What's new in 1.1.0

- Store screenshots now show it in use, with sample data, instead of its first-run screen.

## What's new in 1.0.1

- Its own icon and colour in the Store and in Settings.
