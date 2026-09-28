class_name LoreSheet
extends VBoxContainer
## The menus' Lore page, beside the menu column: the whole chronicle (LoreText) and nothing
## else, no title, set in type so small it can barely be read, if at all: a slab of ant-sized
## text. That's the joke, so keep it that way. Like the controls sheet it has no box of its own;
## the menu puts a blurred backdrop behind it.

const BODY_SIZE := 4          ## px on the 1920x1080 canvas
const WIDTH := 1180.0

var body: RichTextLabel


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_constant_override("separation", 0)
	body = RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(WIDTH, 0)
	body.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var slanted := FontVariation.new()             # (Jost has no italic: lean the roman)
	slanted.base_font = UiTheme.sans(400)
	slanted.variation_transform = Transform2D(Vector2(1, 0), Vector2(0.2, 1), Vector2.ZERO)
	body.add_theme_font_override("normal_font", UiTheme.sans(400))
	body.add_theme_font_override("bold_font", UiTheme.sans(600))
	body.add_theme_font_override("italics_font", slanted)
	for f in ["normal_font_size", "bold_font_size", "italics_font_size"]:
		body.add_theme_font_size_override(f, BODY_SIZE)
	body.add_theme_color_override("default_color", Color(UiTheme.TEXT, 0.78))
	body.text = "[fill]%s[/fill]" % bbcode(LoreText.CHRONICLE)
	add_child(body)


## The chronicle's Markdown as BBCode: **bold** and *italics* (and any [ escaped).
static func bbcode(md: String) -> String:
	var s := md.replace("[", "[lb]")
	s = RegEx.create_from_string("\\*\\*(.+?)\\*\\*").sub(s, "[b]$1[/b]", true)
	s = RegEx.create_from_string("\\*([^*\\n]+?)\\*").sub(s, "[i]$1[/i]", true)
	return s

