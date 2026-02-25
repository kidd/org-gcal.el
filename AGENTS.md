# AGENTS.md

Guidance for coding agents working in `org-gcal.el`.

## Project Scope

- This repo provides Emacs Lisp integration between Org mode and Google Calendar.
- Main implementation files:
  - `org-gcal.el` (sync, fetch, post, delete, OAuth/token flow, entry updates)
  - `org-generic-id.el` (generic Org property ID index/find/update support)
- Main docs: `README.org`.
- Tests: `test/org-gcal-test.el`, `test/org-generic-id-test.el`.

## Build and Test Commands

- Install/update dependencies:
  - `make elpa`
- Compile:
  - `make compile`
- Run tests:
  - `make test`
- Clean generated artifacts/deps cache:
  - `make clean`
- Full local check (same default as CI intent):
  - `make`

Notes:
- The project uses Cask (`Cask`, `make` targets).
- Prefer running `make compile` and `make test` before finishing changes.

## Repo Conventions

### Emacs Lisp style

- Keep `-*- lexical-binding: t -*-` in source/test files.
- Public names use repo prefixes:
  - `org-gcal-...`
  - `org-generic-id-...`
- Internal helpers use double-dash names:
  - `org-gcal--...`
  - `org-generic-id--...`
- User-facing configuration belongs in `defcustom` under existing groups (`org-gcal`, `org-generic-id`) with clear docstrings and correct `:type`.
- Preserve standard file structure: headers, `;;; Commentary:`, `;;; Code:`, and `(provide '...)` footer.

### Behavior and data model constraints

- Preserve Org entry semantics documented in `README.org`:
  - Property keys such as `calendar-id`, `ETag`, `ID`/`entry-id` semantics.
  - Drawer semantics for `org-gcal` contents and timestamps.
- Avoid changing persisted token/id data format unless explicitly required.
- Keep compatibility with supported Emacs versions in CI matrix (Emacs 26+).

### Async and API interactions

- Existing async stack uses `aio`, `deferred`, and `request-deferred`; follow local patterns instead of introducing new async abstractions.
- In tests, mock network/OAuth boundaries (`request-deferred`, token refresh/getters). Do not require live Google API access.

## Testing Guidance

- Prefer ERT coverage for behavior changes in parsing, entry mutation, sync/post/delete logic, and ID lookup behavior.
- Reuse existing test helpers/macros and patterns (`with-temp-buffer`, `org-mode`, `with-mock`, temp files).
- `test/org-gcal-test.el` intentionally includes tests marked `:expected-result :failed`; do not treat them as accidental breakage without confirming intent.

## Change Checklist for Agents

- Make the smallest viable change.
- Update or add tests when behavior changes.
- Run:
  - `make compile`
  - `make test`
- If behavior visible to users changes, update `README.org` accordingly.
- Do not edit generated `.elc` files by hand.
- If modifying `.github/workflows/main.yml` or other Github Action files, use
  `actionlint` to check for errors, attempting to install it if not present.
