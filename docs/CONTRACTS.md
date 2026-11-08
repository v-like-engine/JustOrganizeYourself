# Component contracts — schema 1

This contract defines the boundary shared by Flutter, persistence, workbook exchange, peer synchronization and the optional Python process. Public changes must be communicated to the other component owners before integration.

## Record and snapshot

`JoyRecord` is an immutable value with named construction, `JoyRecord.fromJson(Map<String, dynamic>)`, `toJson()` and `copyWith(...)`. All timestamps are ISO 8601 UTC strings ending in `Z`; comparisons use the parsed instant.

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string | Stable identity; UUID for user-created records |
| `kind` | string | `folder`, `subfolder`, `item`, `project`, `action` or `settings` |
| `parentId` | nullable string | Parent folder, subfolder or project; null for root folders and settings |
| `title` | string | User-visible title |
| `description` | string | User text; empty when absent |
| `createdAt` | string | Original creation time |
| `updatedAt` | string | Time of the current revision |
| `revision` | string | Opaque unique revision token |
| `ancestors` | list of strings | Prior revision tokens known for this record |
| `deletedAt` | nullable string | Deletion timestamp; non-null means a tombstone |
| `data` | JSON object | Specialized fields and extensible attributes |

`copyWith` must preserve every field not explicitly replaced. Clearing a nullable field must be distinguishable from omitting the argument. Import and sync preserve unknown JSON-compatible entries in `data`.

An embedding belongs to the exact `title + '\n' + description` stored as `sourceText`. A changed source marks it stale; the graph must not combine vectors from different model IDs or revisions. Positions may remain stored for offline viewing but do not validate an edited record's old vector.

`JoySnapshot` has named construction with `deviceId`, `records` and `schemaVersion` defaulting to `1`; it provides `fromJson` and `toJson`:

```json
{
  "schemaVersion": 1,
  "deviceId": "device-uuid",
  "records": [
    {
      "id": "example-task-uuid",
      "kind": "item",
      "parentId": "inbox",
      "title": "Buy groceries",
      "description": "",
      "createdAt": "2026-11-08T12:00:00.000Z",
      "updatedAt": "2026-11-08T12:00:00.000Z",
      "revision": "example-revision-uuid",
      "ancestors": [],
      "deletedAt": null,
      "data": {}
    }
  ]
}
```

Only schema 1 is currently accepted. Duplicate record IDs, broken references, invalid dates, unsupported record kinds and impossible parent relationships are rejected before mutation. Snapshot replacement is a database transaction. An unsupported schema does not become an empty system.

### Hierarchy

Root folders have no parent. A `subfolder` belongs to a folder. An `item` belongs to a folder or subfolder. A `project` belongs to a folder or subfolder, normally Projects or one of its groups. An `action` belongs to a project. Settings have no parent. Records moved to Trash may temporarily have Trash as their parent, including folders; their original identity and hierarchy remain recoverable. Tombstones are retained for merge history but are excluded from ordinary lists.

Seed folder IDs are `inbox`, `projects`, `knowledge`, `contacts`, `shopping`, `calendar`, `delegated`, `someday`, `urgent`, `by-date`, `conditional` and `trash`. Seed revision tokens are deterministic and identical across fresh installations. Seed labels may be translated; IDs remain unchanged.

### Specialized data

The following keys are the schema 1 convention; unrecognized extra keys remain preserved:

| Kind/context | `data` keys |
| --- | --- |
| Folders and subfolders | `order` number; optional `category` identifying a built-in role |
| Project | `plan` string, `completionCriterion` string, `draft` boolean |
| Action | `order` number; action text is the record title |
| Calendar item | `scheduledAt` UTC string; optional `endsAt` and `timeZone` |
| Delegated item | `assignedTo` string and `dueAt` UTC string when set |
| Trash item | `trashedAt` UTC string, independently of original creation time |
| Embedding | `embedding` object with `modelId`, `revision`, `vector`, `textHash`, `sourceText`, and optional graph position `x`, `y` |
| Settings | `locale`, `trashDays` and `triageMenus` |

`dueAt` is the expected date for the current UI; more specific delegation date meanings need a product decision. Missing optional fields remain absent rather than fabricating dates.

## Storage API

The package export is `package:joy_core/joy_core.dart`. Storage is synchronous SQLite and has no Flutter dependency. Flutter can refresh its own notifier after a mutation.

