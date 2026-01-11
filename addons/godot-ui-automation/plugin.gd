# =============================================================================
# Godot UI Automation - Visual UI Automation Testing for Godot
# =============================================================================
# MIT License - Copyright (c) 2025 Poplava
#
# Support & Community:
#   Discord: https://discord.gg/9GnrTKXGfq
#   GitHub:  https://github.com/graydwarf/godot-ui-automation
#   More Tools: https://poplava.itch.io
# =============================================================================

@tool
extends EditorPlugin

const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")
const AUTOLOAD_NAME = "UITestRunner"

func _enter_tree():
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, "res://addons/godot-ui-automation/godot-ui-automation.gd")
	print("[%s] Plugin enabled" % Utils.PLUGIN_NAME)

func _exit_tree():
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[%s] Plugin disabled" % Utils.PLUGIN_NAME)
