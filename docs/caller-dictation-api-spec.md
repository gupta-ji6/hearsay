# Caller-Mode Dictation API Spec

## Summary

Add a local request/response API to Hearsay so trusted local tools can invoke Hearsay dictation and receive the transcript programmatically instead of having Hearsay paste into the currently focused app.

Primary motivating client: the `pi-vscode` extension. The VS Code extension wants to support a workflow like:

1. User selects code/text in VS Code.
2. User presses a VS Code shortcut, e.g. `Cmd+K`.
3. VS Code asks Hearsay to start recording.
4. User speaks an instruction.
5. Hearsay transcribes using the normal Hearsay pipeline.
6. Hearsay returns the transcript to VS Code without pasting anywhere.
7. VS Code attaches the selected code as context, inserts the transcript into the Pi chat sidebar, and optionally submits it.

This should preserve all existing Hearsay behavior for global hotkeys: normal Right Option / toggle dictation should still paste at the cursor according to current preferences.

## Goals

- Reuse Hearsay's existing recording, transcription, cleanup, sounds, status indicator, model selection, and history pipeline.
- Add a separate output destination: `returnToCaller`, distinct from the current paste/clipboard behavior.
- Allow a trusted local app to start, stop, cancel, and receive dictation results.
- Avoid focus hacks such as simulating Hearsay hotkeys or scraping pasted text back out of VS Code.
- Support a smooth caller workflow where VS Code can display `Listening...`, `Transcribing...`, and final/error states.
- Keep API local-only and visible to the user so arbitrary remote clients cannot trigger the microphone.

## Non-goals

- Do not replace the existing global Hearsay hotkey UX.
- Do not make Hearsay depend on VS Code or Pi.
- Do not require cloud services.
- Do not paste into VS Code for this integration; the caller should receive text and decide what to do.
- Do not support remote network access. Bind only to loopback.

## Current Hearsay behavior relevant to this change

Important existing files:

- `Hearsay/AppDelegate.swift`
  - Owns app lifecycle, hotkey monitor setup, recording start/stop, transcription, cleanup, paste/copy behavior, indicator state, and history save.
  - The current final-output logic is near the end of transcription and calls `TextInserter.insert(finalText)`, `TextInserter.copyToClipboard(finalText)`, or `TextInserter.insertWithoutClipboard(finalText)` depending on user preferences.
- `Hearsay/Core/HotkeyMonitor.swift`
  - Detects global hold/toggle/screenshot hotkeys and calls AppDelegate closures.
- `Hearsay/Core/TextInserter.swift` if present, or equivalent text insertion helper.
  - Responsible for paste/clipboard insertion.
- `Hearsay/History/HistoryStore.swift`
  - Saves final transcripts.
- `Hearsay/UI/...`
  - Recording/transcribing/done indicator and menu state.

The new API should reuse as much of the path in `AppDelegate` as possible and only branch at the final output delivery step.

## Proposed architecture

Introduce an internal dictation session abstraction and a local API server.

```text
Caller app, e.g. VS Code
  POST /v1/dictations
        ↓
HearsayLocalAPIServer
        ↓
DictationCoordinator / AppDelegate recording pipeline
        ↓
Existing recorder + transcriber + cleanup pipeline
        ↓
TranscriptDelivery.returnToCaller(requestId)
        ↓
HTTP/SSE/WebSocket response to caller
```

### New concepts

#### DictationRequest

Represents one caller-originated dictation request.

Suggested fields:

```swift
struct DictationRequest {
    let id: UUID
    let caller: String              // e.g. "pi-vscode"
    let mode: DictationMode         // initially only .returnToCaller
    let createdAt: Date
    let metadata: [String: String]
}
```

#### DictationMode

```swift
enum DictationMode {
    case pasteAtCursor              // existing global-hotkey behavior
    case returnToCaller             // new API behavior
}
```

#### DictationResult

```swift
struct DictationResult: Codable {
    let requestId: String
    let status: String              // "completed", "cancelled", "failed"
    let text: String?
    let error: String?
    let durationSeconds: Double?
}
```

#### TranscriptDelivery

Factor the current paste/copy finalization branch into a small delivery layer:

```swift
protocol TranscriptDelivering {
    func deliver(_ text: String, context: TranscriptDeliveryContext)
}
```

Where context includes the source/mode/requestId. Implementations:

- `PasteTranscriptDelivery`: current behavior using copy/paste settings.
- `CallerTranscriptDelivery`: completes the API request with the final transcript.

This keeps the transcription pipeline independent from output mechanics.

## Local API design

Preferred API: local HTTP server bound to `127.0.0.1` only.

Suggested server location:

```text
Hearsay/Core/HearsayLocalAPIServer.swift
```

The server can use `Network.framework` (`NWListener`) or a tiny embedded HTTP server if the project already uses one. Keep it dependency-light.

### Port discovery

Hearsay should write connection info to an app support file when the server is ready:

```text
~/Library/Application Support/Hearsay/local-api.json
```

Suggested contents:

```json
{
  "host": "127.0.0.1",
  "port": 49321,
  "version": 1
}
```

