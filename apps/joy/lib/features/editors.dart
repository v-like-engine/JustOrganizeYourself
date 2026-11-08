import 'package:flutter/material.dart';
import 'package:joy_core/joy_core.dart';
import '../controller.dart';
import '../l10n.dart';

Future<T?> showClosedDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    barrierDismissible: barrierDismissible,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  );
  final result = await navigator.push(route);
  await route.completed;
  return result;
}

Future<void> editFolder(
  BuildContext context,
  JoyController controller,
  Words words, {
  JoyRecord? record,
  String? parentId,
}) async {
  final name = TextEditingController(text: record?.title ?? '');
  final description = TextEditingController(text: record?.description ?? '');
  final form = GlobalKey<FormState>();
  String? error;
  await showClosedDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          words[record == null
              ? (parentId == null ? 'newFolder' : 'newSubfolder')
              : 'edit'],
        ),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 440,
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    autofocus: true,
                    decoration: InputDecoration(labelText: words['name']),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? words['required']
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: description,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: words['description'],
                    ),
                  ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
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
            child: Text(words['cancel']),
          ),
          FilledButton(
            onPressed: () {
              if (!form.currentState!.validate()) return;
              try {
                if (record == null) {
                  controller.repository.create(
                    kind: parentId == null ? 'folder' : 'subfolder',
                    title: name.text,
                    description: description.text,
                    parentId: parentId,
                  );
                } else {
                  controller.repository.edit(
                    record.id,
                    title: name.text,
                    description: description.text,
                  );
                }
                controller.refresh();
                Navigator.pop(context);
              } catch (e) {
                setState(() => error = e.toString());
              }
            },
            child: Text(words['save']),
          ),
        ],
      ),
    ),
  );
  name.dispose();
  description.dispose();
}

Future<bool> editItem(
  BuildContext context,
  JoyController controller,
  Words words, {
  JoyRecord? record,
  String? parentId,
}) async {
  final destination = parentId ?? record?.parentId ?? controller.destination;
  if (record?.kind == 'project' ||
      controller.isWithin(destination, 'projects')) {
    return editProject(
      context,
      controller,
      words,
      record: record,
      parentId: destination,
    );
  }
  final title = TextEditingController(text: record?.title ?? '');
  final description = TextEditingController(text: record?.description ?? '');
  final priority = TextEditingController(
    text: record?.data['priority']?.toString() ?? '',
  );
  final duration = TextEditingController(
    text: record?.data['durationMinutes']?.toString() ?? '',
  );
  final assigned = TextEditingController(
    text: record?.data['assignedTo']?.toString() ?? '',
  );
  final scheduled = TextEditingController(
    text: record?.data['scheduledAt']?.toString() ?? '',
  );
  final ends = TextEditingController(
    text: record?.data['endsAt']?.toString() ?? '',
  );
  final due = TextEditingController(
    text: record?.data['dueAt']?.toString() ?? '',
  );
  final condition = TextEditingController(
    text: record?.data['condition']?.toString() ?? '',
  );
  final form = GlobalKey<FormState>();
  String? error;
  final result = await showClosedDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(words[record == null ? 'add' : 'edit']),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: title,
                    autofocus: true,
                    decoration: InputDecoration(labelText: words['title']),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? words['required']
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: description,
                    minLines: 2,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: words['description'],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (controller.isWithin(destination, 'calendar')) ...[
                    dateField(
                      scheduled,
                      words['startsAt'],
                      words,
                      required: true,
                    ),
                    const SizedBox(height: 16),
                    dateField(ends, words['endsAt'], words),
                    const SizedBox(height: 16),
                  ],
                  if (controller.isWithin(destination, 'delegated')) ...[
                    TextFormField(
                      controller: assigned,
                      decoration: InputDecoration(labelText: words['assignee']),
                    ),
                    const SizedBox(height: 16),
                    dateField(due, words['date'], words),
                    const SizedBox(height: 16),
                  ],
                  if (controller.isWithin(destination, 'by-date')) ...[
                    dateField(due, words['date'], words),
                    const SizedBox(height: 16),
                  ],
                  if (controller.isWithin(destination, 'conditional')) ...[
                    TextFormField(
                      controller: condition,
                      decoration: InputDecoration(
                        labelText: words['conditional'],
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(words['advanced']),
                    children: [
                      TextFormField(
                        controller: priority,
                        decoration: InputDecoration(
                          labelText: words['priority'],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: duration,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: words['duration'],
                        ),
                        validator: (v) =>
                            v != null &&
                                v.isNotEmpty &&
                                (int.tryParse(v) == null || int.parse(v) < 0)
                            ? words['required']
                            : null,
                      ),
                    ],
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
            onPressed: () => Navigator.pop(context, false),
            child: Text(words['cancel']),
          ),
          FilledButton(
            onPressed: () {
              if (!form.currentState!.validate()) return;
              try {
                final data = <String, dynamic>{...?record?.data};
                void put(String key, String text) {
                  if (text.trim().isEmpty) {
                    data.remove(key);
                  } else {
                    data[key] = text.trim();
                  }
                }

                put('priority', priority.text);
                put('assignedTo', assigned.text);
                put('condition', condition.text);
                for (final field in [
                  ('scheduledAt', scheduled),
                  ('endsAt', ends),
                  ('dueAt', due),
                ]) {
                  if (field.$2.text.trim().isEmpty) {
                    data.remove(field.$1);
                  } else {
                    data[field.$1] = DateTime.parse(
                      field.$2.text.trim(),
                    ).toUtc().toIso8601String();
                  }
                }
                if (duration.text.isEmpty) {
                  data.remove('durationMinutes');
                } else {
                  data['durationMinutes'] = int.parse(duration.text);
                }
                if (data['scheduledAt'] != null &&
                    data['endsAt'] != null &&
                    !DateTime.parse(
                      data['endsAt'],
                    ).isAfter(DateTime.parse(data['scheduledAt']))) {
                  throw FormatException(words['invalidDate']);
                }
                if (record == null) {
                  controller.repository.create(
                    kind: 'item',
                    title: title.text,
                    description: description.text,
                    parentId: destination,
                    data: data,
                  );
                } else {
                  controller.repository.edit(
                    record.id,
                    title: title.text,
                    description: description.text,
                    data: data,
                    parentId: destination,
                  );
                }
                controller.refresh();
                Navigator.pop(context, true);
              } catch (e) {
                setState(() => error = e.toString());
              }
            },
            child: Text(words['save']),
          ),
        ],
      ),
    ),
  );
  for (final c in [
    title,
    description,
    priority,
    duration,
    assigned,
    scheduled,
    ends,
    due,
    condition,
  ]) {
    c.dispose();
  }
  return result ?? false;
}

