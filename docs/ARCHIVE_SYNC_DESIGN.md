# Receipt Archive Sync — architecture proposal

**Status: approved and built (Aug 17, 2026).** Implementation: `GraphDriveSyncEngine` in BookkeeperCore; wiring in `Receipts.store(for:)` (CLI) and `Workspace` (app).

## Goal

Make the receipt archive cloud-canonical. Today the archive is a plain folder
(`03_Finance/Receipts Archive`) that the macOS CLI writes into via the local
OneDrive sync agent, which ties the canonical copy to one machine, and the
iPhone/iPad app keeps an entirely separate archive in its Documents container.
After this change every client reads and writes the **same** archive through
the Microsoft Graph API — the same mechanism the swept receipts inbox already
uses — with local copies held only as a cache.

## Layout

```
OneDrive (canonical)
└── 03_Finance/ZohoAIBookkeeper/Receipts Archive/
    ├── 2025/
    │   ├── 2025-07-07-sam-s-club-5A8DCC3A.pdf         ← original, write-once
    │   └── 2025-07-07-sam-s-club-5A8DCC3A.pdf.json    ← sidecar, may be rewritten
    └── 2026/…
```

Unchanged from today: one original per receipt (write-once, never modified)
plus one JSON sidecar (parse result, match status, provenance; rewritten on
status changes). The archive moves one level down into a `ZohoAIBookkeeper/`
folder so app-managed data is visibly separate from hand-managed finance files.

Sync bookkeeping (delta tokens, upload queue) is **not** stored in the archive
— it goes through the existing `SyncStateStore` split (UserDefaults on
iOS/iPadOS, repo-root JSON on the CLI).

## Local cache

Cloud is canonical; local copies are a cache in the platform-blessed location:

| Platform | Cache root | Rationale |
|---|---|---|
| iPhone/iPad | `FileManager.urls(for: .cachesDirectory)` + `ReceiptsArchive/` | Apple's rule: anything re-downloadable belongs in Caches, which iOS may purge under disk pressure. Purge is safe — everything re-hydrates from OneDrive. |
| macOS CLI | `~/Library/Caches/com.emotiveapps.ZohoBookkeeper/ReceiptsArchive/` | Same Apple convention on macOS (`.cachesDirectory` resolves here). It's a cache, so per the owner's storage policy it may live outside the repo; `~/Library/Caches` is the best-practice spot rather than a hidden dotfolder. |

The cache mirrors the cloud layout (`<year>/<file>`), plus one `index.json`
manifest per cache: for every known remote item, its driveItem id, etag,
quickXorHash, size, and whether the content is present locally. `allRecords()`
and `receipts list` read sidecars straight from the cache — no network on the
hot path.

### Staging area (the one non-negotiable subtlety)

A purgeable cache must never be the only holder of a receipt that hasn't
reached OneDrive yet. New ingests and sidecar rewrites are therefore written
first to a small **staging directory** in non-purgeable storage
(iOS: Application Support; CLI: `~/Library/Application Support/com.emotiveapps.ZohoBookkeeper/ArchiveStaging/`),
uploaded from there, and only moved into the cache after Graph confirms the
upload. If the device is offline or Microsoft is signed out, receipts
accumulate in staging and upload on the next sync — nothing is lost to a cache
purge, and the staging folder is empty whenever the system is caught up.

## Sync engine

One new actor in BookkeeperCore, deliberately **generic** — it syncs *one
OneDrive folder against one local cache* and knows nothing about receipts, so
it can be lifted into other apps as-is (the owner intends to reuse it):

```
GraphDriveSyncEngine (actor) — reusable component
 ├─ graph: GraphMailClient        // reuses existing auth + drive methods
 ├─ folderPath: String            // the synced OneDrive folder
 ├─ cache: local cache dir + index.json
 ├─ staging: pending-upload dir + queue
 ├─ syncState: SyncStateStore     // delta token persistence
 │
 ├─ pull()      // delta-based reconcile cloud → cache
 ├─ push()      // drain staging → cloud
 ├─ stage(...)  // write a new/changed file locally, queue for upload
 └─ fileData(at:) // cache hit, else download on demand

ReceiptStore (existing API) — receipts layer on top
 └─ ingest/update/allRecords/record/fileData delegate to the engine
```

### Pull (cloud → cache): delta-first, listing as fallback

Incremental pulls use the **Graph delta API** with a persisted delta token —
one call returns only what changed since the last pull (including renames,
moves, and deletions, which plain listings can miss).

- **OneDrive for Business constraint**: delta is only supported on the drive
  *root*, not arbitrary folders. The engine therefore calls
  `GET /me/drive/root/delta?token=…` and filters the response client-side to
  items whose `parentReference.path` falls under the synced folder. Changes
  elsewhere in the drive cost response bytes but no extra calls, and the token
  still collapses "nothing changed" to a single request.
- The delta token is persisted through `SyncStateStore` (UserDefaults on
  iOS/iPadOS, repo-root `state.json` on the CLI), keyed by drive + folder path
  so multiple synced folders can coexist.
