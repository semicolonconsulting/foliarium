# dmgbuild settings for the Foliarium disk image; scripts/make-dmg.sh passes app, repo and volume_icon.
# The window shows Design/dmg/background.png (and its @2x) with the app on the left and an
# Applications link on the right. The positions match Design/dmg/make-background.py.
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides "defines")
repo = defines["repo"]  # noqa: F821

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [os.path.basename(app)]
icon = defines.get("volume_icon") or None  # noqa: F821

background = os.path.join(repo, "Design", "dmg", "background.png")
# Finder's window bounds include the title bar (32 pt on recent macOS) and the path bar (28 pt),
# so the 640x380 background fills the space between them.
window_rect = ((200, 160), (640, 32 + 380 + 28))
default_view = "icon-view"
show_toolbar = False
show_pathbar = True  # shown either way when the viewer has it on in Finder
show_status_bar = False
show_sidebar = False
show_icon_preview = False
icon_size = 112
text_size = 13
icon_locations = {
    os.path.basename(app): (170, 222),
    "Applications": (470, 222),
}