Use an OS-assigned random available port by default. This avoids port conflicts. The VS Code extension can read this file to discover the current port.

### Authentication

Current implementation does not require an auth token. The API binds only to
`127.0.0.1`, uses a random OS-assigned port, and relies on visible recording UI
plus microphone permissions.

Tradeoff: this keeps generic app integrations and CLI testing simple. A future
hardening pass may add a user setting, per-caller approval, or a Unix socket
transport if local trigger abuse becomes a practical concern.

### Endpoint: health

```http
GET /v1/health
```

Response:

```json
{
  "ok": true,
  "app": "Hearsay",
  "version": "1.0.21",
  "apiVersion": 1,
  "state": "idle"
}
```

Possible `state` values:

- `idle`
- `recording`
- `transcribing`
- `unavailable`

### Endpoint: start caller-mode dictation

```http
POST /v1/dictations
Content-Type: application/json
```

Request:

```json
{
  "caller": "pi-vscode",
  "mode": "returnToCaller",
  "requestId": "client-generated-uuid",
  "autoStop": false,
  "metadata": {
    "workspace": "/Users/swair/.config/nvim",
    "source": "cmd-k-selection"
  }
}
```

The request stays open until the caller stops or cancels dictation and Hearsay
finishes processing. Final success response:

```json
{
  "requestId": "b5a8...",
  "status": "completed",
  "text": "the transcribed text",
  "error": null,
  "durationSeconds": 4.2
}
```

Behavior:

- The caller must provide a UUID `requestId` so it can call `/stop` or `/cancel`
  while the start request is still open.
- If Hearsay is idle, start recording using the same recorder path used by hotkeys.
- Set active mode to `returnToCaller` for this request.
- Show existing recording indicator so the user knows the mic is live.
- Do **not** paste on completion.
- Save transcript to history unless explicitly disabled by request/options.

If Hearsay is already busy:

```http
409 Conflict
```

```json
{
  "error": "busy",
  "state": "recording"
}
```

Initial implementation should allow only one active dictation at a time. That matches the existing app model and avoids ambiguous microphone state.

### Endpoint: stop active dictation

```http
POST /v1/dictations/{requestId}/stop
```

Response:

```json
{
  "requestId": "b5a8...",
  "status": "transcribing"
}
```

Behavior:

- Stops the active recording for that request.
- Runs existing transcription + cleanup pipeline.
- Final result is delivered as the response body of the original `POST /v1/dictations` request.

If request does not match active request, return `404` or `409`.

### Endpoint: cancel active dictation

```http
POST /v1/dictations/{requestId}/cancel
```

Response:

```json
{
  "requestId": "b5a8...",
  "status": "cancelled"
}
```

Behavior:

- Stops recording/transcription if possible.
- Does not paste.
- Does not save an empty transcript to history.
- Clears active caller request.
- Updates indicator appropriately.

### Endpoint: receive status/result events

Optional Server-Sent Events endpoint for callers that want progress updates:

```http
GET /v1/dictations/{requestId}/events
Accept: text/event-stream
```

Events:

```text
event: state
data: {"requestId":"...","state":"recording"}


event: state
data: {"requestId":"...","state":"transcribing"}


event: result
data: {"requestId":"...","status":"completed","text":"...","durationSeconds":4.2}
```

Error event:

```text
event: error
data: {"requestId":"...","status":"failed","error":"No transcriber available"}
```

Cancellation event:

```text
event: result
data: {"requestId":"...","status":"cancelled"}
```

Why keep SSE:

- Easy for VS Code/Node clients to consume.
- Simpler than WebSocket for one-way status/result streaming.
- Lets callers display `recording` and `transcribing` while the start request waits for the final result.

## AppDelegate/pipeline changes

### Refactor final transcript handling

Current transcription completion in `AppDelegate.swift` computes something like:

```swift
let finalText = TranscriptProcessor.process(postProcessedText)
```

Then immediately applies copy/paste preferences.

Change this section so final output routes through a delivery mode:

```swift
switch activeDictationMode {
case .pasteAtCursor:
    // existing copy/paste behavior unchanged
case .returnToCaller(let requestId):
    // complete API request with finalText
}
```

Important: keep these existing behaviors for both modes unless explicitly decided otherwise:

- Run cleanup/post-processing if enabled.
- Run `TranscriptProcessor.process`.
- Play success sound if appropriate.
- Show recording/transcribing/done states.
- Save to history. Recommended default: yes, save caller-mode dictations too, possibly with metadata `source=api`.

### Add callable recording controls

Expose methods that the local API server can call from the main app coordinator:

```swift
func startCallerDictation(request: DictationRequest) throws
func stopCallerDictation(requestId: UUID) throws
func cancelCallerDictation(requestId: UUID) throws
```

These should reuse the same internal start/stop paths as the hotkey closures rather than duplicating audio logic.

### Conflict handling

Rules:

- If hotkey recording is active and API start arrives: reject API start with `busy`.
- If API recording is active and hotkey recording starts: either ignore hotkey or reject/stop with clear logs. Recommended: ignore hotkey start until API session completes.
- If settings window temporarily stops hotkey monitor, API dictation should still work if microphone/transcriber are available.
- If model/transcriber is unavailable, API start should fail with a clear error.

