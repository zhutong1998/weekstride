# WeekStride

**Plan your working week. Keep the details and the next action in view.**

WeekStride is a native macOS planner for project work, recurring responsibilities, and deadlines. Organize tasks by week while keeping details, steps, notes, and local attachments on the same screen. Your work stays on your Mac, with no account or cloud service required.

![WeekStride task board in a three-column layout with rendered demo data](docs/images/task-board.png)

*Three-column task view with rendered demo data. No real work data is shown.*

## Features

- **A week that fits your schedule.** Choose any day as the start of your working week, such as Thursday through Wednesday. Planning groups and completion history follow that setting.
- **Project tasks with inline details.** Read and edit task details, steps, notes, attachments, and dates directly on each card. Tasks can also exist without a project.
- **Separate planning, deadlines, and reminders.** Decide when to work on something, when it must be finished, and when to receive a notification independently.
- **A record of every completion.** Tasks and steps retain their completion dates. Completing a recurring task preserves the original and creates a separate next occurrence.
- **Flexible task views.** Use one, two, or three columns, or an adaptive layout. Show full details or expand tasks from a titles-only view. Each project remembers its view and week filter.
- **Local files and complete backups.** Drop files onto a task to copy them into local storage. Backups include projects, tasks, completion records, and referenced attachments.
- **An optional local API.** Let trusted scripts or AI tools query tasks and mark work complete. Enable it yourself, authenticate with a token, and disable it or rotate the token at any time.

## Plan the week without losing the deadline

| Field | Purpose | Example |
|---|---|---|
| Planned date or week | When you intend to work on the task | Renew a certificate this week |
| Due date | When the work must be finished | The certificate expires at the end of the month |
| Reminder | When macOS should notify you | Three days before expiry, in the morning |
| Completion date | When the work was actually finished | Record Friday's deployment |

Unfinished tasks from earlier planned dates appear in the current week with an overdue planning indicator. Selecting the current week or a future week reschedules the task. A whole-week plan becomes overdue after that working week ends; a specific-date plan becomes overdue after that day. Changing the start of the week recalculates groups and counts while preserving the dates stored on each task.

Completed tasks remain available in history and below the pending tasks for their actual completion week. Completing some steps leaves the parent task open. Completing every step completes the parent; completing the parent also completes its remaining steps.

Recurrence can follow the actual completion date or a fixed due-date schedule, using days, weeks, months, years, or a custom interval. For example, completing a task set to repeat every six months creates its next occurrence immediately. The previous record remains intact. The next task inherits details, notes, and attachments, resets its steps, and starts without a weekly plan.

## Everyday workflow

1. Create a project, or add a task without a project from All tasks.
2. Use the top plus button or `Command-N` to add a task. Pick its planned week and enter a title, details, notes, and steps.
3. Press Return to save the task. Use `Shift-Return` for a new line in details or notes, or to continue with another step. Clicking outside the task keeps your input in place.
4. Drop files from Finder onto the card, or use the attachment button. WeekStride stores its own copy and leaves the original file untouched.
5. Add a due date, reminder, or recurrence when needed. Date and time shortcuts stay in the picker until you confirm.
6. Complete the work and review its history. Supported operations can be undone from the feedback bar or with `Command-Z`.

Drag a task to a sidebar project to move it, or to All tasks to remove its project assignment. Drop it onto a week tab to reschedule it. Moving a task or changing its plan preserves its text, other dates, steps, and attachments.

## Appearance and settings

Settings cover general preferences, appearance and motion, reminders, the local API, data and backups, and app information.

- Follow the system appearance or choose light or dark mode; select from four text sizes.
- Use English or Simplified Chinese, with system, 12-hour, or 24-hour time formatting.
- Choose your week start day, enable launch at login, and keep the app running in the menu bar.
- Set full details or titles-only mode, with fixed or adaptive columns. Narrow windows and larger text automatically reduce the column count.
- Choose a list transition effect or turn transitions off. The app respects the macOS Reduce Motion setting.

Reminders use macOS local notifications and require notification permission. Pausing reminders preserves the dates on your tasks, and reached reminders remain visible in the pending-reminders view. Notification delivery also depends on Focus and system settings.

## Data, privacy, and backups

WeekStride has no account, telemetry, built-in AI service, cloud sync, or third-party runtime dependencies. Task content and attachments are stored locally. You can open the data folder from Settings.

The legacy data identifier is retained for compatibility:

```text
~/Library/Application Support/local.workledger/
  data.json       # Projects, tasks, and completion records
  attachments/    # Local attachment copies
  api-token       # Local API access token
  Backups/        # Safety copies created before restoring a backup
```

A `.workledgerbackup` folder contains task data and referenced attachments, excluding the API token and application preferences. Restoring a backup replaces the current work data after creating a safety copy. Export a backup before uninstalling the app or moving to another Mac.

Data and backups are not additionally encrypted; they rely on your macOS account permissions and disk protection. Removing an attachment reference currently leaves the stored file in place to protect history and recurring tasks. Exported backups include only files still referenced by tasks.

The local API is off by default and listens only on `127.0.0.1:18743`. The app must be running; closing its window can leave it running in the menu bar, while quitting stops the API. It supports queries and completion, with no attachment-content download or arbitrary file access. See the [local API guide](docs/API.md).

Only share the API token with trusted tools. WeekStride does not upload your work, but a cloud AI tool you authorize may send queried content to its own service.

## Install

Requires **macOS 14 or later**. Download the **Apple Silicon** archive from [GitHub Releases](https://github.com/zhutong1998/weekstride/releases/latest), extract it, and move `WeekStride.app` to Applications. The current download is ad-hoc signed and is not notarized by Apple. Intel source builds have not been tested on hardware.

Install the Apple Silicon build with Homebrew:

```bash
brew tap zhutong1998/weekstride https://github.com/zhutong1998/weekstride
brew install --cask zhutong1998/weekstride/weekstride
```

### Upgrading from WorkLedger

WeekStride retains the `local.workledger` bundle identifier and data directory, so existing tasks, attachments, preferences, and the API token remain available. The Homebrew cask name changes from `workledger` to `weekstride`. Export a backup, quit the old app, and replace it rather than running both app bundles at once. If removing a legacy cask, do not use `--zap`, which can remove application data and preferences.

## Build from source

Use **Xcode 26 or later with the macOS 26 SDK**. The resulting app still supports macOS 14 and later. A paid Apple Developer membership is not required to build and run it on your own Mac.

```bash
git clone https://github.com/zhutong1998/weekstride.git
cd weekstride
```

Open `WorkLedger.xcodeproj`, select **WorkLedger → My Mac**, and press `Command-R`. Internal project and module names remain `WorkLedger`; the application is named WeekStride.

Alternatively, run these commands from the repository root:

```bash
# Build the native application
./scripts/build.sh

# Run data-layer, local API, and other tests
swift test
```

The app is built at `build/Build/Products/Release/WeekStride.app`. The SwiftPM executable product, `WeekStrideDev`, is intended for development and testing. Use the bundled `.app` for everyday use so system notifications have the correct application identity.

The build script uses local ad-hoc signing. It does not perform Developer ID signing or Apple notarization.

## Contributing

Issues and improvements are welcome. For interface reports, include your macOS version, display settings, steps to reproduce, and expected behavior. Remove real task content, attachments, and access tokens before sharing screenshots or examples.

WeekStride uses Swift, SwiftUI, and macOS system frameworks, with no third-party libraries to install. It currently focuses on work on a single Mac; team collaboration, mobile apps, and cloud sync are not included.

## License

[MIT License](LICENSE).
