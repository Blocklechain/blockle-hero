extends SceneTree

func _init() -> void:
    var p: String = ProjectSettings.get_setting("application/config/icon", "")
    print("application/config/icon = ", p)
    print("exists on disk        = ", FileAccess.file_exists(p))
    var img := Image.new()
    var err := img.load(ProjectSettings.globalize_path(p))
    print("Image.load err        = ", err)
    print("size                  = ", img.get_width(), "x", img.get_height())
    print("format                = ", img.get_format(), "  (FORMAT_RGB8=", Image.FORMAT_RGB8, " FORMAT_RGBA8=", Image.FORMAT_RGBA8, ")")
    print("has alpha             = ", img.detect_alpha() != Image.ALPHA_NONE)
    var tex := load(p)
    print("load() as resource    = ", tex, "  ", tex.get_width() if tex else -1, "x", tex.get_height() if tex else -1)
    print("corner px             = ", img.get_pixel(0, 0), " ", img.get_pixel(1023, 1023))
    quit()
