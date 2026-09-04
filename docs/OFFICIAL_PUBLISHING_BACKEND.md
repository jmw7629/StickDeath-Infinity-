# Official SDI YouTube Publishing Backend Contract

## Overview

The StickDeath Infinity iOS app submits exported animations to the official SDI YouTube channel via a server-side publishing pipeline. **The iOS client never holds YouTube OAuth credentials.** All YouTube API interactions occur server-side.

This document specifies the exact HTTP API contract that a backend service must implement to support official SDI YouTube publishing.

---

## Base URL

```
https://api.stickdeathinfinity.com/v1/publish
```

The iOS client sends requests to this endpoint. The server URL is configured via `AppConfig.publishingEndpointURL` in the iOS app.

---

## Authentication

All requests from the iOS client include a Supabase session token in the request body (`user_session_token` field). The backend must:

1. Validate the Supabase JWT against the Supabase Auth API or verify it locally using the Supabase JWT secret.
2. Extract the `sub` (user ID) claim from the validated token.
3. Verify the user has an active SDI subscription tier that permits publishing.
4. Reject unauthenticated or unauthorized requests with `401`.

The backend **must not** trust any client-supplied user ID without JWT validation.

---

## Endpoints

### POST `/youtube`

Submit a new publish request. Must be idempotent when the same `idempotency_key` is provided.

#### Request Body