- **Bootstrap and recovery**: with no token (fresh install) the first delta
  call enumerates everything, establishing both the index and the initial
  token. If Graph returns `410 Gone` (`resyncRequired` — tokens expire), the
  engine falls back to a full recursive **folder listing** (the same code
  path, kept as the reliable fallback) and then re-establishes a fresh token.
- Deletions arrive as `deleted` facets in the delta response; per the audit
  policy below they are surfaced as warnings, never propagated silently.

Whichever mechanism produced the change set, each item's **etag** is compared
against `index.json`:
  - new/changed **sidecar** (small) → download immediately; sidecars are the
    queryable metadata and should always be fully present locally.
  - new/changed **original** → record in the index, download **lazily** on
    first `fileData(for:)` (attachment upload, preview). Keeps first-run
    hydration on a phone to ~700 small JSONs, not 400+ PDFs.
  - locally-indexed item missing in cloud → surface a warning, never delete
    local data silently (audit archive: deletions are always human decisions).

### Push (staging → cloud)

- Small files (≤ 4 MB, i.e. everything we've ever archived) upload with a
  single `PUT …:/content` call; anything larger uses a Graph upload session.
- Originals are write-once: uploads use `@microsoft.graph.conflictBehavior:
  fail`; a name collision means a duplicate ingest and is dropped after
  verifying the remote quickXorHash matches (idempotent re-push).
- Sidecars are last-writer-wins **guarded by etag**: push sends `If-Match`;
  on `412 Precondition Failed` the engine re-downloads the remote sidecar,
  merges by newest `updatedAt`, and re-pushes. In practice two writers
  touching the same sidecar simultaneously is rare (one phone, one Mac), but
  the guard makes it safe.
- After a confirmed upload the file moves staging → cache and the index
  records the new etag.

### When sync runs

- **CLI**: at the start and end of every `receipts sync` (pull first so
  matching sees other devices' work; push last), and a push after `attach`.
- **App**: on `syncReceiptsNow`, on Receipts screen appearance (pull only,
  throttled), and after any local ingest/attach (push).
- No daemons, no file watchers: the engine is invoked by the flows that
  already exist.

### Failure model

- Offline / not signed in: pull skips silently, ingests stage locally, push
  retries next run. The app's connection-status row already shows Microsoft
  sign-in state.
- Cache purged (iOS): next pull rebuilds `index.json` and re-downloads
  sidecars; originals return lazily. No user-visible damage.
- Staging survives crashes (plain files + a queue journal); pushes are
  idempotent via hash comparison.

## Call-count expectations (Microsoft Graph, not Zoho — separate quota, generous limits)

| Scenario | Calls |
|---|---|
| Fresh install, first pull | ~4 listing pages + ~690 sidecar downloads ≈ **700**. Originals are lazy, so a phone doesn't pay for 400+ PDFs it may never open; a client that wants the full offline archive (CLI `receipts hydrate`, optional) adds ~690 content downloads ≈ **1,400 total** — matching the "1,000+ on fresh install" expectation. |
| Steady-state pull, nothing changed | **1 delta call**, 0 downloads. |
| Steady-state pull, N changed/new items | 1 delta call (+pages if the change set is large) + N downloads. |
| Delta token expired (rare) | Falls back to a full listing (~4 calls) + changed downloads, then resumes delta. |
| Push of one new receipt | 1 upload (+1 sidecar upload). |

Graph throttling is per-app/per-user and far looser than Zoho's daily cap;
none of this touches the Zoho quota at all.

## What changes for existing code

- `ReceiptStore` keeps its public API (`ingest`, `update`, `allRecords`,
  `record`, `fileData`) but is constructed over the **cache root** and gains
  the engine as its backing writer — `ReceiptPipeline` and both front ends are
  unchanged except for wiring.
- `GraphMailClient` gains `uploadDriveItem` (PUT content / upload session +
  `If-Match`) — listing, download, ensure-folder, and move already exist.
- `receipts.archive_path` in config is replaced by the fixed cloud path
  (`03_Finance/ZohoAIBookkeeper/Receipts Archive`), configurable as
  `receipts.archive_folder_path` for flexibility but with that default.
- The iPhone/iPad app's separate Documents archive goes away — the phone sees
  the same archive as the Mac, which also makes the app's Receipts screen show
  the full history (688 receipts) instead of only phone-ingested ones.

## Migration (one-time)

1. Server-side Graph move of `03_Finance/Receipts Archive` →
   `03_Finance/ZohoAIBookkeeper/Receipts Archive` (instant, IDs stable).
2. First CLI `receipts sync` performs the initial pull (sidecars) and marks
   all existing files as present-in-cloud; nothing re-uploads.
3. Delete nothing: the old local copies under CloudStorage disappear on their
   own once the server-side move syncs.

Note: the OneDrive desktop client will still mirror the archive folder into
`~/Library/CloudStorage/…` on the Mac — that's fine (extra redundancy, and
Finder browsability was the point of putting it in OneDrive). The engine
itself never reads or writes through that mirror.

## Explicitly out of scope (v1)

- Sharing/permissions management on the OneDrive folder
- Background sync on iOS (BGAppRefresh) — manual + on-screen-appearance only
- Multi-account OneDrive support (single Lucky Frog drive, like the inbox)
