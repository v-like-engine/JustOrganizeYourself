FLUTTER ?= flutter
DART ?= dart
PYTHON ?= python

.PHONY: deps check run android embeddings

deps:
	cd packages/joy_core && $(DART) pub get
	cd apps/joy && $(FLUTTER) pub get

check:
	cd packages/joy_core && $(DART) analyze && $(DART) test
	cd apps/joy && $(FLUTTER) analyze && $(FLUTTER) test

run:
	cd apps/joy && $(FLUTTER) run -d linux

android:
	cd apps/joy && $(FLUTTER) build apk --debug --target-platform android-arm64 --split-per-abi

embeddings:
	cd services/embeddings && $(PYTHON) -m joy_embeddings.cli serve
