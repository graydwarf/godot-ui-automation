# Godot UI Test Runner

A visual UI test automation framework for Godot 4.x that enables recording, playback, and validation of user interface interactions.

## Features

- **Record & Replay**: Record mouse clicks, drags, double-clicks, and keyboard input with visual cursor feedback
- **Screenshot Validation**: Capture baseline screenshots and validate against them with configurable tolerance
- **Multiple Screenshots**: Capture multiple checkpoints during a single test for comprehensive validation
- **Test Manager**: Built-in UI for organizing, running, and managing tests with categories
- **Inline Thumbnails**: Preview screenshots directly in the test editor
- **Tolerant Comparison**: Configure pixel tolerance and color threshold for flexible matching
- **Pause/Resume Recording**: Pause recording to interact with your app without capturing events

## Installation

1. Copy the `addons/ui-test-runner` folder to your project's `addons` directory
2. Enable the plugin in Project Settings > Plugins
3. The plugin auto-registers as an autoload singleton

## Usage

### Keyboard Shortcuts

- **F9**: Run demo (if configured)
- **F10**: Toggle playback speed / Capture screenshot (during recording)
- **F11**: Start/Stop recording
- **F12**: Open Test Manager

### Recording a Test

1. Press **F11** to start recording
2. Interact with your UI - clicks, drags, and keyboard input are captured
3. Press **F10** to capture screenshot checkpoints at important moments
4. Press **F11** to stop recording
5. Edit test name and step delays in the Event Editor
6. Click **Save Test**

### Running Tests

1. Press **F12** to open the Test Manager
2. Click the play button (▶) next to a test to run it
3. Use "Run All Tests" to execute all tests in sequence
4. View results in the Results tab

### Test Organization

- Create categories to group related tests
- Drag tests between categories
- Run all tests in a category with the category play button

## Configuration

In the Test Manager's Config tab:

- **Playback Speed**: Instant, Fast, Normal, or Slow
- **Comparison Mode**: Pixel Perfect or Tolerant
- **Pixel Tolerance**: Percentage of pixels allowed to differ (0-10%)
- **Color Threshold**: Maximum RGB difference per pixel (0-50)

## File Structure

Tests are stored as JSON files in `res://tests/ui-tests/`:
- Test definitions: `test_name.json`
- Baseline screenshots: `res://tests/baselines/baseline_test_name.png`

## Requirements

- Godot 4.5+
- Windows (currently tested on Windows only)

## License

MIT License - See LICENSE file for details
