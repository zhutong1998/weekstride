# WeekStride local API

Use the local API to manage projects, tasks, plans, steps, attachments, settings, and backups from trusted scripts or AI tools. Enable it in **Settings → Local API** and copy the access token there. It is disabled by default and listens only on `http://127.0.0.1:18743`.

The app must remain running. Closing its main window can leave it running in the menu bar; quitting stops the API. Initial activation, retrieving a new token, notification permission, and test notifications require the app UI. Login-item registration may require approval in macOS Settings.

## Connect and discover

Open `http://127.0.0.1:18743/` directly in a browser for the built-in English guide, including connection instructions, copyable curl examples, field conventions, and the current route list. It works offline and displays static instructions only: no token, work data, settings, or files are exposed. No external documentation is needed to get started.

Only the exact, bodyless `GET /` help page is accessible without a token. Every data and control endpoint requires `Authorization: Bearer YOUR_TOKEN`, including `/health`, `/v1`, and `/v1/capabilities`. Root URLs with query parameters and other methods are not part of the public-help exception. Start with:

```bash
curl --header 'Authorization: Bearer YOUR_TOKEN' \
  'http://127.0.0.1:18743/health'

curl --header 'Authorization: Bearer YOUR_TOKEN' \
  'http://127.0.0.1:18743/v1/capabilities'
```

`GET /health` returns `{"status":"ok"}`. `GET /v1/capabilities` returns the API version, routes, date conventions, limits, and system actions that require the UI. `GET /v1` is also a discovery endpoint. Query discovery again when updating the app.

The examples below use this optional shell helper. Replace the token locally; never commit a real token:

```bash
export WEEKSTRIDE_TOKEN='YOUR_TOKEN'
export WEEKSTRIDE_URL='http://127.0.0.1:18743'
api() {
  local api_path="$1"
  shift
  curl --silent --show-error --fail-with-body \
    --header "Authorization: Bearer $WEEKSTRIDE_TOKEN" \
    "$WEEKSTRIDE_URL$api_path" "$@"
}
```

Replace identifiers such as `PROJECT_ID`, `TASK_ID`, `STEP_ID`, `ATTACHMENT_ID`, and `BACKUP_ID` with UUIDs returned by the server. Examples using Python require Python 3; the app itself has no Python dependency.

## Request and response rules

- The root help page uses HTML. Ordinary API responses use JSON. Attachment `/content` returns raw `application/octet-stream` bytes. Errors use `{"error":"..."}`.
- JSON bodies must be UTF-8 objects with `Content-Type: application/json`. Unknown fields, duplicate keys, wrong types, and missing required fields are rejected. Booleans and integers are distinct types.
- Omitted PATCH fields are preserved. Explicit `null` clears only nullable fields documented below; it does not mean an empty string, false, or zero.
- Ordinary dates are complete ISO 8601 date-times with a time zone, such as `2026-10-20T10:30:00+08:00` or `2026-10-20T02:30:00Z`. Input supports fractional seconds; impossible dates and missing time zones are rejected.
- **Two opaque formats use native numeric dates instead:** task-deletion snapshots and the `data` inside a portable backup envelope. These use the native `data.json` representation, seconds since `2001-01-01T00:00:00Z`. Preserve their exact numeric values; do not convert them to ordinary API dates or round them.
- Stored dates must fall within UTC years 1 through 9999; unsupported native backup or deletion-snapshot dates are rejected.
- Completion dates cannot fall later than today in the Mac's local calendar. Dates later in the current day are accepted.
- GET requests have no body. Most mutations do not accept query parameters. Query parameter names and values are case-sensitive, cannot repeat, and must have values.
- Mutations that affect active editors first ask the app to save the relevant edits. If validation or saving fails, correct the editor in the app and retry. The API does not discard invalid input to force an operation through.
- Operations write through the same data store as the UI. There is no remote service, pagination, or arbitrary local-path parameter.

## Projects

| Method | Endpoint | Request / result |
|---|---|---|
| GET | `/v1/projects` | Array of projects; optional `status=all`, `active`, or `archived` (default `all`) |
| POST | `/v1/projects` | Required `name`; optional `colorHex`; returns project with `201` |
| GET | `/v1/projects/PROJECT_ID` | One project |
| PATCH | `/v1/projects/PROJECT_ID` | One or more of `name`, `colorHex`, `isArchived`; returns updated project |
| DELETE | `/v1/projects/PROJECT_ID` | Empty body or `{}`; returns `{project, unassignedTaskIDs}` |