Widget dateField(
  TextEditingController controller,
  String label,
  Words words, {
  bool required = false,
}) => Builder(
  builder: (context) => TextFormField(
    controller: controller,
    keyboardType: TextInputType.datetime,
    decoration: InputDecoration(
      labelText: label,
      hintText: '2026-11-08T14:00:00Z',
      suffixIcon: IconButton(
        tooltip: words['date'],
        icon: const Icon(Icons.calendar_month_outlined),
        onPressed: () async {
          final current =
              DateTime.tryParse(controller.text)?.toLocal() ?? DateTime.now();
          final date = await showDatePicker(
            context: context,
            initialDate: current,
            firstDate: DateTime(1900),
            lastDate: DateTime(2200),
          );
          if (date == null || !context.mounted) return;
          final time = await showTimePicker(
            context: context,
            initialTime: TimeOfDay.fromDateTime(current),
          );
          if (time == null) return;
          controller.text = DateTime(
            date.year,
            date.month,
            date.day,
            time.hour,
            time.minute,
          ).toUtc().toIso8601String();
        },
      ),
    ),
    validator: (value) {
      if (value == null || value.trim().isEmpty)
        return required ? words['required'] : null;
      return DateTime.tryParse(value.trim()) == null
          ? words['invalidDate']
          : null;
    },
  ),
);

