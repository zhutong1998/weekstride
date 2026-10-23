import Foundation

struct LocalAPICapabilities: Encodable {
    let name = "WeekStride"
    let apiVersion = 1
    let authentication = "Bearer token; loopback only; enable and copy the token in Settings."
    let dates = "ISO 8601 with time zone. Deletion snapshots and backup envelope.data use the native data.json numeric date format and must retain exact timestamps."
    let limits = ["headerBytes": 16 * 1024, "jsonBodyBytes": 64 * 1024,
                  "fileRequestBytes": 32 * 1024 * 1024, "decodedFileBytes": 16 * 1024 * 1024,
                  "fileResponseBytes": 16 * 1024 * 1024]
    let routes = [
        "GET /health", "GET /v1/capabilities",
        "GET,POST /v1/projects", "GET,PATCH,DELETE /v1/projects/{projectID}",
        "GET,PATCH /v1/projects/{projectID}/view",
        "GET,POST /v1/tasks", "GET,PATCH,DELETE /v1/tasks/{taskID}",
        "POST /v1/tasks/restore", "POST /v1/tasks/{taskID}/plan",
        "POST /v1/tasks/{taskID}/complete", "POST /v1/tasks/{taskID}/reopen",
        "PATCH /v1/tasks/{taskID}/completion-date",
        "POST /v1/tasks/{taskID}/subtasks", "PATCH,DELETE /v1/tasks/{taskID}/subtasks/{subtaskID}",
        "POST /v1/tasks/{taskID}/subtasks/{subtaskID}/complete",
        "POST /v1/tasks/{taskID}/subtasks/{subtaskID}/reopen",
        "PATCH /v1/tasks/{taskID}/subtasks/{subtaskID}/completion-date",
        "GET,POST /v1/tasks/{taskID}/attachments",
        "GET,DELETE /v1/tasks/{taskID}/attachments/{attachmentID}",
        "GET /v1/tasks/{taskID}/attachments/{attachmentID}/content",
        "GET,PATCH /v1/settings", "GET /v1/settings/status",
        "POST /v1/settings/api/disable", "POST /v1/settings/api/rotate-token",
        "GET,POST /v1/backups", "GET,DELETE /v1/backups/{backupID}",
        "POST /v1/backups/import", "POST /v1/backups/{backupID}/restore"
    ]
    let systemActions = "Notification permission and API bootstrap require the app UI. API token rotation requires copying the new token in Settings."
}
