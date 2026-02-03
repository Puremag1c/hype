# Changelog

## [0.0.1] - 2026-02-03

### Fixed

- **PROJECT_ROOT unbound variable** - hype.sh used undefined `$PROJECT_ROOT` instead of `$PROJECT_DIR` in 4 places (lines 383, 664, 666, 667). Caused "unbound variable" error after FINAL_REVIEW passed.

### Added

- **Testing section in SPEC.md** - Tech Writer now collects testing info:
  - Type: web | api | cli | library
  - Start command: how to run the project
  - Test URL: for web/api projects
- **Mandatory browser testing for web projects** - Architect final_review now requires browser check for `Type: web`. No curl fallback allowed.

### Changed

- **architect.md** - final_review reads Testing section from SPEC.md instead of guessing project type
- **tech-writer.md** - includes Testing section in SPEC.md template
- **SPEC.template.md** - added Testing section
