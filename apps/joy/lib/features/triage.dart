import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:joy_core/joy_core.dart';
import '../controller.dart';
import '../l10n.dart';
import 'editors.dart';

Map<String, dynamic> triageMenus(JoyController controller, Words words) {
  final saved = controller.settings['triageMenus'];
  if (saved is Map && saved.isNotEmpty)
    return jsonDecode(jsonEncode(saved)) as Map<String, dynamic>;
  Map<String, dynamic> destination(String id) => {
    'type': 'destination',
    'targetId': id,
  };
  final shopping = controller.records
      .where((r) => r.kind == 'subfolder' && r.parentId == 'shopping')
      .toList();
  return {
    'root': {
      'label': words['inbox'],
      'bindings': {
        '7': destination('projects'),
        '8': destination('knowledge'),
        '9': destination('contacts'),
        '4': shopping.isEmpty
            ? destination('shopping')
            : {'type': 'menu', 'targetId': 'shopping'},
        '5': {'type': 'details'},
        '6': {'type': 'menu', 'targetId': 'more'},
        '1': destination('calendar'),
        '2': destination('trash'),
        '3': destination('delegated'),
      },
    },
    'more': {
      'label': words['folders'],
      'bindings': {
        '7': destination('someday'),
        '8': destination('urgent'),
        '9': destination('by-date'),
        '4': destination('conditional'),
        '5': {'type': 'edit'},
        '6': destination('shopping'),
      },
    },
    if (shopping.isNotEmpty)
      'shopping': {
        'label': words['shopping'],
        'bindings': {
          for (var i = 0; i < math.min(shopping.length, 8); i++)
            '${[7, 8, 9, 4, 6, 1, 2, 3][i]}': destination(shopping[i].id),
          '5': destination('shopping'),
        },
      },
  };
}

class TriageView extends StatefulWidget {
  final JoyController controller;
  final Words words;
  const TriageView({super.key, required this.controller, required this.words});
  @override
  State<TriageView> createState() => _TriageViewState();
}

class _TriageViewState extends State<TriageView> {
  final path = <String>['root'];
  String? failure;
  bool busy = false;
  final focus = FocusNode();

  @override
  void dispose() {
    focus.dispose();
    super.dispose();
  }

  String bindingLabel(Map binding) {
    final w = widget.words;
    if (binding['label'] is String && (binding['label'] as String).isNotEmpty)
      return binding['label'];
    if (binding['type'] == 'menu') {
      final menus = triageMenus(widget.controller, w);
      return (menus[binding['targetId']] as Map?)?['label']?.toString() ??
          w['submenu'];
    }
    if (binding['type'] == 'destination') {
      final record = widget.controller.repository.get(
        binding['targetId']?.toString() ?? '',
      );
      return record == null ||
              record.deletedAt != null ||
              widget.controller.isWithin(record.parentId, 'trash')
          ? '— · ${w['configure']}'
          : folderLabel(record, w);
    }
    return w[binding['type']?.toString() ?? 'action'];
  }

