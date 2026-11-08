import 'dart:io';
import 'package:flutter/material.dart';
import 'package:joy_core/joy_core.dart';
import 'package:path_provider/path_provider.dart';
import 'app.dart';
import 'controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final repository = JoyRepository.open(
      path: '${directory.path}${Platform.pathSeparator}joy.sqlite',
    );
    repository.purgeTrash();
    runApp(JoyApp(controller: JoyController(repository)));
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: SelectableText(
                  'Unable to open your local workspace.\n$error',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
