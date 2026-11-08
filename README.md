# Just Organize Yourself

### Capture freely. Clarify deliberately. Keep your data portable.

A planned **Getting Things Done (GTD)** application for collecting thoughts, organizing projects, and connecting knowledge with people. Start with a calm Inbox, sort one card at a time, and keep devices in sync over local Wi-Fi without an external server. A single Excel workbook provides portable backup and restore.

> **Status: requirements gathering.** This repository currently contains documentation only. The features below describe the intended product; they are not implemented yet. Requirements are still being collected.

[Product specification & implementation checklist](docs/PRODUCT_SPEC.md) · [Planned experience](#planned-experience) · [Data portability](#data-portability) · [Development status](#development-status)

## Why this project?

Capturing an idea should take seconds. Processing a full Inbox should feel manageable. Moving to another device should preserve the work you have already done.

Just Organize Yourself aims to bring those needs together: a focused capture interface, structured GTD organization, mobile swipe sorting, and a portable data format that remains useful outside the app.

## Planned experience

| Area | Intended experience |
| --- | --- |
| **Inbox first** | Open directly into a large, centered text field. Add an item with Enter or the send button, then scroll through previously captured items while the composer stays accessible. |
| **Persistent organization** | Keep Inbox items and all other GTD data between sessions, including creation times and future task attributes. |
| **Your folders, your structure** | Create, rename, describe, and reorder folders and subfolders. Start from editable GTD presets, including Shopping Lists, and organize purchases by supermarket, pharmacy, or marketplace. |
| **Projects with a clear outcome** | Turn an Inbox item into a project with a title, description, free-text plan, completion criterion, and at least one action. Add further actions without the form growing beyond the screen. |
| **Focused processing** | See one Inbox card at a time with a gentle remaining-work indicator: exact counts up to ten, approximate bands above that. |
| **Swipes & numpad** | Configure eight swipe directions plus tap on a phone, and numpad keys 1–9 on a computer. Actions can file a card, open a submenu, show details, or edit. Reach destinations through two or three gestures rather than being limited to eight folders. |
| **Project drafts** | Keep sorting when a card becomes a project. Complete pending project forms afterward, one at a time. Projects can be grouped inside subfolders. |
| **Similar-item hints** | While typing, browse nonblocking suggestions for existing tasks with matching words or word forms. Select an existing task to discard the current draft instead of creating a duplicate. |
| **Trash** | Route unwanted cards to a required Trash folder. Automatically remove them after a configurable number of days. |
| **Calendar & delegation** | Schedule an item with date and time for Google Calendar exchange, or record whom a task is delegated to and its date. Include starter categories for later, urgent, dated, and conditional work. |
| **Knowledge & Contacts** | Store titled entries with descriptions and creation times, and explore both categories in one graph with distinct colors. |
| **Local semantic discovery** | Optionally use a lightweight local embedding model to place related knowledge and contacts near each other. Desktop processing can happen later for entries captured on a phone. |

Starter folders provide a useful GTD setup, not a fixed taxonomy. Users can customize the structure and filing shortcuts. Trash must remain available; the exact treatment of other built-in entry points when deleting presets still needs design.

## Local device synchronization

**Wi-Fi synchronization is a required core feature**, with manual XLSX transfer as an alternative. Devices on the same home network or phone hotspot exchange data directly; no external synchronization server is required.

The proposed pairing experience is **Synchronize → find a nearby device → confirm a code**, with QR pairing and a manual address/port fallback when discovery is unavailable. This is a design proposal, not an implemented protocol.

New items from both devices must survive. Conflicting versions must show their differences and let the user choose which version to keep. A device with more items must not silently overwrite changes on the other device just because its collection is larger.

## Data portability

**Your GTD system → `.xlsx` → another device → your GTD system.**

The exchange format is an Excel `.xlsx` workbook: **folders are sheets; subfolders are represented within those sheets**. Projects add another level inside their group, with actions belonging to the correct project. Export must preserve the structure, empty folders, names, descriptions, ordering, settings, creation times, and other supported metadata so an import can reconstruct the system.

- **Whole-system import:** choose between adding to existing data and replacing it. Adding is the default, safer action.
- **New folders:** add nonconflicting folders and subfolders found in an imported workbook without changing the existing organization.
- **Undo import:** immediately undo either an addition or a replacement and recover the previous state.
- **Inbox-only import:** load a simple workbook, including a single column without a header. Each nonempty row becomes an Inbox item. Items without creation times receive the same UTC timestamp for that import batch.
- **Extensible metadata:** account for future attributes such as priority and duration, as well as embedding data when available.

Restoring the user system must need only **one `.xlsx` file**, with at most a separately installed optional embedding model. The primary runtime storage format, detailed workbook schema, duplicate handling, and local synchronization protocol still need design. Direct `.xlsx` storage remains an option. Legacy `.xls` support has not been specified.

## Languages

English is the default interface language. The planned language set is:

| Language | Locale |
| --- | --- |
| English | `en` |
| Russian | `ru` |
| French | `fr` |
| Spanish | `es` |
| German | `de` |
| Serbian | `sr` — script to be decided |

Language selection must not change user content or portable field identifiers. Stored creation times use UTC.

## Roadmap & acceptance

The [product specification](docs/PRODUCT_SPEC.md) records requirements in Russian for review with the project owner. It contains stable requirement IDs, implementation subtasks, acceptance criteria, verification scenarios, and open decisions.

Planned work is grouped into:

1. Durable data, customizable folders, and Inbox capture with similar-item hints.
2. Lossless one-file export, safe import, and undo.
3. Project creation, grouping, and action lists.
4. Focused card processing with configurable swipe/numpad menus and Trash.
5. Direct Wi-Fi synchronization and visible conflict resolution.
6. Calendar exchange, delegation, and starter GTD workflows.
7. Knowledge, Contacts, and a shared semantic graph.
8. Localization across the six requested languages.

This is a provisional grouping, not a committed release sequence. A feature is complete only after implementation and verification; documenting a requirement does not complete it.

## Development status

No application code, selected technology stack, dependency manifests, build commands, or test runner exist yet. There are no installation or launch instructions to execute at this stage. Those instructions will be added and verified when implementation begins.

While requirements are being gathered:

- Capture incoming requirements before implementing features.
- Extend the specification as the owner continues describing the product.
- Record architectural proposals separately from confirmed product requirements.
- Update checklist status with evidence of implementation and verification.

## Longer-term exploration

The original project vision also mentions local agents that learn the user's Inbox sorting patterns. Their behavior, training, resource budget, and relationship to semantic embeddings remain unspecified. They are a future idea rather than a current implementation commitment.
