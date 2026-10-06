"""Finder layout for the Lightweight Reader installer image."""

application = defines["app"]
background = defines["background"]
icon = defines["icon"]

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((170, 140), (960, 650))
default_view = "icon-view"
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 16
label_pos = "bottom"
icon_locations = {
    "Lightweight Reader.app": (248, 330),
    "Applications": (712, 330),
}