## VS Code client flow this enables

The `pi-vscode` extension would eventually do:

1. On `Cmd+K`, capture selected editor text.
2. Read `~/Library/Application Support/Hearsay/local-api.json`.
3. Generate a UUID and `POST /v1/dictations` with `caller=pi-vscode` and that `requestId`.
4. Show status in Pi sidebar: `Listening...`.
5. On second shortcut press or UI stop, call `/stop`.
6. Wait for the original `POST /v1/dictations` request to return the final result.
7. Optionally subscribe to `/events` for progress states.
8. When result arrives:
   - attach selected code as context,
   - set Pi chat input to transcript,
   - optionally submit.

This flow avoids stealing focus from the editor until VS Code deliberately updates the Pi sidebar.

## Permissions and privacy

- Hearsay already requests microphone permission; API-triggered recording should use the same permission path.
- Hearsay should visibly indicate active recording for API sessions exactly like hotkey sessions.
- Consider adding a setting: `Enable local API for integrations`.
  - Default can be on for developer builds; a future productized version may add per-caller approval.
- Consider showing connected caller name in logs/status, e.g. `Recording for pi-vscode`.
- Bind to `127.0.0.1`, never `0.0.0.0`.

## Error model

Common JSON error response:

```json
{
  "error": "busy",
  "message": "Hearsay is already recording"
}
```

Suggested error codes:

- `busy`
- `not_found`
- `invalid_request`
- `microphone_permission_missing`
- `transcriber_unavailable`
- `recording_failed`
- `transcription_failed`
- `cancelled`

HTTP mapping:

- `400` invalid request
- `404` unknown request id
- `409` busy/conflicting request state
- `500` unexpected internal failure
- `503` transcriber/model unavailable

## Testing plan

### Unit tests

Add tests around the delivery split:

- Final transcript in `pasteAtCursor` mode calls the existing paste/copy behavior.
- Final transcript in `returnToCaller` mode does not call `TextInserter`.
- Caller-mode result contains processed/cleaned final text.
- Caller-mode cancellation does not paste.
- Busy state rejects a second request.

### API tests

If practical, add local server tests:

- `GET /v1/health` succeeds.
- `POST /v1/dictations` starts a request when idle and returns the final result after stop/cancel.
- Starting while busy returns `409`.
- Stop transitions to transcribing and completes the original start request.
- Cancel returns cancelled and clears state.

### Manual integration test

1. Launch Hearsay dev build.
2. Verify `local-api.json` exists and points to a listening port.
3. Run a small curl or Node script that starts dictation.
4. Speak a short phrase.
5. Stop dictation through API.
6. Verify transcript returns in API result.
7. Verify no text is pasted into the currently focused app.
8. Verify normal Right Option dictation still pastes as before.

Example curl sketch:

```bash
API_JSON="$HOME/Library/Application Support/Hearsay/local-api.json"
PORT=$(jq -r .port "$API_JSON")
REQ_ID=$(uuidgen)

curl -sS \
  -H "Content-Type: application/json" \
  -d "{\"caller\":\"manual-test\",\"mode\":\"returnToCaller\",\"requestId\":\"$REQ_ID\"}" \
  "http://127.0.0.1:$PORT/v1/dictations"
```

## Implementation sequence

1. Add `DictationMode`, `DictationRequest`, and `DictationResult` types.
2. Refactor final transcript handling in `AppDelegate.swift` into a delivery abstraction.
3. Add caller-mode state to the recording/transcription coordinator.
4. Implement `startCallerDictation`, `stopCallerDictation`, `cancelCallerDictation` methods.
5. Add local API server bound to loopback.
6. Add `local-api.json` discovery file.
7. Wire API requests to the coordinator methods.
8. Add tests.
9. Add README/developer documentation for the local API.
10. Only after Hearsay API works, update `pi-vscode` to consume it.

## Open questions

- Should caller-mode dictations be saved to history by default? Recommendation: yes, with metadata indicating API/caller source.
- Should API be enabled by default? Recommendation: yes for developer builds; consider a settings toggle or per-caller approval before wider distribution.
- Should VS Code auto-stop recording on second `Cmd+K`, on key release, or via a sidebar Stop button? This is a VS Code UX decision, not a Hearsay blocker.
- Should Hearsay play the paste sound for caller-mode results? Recommendation: use a success sound, but perhaps not the exact paste sound because nothing was pasted.
- Should Hearsay support streaming partial transcription later? Not required for v1. The v1 result can be final-text only.

## Justification

This architecture is preferable to shortcut simulation because:

- It is deterministic: the caller receives the transcript directly.
- It is focus-safe: Hearsay will not accidentally paste into the wrong textbox.
- It keeps Hearsay app-agnostic: VS Code is just one local client.
- It reuses the existing Hearsay transcription quality and settings.
- It keeps local automation simple while staying loopback-only and visibly indicating microphone activity.
- It creates a general foundation for future integrations, e.g. terminal prompts, browser textareas, note apps, or other coding assistants.
