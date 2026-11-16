#!/usr/bin/env python3
"""生成 Android 启动图标资源（纯几何图形，不使用任何第三方素材）。

设计约束：
- 颜色只取自 `lib/core/theme/tokens.dart` 的既有令牌（accent #3E63DD / surface #FFFFFF /
  accentSoft #E8EDFB），不自造新色值；
- 图形是「日历」这一应用语义本身，不含文字、不含渐变、不含外部图片；
- **这是供安装包可用的中性占位图标**。`design/reference/README.md` 说明发起人确认的
  效果图尚未入库；效果图到位后应替换本脚本产物，而不是反过来按图标调整 UI。

产物（写入 android/app/src/main/res/）：
  mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png          传统图标（48dp）
  mipmap-{...}/ic_launcher_round.png                                圆形传统图标
  mipmap-{...}/ic_launcher_foreground.png                           自适应图标前景（108dp 画布）
  mipmap-anydpi-v26/ic_launcher.xml + ic_launcher_round.xml         自适应图标
  values/ic_launcher_background.xml                                 自适应图标背景色

用法：python scripts/android/gen_icons.py
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

REPO_ROOT = Path(__file__).resolve().parents[2]
RES_DIR = REPO_ROOT / "android" / "app" / "src" / "main" / "res"

ACCENT = (62, 99, 221, 255)          # AppColors.accent  #3E63DD
ACCENT_SOFT = (232, 237, 251, 255)   # AppColors.accentSoft #E8EDFB
SURFACE = (255, 255, 255, 255)       # AppColors.surface #FFFFFF

DENSITIES = {
    "mdpi": 1.0,
    "hdpi": 1.5,
    "xhdpi": 2.0,
    "xxhdpi": 3.0,
    "xxxhdpi": 4.0,
}

SUPERSAMPLE = 4


def _rounded_rect(draw: ImageDraw.ImageDraw, box, radius, fill):
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def draw_calendar(
    image: Image.Image,
    *,
    canvas_units: float,
    origin_x: float,
    origin_y: float,
    glyph_units: float,
    with_background: bool,
    round_background: bool,
) -> None:
    """在 image 上画图标。

    canvas_units：整张画布的逻辑单位数（自适应图标的画布是 108dp，安全区 66dp）。
    glyph_units：日历图形占用的逻辑单位数（宽度）。
    with_background：是否先铺 accent 底色（传统图标用；自适应图标背景是单独一层）。
    """
    scale = image.width / canvas_units
    draw = ImageDraw.Draw(image)

    if with_background:
        if round_background:
            draw.ellipse((0, 0, image.width - 1, image.height - 1), fill=ACCENT)
        else:
            _rounded_rect(
                draw,
                (0, 0, image.width - 1, image.height - 1),
                radius=canvas_units * 0.22 * scale,
                fill=ACCENT,
            )

    # 日历主体：宽 glyph_units、高 glyph_units * 0.875
    width = glyph_units * scale
    height = glyph_units * 0.875 * scale
    left = origin_x * scale
    top = origin_y * scale
    body_radius = glyph_units * 0.10 * scale

    _rounded_rect(draw, (left, top, left + width, top + height), body_radius, SURFACE)

    # 顶部装订条：主体高度 24%，用 accent 填充（与白色主体形成清晰边界）
    header_h = height * 0.24
    draw.rounded_rectangle(
        (left, top, left + width, top + header_h + body_radius),
        radius=body_radius,
        fill=ACCENT,
    )
    # 补一块直角矩形，避免圆角在中间产生凹陷
    draw.rectangle((left, top + header_h, left + width, top + header_h + body_radius), fill=ACCENT)

    # 两个装订环：露出主体上方
    ring_w = width * 0.10
    ring_h = height * 0.16
    ring_r = ring_w * 0.45
    ring_y = top - ring_h * 0.45
    for cx in (left + width * 0.30, left + width * 0.70):
        _rounded_rect(
            draw,
            (cx - ring_w / 2, ring_y, cx + ring_w / 2, ring_y + ring_h),
            ring_r,
            SURFACE,
        )

    # 日期网格：2 行 × 3 列圆点（按列中心等距分布，视觉居中）
    dot_r = width * 0.055
    grid_top = top + header_h + height * 0.20
    row_step = height * 0.24
    centers = [left + width * (0.24 + 0.26 * col) for col in range(3)]
    for row in range(2):
        cy = grid_top + row * row_step
        for cx in centers:
            draw.ellipse(
                (cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r),
                fill=ACCENT if row == 0 else ACCENT_SOFT,
            )


def save_icon(image: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def main() -> None:
    for density, factor in DENSITIES.items():
        target_dir = RES_DIR / f"mipmap-{density}"
        target_dir.mkdir(parents=True, exist_ok=True)

        # 传统图标：48dp
        legacy_px = int(round(48 * factor)) * SUPERSAMPLE
        for name, is_round in (("ic_launcher.png", False), ("ic_launcher_round.png", True)):
            canvas = Image.new("RGBA", (legacy_px, legacy_px), (0, 0, 0, 0))
            glyph_units = 48 * 0.62
            draw_calendar(
                canvas,
                canvas_units=48,
                origin_x=(48 - glyph_units) / 2,
                origin_y=(48 - glyph_units * 0.875) / 2,
                glyph_units=glyph_units,
                with_background=True,
                round_background=is_round,
            )
            final = canvas.resize(
                (int(round(48 * factor)), int(round(48 * factor))),
                Image.LANCZOS,
            )
            save_icon(final, target_dir / name)

        # 自适应图标前景：108dp 画布，图形限制在中央 66dp 安全区
        adaptive_px = int(round(108 * factor)) * SUPERSAMPLE
        foreground = Image.new("RGBA", (adaptive_px, adaptive_px), (0, 0, 0, 0))
        glyph_units = 108 * 0.46
        draw_calendar(
            foreground,
            canvas_units=108,
            origin_x=(108 - glyph_units) / 2,
            origin_y=(108 - glyph_units * 0.875) / 2,
            glyph_units=glyph_units,
            with_background=False,
            round_background=False,
        )
        final = foreground.resize(
            (int(round(108 * factor)), int(round(108 * factor))),
            Image.LANCZOS,
        )
        save_icon(final, target_dir / "ic_launcher_foreground.png")

    # 自适应图标 XML（API 26+）
    anydpi = RES_DIR / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    adaptive_xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
"""
    (anydpi / "ic_launcher.xml").write_text(adaptive_xml, encoding="utf-8")
    (anydpi / "ic_launcher_round.xml").write_text(adaptive_xml, encoding="utf-8")

    colors = RES_DIR / "values"
    colors.mkdir(parents=True, exist_ok=True)
    (colors / "ic_launcher_background.xml").write_text(
        """<?xml version="1.0" encoding="utf-8"?>
<resources>
    <!-- AppColors.accent #3E63DD（lib/core/theme/tokens.dart） -->
    <color name="ic_launcher_background">#3E63DD</color>
</resources>
""",
        encoding="utf-8",
    )

    print("icon resources written to", RES_DIR)


if __name__ == "__main__":
    main()