Names must contain non-whitespace text and are trimmed when saved. `colorHex` defaults to `3478F6` and accepts six hexadecimal digits, optionally prefixed by `#`. `isArchived` is a boolean; PATCH it to `true` to archive or `false` to restore.

Deleting a project **keeps its tasks**, including completed records, and removes their project assignment. It does not delete task text or files. Assigning a task to an archived project is rejected with `409`; restore the project first.

```bash
api '/v1/projects' --request POST \
  --header 'Content-Type: application/json' \
  --data '{"name":"Website operations","colorHex":"168F83"}'

api '/v1/projects/PROJECT_ID' --request PATCH \
  --header 'Content-Type: application/json' \
  --data '{"isArchived":true}'
```

## Tasks: create, read, edit, and filter

| Method | Endpoint | Request / result |
|---|---|---|
| GET | `/v1/tasks` | Array of tasks, with optional filters below |
| POST | `/v1/tasks` | Required `title`, plus editable fields below; returns task with `201` |
| GET | `/v1/tasks/TASK_ID` | One task |
| PATCH | `/v1/tasks/TASK_ID` | At least one editable field; returns updated task |
| DELETE | `/v1/tasks/TASK_ID` | Empty body or `{}`; returns an opaque native-date deletion snapshot |
| POST | `/v1/tasks/restore` | `{"snapshot": <unchanged deletion response>}`; returns restored task with `201` |

### Editable task fields

| Field | Type / behavior |
|---|---|
| `title` | Nonempty string; trimmed when saved |
| `details`, `notes` | Strings; use `""` to clear |
| `projectID` | Existing active project UUID, or `null` to unassign |
| `plannedAt` | ISO date-time, or `null` to clear the plan and its granularity |
| `planGranularity` | `"day"`, `"week"`, or `null`; a non-null value requires `plannedAt` |
| `dueAt` | ISO date-time or `null` |
| `reminderAt` | ISO date-time or `null` |
| `repeatRule` | Recurrence object below, or `null` to disable recurrence |

A new task has empty details and notes, no project, no steps or attachments, and no dates or recurrence unless supplied. Setting `plannedAt` without an existing granularity defaults it to `day`. Clearing `dueAt` also clears the recurrence schedule anchor and changes a fixed-schedule rule to completion-based recurrence.

A recurrence object requires **exactly** these three fields:

```json
{"every":6,"unit":"month","basis":"completion"}
```

`every` is an integer from `1` through `10000`. `unit` is `day`, `week`, `month`, or `year`. `basis` is `completion` or `schedule`; `schedule` requires a due date. Changing the rule resets its internal schedule anchor.

IDs, timestamps, completion fields, steps, attachments, series links, completion snapshots, and schedule anchors are protected from ordinary POST/PATCH. In particular, do not send `id`, `createdAt`, `updatedAt`, `completedAt`, `completionSource`, `subtasks`, `attachments`, `seriesID`, `nextTaskID`, `completionSubtaskSnapshot`, or `scheduleAnchor`. Use the dedicated endpoints instead. Sending a full GET response back as a task PATCH is rejected.

```bash
api '/v1/tasks' --request POST \
  --header 'Content-Type: application/json' \
  --data '{"title":"Renew domain certificate","projectID":"PROJECT_ID","details":"Verify the renewed certificate chain.","repeatRule":{"every":6,"unit":"month","basis":"completion"}}'

api '/v1/tasks/TASK_ID' --request PATCH \
  --header 'Content-Type: application/json' \
  --data '{"notes":"Deployment checked","projectID":null,"reminderAt":null}'
```

### Query filters

Filters combine with AND. With no status filter, both open and completed tasks are returned. API queries include tasks in archived projects unless you filter them yourself. Results follow stored order; sort them in the client if needed.

| Parameter | Values / semantics |
|---|---|
| `status` | `all`, `open`, or `completed` |
| `projectId` | Project UUID, or `none` for unassigned tasks; note lowercase `d`, unlike the JSON field `projectID` |
| `search` | Case-insensitive substring across title, details, notes, step titles, and attachment names |
| `plan` | `thisWeek`, `nextWeek`, `week`, or `unscheduled` |
| `week` | ISO date-time required only with `plan=week`; selects its containing working week |
| `overduePlan` | `true` or `false`, using planning-overdue rules |
| `urgent` | `true` or `false`; true means an open task with a due date or reminder at or before now |
| `dueFrom`, `dueBefore` | Due-date interval: inclusive lower bound, exclusive upper bound |
| `reminderFrom`, `reminderBefore` | Reminder interval, with the same bounds |
| `completedFrom`, `completedBefore` | Actual-completion interval, with the same bounds |

