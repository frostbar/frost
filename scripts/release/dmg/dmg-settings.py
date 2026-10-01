# dmgbuild settings (https://dmgbuild.readthedocs.io). Invoked by scripts/release/release.sh:
#   dmgbuild -s dmg-settings.py -D app=<Frost.app> -D background=<background.png> "Frost <version>" out.dmg
# dmgbuild writes .DS_Store directly, without going through Finder, and never opens a window.
import os.path

app = defines["app"]
app_name = os.path.basename(app)

format = "ULFO"  # lzfse compression (macOS 10.11+)
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")

# Window and icon positions must line up with the arrow drawn by make-background.swift.
background = defines["background"]
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (165, 190),
    "Applications": (495, 190),
}
