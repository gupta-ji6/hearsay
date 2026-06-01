# Hearsay Local API Integration Guide

This guide is for apps that want to trigger Hearsay dictation and receive the
final transcript programmatically instead of having Hearsay paste into the
focused app.

The API is local-only:

- Hearsay binds to `127.0.0.1`.
- Hearsay chooses a random available port on launch.
- Hearsay writes the current API location to
  `~/Library/Application Support/Hearsay/local-api.json`.
- There is no bearer token in the current implementation.
- Only one dictation can be active at a time.

## Recommended Integration Shape

Use the HTTP API directly when you are building an editor extension, native app,
or long-running tool. Use the `hearsay` CLI when you want a simple subprocess
interface or a quick manual test.

The normal flow is:

1. Read `local-api.json`.
2. Generate a UUID request ID in your app.
3. Start dictation with `POST /v1/dictations`.
4. Keep that request open.
5. When the user ends dictation in your app, call
   `POST /v1/dictations/{requestId}/stop`.
6. Read the final transcript from the original `POST /v1/dictations` response.

The start request intentionally returns the transcript in the same HTTP response.
The separate stop request only tells Hearsay to stop recording and begin
transcription.

## Discovery

Read:

```text
~/Library/Application Support/Hearsay/local-api.json
```

Example:

```json
{
  "host": "127.0.0.1",
  "port": 59194,
  "version": 1
}
```

If the file is missing or the port does not respond, ask the user to open
Hearsay and retry.

## Health Check

```http
GET /v1/health
```

Example:

```bash
API_JSON="$HOME/Library/Application Support/Hearsay/local-api.json"
HOST=$(jq -r .host "$API_JSON")
PORT=$(jq -r .port "$API_JSON")

curl -sS "http://$HOST:$PORT/v1/health" | jq
```

Response:

```json
{
  "apiVersion": 1,
  "app": "Hearsay",
  "ok": true,
  "state": "idle",
  "version": "1.0.21"
}
```

States:

- `idle`
- `recording`
- `transcribing`
- `unavailable`

## Start Dictation

```http
POST /v1/dictations
Content-Type: application/json
```

Request:

```json
{
  "caller": "my-editor-extension",
  "mode": "returnToCaller",
  "requestId": "F05FE720-122D-45EC-A818-28D2BF081168",
  "metadata": {
    "source": "shortcut",
    "workspace": "/path/to/workspace"
  }
}
```

The caller must provide `requestId`. Hearsay uses that ID for stop, cancel,
events, and the final response.

This request stays open until dictation completes, fails, or is cancelled.

Completed response:

```json
{
  "requestId": "F05FE720-122D-45EC-A818-28D2BF081168",
  "status": "completed",
  "text": "Summarize this function and suggest a cleaner name.",
  "error": null,
  "durationSeconds": 3.42
}
```

Failed response:

```json
{
  "requestId": "F05FE720-122D-45EC-A818-28D2BF081168",
  "status": "failed",
  "text": null,
  "error": "No audio captured",
  "durationSeconds": null
}
```

## Stop Dictation

```http
POST /v1/dictations/{requestId}/stop
```

This stops recording and starts transcription. The transcript is not returned
from this endpoint; it is returned from the original start request.

Example response:

```json
{
  "requestId": "F05FE720-122D-45EC-A818-28D2BF081168",
  "status": "transcribing"
}
```

If Hearsay has already completed the request, stop is treated as a no-op and
returns the completed status.

## Cancel Dictation

```http
POST /v1/dictations/{requestId}/cancel
```

This cancels the active request. The original start request completes with:

```json
{
  "requestId": "F05FE720-122D-45EC-A818-28D2BF081168",
  "status": "cancelled",
  "text": null,
  "error": null,
  "durationSeconds": null
}
```

## Optional Progress Events

Callers that want progress updates can open:

```http
GET /v1/dictations/{requestId}/events
```

This is a Server-Sent Events stream. It may emit `state`, `result`, or `error`
events. The simplest integration can skip this and rely on local UI state.

## End-to-End curl Test

Terminal 1:

```bash
API_JSON="$HOME/Library/Application Support/Hearsay/local-api.json"
HOST=$(jq -r .host "$API_JSON")
PORT=$(jq -r .port "$API_JSON")
REQ_ID=$(uuidgen)

echo "$REQ_ID"

curl -sS \
  -H "Content-Type: application/json" \
  -d "{\"caller\":\"manual-curl\",\"mode\":\"returnToCaller\",\"requestId\":\"$REQ_ID\"}" \
  "http://$HOST:$PORT/v1/dictations" | jq
```

Terminal 2, after speaking:

```bash
API_JSON="$HOME/Library/Application Support/Hearsay/local-api.json"
HOST=$(jq -r .host "$API_JSON")
PORT=$(jq -r .port "$API_JSON")
REQ_ID="paste-the-request-id-from-terminal-1"

curl -sS -X POST \
  "http://$HOST:$PORT/v1/dictations/$REQ_ID/stop" | jq
```

## CLI Integration

The `hearsay` CLI is useful when an app wants to shell out instead of
implementing HTTP itself.

Manual test:

```bash
hearsay dictate --caller manual-cli --json --stop-on-enter
```

Application-style usage:

```bash
REQ_ID=$(uuidgen)
hearsay dictate --caller my-app --request-id "$REQ_ID" --json
```

The command above blocks until the transcript is ready. Your app can stop it
from another process:

```bash
hearsay stop "$REQ_ID"
```

For editor extensions, the direct HTTP API is usually cleaner than managing a
long-running subprocess, but both surfaces use the same Hearsay local API.

## Error Handling

Common HTTP errors:

- `400 invalid_request`: bad JSON, missing caller, invalid request ID, or
  unsupported mode.
- `404 not_found`: request ID is not active or known.
- `409 busy`: another dictation is recording or transcribing.
- `503 microphone_permission_missing`: Hearsay does not have microphone access.
- `503 transcriber_unavailable`: no transcription model is available.
- `500 recording_failed` or `500 transcription_failed`: Hearsay could not finish
  the request.

Apps should treat `409 busy` as a real mutex: only one app can own dictation at
a time. Show a short busy state and let the user retry.

## VS Code Extension Sketch

Pseudo-flow:

```text
onShortcut:
  selectedText = editor.selection
  api = read local-api.json
  requestId = uuid()
  startPromise = post /v1/dictations with requestId
  show "Listening..."

onUserStop:
  post /v1/dictations/{requestId}/stop
  show "Transcribing..."
  result = await startPromise
  insert result.text into chat input with selectedText as context
```

The important part is that the caller owns final insertion. In caller mode,
Hearsay records, transcribes, cleans up, saves history, and returns text. It
does not paste.