Date bounds require ISO date-times. A task without the relevant date does not match a bounded interval. If both bounds are present, `From` must be earlier than `Before`.

Week filters use the configured `weekStart` and the Mac's current calendar/time zone. `thisWeek` includes open tasks planned before the end of the current working week, including overdue plans; completed tasks match their **actual completion week**. `nextWeek` and `week` use completion time for completed tasks, otherwise planned time. `unscheduled` matches only open tasks without a planned date.

```bash
api '/v1/tasks?status=open&plan=thisWeek'
api '/v1/tasks?projectId=none&overduePlan=true'

# --data-urlencode avoids treating a time-zone + sign as a space.
api '/v1/tasks' --get \
  --data-urlencode 'status=completed' \
  --data-urlencode 'completedFrom=2026-10-01T00:00:00+08:00' \
  --data-urlencode 'completedBefore=2026-11-01T00:00:00+08:00'
```

### Restore a deleted task

Save the **entire DELETE response** as an opaque snapshot. It contains `task` and `predecessorIDs`, with native numeric dates so recurrence and undo timestamps keep their exact precision. Wrap it without editing or converting any dates:

```bash
api '/v1/tasks/TASK_ID' --request DELETE --output deleted-task.json
python3 - <<'PY'
from pathlib import Path
snapshot = Path('deleted-task.json').read_bytes()
Path('restore-task.json').write_bytes(b'{"snapshot":' + snapshot + b'}')
PY
api '/v1/tasks/restore' --request POST \
  --header 'Content-Type: application/json' \
  --data-binary @restore-task.json
```

Restoration is rejected with `409` if the task ID already exists. References must still form a valid ledger, so a removed project can prevent restoration. Missing successor links are cleared; eligible completed predecessor links are restored without overwriting an existing link. Deleting a task does not delete its successor or physical attachment files. Use a full backup when you need to restore a complete project or ledger.

## Plan and reschedule

`POST /v1/tasks/TASK_ID/plan` accepts required `plan` and an optional `date`:

| `plan` | `date` | Effect |
|---|---|---|
| `thisWeek` | Omit | Replan into the current working week |
| `nextWeek` | Omit | Replan into the next working week |
| `weekAfterNext` | Omit | Replan two weeks ahead |
| `week` | Required ISO date-time | Normalize to the start of its configured working week |
| `day` | Required ISO date-time | Normalize to the start of that local calendar day |
| `unscheduled` | Omit | Clear only the plan and its granularity |

Relative choices use the current local day and calendar-week offsets, so selecting this week or a future week clears an old planning-overdue state. An explicitly chosen past week/day can still be overdue. Due date, reminder, project, text, steps, and completion history remain unchanged. Reopen a completed task before using this endpoint.

```bash
api '/v1/tasks/TASK_ID/plan' --request POST \
  --header 'Content-Type: application/json' \
  --data '{"plan":"nextWeek"}'
```

## Completion, reopening, and actual dates

| Method | Endpoint | Body / result |
|---|---|---|
| POST | `/v1/tasks/TASK_ID/complete` | No body, `{}`, or optional `completedAt`; returns `CompletionResult` |
| POST | `/v1/tasks/TASK_ID/reopen` | Empty body or `{}`; returns reopened task |
| PATCH | `/v1/tasks/TASK_ID/completion-date` | Required `completedAt`; returns updated task |

Example completion body:

```json
{"completedAt":"2026-10-20T10:30:00+08:00"}
```

Omitting `completedAt` on a **complete** endpoint records the current time. A completion-date PATCH requires it and requires the task or step to be completed already. Null is not accepted. Changing an actual completion date updates that record only; it does not regenerate the next recurring task or silently change its dates.

`CompletionResult` contains `task`, optional `nextTask`, and `alreadyCompleted`. Repeated completion is idempotent: it returns the existing record and same next task without generating another occurrence. Completing the parent completes unfinished steps. Completing its last unfinished step completes the parent using the latest actual step-completion time.

Reopening restores the previous step-completion snapshot and removes a generated next task only when that task is still untouched, unfinished, and has no completed steps or successor. If later work would be lost, or a legacy completed task lacks the required step snapshot, reopening returns `409`. Handle the later task explicitly rather than discarding it to bypass the conflict. Reopening an already open task is a no-op.

