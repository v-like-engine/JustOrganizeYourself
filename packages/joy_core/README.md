# joy_core

The offline Dart component shared by the Android and desktop application. It owns SQLite persistence, record identity, hierarchy validation, workbook exchange, and direct peer synchronization. Flutter widgets and the optional Python embedding process are separate components.

## Run checks

From this directory, with Dart 3.5 or newer:

```sh
dart pub get
dart test
dart analyze
```

The cloud toolchain is available through `source /workspace/.toolchains/env.sh`. Linux needs a SQLite shared library; the repository accepts both `libsqlite3.so` and the distribution runtime `libsqlite3.so.0`. Android receives its SQLite library through the Flutter application's native dependencies.

## Repository

Open a persistent database with `JoyRepository.open(path: databasePath)`, or use `JoyRepository.memory()` for tests. All repository methods are synchronous; the UI refreshes its state after a successful mutation.

| Operation | Behavior |
| --- | --- |
| `create`, `edit`, `move` | Validate the resulting hierarchy before saving; every change receives a new revision and retains the previous revision in its ancestry. `edit(data: …)` replaces the supplied data map. |
| `saveProject` | Validate mandatory fields and at least one action before making any changes. Drafts may be incomplete. Preserve existing action identities when their titles or positions identify them. |
| `snapshot` | Return all records, including deletion tombstones and portable settings. Keep local device identity outside the imported record set. |
| `importSnapshot` | Add nonconflicting identities by default; reject divergent matching identities instead of silently overwriting them. `replace: true` deliberately restores the selected state, issuing descendant revisions for older or divergent restored values and deletion tombstones for absent known records. This prevents a stale peer from resurrecting replaced data. |
| `undoImport` | Restore the complete pre-import record set, including structure and settings. Available in the current process until the next successful mutation. |
| `replaceAll` | Atomically validate and apply a complete snapshot. `expectedState` rejects a stale synchronization result. |
| `trash`, `restore`, `purgeTrash` | Store the Trash entry time independently from creation time, restore its previous destination, and clear expired payloads while retaining minimal identity/history tombstones after expiration. Nonempty folder deletion requires an explicit content-handling choice. |
| `ordinalOf` | Derive a display number from UTC creation time and ID. The number is never the record identity; tombstones remain in the sequence. |

Required root records are `inbox`, `trash`, and `settings`. Other starter folders are editable and removable when empty. Record metadata is immutable to prevent edits that bypass revision tracking. JSON timestamps use valid UTC values ending in `Z`.

The shared wire format and component boundaries are described in [CONTRACTS.md](../../docs/CONTRACTS.md) and [ARCHITECTURE.md](../../docs/ARCHITECTURE.md).
