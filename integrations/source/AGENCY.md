# Project integration — Agency

This file is the **single source of truth** for AI coding assistants working in this repository.

## Repository

- **Stack:** Flutter (Dart) client, Firebase (Firestore, Functions, Auth, etc.).
- **Run analysis:** `dart analyze` on touched files when changing Dart code.
- **Dependencies:** After changing Flutter or Node deps, run `./scripts/install.sh --workspace` (or `flutter pub get` and `cd functions && npm install`).

## Conventions

- Prefer **focused diffs**; match existing style, naming, and imports in nearby files.
- **Do not** commit secrets, API keys, or `.env` with real credentials.
- Follow project linter / formatter settings if present.

## Generated outputs

`./scripts/convert.sh` materializes this document into per-tool formats under `integrations/build/`.
`./scripts/install.sh` copies those files to Cursor rules, Aider `CONVENTIONS.md`, etc.

Edit **this** file, then re-run convert + install to propagate changes.
