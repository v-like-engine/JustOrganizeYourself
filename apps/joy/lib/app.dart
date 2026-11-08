import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:joy_core/joy_core.dart';
import 'controller.dart';
import 'l10n.dart';
import 'features/editors.dart';
import 'features/exchange.dart';
import 'features/triage.dart';
import 'features/knowledge_graph.dart';

class JoyApp extends StatelessWidget {
  final JoyController controller;
  const JoyApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => MaterialApp(
      title: 'Just Organize Yourself',
      debugShowCheckedModeBanner: false,
      locale: Locale(controller.locale),
      supportedLocales: languageNames.keys.map((l) => Locale(l)).toList(),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff326c57),
          surface: const Color(0xfff8f9f5),
        ),
        scaffoldBackgroundColor: const Color(0xfff8f9f5),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          color: Colors.white,
          margin: const EdgeInsets.symmetric(vertical: 5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xffe3e7df)),
          ),
        ),
        dialogTheme: DialogThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
        ),
      ),
      home: Workspace(controller: controller),
    ),
  );
}

class Workspace extends StatefulWidget {
  final JoyController controller;
  const Workspace({super.key, required this.controller});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> with WidgetsBindingObserver {
  bool graph = false;
  Timer? cleanup;
  Words get w => Words(widget.controller.locale);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    cleanup = Timer.periodic(const Duration(hours: 1), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed)
        purgeTrash();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) purgeTrash();
  }

  void purgeTrash() {
    if (!mounted) return;
    try {
      if (widget.controller.repository.purgeTrash() > 0)
        widget.controller.refresh();
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  void dispose() {
    cleanup?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> beginProcessing() => safely(() async {
    final c = widget.controller;
    if ((c.settings['triageMenus'] as Map?)?.isEmpty ?? true)
      await configureTriage(context, c, w);
    if (!mounted) return;
    c.processing = true;
    c.refresh();
  });

  Future<void> safely(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString()),
            duration: const Duration(seconds: 6),
          ),
        );
    }
  }

  Future<void> openFolder(String id) async {
    setState(() => graph = false);
    widget.controller.select(id);
    if (id == 'projects' && widget.controller.projectDrafts.isNotEmpty)
      await completeProjects();
  }

  Future<void> completeProjects() async {
    while (mounted && widget.controller.projectDrafts.isNotEmpty) {
      final next = widget.controller.projectDrafts.first;
      final saved = await editProject(
        context,
        widget.controller,
        w,
        record: next,
      );
      if (!saved) break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 940;
        final title = graph
            ? w['graph']
            : c.selectedFolder == null
            ? w['inbox']
            : folderLabel(c.selectedFolder!, w);
        final navigation = _navigation(closeOnSelect: !wide);
        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            backgroundColor: Colors.transparent,
            actions: [
              if (c.repository.canUndoImport)
                IconButton(
                  tooltip: w['undo'],
                  onPressed: () {
                    c.repository.undoImport();
                    c.refresh();
                  },
                  icon: const Icon(Icons.undo),
                ),
              if (c.folderId == 'inbox' && !c.processing && !graph)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: constraints.maxWidth < 600
                      ? IconButton(
                          tooltip: w['process'],
                          onPressed: c.inbox.isEmpty ? null : beginProcessing,
                          icon: const Icon(Icons.style_outlined),
                        )
                      : TextButton.icon(
                          onPressed: c.inbox.isEmpty ? null : beginProcessing,
                          icon: const Icon(Icons.style_outlined),
                          label: Text(w['process']),
                        ),
                ),
              PopupMenuButton<String>(
                tooltip: w['exchange'],
                onSelected: (value) => safely(() async {
                  switch (value) {
                    case 'export':
                      await exportWorkbook(c);
                    case 'import':
                      await importWorkbook(context, c, w);
                    case 'importInbox':
                      await importWorkbook(context, c, w, inboxOnly: true);
                    case 'calendar':
                      await exportCalendar(c);
                    case 'sync':
                      await showSync(context, c, w);
                    case 'settings':
                      await showSettings(context, c, w);
                  }
                }),
                itemBuilder: (context) => [
                  for (final entry in [
                    ('export', 'export'),
                    ('import', 'import'),
                    ('importInbox', 'importInbox'),
                    ('calendar', 'exportCalendar'),
                    ('sync', 'sync'),
                    ('settings', 'settings'),
                  ])
                    PopupMenuItem(value: entry.$1, child: Text(w[entry.$2])),
                ],
              ),
            ],
          ),
          drawer: wide ? null : Drawer(child: SafeArea(child: navigation)),
          body: SafeArea(
            top: false,
            child: Row(
              children: [
                if (wide) SizedBox(width: 236, child: navigation),
                if (wide) const VerticalDivider(width: 1),
                Expanded(
                  child: graph
                      ? KnowledgeGraph(controller: c, words: w)
                      : c.processing
                      ? TriageView(controller: c, words: w)
                      : c.folderId == 'inbox'
                      ? InboxView(
                          controller: c,
                          words: w,
                          onOpen: (r) => safely(() async {
                            await editItem(context, c, w, record: r);
                          }),
                          onMenu: _itemAction,
                        )
                      : _folderView(),
                ),
              ],
            ),
          ),
          floatingActionButton: c.folderId == 'inbox' || c.processing || graph
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => safely(() async {
                    await editItem(context, c, w, parentId: c.destination);
                  }),
                  icon: const Icon(Icons.add),
                  label: Text(w['add']),
                ),
        );
      },
    );
  }

  Widget _navigation({required bool closeOnSelect}) {
    final c = widget.controller;
    return Material(
      color: const Color(0xffeef1e9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 12, 22),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xff326c57),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.spa_outlined, color: Colors.white),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Just Organize\nYourself',
                    style: TextStyle(fontWeight: FontWeight.w600, height: 1.3),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    w['folders'],
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                IconButton(
                  tooltip: w['newFolder'],
                  visualDensity: VisualDensity.compact,
                  onPressed: () => safely(() async {
                    await editFolder(context, c, w);
                  }),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (final folder in c.folders)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: ListTile(
                      dense: true,
                      selected: !graph && c.folderId == folder.id,
                      selectedTileColor: const Color(0xffdce7d7),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      leading: Icon(folderIcon(folder.id), size: 21),
                      title: Text(folderLabel(folder, w), maxLines: 2),
                      onTap: () {
                        if (closeOnSelect) Navigator.of(context).pop();
                        safely(() => openFolder(folder.id));
                      },
                      trailing: PopupMenuButton<String>(
                        tooltip: w['edit'],
                        padding: EdgeInsets.zero,
                        onSelected: (action) => safely(() async {
                          if (action == 'edit')
                            await editFolder(context, c, w, record: folder);
                          if (action == 'up') c.reorder(folder, -1);
                          if (action == 'down') c.reorder(folder, 1);
                          if (action == 'delete') {
                            c.repository.delete(folder.id);
                            c.refresh();
                          }
                        }),
                        itemBuilder: (context) => [
                          for (final item in [
                            ('edit', 'edit'),
                            ('up', 'moveUp'),
                            ('down', 'moveDown'),
                            ('delete', 'delete'),
                          ])
                            PopupMenuItem(
                              value: item.$1,
                              child: Text(w[item.$2]),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: Text(w['graph']),
            selected: graph,
            onTap: () {
              if (closeOnSelect) Navigator.pop(context);
              setState(() => graph = true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.sync),
            title: Text(w['sync']),
            onTap: () => safely(() async {
              if (closeOnSelect) Navigator.pop(context);
              await showSync(context, c, w);
            }),
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: Text(w['settings']),
            onTap: () => safely(() async {
              if (closeOnSelect) Navigator.pop(context);
              await showSettings(context, c, w);
            }),
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _folderView() {
    final c = widget.controller;
    final description = c.selectedFolder?.description ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (description.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        SizedBox(
          height: 62,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(folderLabel(c.selectedFolder!, w)),
                  selected: c.subfolderId == null,
                  onSelected: (_) => c.select(c.folderId),
                ),
              ),
              for (final child in c.subfolders)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(
                    children: [
                      ChoiceChip(
                        label: Text(child.title),
                        selected: c.subfolderId == child.id,
                        onSelected: (_) =>
                            c.select(c.folderId, child: child.id),
                      ),
                      PopupMenuButton<String>(
                        tooltip: w['edit'],
                        onSelected: (action) => safely(() async {
                          if (action == 'edit')
                            await editFolder(context, c, w, record: child);
                          if (action == 'up') c.reorder(child, -1);
                          if (action == 'down') c.reorder(child, 1);
                          if (action == 'delete') {
                            c.repository.delete(child.id);
                            if (c.subfolderId == child.id) c.subfolderId = null;
                            c.refresh();
                          }
                        }),
                        itemBuilder: (_) => [
                          for (final entry in [
                            ('edit', 'edit'),
                            ('up', 'moveUp'),
                            ('down', 'moveDown'),
                            ('delete', 'delete'),
                          ])
                            PopupMenuItem(
                              value: entry.$1,
                              child: Text(w[entry.$2]),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 18),
                label: Text(w['newSubfolder']),
                onPressed: () => safely(() async {
                  await editFolder(context, c, w, parentId: c.folderId);
                }),
              ),
            ],
          ),
        ),
        if (c.folderId == 'projects' && c.projectDrafts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: OutlinedButton.icon(
              onPressed: () => safely(completeProjects),
              icon: const Icon(Icons.edit_note),
              label: Text(
                '${w['pendingProjects']} (${c.projectDrafts.length})',
              ),
            ),
          ),
        Expanded(
          child: c.items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(w['empty'], textAlign: TextAlign.center),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 100),
                  itemCount: c.items.length,
                  itemBuilder: (context, index) {
                    final item = c.items[index];
                    return ItemCard(
                      record: item,
                      controller: c,
                      words: w,
                      onTap: () => safely(() async {
                        await editItem(context, c, w, record: item);
                      }),
                      onAction: (action) => _itemAction(item, action),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _itemAction(JoyRecord item, String action) => safely(() async {
    final c = widget.controller;
    switch (action) {
      case 'edit':
        await editItem(context, c, w, record: item);
      case 'move':
        final target = await chooseDestination(context, c, w);
        if (target == null || !mounted) return;
        if (target == 'trash') {
          c.repository.trash(item.id);
        } else if (c.isWithin(target, 'projects') ||
            c.isWithin(target, 'calendar') ||
            c.isWithin(target, 'delegated') ||
            c.isWithin(target, 'by-date') ||
            c.isWithin(target, 'conditional')) {
          await editItem(context, c, w, record: item, parentId: target);
        } else {
          c.repository.move(item.id, target);
        }
      case 'delete':
        final yes = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(w['confirmDelete']),
            content: Text(item.title),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(w['cancel']),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(w['trash']),
              ),
            ],
          ),
        );
        if (yes == true) c.repository.trash(item.id);
      case 'restore':
        c.repository.restore(item.id);
      case 'up':
        c.reorder(item, -1);
      case 'down':
        c.reorder(item, 1);
    }
    c.refresh();
  });
}

class InboxView extends StatefulWidget {
  final JoyController controller;
  final Words words;
  final ValueChanged<JoyRecord> onOpen;
  final void Function(JoyRecord, String) onMenu;
  const InboxView({
    super.key,
    required this.controller,
    required this.words,
    required this.onOpen,
    required this.onMenu,
  });
  @override
  State<InboxView> createState() => _InboxViewState();
}

class _InboxViewState extends State<InboxView> {
  final text = TextEditingController();
  final description = TextEditingController();
  final focus = FocusNode();
  bool showDescription = false;
  String? error;

  @override
  void dispose() {
    text.dispose();
    description.dispose();
    focus.dispose();
    super.dispose();
  }

  void submit() {
    if (text.text.trim().isEmpty) return;
    try {
      widget.controller.capture(text.text, description.text);
      text.clear();
      description.clear();
      setState(() {
        error = null;
        showDescription = false;
      });
      focus.requestFocus();
    } catch (e) {
      setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    final c = widget.controller;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 500;
        final suggestions = c.suggestions(text.text);
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, compact ? 8 : 42, 20, 12),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 740),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (!compact) ...[
                        Text(
                          w['capture'],
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 28),
                      ],
                      Text(
                        w['push'],
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 10),
                      CallbackShortcuts(
                        key: const ValueKey('capture-shortcuts'),
                        bindings: {
                          const SingleActivator(LogicalKeyboardKey.enter):
                              submit,
                          const SingleActivator(LogicalKeyboardKey.numpadEnter):
                              submit,
                        },
                        child: TextField(
                          key: const ValueKey('inbox-composer'),
                          controller: text,
                          focusNode: focus,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.send,
                          onChanged: (_) => setState(() {}),
                          onSubmitted: (_) => submit(),
                          decoration: InputDecoration(
                            hintText: w['placeholder'],
                            contentPadding: const EdgeInsets.all(22),
                            suffixIcon: IconButton(
                              tooltip: w['send'],
                              onPressed: submit,
                              icon: const Icon(Icons.arrow_upward_rounded),
                            ),
                          ),
                          onEditingComplete: submit,
                        ),
                      ),
                      if (showDescription && !compact) ...[
                        const SizedBox(height: 10),
                        TextField(
                          controller: description,
                          maxLines: 2,
                          decoration: InputDecoration(
                            labelText: w['description'],
                          ),
                        ),
                      ],
                      if (!compact)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => setState(
                              () => showDescription = !showDescription,
                            ),
                            icon: Icon(
                              showDescription ? Icons.remove : Icons.add,
                              size: 16,
                            ),
                            label: Text(w['description']),
                          ),
                        ),
                      if (suggestions.isNotEmpty &&
                          constraints.maxHeight > 260) ...[
                        Text(
                          w['similar'],
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                        const SizedBox(height: 4),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight: compact ? 90 : 130,
                          ),
                          child: Material(
                            color: const Color(0xffeef2e9),
                            borderRadius: BorderRadius.circular(12),
                            clipBehavior: Clip.antiAlias,
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: suggestions.length,
                              itemBuilder: (context, index) {
                                final item = suggestions[index];
                                final parent = c.repository.get(
                                  item.parentId ?? '',
                                );
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.history, size: 18),
                                  title: Text(
                                    item.title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: parent == null
                                      ? null
                                      : Text(folderLabel(parent, w)),
                                  onTap: () {
                                    text.clear();
                                    description.clear();
                                    setState(() {});
                                    focus.requestFocus();
                                  },
                                );
                              },
                            ),
                          ),
                        ),
                      ],
                      if (error != null)
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: c.inbox.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          w['empty'],
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                    )
                  : ListView.builder(
                      key: const ValueKey('inbox-items'),
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                      itemCount: c.inbox.length,
                      itemBuilder: (context, index) {
                        final record = c.inbox[index];
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 740),
                            child: ItemCard(
                              record: record,
                              controller: c,
                              words: w,
                              onTap: () => widget.onOpen(record),
                              onAction: (action) =>
                                  widget.onMenu(record, action),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class ItemCard extends StatelessWidget {
  final JoyRecord record;
  final JoyController controller;
  final Words words;
  final VoidCallback onTap;
  final ValueChanged<String> onAction;
  const ItemCard({
    super.key,
    required this.record,
    required this.controller,
    required this.words,
    required this.onTap,
    required this.onAction,
  });
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      leading: Icon(
        record.kind == 'project'
            ? Icons.account_tree_outlined
            : Icons.radio_button_unchecked,
        color: const Color(0xff6c8275),
      ),
      title: Text(record.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (record.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                record.description,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 5),
          Text(
            '#${controller.repository.ordinalOf(record.id) ?? '—'} · ${record.createdAt.replaceAll('T', ' ').split('.').first.replaceAll('Z', '')} UTC',
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: const Color(0xff748071)),
          ),
          if (record.data['draft'] == true)
            Text(
              words['draft'],
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          if (record.data['assignedTo'] != null)
            Text('${words['assignee']}: ${record.data['assignedTo']}'),
          if (record.data['scheduledAt'] != null)
            Text('${words['date']}: ${record.data['scheduledAt']}'),
        ],
      ),
      onTap: onTap,
      trailing: PopupMenuButton<String>(
        tooltip: words['details'],
        onSelected: onAction,
        itemBuilder: (_) => [
          for (final e in [
            ('edit', 'edit'),
            ('move', 'move'),
            ('up', 'moveUp'),
            ('down', 'moveDown'),
            if (record.parentId == 'trash')
              ('restore', 'back')
            else
              ('delete', 'trash'),
          ])
            PopupMenuItem(value: e.$1, child: Text(words[e.$2])),
        ],
      ),
    ),
  );
}