Future<bool> editProject(
  BuildContext context,
  JoyController controller,
  Words words, {
  JoyRecord? record,
  String? parentId,
}) async {
  final title = TextEditingController(text: record?.title ?? '');
  final description = TextEditingController(text: record?.description ?? '');
  final plan = TextEditingController(
    text: record?.data['plan'] as String? ?? '',
  );
  final criterion = TextEditingController(
    text: record?.data['completionCriterion'] as String? ?? '',
  );
  final previousActions = record == null
      ? <JoyRecord>[]
      : controller.ordered(
          controller.records.where(
            (r) => r.kind == 'action' && r.parentId == record.id,
          ),
        );
  final removedActions = <TextEditingController>[];
  final actions = previousActions
      .map((r) => TextEditingController(text: r.title))
      .toList();
  if (actions.isEmpty) actions.add(TextEditingController());
  final form = GlobalKey<FormState>();
  String? error;
  final result = await showClosedDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(words['project']),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final field in [
                      (title, 'title'),
                      (description, 'description'),
                      (plan, 'plan'),
                    ]) ...[
                      TextFormField(
                        controller: field.$1,
                        minLines: field.$2 == 'title' ? 1 : 2,
                        maxLines: field.$2 == 'title' ? 2 : 5,
                        decoration: InputDecoration(labelText: words[field.$2]),
                        validator: (v) => v == null || v.trim().isEmpty
                            ? words['required']
                            : null,
                      ),
                      const SizedBox(height: 16),
                    ],
                    Text(
                      words['actions'],
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 210),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: actions.length,
                        itemBuilder: (context, i) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: actions[i],
                                  decoration: InputDecoration(
                                    labelText: '${words['action']} ${i + 1}',
                                  ),
                                  validator: (v) =>
                                      i == 0 && (v == null || v.trim().isEmpty)
                                      ? words['atLeastOne']
                                      : null,
                                ),
                              ),
                              IconButton(
                                tooltip: words['addAction'],
                                onPressed: () => setState(
                                  () => actions.add(TextEditingController()),
                                ),
                                icon: const Icon(Icons.add),
                              ),
                              if (actions.length > 1)
                                IconButton(
                                  tooltip: words['delete'],
                                  onPressed: () => setState(() {
                                    removedActions.add(actions.removeAt(i));
                                  }),
                                  icon: const Icon(Icons.remove),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: criterion,
                      minLines: 2,
                      maxLines: 4,
                      decoration: InputDecoration(
                        labelText: words['criterion'],
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? words['required']
                          : null,
                    ),
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(words['cancel']),
          ),
          FilledButton(
            onPressed: () {
              if (!form.currentState!.validate()) return;
              try {
                controller.repository.saveProject(
                  id: record?.id,
                  parentId: parentId ?? record?.parentId ?? 'projects',
                  title: title.text,
                  description: description.text,
                  plan: plan.text,
                  criterion: criterion.text,
                  actions: actions
                      .map((c) => c.text)
                      .where((s) => s.trim().isNotEmpty)
                      .toList(),
                );
                controller.refresh();
                Navigator.pop(context, true);
              } catch (e) {
                setState(() => error = e.toString());
              }
            },
            child: Text(words['save']),
          ),
        ],
      ),
    ),
  );
  for (final c in [
    title,
    description,
    plan,
    criterion,
    ...actions,
    ...removedActions,
  ]) {
    c.dispose();
  }
  return result ?? false;
}

Future<String?> chooseDestination(
  BuildContext context,
  JoyController controller,
  Words words,
) => showClosedDialog<String>(
  context: context,
  builder: (context) => SimpleDialog(
    title: Text(words['destination']),
    children: [
      SizedBox(
        width: 420,
        height: 380,
        child: ListView(
          children: [
            for (final folder in controller.folders) ...[
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folderLabel(folder, words)),
                onTap: () => Navigator.pop(context, folder.id),
              ),
              for (final child in controller.ordered(
                controller.records.where(
                  (r) => r.kind == 'subfolder' && r.parentId == folder.id,
                ),
              ))
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 46, right: 16),
                  title: Text(child.title),
                  onTap: () => Navigator.pop(context, child.id),
                ),
            ],
          ],
        ),
      ),
    ],
  ),
);

String folderLabel(JoyRecord folder, Words words) {
  const seedTitles = {
    'inbox': 'Inbox',
    'projects': 'Projects',
    'knowledge': 'Knowledge',
    'contacts': 'Contacts',
    'shopping': 'Shopping Lists',
    'calendar': 'Calendar',
    'delegated': 'Delegated',
    'someday': 'Someday / Later',
    'urgent': 'Urgent',
    'by-date': 'By Date',
    'conditional': 'Conditional',
    'trash': 'Trash',
  };
  return folder.title == seedTitles[folder.id]
      ? words[folder.id]
      : folder.title;
}
