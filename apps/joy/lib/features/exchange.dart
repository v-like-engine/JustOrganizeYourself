import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:joy_core/joy_core.dart';
import '../controller.dart';
import '../l10n.dart';
import 'editors.dart' show folderLabel;

Future<void> savePortableFile(String name, List<int> bytes) async {
  final result = await FilePicker.platform.saveFile(
    dialogTitle: name,
    fileName: name,
    bytes: Uint8List.fromList(bytes),
  );
  if (result != null && !Platform.isAndroid && !Platform.isIOS)
    await File(result).writeAsBytes(bytes, flush: true);
}

Future<void> exportWorkbook(JoyController controller) async {
  await savePortableFile(
    'just-organize-yourself.xlsx',
    WorkbookCodec().encode(controller.repository.snapshot()),
  );
}

Future<void> exportCalendar(JoyController controller) async {
  final items = controller.records
      .where(
        (r) => r.kind == 'item' && controller.isWithin(r.parentId, 'calendar'),
      )
      .toList();
  final text = CalendarExporter().exportEvents(items);
  await savePortableFile('joy-calendar.ics', utf8.encode(text));
}

Future<void> importWorkbook(
  BuildContext context,
  JoyController controller,
  Words words, {
  bool inboxOnly = false,
}) async {
  final file = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['xlsx'],
    withData: true,
  );
  if (file == null || file.files.isEmpty || !context.mounted) return;
  final importedAt = DateTime.now().toUtc();
  final selected = file.files.single;
  final bytes = selected.bytes ?? await File(selected.path!).readAsBytes();
  if (!context.mounted) return;
  final options = await showDialog<ImportOptions>(
    context: context,
    builder: (context) => ImportDialog(words: words, inboxOnly: inboxOnly),
  );
  if (options == null || !context.mounted) return;
  final repo = controller.repository;
  final expectedState = repo.stateToken;
  final current = repo.snapshot();
  JoySnapshot incoming;
  if (inboxOnly) {
    final items = WorkbookCodec().decodeInbox(
      bytes,
      hasHeader: options.header,
      titleColumn: options.titleColumn,
      descriptionColumn: options.descriptionColumn,
      createdAtColumn: options.dateColumn,
      importedAt: importedAt,
    );
    final removed = <String>{};
    if (options.replace) {
      for (final r in current.records) {
        if (r.parentId == 'inbox') removed.add(r.id);
      }
      var changed = true;
      while (changed) {
        changed = false;
        for (final r in current.records) {
          if (removed.contains(r.parentId) && removed.add(r.id)) changed = true;
        }
      }
    }
    incoming = JoySnapshot(
      deviceId: current.deviceId,
      records: [
        ...current.records.where((r) => !removed.contains(r.id)),
        ...items,
      ],
    );
  } else {
    incoming = WorkbookCodec().decode(bytes);
    if (!options.replace) {
      final plan = mergeSnapshots(current, incoming);
      final choices = await chooseConflicts(context, plan, words);
      if (choices == null || !context.mounted) return;
      incoming = plan.resolve(choices);
    }
  }
  if (options.replace && context.mounted) {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => ImportReviewDialog(
        words: words,
        fileName: selected.name,
        current: current,
        incoming: incoming,
        inboxOnly: inboxOnly,
      ),
    );
    if (confirmed != true || !context.mounted) return;
  }
  if (!context.mounted) return;
  if (repo.stateToken != expectedState) throw StateError(words['review']);
  if (options.replace) {
    repo.importSnapshot(incoming, replace: true, expectedState: expectedState);
  } else {
    repo.replaceAll(incoming, rememberUndo: true, expectedState: expectedState);
  }
  controller.refresh();
  if (context.mounted)
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(words['imported']),
        action: SnackBarAction(
          label: words['undo'],
          onPressed: () {
            repo.undoImport();
            controller.refresh();
          },
        ),
      ),
    );
}

