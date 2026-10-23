# WeekStride 本地 API

本地 API 让脚本和可信工具查询工作内容、完成任务或执行步骤。它默认关闭，由用户在「设置 → 本地 API」手动开启；只监听本机 `http://127.0.0.1:18743`，每个请求都需要 Bearer 访问令牌，包括健康检查。

应用必须保持运行。关闭主窗口后可继续在菜单栏运行，完全退出应用后 API 停止。关闭 API 或重置令牌会使现有连接失效，旧令牌无法继续使用。

## 首次连接

1. 在「设置 → 本地 API」中开启服务，等待状态显示已开启。
2. 复制访问令牌，只提供给可信工具。
3. 调用健康检查，再查询任务 ID，最后执行完成操作。

下列示例使用占位符；请在自己的工具中替换 `YOUR_TOKEN` 和 `TASK_UUID`。

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

## 接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health` | 返回服务状态，也需要认证 |
| GET | `/v1/projects` | 查询项目 |
| GET | `/v1/tasks` | 查询任务，包含正文与附件元数据 |
| GET | `/v1/tasks?status=open` | 仅未完成任务；也可传 `completed` |
| GET | `/v1/tasks?projectId=UUID` | 按项目过滤，可与 `status` 同时使用 |
| GET | `/v1/tasks/UUID` | 查询单个任务 |
| POST | `/v1/tasks/UUID/complete` | 完成主任务 |
| POST | `/v1/tasks/UUID/subtasks/UUID/complete` | 完成执行步骤 |

任务响应中，`plannedAt` 为独立的计划时间，`planGranularity` 为 `day` 或 `week`，与 `dueAt`、`reminderAt` 分开保存。未安排时省略前两个字段；未关联项目时省略 `projectID`。不带项目过滤的查询也会返回未关联项目的任务。

接口目前提供查询和完成，不提供任务创建、正文修改、重新安排计划、项目移动、附件内容下载或任意文件访问。

## 完成与循环

完成请求可以不带正文，或发送 `{}`，此时记录当前时间。也可以指定历史完成时间：

```json
{"completedAt":"2026-10-20T10:30:00+08:00"}
```

`completedAt` 必须为包含时区的完整 ISO 8601 日期时间字符串，支持小数秒。正文非空时需要 `Content-Type: application/json`。未知字段、空值、无效日期、缺少时区或晚于今天的完成日期返回 `400`，不会完成任务。

有效请求会先提交该任务正在编辑的内容；编辑校验或保存失败时返回 `400`，任务保持未完成。

完成结果包含 `task`、可选的 `nextTask` 和 `alreadyCompleted`：

- 循环任务会保留本次完成记录，并创建独立的下一次任务。
- 已完成任务重复请求会返回原完成记录及同一个下一次任务，不会重复创建。
- 完成某个步骤尚未触发主任务完成时，返回当前主任务，`nextTask` 为空。
- 完成后的原任务保留原计划时间，新生成的循环任务计划为未安排。

## 错误与连接检查

| 情况 | 处理 |
|---|---|
| 连接被拒绝 | 确认应用运行、API 开启，地址为 `http://127.0.0.1:18743` |
| `401` | 检查 Bearer 令牌；重置后需更新工具中的令牌 |
| `403` | 只接受本机请求；带 `Origin` 的浏览器请求会被拒绝 |
| `400` | 查看 `error`，检查日期、JSON、查询参数或应用内尚未保存的编辑 |
| `404` | 重新查询任务和步骤 ID，记录可能已被删除 |
| `500` | 操作未完成，请检查应用中的任务和存储状态后重试 |

服务拒绝非本机 Host，限制请求头为 16 KB、正文为 64 KB，并设置连接超时。

## 隐私

令牌保存在本机数据目录，不包含在任务备份中。不要提交令牌或真实任务响应到公开仓库，也不要把令牌交给不可信网页和工具。

WeekStride 不主动上传工作内容。你授权使用 API 的云端 AI 或其他工具，可能会将查询结果发送到自己的服务端；是否允许由你和所用工具决定。

[返回项目介绍](../README.md)
