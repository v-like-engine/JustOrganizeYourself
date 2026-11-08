# Development and review

Just Organize Yourself uses Flutter/Dart for Android and desktop, SQLite for local state, XLSX for portable backup, and a separately started optional Python service for embeddings. Start with [the product requirements](docs/PRODUCT_SPEC.md), [architecture](docs/ARCHITECTURE.md) and [component contracts](docs/CONTRACTS.md).

## Working on a feature

Choose a coherent requirement block and agree on the files it owns. Keep its implementation, tests and contract changes together. Communicate public API changes to callers before integrating them; do not silently rename a field in one component.

A requirement is complete after its behavior is implemented and checked. Record the relevant test command or manual scenario and the result. A passing build alone does not verify import safety, a real peer exchange or usability on a phone.

For coordinated work, the architect checks module boundaries, data ownership and contract consistency. The critic independently checks functionality, UI usability and adherence to the product scope. Implementers run their own tests, respond to findings and let the reviewer recheck the fix. The current team limit is seven simultaneous agents including the coordinator.

## Component checks

Install a compatible Flutter SDK and Python 3.11 or newer. The package lockfiles record resolved dependencies. In the managed development environment, `source /workspace/.toolchains/env.sh` selects the prepared toolchain and writable cache locations; that path is specific to the current cloud workspace.

From `packages/joy_core`:

```sh
dart pub get
dart analyze
dart test
```

From `apps/joy`:

```sh
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
```

Android builds require the Android SDK and accepted SDK licenses. Desktop builds require the native Flutter toolchain for the target operating system. The prepared cloud Linux prefix can be selected with `source /workspace/.toolchains/linux-env.sh` when present. A missing compiler or GTK development package on another host is an environment limitation and should be reported separately from an application defect.

From `services/embeddings`, use a Python virtual environment and the service's own [instructions](services/embeddings/README.md) for installation, tests, model verification and startup. Model download is explicit. API tests with a test backend do not prove semantic model quality.

## Data integrity

- Record IDs identify data; display task numbers do not.
- Preserve original creation time through moves and Inbox-to-project conversion.
- Preserve unknown supported JSON attributes during workbook and peer exchange.
- Validate an entire import before changing SQLite, including parent references and settings.
- Keep import undo as a complete prior state until another mutation invalidates it.
- Retain deletion history for synchronization; an old peer is not a source of automatic resurrection.
- Keep independent additions from both devices and expose divergent edits to the user.
- Treat optional model output as stale after the source text or model revision changes.

## Scope and style

Technical support for existing requirements, such as stable IDs, conflict previews and task numbering, belongs with the feature. Unrelated product capabilities require the owner's agreement. Calendar integration is outbound export only; reverse import requires a separate decision.

Use straightforward names, small useful boundaries and the project's formatter. Code Humanizer supports review for direct, readable code. Preserve required validation, usable errors and meaningful tests. Do not introduce artificial inconsistency or weaken behavior to imitate a style sample.

Describe limitations concretely in the final report. Separate implemented behavior, tests that passed, tests not run, environment blockers and questions that need a product decision. Update unchecked product requirements only when their acceptance evidence exists.