```json
{
  "idempotency_key": "uuid-v4-string",
  "export_asset_url": "https://storage.example.com/media/exports/abc123/export.mp4",
  "export_format": "MP4",
  "title": "My StickDeath Animation",
  "description": "An epic stick figure battle created with StickDeath Infinity",
  "tags": ["animation", "stickdeath", "stickfigure"],
  "thumbnail_data": null,
  "visibility": "unlisted",
  "audience": "all",
  "user_session_token": "eyJhbGciOi..."
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `idempotency_key` | string (UUID) | Yes | Client-generated unique key. Duplicate submissions with the same key return the existing job. |
| `export_asset_url` | string (URL) | Yes | URL of the exported media file (Supabase Storage public URL or signed URL). |
| `export_format` | string | Yes | One of: `MP4`, `GIF`, `PNG`, `Spritesheet`. YouTube publishing requires `MP4`. |
| `title` | string | Yes | Video title. Max 100 characters. |
| `description` | string | Yes | Video description. Max 5000 characters. |
| `tags` | string[] | No | Array of tag strings. Max 500 characters total. |
| `thumbnail_data` | string (base64) or null | No | Base64-encoded JPEG thumbnail image. Max 2MB. |
| `visibility` | string | Yes | One of: `public`, `unlisted`, `private`. |
| `audience` | string | Yes | One of: `all`, `over_13`, `over_18`. Controls YouTube "Made for Kids" setting. |
| `user_session_token` | string | Yes | Supabase auth JWT for the submitting user. |

#### Response (200 OK)

```json
{
  "server_job_id": "sdi-pub-abc123",
  "status": "queued",
  "video_id": null,
  "video_url": null,
  "estimated_processing_time_seconds": 300,
  "error_message": null
}
```

| Field | Type | Description |
|-------|------|-------------|
| `server_job_id` | string | Server-assigned unique job identifier for status polling. |
| `status` | string | Current job status (see Status Lifecycle). |
| `video_id` | string or null | YouTube video ID once published. |
| `video_url` | string or null | Full YouTube URL once published. |
| `estimated_processing_time_seconds` | int or null | Estimated time until published. |
| `error_message` | string or null | Error description if status is `failed`. |

#### Idempotent Duplicate (409 Conflict)

When the same `idempotency_key` is submitted again, return `409` with the existing job response body (same structure as 200).

#### Error Responses

| Status | Meaning |
|--------|---------|
| 401 | Invalid or missing session token |
| 403 | User not authorized to publish (subscription tier check) |
| 422 | Invalid metadata (missing title, invalid format, etc.) |
| 429 | Rate limited — retry after `Retry-After` header |
| 503 | Server temporarily unavailable |

---

### GET `/youtube/{server_job_id}/status`

Poll the status of an in-flight publish job.

#### Path Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `server_job_id` | string | The server job ID from the publish response. |

#### Response (200 OK)

```json
{
  "server_job_id": "sdi-pub-abc123",
  "status": "processing",
  "video_id": null,
  "video_url": null,
  "error_message": null,
  "progress_percent": 65
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Current job status. |
| `progress_percent` | int or null | Upload/processing progress 0-100. |
| `video_id` | string or null | YouTube video ID when published. |
| `video_url` | string or null | Full YouTube URL when published. |
| `error_message` | string or null | Error if status is `failed`. |

---

### POST `/youtube/{server_job_id}/cancel`

Request cancellation of a publish job. Only possible before server acceptance (states: `uploading`, `queued`).

#### Response (200 OK)

```json
{
  "server_job_id": "sdi-pub-abc123",
  "status": "cancelled"
}
```

If the job is already in `processing` or `published` state, return `409` with an appropriate error message.

---

## Status Lifecycle

```
preparing → uploading → queued → processing → published
                          ↓          ↓
                        failed     failed
                          ↓
                       cancelled
```

| Status | Description | Client Behavior |
|--------|-------------|-----------------|
| `preparing` | Job created, asset being validated | Show "Preparing" |
| `uploading` | Asset being transferred to server | Show "Uploading" with progress |
| `queued` | Asset received, waiting for YouTube API slot | Show "In Queue" |
| `processing` | YouTube is processing the video | Show "Processing" with progress |
| `published` | YouTube video is live | Show success with video URL |
| `failed` | Error occurred (see `error_message`) | Show error, allow retry |
| `cancelled` | User cancelled before processing | Show cancelled state |

---

## Server-Side Responsibilities

### 1. Asset Ingestion

- Receive the `export_asset_url` from the request body.
- Download the asset from the provided URL (Supabase Storage).
- Validate the asset is a valid video file matching the declared `export_format`.
- Store the asset temporarily for YouTube upload.

### 2. YouTube OAuth Credential Ownership

The backend **must** own and manage all YouTube OAuth credentials:

- A YouTube API project with YouTube Data API v3 enabled.
- OAuth 2.0 client credentials (client ID + client secret) for a **server-side** (web application) flow.
- A refresh token for the official SDI YouTube channel account.
- The refresh token must be stored encrypted at rest (e.g., AWS Secrets Manager, Vault, or encrypted database column).

**Never expose YouTube client secrets, refresh tokens, or access tokens to the iOS client.**

### 3. YouTube Upload Flow

1. Use the stored refresh token to obtain a fresh access token from Google OAuth.
2. Initiate a resumable upload to the YouTube Data API v3 (`videos.insert` endpoint).
3. Transfer the video asset in chunks (resumable upload protocol).
4. Set video metadata: title, description, tags, category, privacy status, Made for Kids flag.
5. Upload the thumbnail if provided.
6. Handle YouTube API rate limits and retry with exponential backoff.

### 4. Idempotency

- Store a mapping of `idempotency_key → server_job_id` in the database.
- When a duplicate `idempotency_key` is received, return the existing job status instead of creating a new one.
- This prevents duplicate YouTube uploads from repeated client taps.

### 5. Status Tracking

- Persist job state in a database table (`publish_jobs`).
- Update status as the upload progresses through YouTube's pipeline.
- The polling endpoint reads from this table.

### 6. Optional: Push Notifications

For a better user experience, the backend can optionally send push notifications (via APNs) when a job reaches `published` or `failed` status, rather than relying solely on client-side polling.

### 7. Cleanup

- Delete temporary asset files after successful upload to YouTube.
- Retain job records for audit purposes but mark completed jobs for eventual archival.
- Optionally auto-delete assets after 7 days if the job failed and was not retried.

---

## Database Schema (Suggested)

```sql
CREATE TABLE publish_jobs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id),
    idempotency_key UUID NOT NULL UNIQUE,
    server_job_id TEXT UNIQUE,
    export_asset_url TEXT NOT NULL,
    export_format TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL,
    tags TEXT[] DEFAULT '{}',
    thumbnail_url TEXT,
    visibility TEXT NOT NULL DEFAULT 'unlisted',
    audience TEXT NOT NULL DEFAULT 'all',
    status TEXT NOT NULL DEFAULT 'preparing',
    youtube_video_id TEXT,
    youtube_video_url TEXT,
    error_message TEXT,
    progress_percent INTEGER,
    retry_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now(),
    published_at TIMESTAMPTZ
);

CREATE INDEX idx_publish_jobs_user_id ON publish_jobs(user_id);
CREATE INDEX idx_publish_jobs_idempotency ON publish_jobs(idempotency_key);
CREATE INDEX idx_publish_jobs_status ON publish_jobs(status);
```

---

## Security Requirements

1. **No client-side YouTube credentials.** The iOS app must never contain YouTube API keys, OAuth client secrets, or refresh tokens.
2. **JWT validation.** Every request must include a valid Supabase session token. The backend validates it server-side.
3. **Asset URL validation.** Only accept asset URLs from trusted storage origins (e.g., Supabase Storage buckets).
4. **Rate limiting.** Implement per-user rate limits (e.g., 5 publish requests per hour).
5. **Content moderation.** The backend should support an approval queue where the owner can review submissions before they go live on YouTube. This is a future enhancement that the client contract already supports (the `queued` state can accommodate manual approval).
6. **Encrypted secrets.** YouTube OAuth credentials must be encrypted at rest and never logged.

---

## Client Integration Notes

The iOS client (`YouTubePublishingClient`) implements:

- `publish(request:)` — POST to `/youtube`
- `status(serverJobID:)` — GET `/youtube/{id}/status`
- `cancel(serverJobID:)` — POST `/youtube/{id}/cancel`

The client polls status every 5 seconds until the job reaches a terminal state (`published`, `failed`, `cancelled`), with a maximum of 60 attempts (5 minutes).

The `PublishJob` model on the client is persisted locally (UserDefaults for bridge scope; SwiftData in production) to survive app backgrounding/termination.

---

## Testing the Backend

### Smoke Test

```bash
curl -X POST https://api.stickdeathinfinity.com/v1/publish/youtube \
  -H "Content-Type: application/json" \
  -d '{
    "idempotency_key": "test-001",
    "export_asset_url": "https://example.com/test.mp4",
    "export_format": "MP4",
    "title": "Test Upload",
    "description": "Testing the SDI publishing pipeline",
    "tags": ["test"],
    "thumbnail_data": null,
    "visibility": "private",
    "audience": "all",
    "user_session_token": "<valid-supabase-jwt>"
  }'
```

### Expected Response

```json
{
  "server_job_id": "sdi-pub-test-001",
  "status": "queued",
  "video_id": null,
  "video_url": null,
  "estimated_processing_time_seconds": 120,
  "error_message": null
}
```

---

## Future Enhancements (Not in Bridge Scope)

- **Owner approval queue**: Manual review before YouTube publication.
- **Scheduled publishing**: Allow users to pick a future publish time.
- **Multi-platform publishing**: Extend to TikTok, Instagram Reels, etc.
- **Analytics callback**: Server pushes publish analytics to the app.
- **Webhook notifications**: Server notifies the app of status changes via Supabase Realtime or webhooks.
