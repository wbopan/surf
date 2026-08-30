# dmgbuild 的设置文件（分发计划 §5）。由 scripts/release-dmg.sh 调：
#
#   dmgbuild -s dmg-settings.py -D app=<路径> "<卷名>" <输出.dmg>
#
# **两行是硬要求，不是口味**（§5.2）：dmgbuild 默认还是 HFS+ / UDZO，
# 而现代 macOS 与 Sparkle 都要 APFS / ULFO。写死在这里，命令行不必记。
import os.path

app = defines["app"]
app_name = os.path.basename(app)

# ---------------------------------------------------------------- 镜像本身
filesystem = "APFS"
format = "ULFO"
size = None          # 由 dmgbuild 按内容算

# ---------------------------------------------------------------- 内容
files = [app]
symlinks = {"Applications": "/Applications"}

# ---------------------------------------------------------------- 版式
# 没有自制背景图，用 dmgbuild 自带的箭头（HiDPI 默认开着，见 §5.1）。
background = "builtin-arrow"
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 200), (560, 380))
icon_size = 96
text_size = 12
icon_locations = {
    app_name: (150, 180),
    "Applications": (410, 180),
}
