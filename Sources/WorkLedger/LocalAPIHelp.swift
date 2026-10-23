import Foundation

enum LocalAPIHelp {
    static let response = LocalAPIResponse(
        status: 200,
        body: Data(page.utf8),
        contentType: "text/html; charset=utf-8",
        headers: [
            "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            "Referrer-Policy": "no-referrer"
        ]
    )

    private static let page: String = {
        let capabilities = LocalAPICapabilities()
        let routes = capabilities.routes.map { "<li><code>\(escape($0))</code></li>" }.joined(separator: "\n")
        return #"""
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="color-scheme" content="light dark">
          <title>WeekStride Local API</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; line-height: 1.6; }
            body { max-width: 960px; margin: 0 auto; padding: 32px 24px 64px; }
            h1 { margin-bottom: 0; letter-spacing: -.03em; } h2 { margin-top: 2em; } h3 { margin-top: 1.5em; }
            a { color: light-dark(#0066cc, #85baff); } nav { display: flex; flex-wrap: wrap; gap: 8px 20px; margin: 24px 0; }
            code { font-family: ui-monospace, monospace; font-size: .9em; overflow-wrap: anywhere; }
            pre { padding: 16px; background: light-dark(#f3f5f7, #202329); border-radius: 12px; overflow: auto; line-height: 1.5; }
            pre code { overflow-wrap: normal; } table { width: 100%; border-collapse: collapse; }
            th, td { text-align: left; vertical-align: top; padding: 10px 8px; border-bottom: 1px solid light-dark(#dce1e6, #454b54); }
            .notice { border-left: 3px solid #168f83; padding: 8px 16px; background: light-dark(#eef8f6, #172e2a); border-radius: 0 8px 8px 0; }
            .routes { padding-left: 20px; } .routes li { margin: 6px 0; } summary { cursor: pointer; font-weight: 600; }
            @media (max-width: 600px) { body { padding: 16px; } th, td { padding: 8px 4px; } }
          </style>
        </head>
        <body>
        <header>
          <h1>WeekStride Local API</h1>
          <p>Manage your weekly work from trusted scripts and AI tools, using the same local data as the app.</p>
          <p class="notice">The server is running. This page contains static instructions only: it does not display your token,
          tasks, settings, or files, and cannot change them. All data and control endpoints require your Bearer token.</p>
        </header>
        <nav aria-label="API guide sections">
          <a href="#connect">Connect</a><a href="#quick-start">Quick start</a><a href="#work">Tasks and projects</a>
          <a href="#files">Files and backups</a><a href="#settings">Settings</a><a href="#routes">All routes</a><a href="#rules">Rules and errors</a>
        </nav>

        <section id="connect">
          <h2>1. Connect</h2>
          <ol>
            <li>Open WeekStride → Settings → Local API. Enable the API if needed, then copy the access token there.</li>
            <li>Use <code>http://127.0.0.1:18743</code> as the base address. Keep WeekStride running; quitting stops the server.</li>
            <li>Send <code>Authorization: Bearer YOUR_TOKEN</code> with every API request, including <code>/health</code>
            and <code>/v1/capabilities</code>. The only token-free endpoint is this exact <code>GET /</code> help page.</li>
          </ol>
          <p>Copy this helper into Terminal and replace <code>YOUR_TOKEN</code> locally. Never paste a real token into a public issue,
          repository, or shared screenshot. The API never returns the token.</p>
          <pre><code>export WEEKSTRIDE_TOKEN='YOUR_TOKEN'
        export WEEKSTRIDE_URL='http://127.0.0.1:18743'
        api() {
          local api_path="$1"
          shift
          curl --silent --show-error --fail-with-body \
            --header "Authorization: Bearer $WEEKSTRIDE_TOKEN" \
            "$WEEKSTRIDE_URL$api_path" "$@"
        }

        api '/health'
        # Expected: {"status":"ok"}</code></pre>
          <p>A token grants full local work, attachment, settings, and backup access. Only give it to trusted tools.
          Remote AI tools may send queried content to their own service. This page runs without scripts or external assets.</p>
        </section>

        <section id="quick-start">
          <h2>2. Read, create, and complete a task</h2>
          <p>These examples use the helper above. Replace <code>TASK_ID</code>, <code>PROJECT_ID</code>, <code>STEP_ID</code>,
          <code>ATTACHMENT_ID</code>, and <code>BACKUP_ID</code> with UUIDs returned by the API.</p>
          <pre><code># Read this week's open tasks.
        api '/v1/tasks?status=open&amp;plan=thisWeek'

        # Create a task; save the returned id as TASK_ID.
        api '/v1/tasks' --request POST --header 'Content-Type: application/json' \
          --data '{"title":"Renew domain certificate","details":"Verify HTTPS after deployment."}'

        # Put it in this working week.
        api '/v1/tasks/TASK_ID/plan' --request POST --header 'Content-Type: application/json' \
          --data '{"plan":"thisWeek"}'

        # Complete it now. An empty body uses the current time.
        api '/v1/tasks/TASK_ID/complete' --request POST

        # Read the task and its recorded completion date.
        api '/v1/tasks/TASK_ID'</code></pre>
          <p>Completion returns <code>task</code>, optional <code>nextTask</code>, and <code>alreadyCompleted</code>.
          Retrying completion does not create another recurring occurrence. Reopen with <code>POST /v1/tasks/TASK_ID/reopen</code>;
          it returns <code>409</code> if undo would discard later work.</p>
        </section>

        <section id="work">
          <h2>3. Tasks, projects, dates, and steps</h2>
          <table>
            <thead><tr><th>Action</th><th>Body or query</th></tr></thead>
            <tbody>
              <tr><td>Create a project</td><td><code>POST /v1/projects</code> with <code>{"name":"Operations","colorHex":"168F83"}</code>.
              List with <code>GET /v1/projects?status=active</code>; <code>status</code> also accepts <code>all</code> or <code>archived</code>.</td></tr>
              <tr><td>Edit or archive a project</td><td><code>PATCH /v1/projects/PROJECT_ID</code>: <code>name</code>, six-digit <code>colorHex</code>,
              or boolean <code>isArchived</code>. Deleting a project keeps its tasks and removes their project assignment.</td></tr>
              <tr><td>Create or edit a task</td><td><code>POST /v1/tasks</code> requires <code>title</code>. <code>PATCH /v1/tasks/TASK_ID</code>
              accepts <code>title</code>, <code>details</code>, <code>notes</code>, <code>projectID</code>, <code>plannedAt</code>,
              <code>planGranularity</code>, <code>dueAt</code>, <code>reminderAt</code>, and <code>repeatRule</code>.
              Use <code>projectID:null</code> to unassign. Names and titles cannot be blank. Use dedicated endpoints for steps, files, and completion.</td></tr>
              <tr><td>Plan a task</td><td><code>POST /v1/tasks/TASK_ID/plan</code>: <code>{"plan":"nextWeek"}</code>.
              Choices: <code>thisWeek</code>, <code>nextWeek</code>, <code>weekAfterNext</code>, <code>unscheduled</code>;
              <code>week</code> and <code>day</code> require an ISO <code>date</code> field. Weeks follow Settings → Week starts on.
              Replanning this week clears an old overdue plan without changing the due date or reminder.</td></tr>
              <tr><td>Set dates and recurrence</td><td><code>PATCH /v1/tasks/TASK_ID</code> with ISO <code>dueAt</code>, <code>reminderAt</code>,
              or <code>plannedAt</code>; <code>null</code> clears a date. <code>planGranularity</code> is <code>day</code> or <code>week</code>
              and requires a plan date. <code>repeatRule</code> is <code>{"every":6,"unit":"month","basis":"completion"}</code>:
              <code>every</code> is 1–10000, unit is <code>day|week|month|year</code>, basis is <code>completion|schedule</code>.
              Schedule-based recurrence requires a due date; <code>repeatRule:null</code> disables it.</td></tr>
              <tr><td>Add or edit a step</td><td><code>POST /v1/tasks/TASK_ID/subtasks</code> or
              <code>PATCH /v1/tasks/TASK_ID/subtasks/STEP_ID</code> with <code>{"title":"Verify certificate"}</code>.
              Use <code>DELETE</code> to remove a step. The UI calls subtasks “steps”; API paths retain <code>subtasks</code>.</td></tr>
              <tr><td>Complete a step or correct a date</td><td><code>POST /v1/tasks/TASK_ID/subtasks/STEP_ID/complete</code>
              accepts no body or optional ISO <code>completedAt</code>. Completing the last unfinished step completes its parent.
              For completed records, <code>PATCH …/completion-date</code> requires <code>completedAt</code>.
              Use <code>POST …/reopen</code> to reopen; reopen the parent before reopening a step.</td></tr>
              <tr><td>Delete and restore a task</td><td><code>DELETE /v1/tasks/TASK_ID</code> returns an opaque snapshot.
              Restore with <code>POST /v1/tasks/restore</code> and <code>{"snapshot":UNCHANGED_DELETE_RESPONSE}</code>.
              Preserve native numeric timestamps exactly. Deleting a task retains physical attachment files and does not delete its recurring successor.</td></tr>
            </tbody>
          </table>
          <h3>Task filters</h3>
          <p><code>GET /v1/tasks</code> returns open and completed tasks unless filtered. Filters combine with AND:
          <code>status=all|open|completed</code>, <code>projectId=PROJECT_ID|none</code>, <code>search=TEXT</code>,
          <code>plan=thisWeek|nextWeek|week|unscheduled</code> (with ISO <code>week</code> only for <code>plan=week</code>),
          <code>overduePlan=true|false</code>, and <code>urgent=true|false</code>.
          Date intervals use <code>dueFrom/dueBefore</code>, <code>reminderFrom/reminderBefore</code>,
          or <code>completedFrom/completedBefore</code>: inclusive start, exclusive end.</p>
          <p>This week's open tasks include older unfinished plans. Completed tasks are grouped by actual completion week.
          Query field <code>projectId</code> has a lowercase <code>d</code>; JSON field <code>projectID</code> has uppercase <code>ID</code>.
          Use curl <code>--get --data-urlencode</code> for dates containing a <code>+</code> time-zone offset.</p>
        </section>

        <section id="files">
          <h2>4. Attachments and backups</h2>
          <p>Upload with <code>POST /v1/tasks/TASK_ID/attachments</code> and
          <code>{"name":"note.txt","contentBase64":"SGVsbG8="}</code>. Use a basename and canonical padded Base64 without whitespace,
          never a local path. List metadata with <code>GET</code>; download raw bytes from <code>…/ATTACHMENT_ID/content</code>.
          Deleting an attachment removes its reference but retains stored bytes for history and recurring tasks.</p>
          <pre><code># Create a managed snapshot; save the returned id as BACKUP_ID.
        api '/v1/backups' --request POST
        # Download the portable snapshot.
        api '/v1/backups/BACKUP_ID' --output weekstride-backup.json
        # Restore it only when you intend to replace all current work data.
        api '/v1/backups/BACKUP_ID/restore' --request POST --header 'Content-Type: application/json' \
          --data '{"confirm":"replace-current-data"}'</code></pre>
          <p class="notice"><strong>Restoration replaces current projects, tasks, and completion history.</strong>
          A safety copy is created first. API tokens and application preferences are preserved.</p>
          <p><code>GET /v1/backups</code> lists API-managed snapshots only. <code>DELETE /v1/backups/BACKUP_ID</code> deletes that snapshot.
          A portable export contains <code>format:"weekstride-backup-v1"</code>, native ledger <code>data</code>, and <code>attachments</code>
          entries containing <code>storedName</code> and <code>contentBase64</code>. Preserve the envelope unchanged.
          To import, add <code>"confirm":"replace-current-data"</code> to that exported JSON object and
          <code>POST /v1/backups/import</code>. <strong>Import restores immediately; it is not an upload-only operation.</strong>
          No file endpoint accepts arbitrary filesystem paths.</p>
        </section>

        <section id="settings">
          <h2>5. Settings and display preferences</h2>
          <p>Read <code>GET /v1/settings</code> before making a partial <code>PATCH /v1/settings</code>. Supported fields:</p>
          <ul>
            <li><code>weekStart</code>: integer 1 (Sunday) to 7 (Saturday); default 5 (Thursday).</li>
            <li><code>appAppearance</code>: <code>system|light|dark</code>; <code>appTextSize</code>: <code>small|standard|large|extraLarge</code>.</li>
            <li><code>appLanguage</code>: <code>system|zh-Hans|en</code>; <code>appTimeFormat</code>: string <code>system|12|24</code>.</li>
            <li><code>taskColumns</code>: <code>one|two|three|automatic</code>; <code>taskDetails</code>: <code>expanded|titles</code>.</li>
            <li><code>taskListEffect</code>: <code>slide|slideFade|scaleFade|none</code>; <code>remindersEnabled</code> and <code>launchAtLogin</code>: booleans.</li>
            <li><code>runInMenuBar</code>: boolean, default <code>true</code>. Show or hide the menu bar icon; this does not quit the app.</li>
          </ul>
          <p><code>GET /v1/settings/status</code> reports service availability and permissions. Notification permission and test notifications
          require the app UI; login registration may require macOS approval. Global display changes preserve project overrides.</p>
          <p><code>GET/PATCH /v1/projects/PROJECT_ID/view</code> supports <code>columns</code>, <code>details</code>,
          <code>planFilter:all|thisWeek|nextWeek|week|unscheduled</code>, and ISO <code>week</code> with <code>planFilter:"week"</code>.
          <code>resetDisplay:true</code> clears the display override and cannot be combined with <code>columns</code> or <code>details</code>.</p>
          <p><code>POST /v1/settings/api/disable</code> or <code>POST /v1/settings/api/rotate-token</code> accepts no body or <code>{}</code>
          and returns <code>202</code> before acting. Disabling stops the server. After rotation, copy the new token from Settings;
          the old token stops working. Enabling the API again always requires the app UI.</p>
        </section>

        <section id="routes">
          <h2>6. All data and control routes</h2>
          <p>API version \#(capabilities.apiVersion). Every route below requires a Bearer token.
          <code>GET /v1/capabilities</code> returns this same route list as JSON for automation.</p>
          <details><summary>Show all routes</summary><ul class="routes">
        \#(routes)
          </ul></details>
        </section>

        <section id="rules">
          <h2>7. Request rules, limits, and errors</h2>
          <ul>
            <li>Use HTTP/1.1 with matching loopback Host. Any <code>Origin</code> header is rejected: there is no browser cross-origin access.
            Opening this help page directly is supported. Chunked bodies, <code>Expect</code>, duplicate headers, and pipelining are rejected.</li>
            <li>GET requests have no body. JSON bodies must be UTF-8 objects with <code>Content-Type: application/json</code>.
            Unknown fields, duplicate keys, wrong types, and repeated query parameters are rejected.</li>
            <li>Omitted PATCH fields stay unchanged. Only documented nullable fields accept <code>null</code>;
            clear details and notes with <code>""</code>. Do not PATCH a full GET response.</li>
            <li>Use complete ISO 8601 dates with time zones, such as <code>2026-10-23T09:00:00+08:00</code>.
            Completion dates cannot be later than today in the Mac's local calendar.</li>
            <li><strong>Deletion snapshots and backup data use native numeric dates</strong> (seconds since 2001-01-01 UTC).
            Keep exact numeric values; do not convert or round them.</li>
            <li>Mutations save relevant active editors first. If validation or saving fails, correct the editor in WeekStride and retry.
            WeekStride must remain running and the API enabled; a refused connection can also mean the port is in use.</li>
            <li>Limits: 16 KiB headers; 64 KiB ordinary JSON; 32 MiB encoded file requests; 16 MiB decoded files/backups and file responses.
            Base64 adds overhead. Up to 8 connections, 30 seconds each. Use the app UI for larger files and backups.</li>
          </ul>
          <p>Most responses are JSON; attachment downloads return raw bytes. Errors are <code>{"error":"message"}</code>.
          <code>200</code> success, <code>201</code> created, <code>202</code> accepted;
          <code>400</code> invalid input or pending edits, <code>401</code> missing/invalid token, <code>403</code> Host/Origin blocked,
          <code>404</code> missing route/record, <code>405</code> unsupported method, <code>409</code> data conflict,
          <code>413</code> size limit, <code>500</code> storage/internal failure. Inspect the app before retrying a storage failure.</p>
        </section>
        </body>
        </html>
        """#
    }()

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
