# dmgbuild settings for the k8sman installer (tools/make-dmg.sh passes
# -D app=<path to k8sman.app>). Window content is 640x400 pt; the background
# (background.tiff, 1x + 2x) is made by make-background.swift.
import os

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
here = os.path.dirname(os.path.abspath(defines["settings"]))  # noqa: F821

volume_name = "k8sman"
format = "UDZO"
filesystem = "HFS+"
compression_level = 9

files = [app]
symlinks = {"Applications": "/Applications"}

# Volume icon from the app's own icon, when the build has one.
_icns = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
if os.path.exists(_icns):
    icon = _icns

background = os.path.join(here, "background.tiff")

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
window_rect = ((200, 160), (640, 428))  # +28 pt title bar
default_view = "icon-view"

arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    os.path.basename(app): (170, 200),
    "Applications": (470, 200),
}
