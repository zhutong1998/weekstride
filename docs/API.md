# WeekStride local API

The local API lets trusted scripts and tools query work and complete tasks or steps. It is disabled by default. Enable it in **Settings → Local API**. It listens only on `http://127.0.0.1:18743`, and every request requires a Bearer access token, including health checks.

The app must remain running. Closing the main window can leave it running in the menu bar; quitting stops the API. Disabling the API or rotating the token invalidates existing connections. The previous token cannot be used after rotation.

## First connection

1. Enable the API in Settings and wait until its status indicates that it is running.
2. Copy the access token and provide it only to a trusted tool.
3. Check the service health, query task IDs, and then request completion.

The examples use placeholders. Replace `YOUR_TOKEN` and `TASK_UUID` in your own tool.

```bash
curl --header 'Authorization: Bearer YOUR_TOKEN' \
  'http://127.0.0.1:18743/health'

curl --header 'Authorization: Bearer YOUR_TOKEN' \
  'http://127.0.0.1:18743/v1/tasks?status=open'

curl --request POST \
  --header 'Authorization: Bearer YOUR_TOKEN' \
  --header 'Content-Type: application/json' \
  --data '{}' \
  'http://127.0.0.1:18743/v1/tasks/TASK_UUID/complete'
```

## Endpoints

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Service status; authentication is required |
| GET | `/v1/projects` | List projects |
| GET | `/v1/tasks` | List tasks, including text and attachment metadata |
| GET | `/v1/tasks?status=open` | Filter unfinished tasks; `completed` is also accepted |
| GET | `/v1/tasks?projectId=UUID` | Filter by project; can be combined with `status` |
| GET | `/v1/tasks/UUID` | Get one task |
| POST | `/v1/tasks/UUID/complete` | Complete a parent task |
| POST | `/v1/tasks/UUID/subtasks/UUID/complete` | Complete a step |

Task responses store the independent plan in `plannedAt`, with `planGranularity` set to `day` or `week`. These fields are separate from `dueAt` and `reminderAt`. Unscheduled tasks omit the plan fields. Tasks without a project omit `projectID`; an unfiltered query includes these tasks too.

The API currently supports queries and completion. It does not support creating tasks, editing text, rescheduling, moving projects, downloading attachment contents, or accessing arbitrary files.

## Completion and recurrence

A completion request may have no body, or use `{}` to record the current time. You can also provide a historical completion time:

```json
{"completedAt":"2026-10-20T10:30:00+08:00"}
```

`completedAt` must be a complete ISO 8601 date-time string with a time zone. Fractional seconds are supported. A nonempty body requires `Content-Type: application/json`. Unknown fields, null values, invalid dates, a missing time zone, or a completion date later than today return `400` without completing the task.

A valid request first commits any active edits for that task. If validation or saving fails, the API returns `400` and leaves the task unfinished.

The response contains `task`, an optional `nextTask`, and `alreadyCompleted`:

- Completing a recurring task retains the completed record and creates a separate next occurrence.
- Repeating a request for an already completed task returns the original completion record and the same next task, without creating duplicates.
- When completing a step does not complete the parent, the response contains the updated parent and no next task.
- The completed task keeps its original plan. A newly generated recurring task starts without a plan.

## Errors and connection checks

| Result | What to check |
|---|---|
| Connection refused | Ensure the app is running, the API is enabled, and the address is `http://127.0.0.1:18743` |
| `401` | Check the Bearer token; update your tool after rotating it |
| `403` | Only local requests are accepted; browser requests containing `Origin` are rejected |
| `400` | Read `error` and check dates, JSON, query parameters, or unsaved edits in the app |
| `404` | Query task and step IDs again; the record may have been deleted |
| `500` | The operation did not complete; check tasks and storage status in the app before retrying |

The service rejects nonlocal Host headers, limits request headers to 16 KB and bodies to 64 KB, and applies connection timeouts.

## Privacy

The token is stored in the local data directory and is excluded from task backups. Do not commit it or real task responses to a public repository, or share it with untrusted websites and tools.

WeekStride does not upload your work. A cloud AI service or another tool that you authorize may send queried content to its own servers. Whether to allow that depends on you and the tool you choose.

[Back to the project overview](../README.md)