class ImportReviewDialog extends StatelessWidget {
  final Words words;
  final String fileName;
  final JoySnapshot current;
  final JoySnapshot incoming;
  final bool inboxOnly;

  const ImportReviewDialog({
    super.key,
    required this.words,
    required this.fileName,
    required this.current,
    required this.incoming,
    this.inboxOnly = false,
  });

  int taskCount(JoySnapshot snapshot) => snapshot.records
      .where(
        (record) =>
            record.deletedAt == null &&
            ['item', 'project', 'action'].contains(record.kind) &&
            (!inboxOnly || record.parentId == 'inbox'),
      )
      .length;

  int folderCount(JoySnapshot snapshot) => snapshot.records
      .where(
        (record) =>
            record.deletedAt == null &&
            ['folder', 'subfolder'].contains(record.kind),
      )
      .length;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(words['replace']),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            words[inboxOnly ? 'importInbox' : 'import'],
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          Text(fileName),
          const SizedBox(height: 12),
          Text(
            '${words['count']}: ${taskCount(current)} → ${taskCount(incoming)}',
          ),
          if (!inboxOnly)
            Text(
              '${words['folders']}: ${folderCount(current)} → ${folderCount(incoming)}',
            ),
          const SizedBox(height: 16),
          Text(words['replaceWarning']),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context, false),
        child: Text(words['cancel']),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, true),
        child: Text(words['replace']),
      ),
    ],
  );
}

class ImportOptions {
  final bool replace;
  final bool header;
  final int titleColumn;
  final int? descriptionColumn;
  final int? dateColumn;
  const ImportOptions({
    this.replace = false,
    this.header = false,
    this.titleColumn = 0,
    this.descriptionColumn,
    this.dateColumn,
  });
}

class ImportDialog extends StatefulWidget {
  final Words words;
  final bool inboxOnly;
  const ImportDialog({super.key, required this.words, required this.inboxOnly});
  @override
  State<ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<ImportDialog> {
  bool replace = false;
  bool header = false;
  final title = TextEditingController(text: '1');
  final description = TextEditingController();
  final date = TextEditingController();
  final form = GlobalKey<FormState>();

  @override
  void dispose() {
    title.dispose();
    description.dispose();
    date.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    Widget columnField(
      TextEditingController value,
      String key, {
      bool required = false,
    }) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: TextFormField(
        controller: value,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: w[key]),
        validator: (v) {
          if ((v == null || v.trim().isEmpty) && !required) return null;
          final number = int.tryParse(v ?? '');
          return number == null || number < 1 ? w['required'] : null;
        },
      ),
    );
    return AlertDialog(
      title: Text(w['importMode']),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: false,
                      label: Text(w['add']),
                      icon: const Icon(Icons.add),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text(w['replace']),
                      icon: const Icon(Icons.swap_horiz),
                    ),
                  ],
                  selected: {replace},
                  onSelectionChanged: (v) => setState(() => replace = v.single),
                ),
                const SizedBox(height: 16),
                Text(w['mergeHint']),
                if (widget.inboxOnly) ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: header,
                    onChanged: (v) => setState(() => header = v ?? false),
                    title: Text(w['header']),
                  ),
                  columnField(title, 'titleColumn', required: true),
                  columnField(description, 'descriptionColumn'),
                  columnField(date, 'dateColumn'),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(w['cancel']),
        ),
        FilledButton(
          onPressed: () {
            if (!form.currentState!.validate()) return;
            Navigator.pop(
              context,
              ImportOptions(
                replace: replace,
                header: header,
                titleColumn: int.parse(title.text) - 1,
                descriptionColumn: int.tryParse(description.text) == null
                    ? null
                    : int.parse(description.text) - 1,
                dateColumn: int.tryParse(date.text) == null
                    ? null
                    : int.parse(date.text) - 1,
              ),
            );
          },
          child: Text(w['import']),
        ),
      ],
    );
  }
}