  Future<void> dispatch(String number) async {
    if (busy || widget.controller.inbox.isEmpty) return;
    final menus = triageMenus(widget.controller, widget.words);
    final menu = menus[path.last] as Map? ?? menus['root'] as Map;
    final binding = (menu['bindings'] as Map? ?? {})[number] as Map?;
    if (binding == null) return;
    final record = widget.controller.inbox.first;
    setState(() {
      busy = true;
      failure = null;
    });
    try {
      switch (binding['type']) {
        case 'menu':
          final target = binding['targetId'] as String?;
          if (target == null || !menus.containsKey(target))
            throw StateError(widget.words['submenu']);
          setState(() => path.add(target));
        case 'details':
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(record.title),
              content: SingleChildScrollView(
                child: Text(
                  record.description.isEmpty ? '—' : record.description,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(widget.words['close']),
                ),
              ],
            ),
          );
        case 'edit':
          await editItem(
            context,
            widget.controller,
            widget.words,
            record: record,
          );
        case 'destination':
          final target = binding['targetId'] as String;
          final destination = widget.controller.repository.get(target);
          if (destination == null ||
              destination.deletedAt != null ||
              widget.controller.isWithin(destination.parentId, 'trash'))
            throw StateError(widget.words['configure']);
          if (widget.controller.isWithin(target, 'calendar') ||
              widget.controller.isWithin(target, 'delegated') ||
              widget.controller.isWithin(target, 'by-date') ||
              widget.controller.isWithin(target, 'conditional')) {
            await editItem(
              context,
              widget.controller,
              widget.words,
              record: record,
              parentId: target,
            );
          } else if (target == 'trash') {
            widget.controller.repository.trash(record.id);
          } else {
            widget.controller.repository.move(record.id, target);
          }
          widget.controller.refresh();
          setState(() {
            path.clear();
            path.add('root');
          });
      }
    } catch (e) {
      if (mounted) setState(() => failure = e.toString());
    }
    if (mounted) {
      setState(() => busy = false);
      focus.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final w = widget.words;
    final entries = c.inbox;
    final menus = triageMenus(c, w);
    final currentMenu = menus[path.last] as Map? ?? menus['root'] as Map;
    final bindings = currentMenu['bindings'] as Map? ?? {};
    final numberKeys = {
      LogicalKeyboardKey.numpad1: '1',
      LogicalKeyboardKey.numpad2: '2',
      LogicalKeyboardKey.numpad3: '3',
      LogicalKeyboardKey.numpad4: '4',
      LogicalKeyboardKey.numpad5: '5',
      LogicalKeyboardKey.numpad6: '6',
      LogicalKeyboardKey.numpad7: '7',
      LogicalKeyboardKey.numpad8: '8',
      LogicalKeyboardKey.numpad9: '9',
      LogicalKeyboardKey.digit1: '1',
      LogicalKeyboardKey.digit2: '2',
      LogicalKeyboardKey.digit3: '3',
      LogicalKeyboardKey.digit4: '4',
      LogicalKeyboardKey.digit5: '5',
      LogicalKeyboardKey.digit6: '6',
      LogicalKeyboardKey.digit7: '7',
      LogicalKeyboardKey.digit8: '8',
      LogicalKeyboardKey.digit9: '9',
    };
    return Focus(
      autofocus: true,
      focusNode: focus,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final editingContext = FocusManager.instance.primaryFocus?.context;
        if (editingContext?.findAncestorStateOfType<EditableTextState>() !=
            null)
          return KeyEventResult.ignored;
        final number = numberKeys[event.logicalKey];
        if (number == null) return KeyEventResult.ignored;
        dispatch(number);
        return KeyEventResult.handled;
      },
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 660),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Row(
                      children: [
                        TextButton.icon(
                          onPressed: () {
                            c.processing = false;
                            c.refresh();
                          },
                          icon: const Icon(Icons.arrow_back),
                          label: Text(w['back']),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: w['configure'],
                          onPressed: () async {
                            await configureTriage(context, c, w);
                            if (mounted)
                              setState(() {
                                path.clear();
                                path.add('root');
                              });
                          },
                          icon: const Icon(Icons.tune),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (entries.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 64),
                        child: Column(
                          children: [
                            const Icon(Icons.check_circle_outline, size: 64),
                            const SizedBox(height: 16),
                            Text(
                              w['clear'],
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                          ],
                        ),
                      )
                    else ...[
                      Text(
                        '${remainingLabel(entries.length)} ${w['remaining']}',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 18),
                      _SwipeCard(
                        record: entries.first,
                        onDirection: dispatch,
                        onTap: () => dispatch('5'),
                        number: c.repository.ordinalOf(entries.first.id),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          if (path.length > 1)
                            IconButton(
                              tooltip: w['back'],
                              onPressed: () =>
                                  setState(() => path.removeLast()),
                              icon: const Icon(Icons.arrow_back),
                            ),
                          Expanded(
                            child: Text(
                              path
                                  .map(
                                    (p) =>
                                        (menus[p] as Map?)?['label']
                                            ?.toString() ??
                                        p,
                                  )
                                  .join(' / '),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: 440,
                        child: GridView.count(
                          crossAxisCount: 3,
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          childAspectRatio: 1.65,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          children: [
                            for (final key in [
                              '7',
                              '8',
                              '9',
                              '4',
                              '5',
                              '6',
                              '1',
                              '2',
                              '3',
                            ])
                              OutlinedButton(
                                onPressed: bindings[key] == null || busy
                                    ? null
                                    : () => dispatch(key),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.all(6),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      key,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.labelSmall,
                                    ),
                                    const SizedBox(height: 3),
                                    Flexible(
                                      child: Text(
                                        bindings[key] == null
                                            ? '—'
                                            : bindingLabel(
                                                bindings[key] as Map,
                                              ),
                                        textAlign: TextAlign.center,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        w['triageHint'],
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (failure != null)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            failure!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeCard extends StatefulWidget {
  final JoyRecord record;
  final int? number;
  final ValueChanged<String> onDirection;
  final VoidCallback onTap;
  const _SwipeCard({
    required this.record,
    required this.onDirection,
    required this.onTap,
    this.number,
  });
  @override
  State<_SwipeCard> createState() => _SwipeCardState();
}

class _SwipeCardState extends State<_SwipeCard> {
  Offset drag = Offset.zero;
  Offset origin = Offset.zero;
  int? pointer;

  void finish(Offset position) {
    final offset = position - origin;
    setState(() {
      drag = Offset.zero;
      pointer = null;
    });
    if (offset.distance < 45) {
      widget.onTap();
      return;
    }
    final angle = (math.atan2(offset.dy, offset.dx) / (math.pi / 4)).round();
    widget.onDirection(
      {
        0: '6',
        1: '3',
        2: '2',
        3: '1',
        4: '4',
        -4: '4',
        -3: '7',
        -2: '8',
        -1: '9',
      }[angle]!,
    );
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    onTap: widget.onTap,
    child: RawGestureDetector(
      behavior: HitTestBehavior.opaque,
      gestures: {
        EagerGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
              () => EagerGestureRecognizer(),
              (_) {},
            ),
      },
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (pointer == null) {
            pointer = event.pointer;
            origin = event.position;
            drag = Offset.zero;
          }
        },
        onPointerMove: (event) {
          if (event.pointer == pointer)
            setState(() => drag = event.position - origin);
        },
        onPointerUp: (event) {
          if (event.pointer == pointer) finish(event.position);
        },
        onPointerCancel: (event) {
          if (event.pointer == pointer)
            setState(() {
              pointer = null;
              drag = Offset.zero;
            });
        },
        child: Transform.translate(
          offset: drag * .25,
          child: Card(
            elevation: 1,
            color: Theme.of(context).colorScheme.surface,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 150),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '#${widget.number ?? '—'}',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.record.title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (widget.record.description.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        widget.record.description,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> configureTriage(
  BuildContext context,
  JoyController controller,
  Words words,
) => showDialog<void>(
  context: context,
  builder: (context) => TriageSettings(controller: controller, words: words),
);

class TriageSettings extends StatefulWidget {
  final JoyController controller;
  final Words words;
  const TriageSettings({
    super.key,
    required this.controller,
    required this.words,
  });
  @override
  State<TriageSettings> createState() => _TriageSettingsState();
}

class _TriageSettingsState extends State<TriageSettings> {
  late Map<String, dynamic> menus = triageMenus(
    widget.controller,
    widget.words,
  );
  String selected = 'root';
  String? failure;
  @override
  Widget build(BuildContext context) {
    final w = widget.words;
    final menu = menus[selected] as Map;
    final bindings = menu['bindings'] as Map;
    return AlertDialog(
      title: Text(w['configure']),
      content: SizedBox(
        width: 550,
        height: 440,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: selected,
                    decoration: InputDecoration(labelText: w['menuName']),
                    items: menus.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text((e.value as Map)['label'].toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => selected = v!),
                  ),
                ),
                IconButton(
                  tooltip: w['newMenu'],
                  onPressed: () async {
                    final text = TextEditingController();
                    final name = await showClosedDialog<String>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(w['newMenu']),
                        content: TextField(controller: text, autofocus: true),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(w['cancel']),
                          ),
                          FilledButton(
                            onPressed: () {
                              if (text.text.trim().isNotEmpty)
                                Navigator.pop(context, text.text.trim());
                            },
                            child: Text(w['add']),
                          ),
                        ],
                      ),
                    );
                    text.dispose();
                    if (name != null && mounted)
                      setState(() {
                        selected =
                            'menu-${DateTime.now().microsecondsSinceEpoch}';
                        menus[selected] = {
                          'label': name,
                          'bindings': <String, dynamic>{},
                        };
                      });
                  },
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (final key in [
                    '7',
                    '8',
                    '9',
                    '4',
                    '5',
                    '6',
                    '1',
                    '2',
                    '3',
                  ])
                    ListTile(
                      leading: CircleAvatar(radius: 16, child: Text(key)),
                      title: Text(_label(bindings[key] as Map?)),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () async {
                        final result = await _binding(
                          context,
                          bindings[key] as Map?,
                        );
                        if (result != null && mounted)
                          setState(() => bindings[key] = result);
                      },
                    ),
                ],
              ),
            ),
            if (failure != null)
              Text(
                failure!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(w['cancel']),
        ),
        FilledButton(
          onPressed: () {
            try {
              widget.controller.saveSettings({'triageMenus': menus});
              Navigator.pop(context);
            } catch (e) {
              setState(() => failure = e.toString());
            }
          },
          child: Text(w['save']),
        ),
      ],
    );
  }

  String _label(Map? binding) {
    if (binding == null) return '—';
    if (binding['type'] == 'destination') {
      final r = widget.controller.repository.get(
        binding['targetId']?.toString() ?? '',
      );
      return r == null ? '—' : folderLabel(r, widget.words);
    }
    if (binding['type'] == 'menu')
      return (menus[binding['targetId']] as Map?)?['label']?.toString() ?? '—';
    return widget.words[binding['type']?.toString() ?? 'action'];
  }

  Future<Map<String, dynamic>?> _binding(BuildContext context, Map? existing) {
    var type = existing?['type'] as String? ?? 'destination';
    String? target = existing?['targetId'] as String?;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) {
          final targets = type == 'menu'
              ? {
                  for (final entry in menus.entries)
                    entry.key: (entry.value as Map)['label'].toString(),
                }
              : {
                  for (final folder in widget.controller.folders) ...{
                    folder.id: folderLabel(folder, widget.words),
                    for (final child in widget.controller.records.where(
                      (r) => r.kind == 'subfolder' && r.parentId == folder.id,
                    ))
                      child.id:
                          '${folderLabel(folder, widget.words)} / ${child.title}',
                  },
                };
          if (!targets.containsKey(target)) target = targets.keys.firstOrNull;
          return AlertDialog(
            title: Text(widget.words['action']),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: type,
                    items: ['destination', 'menu', 'details', 'edit']
                        .map(
                          (t) => DropdownMenuItem(
                            value: t,
                            child: Text(
                              widget.words[t == 'menu' ? 'submenu' : t],
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => change(() {
                      type = v!;
                      target = null;
                    }),
                  ),
                  if (type == 'destination' || type == 'menu') ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: ValueKey(type),
                      initialValue: target,
                      isExpanded: true,
                      items: targets.entries
                          .map(
                            (e) => DropdownMenuItem(
                              value: e.key,
                              child: Text(
                                e.value,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => change(() => target = v),
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(widget.words['cancel']),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, <String, dynamic>{
                  'type': type,
                  if (type == 'destination' || type == 'menu')
                    'targetId': target,
                }),
                child: Text(widget.words['save']),
              ),
            ],
          );
        },
      ),
    );
  }
}
