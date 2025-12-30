@tool
extends EditorPlugin

const AUTOLOAD_NAME = "UITestRunner"

func _enter_tree():
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/ui-test-runner/ui-test-runner.gd")
	print("[UI Test Runner] Plugin enabled")

func _exit_tree():
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[UI Test Runner] Plugin disabled")