## Steps

The UI calls subtasks “steps”; the API path remains `subtasks`.

| Method | Endpoint | Body / result |
|---|---|---|
| GET | `/v1/tasks/TASK_ID/subtasks` | Array of steps |
| POST | `/v1/tasks/TASK_ID/subtasks` | Required nonempty `title`; returns step with `201` |
| GET | `/v1/tasks/TASK_ID/subtasks/STEP_ID` | One step |
| PATCH | `/v1/tasks/TASK_ID/subtasks/STEP_ID` | Required nonempty `title`; returns updated step |
| DELETE | `/v1/tasks/TASK_ID/subtasks/STEP_ID` | Empty body or `{}`; returns removed step |
| POST | `/v1/tasks/TASK_ID/subtasks/STEP_ID/complete` | Same optional completion body as parent; returns `CompletionResult` |
| POST | `/v1/tasks/TASK_ID/subtasks/STEP_ID/reopen` | Empty body or `{}`; returns updated parent task |
| PATCH | `/v1/tasks/TASK_ID/subtasks/STEP_ID/completion-date` | Required `completedAt`; returns updated parent task |

Adding a step requires an open parent. Reopening a step also requires an open parent; reopen the parent first if necessary. Titles are trimmed, cannot be blank, and cannot be cleared with null. Step IDs and completion fields cannot be changed by a title PATCH. Removing a step does not itself complete the parent.

```bash
api '/v1/tasks/TASK_ID/subtasks' --request POST \
  --header 'Content-Type: application/json' \
  --data '{"title":"Verify HTTPS after deployment"}'
```

## Attachments

| Method | Endpoint | Body / result |
|---|---|---|
| GET | `/v1/tasks/TASK_ID/attachments` | Array of attachment metadata |
| POST | `/v1/tasks/TASK_ID/attachments` | Required `name` and `contentBase64`; returns metadata with `201` |
| GET | `/v1/tasks/TASK_ID/attachments/ATTACHMENT_ID` | Metadata: `id`, `name`, `storedName`, `size` in bytes |
| GET | `/v1/tasks/TASK_ID/attachments/ATTACHMENT_ID/content` | Raw file bytes, `application/octet-stream` |
| DELETE | `/v1/tasks/TASK_ID/attachments/ATTACHMENT_ID` | No body; returns `{"deleted":true}` |

Uploads contain file bytes, not a filesystem path. `name` must be a basename other than `.` or `..`, at most 255 UTF-8 bytes, without slash, backslash, or control characters. `contentBase64` must be canonical padded Base64 without whitespace. Files and immediate directories must not be symbolic links; downloads validate the stored metadata and regular-file size. Deleting an attachment removes the task reference while retaining the stored bytes for history or other tasks.

```bash
python3 - <<'PY'
import base64, json
from pathlib import Path
source = Path('checklist.txt')
Path('attachment-upload.json').write_text(json.dumps({
    'name': source.name,
    'contentBase64': base64.b64encode(source.read_bytes()).decode('ascii')
}))
PY
api '/v1/tasks/TASK_ID/attachments' --request POST \
  --header 'Content-Type: application/json' \
  --data-binary @attachment-upload.json

api '/v1/tasks/TASK_ID/attachments/ATTACHMENT_ID/content' \
  --output downloaded-checklist.txt
```

A decoded attachment is limited to 16 MiB. Use the app UI for larger files. No endpoint accepts arbitrary source or destination paths on the Mac.

## Settings and project views

| Method | Endpoint | Purpose |
|---|---|---|
| GET | `/v1/settings` | Current settings plus service `status` |
| PATCH | `/v1/settings` | Change one or more settings below; returns current settings and status |
| GET | `/v1/settings/status` | Service availability, permissions, and supported system actions |
| GET | `/v1/projects/PROJECT_ID/view` | Effective display mode and remembered week filter for that project |
| PATCH | `/v1/projects/PROJECT_ID/view` | Change or reset project-view preferences |

### Global settings

Use these raw values, rather than translated UI labels:

