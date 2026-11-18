from pathlib import Path

app = Path(defines["app"]).resolve()
files = [str(app)]
symlinks = {"Applications": "/Applications"}
icon = str(app / "Contents/Resources/AppIcon.icns")
background = defines["background"]
window_rect = ((160, 120), (560, 320))
default_view = "icon-view"
show_toolbar = show_status_bar = show_pathbar = show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
icon_locations = {"NeSpat.app": (155, 184), "Applications": (405, 184)}