Future<void> showSettings(
  BuildContext context,
  JoyController controller,
  Words words,
) => showDialog<void>(
  context: context,
  builder: (context) => SettingsDialog(controller: controller, words: words),
);

class SettingsDialog extends StatefulWidget {
  final JoyController controller;
  final Words words;
  const SettingsDialog({
    super.key,
    required this.controller,
    required this.words,
  });
  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late String locale = widget.controller.locale;
  late final retention = TextEditingController(
    text: '${widget.controller.settings['trashDays'] ?? 30}',
  );
  late final embedding = TextEditingController(
    text:
        widget.controller.settings['embeddingUrl'] as String? ??
        'http://127.0.0.1:8766',
  );
  final form = GlobalKey<FormState>();
  String? error;
  @override
  void dispose() {
    retention.dispose();
    embedding.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    return AlertDialog(
      title: Text(w['settings']),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: locale,
                  decoration: InputDecoration(labelText: w['language']),
                  items: languageNames.entries
                      .map(
                        (e) => DropdownMenuItem(
                          value: e.key,
                          child: Text(e.value),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() => locale = v!),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: retention,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: w['trashDays']),
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return n == null || n < 1 ? w['required'] : null;
                  },
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: embedding,
                  decoration: InputDecoration(labelText: w['embeddingUrl']),
                  validator: (v) {
                    final uri = Uri.tryParse(v ?? '');
                    return uri == null ||
                            !['http', 'https'].contains(uri.scheme) ||
                            uri.host.isEmpty
                        ? w['required']
                        : null;
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () =>
                      configureTriage(context, widget.controller, w),
                  icon: const Icon(Icons.tune),
                  label: Text(w['configure']),
                ),
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
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
            try {
              widget.controller.saveSettings({
                'locale': locale,
                'trashDays': int.parse(retention.text),
                'embeddingUrl': embedding.text.trim(),
              });
              widget.controller.repository.purgeTrash();
              widget.controller.refresh();
              Navigator.pop(context);
            } catch (e) {
              setState(() => error = e.toString());
            }
          },
          child: Text(w['save']),
        ),
      ],
    );
  }
}

IconData folderIcon(String id) => switch (id) {
  'inbox' => Icons.inbox_outlined,
  'projects' => Icons.account_tree_outlined,
  'knowledge' => Icons.auto_stories_outlined,
  'contacts' => Icons.people_outline,
  'shopping' => Icons.shopping_bag_outlined,
  'calendar' => Icons.calendar_today_outlined,
  'delegated' => Icons.send_outlined,
  'trash' => Icons.delete_outline,
  'urgent' => Icons.bolt_outlined,
  _ => Icons.folder_outlined,
};