| Field | Accepted values |
|---|---|
| `weekStart` | Integer `1` through `7`: Sunday through Saturday; default `5` (Thursday) |
| `appAppearance` | `system`, `light`, `dark` |
| `appTextSize` | `small`, `standard`, `large`, `extraLarge` |
| `appLanguage` | `system`, `zh-Hans`, `en` |
| `appTimeFormat` | `system`, `12`, `24` (all strings) |
| `taskColumns` | `one`, `two`, `three`, `automatic` |
| `taskDetails` | `expanded`, `titles` |
| `taskListEffect` | `slide`, `slideFade`, `scaleFade`, `none` |
| `remindersEnabled` | Boolean |
| `runInMenuBar` | Boolean; default `true`; shows or hides the menu bar icon without quitting the app |
| `launchAtLogin` | Boolean; requires a running `.app` bundle and application services |

```bash
api '/v1/settings' --request PATCH \
  --header 'Content-Type: application/json' \
  --data '{"weekStart":5,"appLanguage":"en","taskColumns":"automatic","appTimeFormat":"24"}'
```

Disabling reminders preserves task dates; re-enabling schedules future reminders and leaves already reached items visible in the app. The API cannot grant notification permission, send a test notification, or approve a macOS login item. A login change may report `requiresApproval`; complete that step in macOS Settings.

Status fields include `servicesAvailable`, `apiEnabled`, `launchAtLogin`, `launchAtLoginStatus`, `notificationAuthorization`, `isBackingUp`, `runsInMenuBar`, `notificationPermissionRequiresUI`, `testNotificationRequiresUI`, and `canChangeReminders`, `canChangeLaunchAtLogin`, `canDisableAPI`, `canRotateAPIToken`. Optional service-dependent values may be omitted when unavailable. `launchAtLogin` is reported inside status, not as a top-level GET setting.

`runsInMenuBar` reflects the current `runInMenuBar` setting. Hiding the icon keeps tasks, reminders and the API running; reopen WeekStride from the Dock and enable the icon again in Settings → General, or PATCH `runInMenuBar` to `true`. Task-data backups and restores leave this preference unchanged.

`launchAtLoginStatus` uses `enabled`, `requiresApproval`, `notRegistered`, `notFound`, or `unknown`. `notificationAuthorization` uses `notDetermined`, `denied`, `authorized`, `provisional`, or `unknown`.

### Per-project preferences

View responses contain `id`, `columns`, `details`, `planFilter`, and optional ISO `week`. PATCH accepts:

- `columns`: the `taskColumns` raw values above.
- `details`: `expanded` or `titles`.
- `planFilter`: `all`, `thisWeek`, `nextWeek`, `week`, or `unscheduled`.
- `week`: required with `planFilter:"week"`, normalized to the configured working-week start; not accepted with other filters.
- `resetDisplay`: boolean; `true` clears the project's display override and inherits global columns/details. It cannot be combined with `columns` or `details`, but may be combined with a week-filter change.

Changing global defaults leaves explicit project overrides intact. View changes do not rewrite task dates or completion records.

```bash
api '/v1/projects/PROJECT_ID/view' --request PATCH \
  --header 'Content-Type: application/json' \
  --data '{"columns":"two","details":"titles","planFilter":"thisWeek"}'
```

### Disable the API or rotate its token

`POST /v1/settings/api/disable` and `POST /v1/settings/api/rotate-token` accept no body or `{}` and return `202` with `status:"accepted"` and an explanatory `message`. The action runs **after the response is successfully sent**.

Disabling stops the server; enable it again manually in the app. Rotation invalidates the old token and existing connections and, if the API was running, starts it again with the new token. The new token is **never returned by the API**: copy it from Settings. `apiEnabled` and the token are not writable through ordinary settings PATCH.

## Managed backups and portable restore

| Method | Endpoint | Body / result |
|---|---|---|
| GET | `/v1/backups` | Managed records `{id, createdAt?}` |
| POST | `/v1/backups` | Empty body or `{}`; creates a local snapshot and returns its record with `201` |
| GET | `/v1/backups/BACKUP_ID` | Export a portable JSON envelope |
| DELETE | `/v1/backups/BACKUP_ID` | No body; deletes that managed backup, returns `{"deleted":true}` |
| POST | `/v1/backups/BACKUP_ID/restore` | Required `confirm:"replace-current-data"`; replaces current work data |
| POST | `/v1/backups/import` | Portable envelope plus required confirmation; replaces current work data |

Managed backups live under `APIBackups` in the app's data folder and have UUID identifiers. These endpoints list only API-managed snapshots, not arbitrary files, UI exports, or the separate pre-restore safety copies. Create one, retain its returned `id`, and download it:

```bash
api '/v1/backups' --request POST
api '/v1/backups/BACKUP_ID' --output weekstride-backup.json
```

