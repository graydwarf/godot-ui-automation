# =============================================================================
# UI Test Runner - Visual UI Automation Testing for Godot
# =============================================================================
# MIT License - Copyright (c) 2025 Poplava
#
# Support & Community:
#   Discord: https://discord.gg/9GnrTKXGfq
#   GitHub:  https://github.com/graydwarf/godot-ui-test-runner
#   More Tools: https://poplava.itch.io
# =============================================================================

@tool
extends EditorPlugin

const AUTOLOAD_NAME = "UITestRunner"

func _enter_tree():
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/ui-test-runner/ui-test-runner.gd")
	print("[UI Test Runner] Plugin enabled")

func _exit_tree():
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[UI Test Runner] Plugin disabled")