```dart
JoyRepository.open({required String path, String? deviceId})
JoyRepository.memory({String? deviceId})
List<JoyRecord> all({bool includeDeleted = false})
JoyRecord? get(String id)
List<JoyRecord> children(String parentId)
List<JoyRecord> get folders
List<JoyRecord> get inboxItems
JoySnapshot snapshot()
JoyRecord create({required String kind, required String title,
  String? parentId, String description = '', Map<String, dynamic> data = const {}})
JoyRecord edit(String id, {String? title, String? description,
  Map<String, dynamic>? data})
JoyRecord move(String id, String parentId)
JoyRecord trash(String id)
int purgeTrash({DateTime? now})
int? ordinalOf(String id)
JoyRecord get settings
JoyRecord saveSettings(Map<String, dynamic> settings)
void replaceAll(JoySnapshot snapshot, {bool rememberUndo = false,
  String? expectedState})
void importSnapshot(JoySnapshot snapshot,
  {bool replace = false, String? expectedState})
bool undoImport()
void close()
```

`saveProject` is the storage helper for atomically validating/saving the project and ordered action records. It accepts optional existing `id`, `parentId`, title, description, plan, completion criterion, action title list and `draft` flag. Complete projects require the agreed mandatory fields and one nonempty action. Deferred mobile projects use `draft: true`.

`settings` returns the settings record; values are in `settings.data`. `saveSettings` merges supplied keys into existing settings data. `edit(data: ...)` replaces the data map; callers merge fields they intend to preserve. Storage, not the UI, creates revision tokens on ordinary edits. `replaceAll` installs a reviewed snapshot without synthesizing edits to each row. `importSnapshot(replace: true)` instead represents an intentional local change: known active records absent from the workbook become minimal tombstones; older or divergent restored values receive a new revision descending from both the known current and imported histories. An imported record already descending from the current revision is kept intact. This preserves lossless fresh restoration while preventing an old peer from resurrecting intentionally replaced records. Import Add must not overwrite divergent same-ID records; it reports the conflict before any mutation. Exact duplicates may be skipped. Import undo restores all records and settings, including hierarchy and tombstones, until another mutation invalidates it. Navigation does not invalidate undo.

`ordinalOf` derives a task number from records of kind `item`, `project` and `action`, including retained tombstones, ordered by creation instant and then stable ID. Renaming, moving or marking a record deleted does not create a new identity. Task numbers never participate in conflict detection.

Final Trash purge clears title, description and the data map, including stored vectors, from expired records and their descendants. Stable IDs, kind, parent linkage, creation time and deletion/revision history remain as minimal synchronization tombstones.

## Merge and peer synchronization

`mergeSnapshots(JoySnapshot local, JoySnapshot remote)` is a pure function returning a `MergePlan`. `plan.conflicts` contains `MergeConflict` records exposing `id`, `local`, `remote` and `changedFields`. `plan.resolve(Map<String, ConflictChoice> choices)` produces a validated merged snapshot; missing choices cannot silently select a default. `ConflictChoice` has `local` and `remote` values. `resolved(...)` is an alias of `resolve(...)`.

For the same ID:

1. Same revision and same content is unchanged.
2. If one revision is in the other record's ancestry, keep the descendant.
3. Divergent revisions are a conflict, including delete/edit and move/edit differences.
4. Independent IDs are retained from both devices, even if their titles or task numbers match.

A conflict resolution creates a new revision that includes both histories. The next exchange must not ask the same conflict again. Identical revision IDs with differing content indicate invalid or incompatible input, not a safe equality.

A parent deletion combined with independent live children is a structural conflict. Such a `MergeConflict` also exposes `dependentChildren: List<JoyRecord>` and `blockedChoice: ConflictChoice?`. The destructive choice is disabled: retain the parent, or explicitly move its children before synchronizing again. Resolving to the blocked choice throws an actionable error without mutation. This conservative rule avoids silently deleting or relocating independent work.

```dart
Future<PeerServer> PeerServer.start(JoyRepository repository,
  {String address = '0.0.0.0', int port = 0, String? pairingCode})
int get port
String get pairingCode
Future<void> close()
Future<RemoteSyncSession> PeerClient().preview(
  Uri endpoint, String pairingCode, JoySnapshot local)
MergePlan get RemoteSyncSession.plan
Future<void> RemoteSyncSession.commit(
  JoyRepository repository, Map<String, ConflictChoice> choices)
```