The exported envelope has exactly this structure:

```json
{
  "format": "weekstride-backup-v1",
  "data": {"schemaVersion":1,"projects":[],"tasks":[]},
  "attachments": []
}
```

`data` is the **native LedgerData**, not an ordinary `/v1/tasks` response. Its dates are numeric seconds since 2001-01-01 UTC, preserving the exact stored floating-point timestamps needed for recurrence undo. Each entry in `attachments` has exactly `storedName` and `contentBase64`. Keep exported envelopes intact; do not rebuild them from GET tasks, convert dates to ISO strings, or round timestamps. Tokens and preferences are excluded.

Restore a managed backup:

```bash
api '/v1/backups/BACKUP_ID/restore' --request POST \
  --header 'Content-Type: application/json' \
  --data '{"confirm":"replace-current-data"}'
```

To import a downloaded envelope, add the confirmation without parsing or rewriting its native numeric values:

```bash
python3 - <<'PY'
from pathlib import Path
backup = Path('weekstride-backup.json').read_bytes().strip()
assert backup.startswith(b'{') and backup.endswith(b'}')
Path('backup-import.json').write_bytes(
    backup[:-1] + b',"confirm":"replace-current-data"}'
)
PY
api '/v1/backups/import' --request POST \
  --header 'Content-Type: application/json' \
  --data-binary @backup-import.json
```

Both restore forms return `{"restored":true}`. **Import restores immediately; it is not an upload-only operation.** They replace projects, tasks, and completion history after validating the ledger and all referenced files and creating a safety copy in `Backups`. Existing attachment contents with a conflicting stored name cause a conflict instead of being overwritten. API tokens, application preferences, and managed-backup records are not replaced by the imported ledger.

Import requires `format`, `data`, `attachments`, and `confirm`. Attachment entries must be unique, referenced by the ledger, complete for every referenced stored name, and match recorded byte sizes. Unknown attachment fields, unsafe names, duplicate files, invalid Base64, invalid graph links, and symbolic links are rejected. Deleting a managed backup deletes that snapshot only, not current work data.

## Limits and errors

| Limit | Maximum |
|---|---|
| HTTP headers | 16 KiB |
| Ordinary JSON request body, including task snapshot restore | 64 KiB |
| Encoded attachment upload or portable-backup import request | 32 MiB |
| Decoded attachment | 16 MiB |
| Decoded portable backup | 16 MiB total native ledger JSON plus unique referenced file bytes |
| Attachment download / portable-backup export response | 16 MiB |
| Simultaneous connections | 8 |
| Connection timeout | 30 seconds |

Base64 and JSON add overhead: a backup that fits the decoded budget may still exceed the export-response limit. Managed backup creation and restoration also enforce the decoded budget. Use the app's file picker and backup interface for larger files or ledgers. A task-deletion snapshot larger than the ordinary 64 KiB restore request limit should be recovered through a full UI backup instead.

| Status | Meaning |
|---|---|
| `200` | Successful query or mutation |
| `201` | Project, task, step, attachment, restored task, or managed backup created |
| `202` | API stop or token rotation accepted; action follows response delivery |
| `400` | Invalid fields, dates, JSON, query parameters, pending edits, or unavailable application action |
| `401` | Missing or invalid Bearer token |
| `403` | Nonlocal Host or a request containing an `Origin` header |
| `404` | Missing route or record |
| `405` | Unsupported HTTP method |
| `409` | Data conflict, such as an existing restored ID, an archived target project, or unsafe recurrence undo |
| `413` | Header, body, decoded content, or file-response limit exceeded |
| `500` | Storage or another internal operation failed; inspect the app before retrying |

The server accepts HTTP/1.1 with a matching loopback Host (`127.0.0.1:18743` or `localhost:18743`). Browser requests with `Origin` are rejected; there is no cross-origin browser access. Chunked transfer, `Expect`, pipelined requests, and duplicate HTTP header names are not supported. Connections close after one response.

## Privacy and automation boundaries

A token authorizes full local work management, file-content access, settings changes, and confirmed backup replacement. Give it only to tools you trust. The API does not expose arbitrary paths or a token-reading endpoint, and it cannot bootstrap itself or bypass macOS permissions.

WeekStride does not upload your work. A cloud AI service or other tool that you authorize may send queried tasks and attachment contents to its own servers. Keep real tokens, task responses, exported snapshots, and backups out of public repositories.

[Back to the project overview](../README.md)