Future<Map<String, ConflictChoice>?> chooseConflicts(
  BuildContext context,
  MergePlan plan,
  Words words,
) async {
  if (plan.conflicts.isEmpty) return {};
  return showDialog<Map<String, ConflictChoice>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ConflictDialog(plan: plan, words: words),
  );
}

class ConflictDialog extends StatefulWidget {
  final MergePlan plan;
  final Words words;
  const ConflictDialog({super.key, required this.plan, required this.words});
  @override
  State<ConflictDialog> createState() => _ConflictDialogState();
}

class _ConflictDialogState extends State<ConflictDialog> {
  final choices = <String, ConflictChoice>{};
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.words['review']),
    content: SizedBox(
      width: 680,
      height: 440,
      child: ListView(
        children: [
          for (final conflict in widget.plan.conflicts)
            Card(
              child: RadioGroup<ConflictChoice>(
                groupValue: choices[conflict.id],
                onChanged: (v) {
                  if (v != null) setState(() => choices[conflict.id] = v);
                },
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conflict.local.title.isNotEmpty
                            ? conflict.local.title
                            : conflict.remote.title.isNotEmpty
                            ? conflict.remote.title
                            : conflict.id,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        conflict.changedFields.join(' · '),
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 8),
                      for (final option in [
                        ConflictChoice.local,
                        ConflictChoice.remote,
                      ]) ...[
                        RadioListTile<ConflictChoice>(
                          contentPadding: EdgeInsets.zero,
                          value: option,
                          enabled: option != conflict.blockedChoice,
                          title: Text(
                            widget.words[option == ConflictChoice.local
                                ? 'local'
                                : 'remote'],
                          ),
                          subtitle: Text(
                            _versionText(
                              option == ConflictChoice.local
                                  ? conflict.local
                                  : conflict.remote,
                              option == ConflictChoice.local
                                  ? widget.plan.local
                                  : widget.plan.remote,
                            ),
                          ),
                        ),
                      ],
                      if (conflict.dependentChildren.isNotEmpty) ...[
                        Text(widget.words['dependentChildren']),
                        Text(
                          conflict.dependentChildren
                              .map((r) => r.title)
                              .join(' · '),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(widget.words['cancel']),
      ),
      FilledButton(
        onPressed: choices.length == widget.plan.conflicts.length
            ? () => Navigator.pop(context, choices)
            : null,
        child: Text(widget.words['apply']),
      ),
    ],
  );

  String _versionText(JoyRecord record, JoySnapshot snapshot) {
    final byId = {for (final r in snapshot.records) r.id: r};
    final path = <String>[];
    final visited = <String>{};
    var parent = record.parentId;
    while (parent != null && visited.add(parent)) {
      final r = byId[parent];
      if (r == null) break;
      path.insert(0, folderLabel(r, widget.words));
      parent = r.parentId;
    }
    return [
      record.title,
      if (record.description.isNotEmpty) record.description,
      if (path.isNotEmpty) path.join(' / '),
      '${record.updatedAt} UTC',
      if (record.deletedAt != null)
        '${widget.words['delete']}: ${record.deletedAt}',
      for (final entry in record.data.entries)
        if (entry.key == 'embedding' && entry.value is Map)
          '${widget.words['graph']}: ${(entry.value as Map)['modelId'] ?? '—'} / ${(entry.value as Map)['revision'] ?? '—'} · ${((entry.value as Map)['vector'] as List?)?.length ?? 0}'
        else
          '${_fieldLabel(entry.key)}: ${entry.value is List && (entry.value as List).length > 12 ? '${(entry.value as List).take(12).join(', ')} … (${(entry.value as List).length})' : entry.value}',
    ].join('\n');
  }

  String _fieldLabel(String key) =>
      widget.words[{
            'plan': 'plan',
            'completionCriterion': 'criterion',
            'assignedTo': 'assignee',
            'dueAt': 'date',
            'scheduledAt': 'startsAt',
            'endsAt': 'endsAt',
            'priority': 'priority',
            'durationMinutes': 'duration',
            'draft': 'draft',
          }[key] ??
          key];
}

Future<void> showSync(
  BuildContext context,
  JoyController controller,
  Words words,
) => showDialog<void>(
  context: context,
  builder: (context) => SyncDialog(controller: controller, words: words),
);

class SyncDialog extends StatefulWidget {
  final JoyController controller;
  final Words words;
  const SyncDialog({super.key, required this.controller, required this.words});
  @override
  State<SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<SyncDialog> {
  PeerServer? server;
  final address = TextEditingController();
  final code = TextEditingController();
  List<String> addresses = [];
  String? status;
  bool busy = false;
  Timer? refresh;

  @override
  void dispose() {
    refresh?.cancel();
    server?.close();
    address.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      status = null;
    });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => status = e.toString());
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    return AlertDialog(
      title: Text(w['sync']),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(w['syncHelp']),
              const SizedBox(height: 16),
              if (server == null)
                OutlinedButton.icon(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                          final running = await PeerServer.start(
                            widget.controller.repository,
                          );
                          final interfaces = await NetworkInterface.list(
                            type: InternetAddressType.IPv4,
                          );
                          if (!mounted) {
                            await running.close();
                            return;
                          }
                          setState(() {
                            server = running;
                            addresses = interfaces
                                .expand((i) => i.addresses)
                                .map(
                                  (a) => 'http://${a.address}:${running.port}',
                                )
                                .toList();
                          });
                          refresh = Timer.periodic(
                            const Duration(seconds: 2),
                            (_) => widget.controller.refresh(),
                          );
                        }),
                  icon: const Icon(Icons.wifi_tethering),
                  label: Text(w['nearby']),
                )
              else ...[
                SelectableText(
                  addresses.isEmpty
                      ? 'http://<local-IP>:${server!.port}'
                      : addresses.join('\n'),
                ),
                const SizedBox(height: 8),
                Text(
                  '${w['code']}: ${server!.pairingCode}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                TextButton(
                  onPressed: () => run(() async {
                    refresh?.cancel();
                    await server!.close();
                    if (mounted) setState(() => server = null);
                  }),
                  child: Text(w['stop']),
                ),
              ],
              const Divider(height: 32),
              TextField(
                controller: address,
                decoration: InputDecoration(
                  labelText: w['address'],
                  hintText: 'http://192.168.1.20:8765',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: code,
                decoration: InputDecoration(labelText: w['code']),
              ),
              const SizedBox(height: 8),
              Text(
                w['syncAddressHelp'],
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        final uri = Uri.tryParse(address.text.trim());
                        if (uri == null ||
                            uri.host.isEmpty ||
                            uri.scheme != 'http')
                          throw FormatException(w['address']);
                        final session = await PeerClient().preview(
                          uri,
                          code.text.trim(),
                          widget.controller.repository.snapshot(),
                        );
                        if (!mounted) return;
                        final choices = await chooseConflicts(
                          context,
                          session.plan,
                          w,
                        );
                        if (choices == null || !mounted) return;
                        if (session.plan.conflicts.isEmpty) {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(w['sync']),
                              content: Text(w['noConflicts']),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: Text(w['cancel']),
                                ),
                                FilledButton(
                                  onPressed: () => Navigator.pop(context, true),
                                  child: Text(w['apply']),
                                ),
                              ],
                            ),
                          );
                          if (confirmed != true) return;
                        }
                        await session.commit(
                          widget.controller.repository,
                          choices,
                        );
                        widget.controller.refresh();
                        if (mounted) setState(() => status = w['syncComplete']);
                      }),
                icon: const Icon(Icons.sync),
                label: Text(w['connect']),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: LinearProgressIndicator(),
                ),
              if (status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(status!),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(w['close']),
        ),
      ],
    );
  }
}