The server uses the existing repository and never creates another database. Every endpoint requires `x-joy-code`. `GET /v1/info` returns device ID and state token; `GET /v1/snapshot` returns the snapshot and its state token. `POST /v1/prepare` accepts `expectedState` and the reviewed `snapshot`, validates them without mutation, and returns a five-minute token. `POST /v1/commit` accepts that token and applies only if the source state is unchanged. Repeating a committed token is idempotent until subsequent edits. Both the client and server reject stale plans. Pairing codes are ephemeral and never included in exported records. A listener is active only while the user enables it.

There is no distributed atomic transaction across devices. The remote device commits first and the local device applies with an expected-state guard. If the acknowledgement is lost or the local data changes during commit, no success is reported; a subsequent exchange safely converges through retained revision history. Current transport is HTTP on a trusted local network; encrypted transport and automatic discovery are not implemented. The UI supports manual device address and pairing code.

## Workbook boundary

`transfer/workbook.dart` exports and decodes schema 1 snapshots. Folder sheets contain their folder definition, subfolders, items, projects and actions with stable IDs and parent references. The `_joy` sheet contains schema and device ID in its first two rows, then the column header and settings or other root records. Display names never serve as identity; valid unique sheet names are generated while original folder names remain in `JoyRecord.title`.

```dart
List<int> WorkbookCodec().encode(JoySnapshot snapshot)
JoySnapshot WorkbookCodec().decode(List<int> bytes)
List<JoyRecord> WorkbookCodec().decodeInbox(List<int> bytes,
  {String? sheetName, bool hasHeader = false, int titleColumn = 0,
   int? descriptionColumn, int? createdAtColumn,
   DateTime? importedAt, String parentId = 'inbox'})
String CalendarExporter().exportEvents(List<JoyRecord> records)
```

Record columns are `id`, `kind`, `parent_id`, `title`, `description`, `created_at`, `updated_at`, `revision`, `ancestors_json`, `deleted_at`, `data_json`, `_index`, `_chunk_field`, `_chunk_index`, `_chunk_value`. `_index` restores snapshot order. Values over 30,000 UTF-16 code units use `_chunk` continuation rows for the same record/field, preserving long descriptions and embedding metadata beyond a single Excel cell. Continuation sequences, unique IDs, required roots, dates and hierarchy are checked before import. All values are literal text cells; imported formula data is rejected.

Inbox-only decoding accepts a selected sheet and zero-based column mapping. Without a header, the first nonempty title cell is data. Rows missing creation dates share exactly one UTC batch timestamp captured before row processing. An invalid supplied creation date rejects the batch before mutation, including impossible dates that a lenient parser would otherwise normalize. Native Excel date and datetime cells are accepted; ISO date strings without a timezone are interpreted as UTC. Applying either import mode and immediate undo belongs to the repository; encoding/export never changes it.

Calendar export reads `data.scheduledAt` and optional `endsAt` and emits UTC RFC 5545 `.ics` with stable event UIDs, escaped text and UTF-8 line folding. If no end is supplied, the export uses a one-hour duration. It has no calendar-import API.

## Optional embedding service

The service binds to loopback by default and runs separately from the client. `GET /health` returns `status`, `modelLoaded`, `model` metadata and an optional failure detail. A missing model produces an honest unavailable response from computation endpoints; test vectors are not evidence of semantic quality.

`POST /v1/embed` accepts `{"entries": [{"id": "record-id", "text": "title and description"}]}`. It returns `model` with `id`, `revision` and `dimensions`, plus `embeddings` in request order containing `id`, `vector` and `textHash`. The client stores these values in record data; it remains the only database writer.

`POST /v1/graph` accepts `nodes` with `id`, `kind`, `title` and `vector`, plus optional `neighbors` and `minSimilarity`. It returns positioned `nodes` with `id`, `kind`, `title`, `x`, `y`, and `edges` with `source`, `target`, `similarity`. Knowledge and Contacts remain distinguishable categories. The Python service README owns the complete validated schema and startup/model-install commands.

The model is installed explicitly and must meet the size budget. Python does not read or mutate the database directly. Outbound Calendar export has no reverse-import endpoint in this scope.
