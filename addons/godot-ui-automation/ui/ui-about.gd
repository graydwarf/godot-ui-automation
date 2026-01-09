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

extends RefCounted
## Shared About component for Godot UI Automation
## Shows title, license, and support links

const Utils = preload("res://addons/godot-ui-automation/utils/utils.gd")

var _tree: SceneTree
var _content: VBoxContainer

func initialize(tree: SceneTree) -> void:
	_tree = tree

# Creates and returns the about content wrapped in styled panel that fills dialog
func create_about_content() -> PanelContainer:
	# Outer styled panel that fills the dialog
	var outer_panel = PanelContainer.new()
	var outer_style = StyleBoxFlat.new()
	outer_style.bg_color = Color(0.12, 0.15, 0.2, 0.8)
	outer_style.border_color = Color(0.3, 0.5, 0.8, 0.6)
	outer_style.set_border_width_all(1)
	outer_style.set_corner_radius_all(8)
	outer_style.set_content_margin_all(16)
	outer_panel.add_theme_stylebox_override("panel", outer_style)
	outer_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Center container to center content
	var center = CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer_panel.add_child(center)

	# Content VBox
	var header_vbox = VBoxContainer.new()
	header_vbox.add_theme_constant_override("separation", 8)
	center.add_child(header_vbox)

	# Title
	var title = Label.new()
	title.text = Utils.PLUGIN_NAME
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(0.4, 0.75, 1.0))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header_vbox.add_child(title)

	# Subtitle
	var subtitle = Label.new()
	subtitle.text = Utils.PLUGIN_SUBTITLE
	subtitle.add_theme_font_size_override("font_size", 14)
	subtitle.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header_vbox.add_child(subtitle)

	# Separator
	var sep = HSeparator.new()
	sep.add_theme_constant_override("separation", 8)
	header_vbox.add_child(sep)

	# License
	var license_label = Label.new()
	license_label.text = "MIT License - Copyright (c) 2025 Poplava"
	license_label.add_theme_font_size_override("font_size", 12)
	license_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	license_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header_vbox.add_child(license_label)

	# Links row
	var links_row = HBoxContainer.new()
	links_row.alignment = BoxContainer.ALIGNMENT_CENTER
	links_row.add_theme_constant_override("separation", 20)
	header_vbox.add_child(links_row)

	var discord_btn = _create_link_button("Discord", "https://discord.gg/9GnrTKXGfq")
	links_row.add_child(discord_btn)

	var github_btn = _create_link_button("GitHub", "https://github.com/graydwarf/godot-ui-automation")
	links_row.add_child(github_btn)

	var itch_btn = _create_link_button("More Tools", "https://poplava.itch.io")
	links_row.add_child(itch_btn)

	return outer_panel

func _create_link_button(text: String, url: String) -> Button:
	var btn = Button.new()
	btn.text = text
	btn.flat = true
	btn.add_theme_font_size_override("font_size", 13)
	btn.add_theme_color_override("font_color", Color(0.5, 0.7, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(0.7, 0.85, 1.0))
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	btn.pressed.connect(func(): OS.shell_open(url))
	return btn
