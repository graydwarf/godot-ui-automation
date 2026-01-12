# Godot UI Automation - Command Line Interface

## Overview

The UI Automation plugin supports command-line arguments for running tests automatically without manual interaction. This enables CI/CD integration and automated test runs.

## Command-Line Arguments

Arguments are passed after `--` separator to be received by the project (not Godot engine).

| Argument | Description |
|----------|-------------|
| `--test-all` | Auto-run all tests on startup |
| `--exit-on-complete` | Exit app after tests complete with exit code (0=pass, 1=fail) |

## Usage Examples

### Run Tests and Exit (CI Mode)
```bash
Godot_v4.5-stable_win64.exe --path "path/to/project" -- --test-all --exit-on-complete
```

### Run Tests and Stay Open (Review Mode)
```bash
Godot_v4.5-stable_win64.exe --path "path/to/project" -- --test-all
```
After tests complete, the Test Manager opens to review results.

### With Isolated Test Data
Use `--user-dir` to redirect all user data to a test-specific folder:
```bash
Godot_v4.5-stable_win64.exe --path "path/to/project" --user-dir "path/to/test-user-data" -- --test-all --exit-on-complete
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | All tests passed |
| 1 | One or more tests failed, or no tests found |

## Test Data Isolation

When using `--user-dir`, the following are redirected:
- `user://godot-ui-automation-history.json` - Test run history
- `user://godot-ui-automation-config.cfg` - Plugin configuration

Test files (`res://tests/ui-tests/*.json`) remain in the project directory.

## Batch Script Example

See `run-tests.bat` in the project root for a complete example:
```batch
@echo off
set GODOT=C:\path\to\Godot.exe
set PROJECT_PATH=C:\path\to\project
set TEST_USER_DIR=%PROJECT_PATH%\test-user-data

"%GODOT%" --path "%PROJECT_PATH%" --user-dir "%TEST_USER_DIR%" -- --test-all --exit-on-complete
echo Exit code: %ERRORLEVEL%
```

## Notes

- The plugin normally only runs in editor mode. With `--test-all`, it also runs in standalone project mode.
- Signal handlers (`ui_test_runner_setup_environment`, `ui_test_runner_test_starting`) are still emitted for app integration.
- The startup warning/countdown is skipped in auto-run mode.
