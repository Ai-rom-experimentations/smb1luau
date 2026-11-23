#!/usr/bin/env python3
"""Export the SMB1Base level/CHR tables into a Roblox Luau ModuleScript.

Run from the repository root with:
    python3 roblox/tools/export_data.py

The generated data is intentionally source-derived: no ROM is embedded.
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "roblox/src/ReplicatedStorage/SMBData.lua"


def section_arrays(path: Path, start: str, stop: str, prefix: str) -> dict[str, list[int]]:
    text = path.read_text()
    a = text.index(start)
    b = text.index(stop, a)
    section = text[a:b]
    result: dict[str, list[int]] = {}
    current: str | None = None
    for line in section.splitlines():
        label = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):\s*$", line)
        if label:
            name = label.group(1)
            current = name if name.startswith(prefix) else None
            if current:
                result[current] = []
            continue
        if current is None or ".byte" not in line:
            continue
        body = line.split(".byte", 1)[1].split(";", 1)[0]
        for token in body.split(","):
            token = token.strip()
            if re.fullmatch(r"\$[0-9a-fA-F]{1,2}", token):
                result[current].append(int(token[1:], 16))
            elif token:
                # These areas are all numeric in the source; fail loudly if a
                # future edit introduces an assembler symbol or string here.
                raise ValueError(f"Unexpected byte token in {current}: {token}")
    return result


def parse_area_orders(path: Path, define_name: str) -> list[str]:
    text = path.read_text()
    start = text.index(f".define {define_name}")
    end = text.index("\n\n", start)
    return re.findall(r"\b[LE]_[A-Za-z0-9_]+", text[start:end])


def parse_world_areas(path: Path) -> list[list[int]]:
    text = path.read_text()
    start = text.index("AreaAddrOffsets:")
    end = text.index("\n\n", start)
    region = text[start:end]
    worlds: list[list[int]] = []
    current: list[int] | None = None
    for line in region.splitlines():
        if re.match(r"World[1-8]Areas:", line):
            if current is not None:
                worlds.append(current)
            current = []
        if current is not None and ".byte" in line:
            body = line.split(".byte", 1)[1].split(";", 1)[0]
            current.extend(int(v.strip()[1:], 16) for v in body.split(",") if v.strip().startswith("$"))
    if current is not None:
        worlds.append(current)
    return worlds


def parse_metatiles(path: Path) -> list[list[int]]:
    text = path.read_text()
    start = text.index("MTILE_CURRENT_INDEX .set $00", text.index(";METATILE GRAPHICS TABLE"))
    end = text.index("; Create the actual metatile tables.", start)
    region = text[start:end]
    current_index = 0
    tiles = [[0, 0, 0, 0, 0, 0] for _ in range(256)]
    for line in region.splitlines():
        m = re.search(r"MTILE_CURRENT_INDEX\s+\.set\s+\$([0-9a-fA-F]+)", line)
        if m:
            current_index = int(m.group(1), 16)
            continue
        m = re.search(r"^\s*MTileDefine\s+(.+?)(?:\s*;.*)?$", line)
        if not m:
            continue
        args = [arg.strip() for arg in m.group(1).split(",")]
        if len(args) != 5:
            raise ValueError(f"Malformed MTileDefine: {line}")
        values = [int(arg[1:], 16) for arg in args[:4]]
        attr = args[4].replace(" ", "")
        flags = 0
        if "MTILE_SOLID" in attr:
            flags |= 1
        if "MTILE_CLIMB" in attr:
            flags |= 2
        if "MTILE_BUMP" in attr:
            flags |= 4
        palette = 0
        for p in range(4):
            if f"MTILE_PALETTE_{p}" in attr:
                palette = p
                break
        tiles[current_index] = [*values, palette, flags]
        current_index += 1
    return tiles


def parse_named_bytes(path: Path, label: str, count: int) -> list[int]:
    text = path.read_text()
    start = text.index(label + ":")
    end = text.find("\n\n", start)
    if end < 0:
        end = len(text)
    data: list[int] = []
    for line in text[start:end].splitlines()[1:]:
        if ".byte" not in line:
            continue
        body = line.split(".byte", 1)[1].split(";", 1)[0]
        for t in body.split(","):
            t = t.strip()
            if t.startswith("%"):
                data.append(int(t[1:], 2))
            elif t.startswith("$"):
                data.append(int(t[1:], 16))
            elif t:
                raise ValueError(f"Unexpected byte in {label}: {t}")
    return data[:count]


def parse_palette_rows(path: Path, label: str) -> list[list[int]]:
    text = path.read_text()
    start = text.index(label + ":")
    end = text.find("\n\n", start)
    if end < 0:
        end = len(text)
    body = text[start:end]
    vals: list[int] = []
    for line in body.splitlines()[1:]:
        if ".byte" not in line:
            continue
        for token in line.split(".byte", 1)[1].split(";", 1)[0].split(","):
            token = token.strip()
            if token.startswith("$"):
                vals.append(int(token[1:], 16))
    # Palette streams begin with the PPU destination header ($3f, $00, $20).
    # Those bytes are not palette entries and must not shift all four background
    # and sprite palettes by one color.
    if vals[:3] == [0x3F, 0x00, 0x20]:
        vals = vals[3:]
    return [vals[i:i + 4] for i in range(0, min(len(vals), 32), 4)]


def luau_bytes(values: list[int], width: int = 16) -> str:
    if not values:
        return "{}"
    rows = []
    for i in range(0, len(values), width):
        rows.append("    " + ",".join(f"0x{x:02X}" for x in values[i:i + width]))
    return "{\n" + ",\n".join(rows) + "\n  }"


def luau_string(hex_data: str, width: int = 96) -> str:
    return '"' + '" ..\n      "'.join(hex_data[i:i + width] for i in range(0, len(hex_data), width)) + '"'


def render() -> str:
    level_path = ROOT / "src/level_tiles.s"
    common_path = ROOT / "src/common.s"
    palette_path = ROOT / "src/reset.s"
    render_path = ROOT / "src/screen_render.s"

    levels = section_arrays(level_path, ";AREA OBJECT DATA", "; Individual metatile data", "L_")
    enemies = section_arrays(level_path, ";ENEMY OBJECT DATA", ";AREA OBJECT DATA", "E_")
    area_order = parse_area_orders(level_path, "AreaDataAddr")
    enemy_order = parse_area_orders(level_path, "EnemyDataAddr")
    worlds = parse_world_areas(common_path)
    metatiles = parse_metatiles(render_path)

    ground_palette = parse_palette_rows(palette_path, "GroundPaletteData")
    water_palette = parse_palette_rows(palette_path, "WaterPaletteData")
    underground_palette = parse_palette_rows(palette_path, "UndergroundPaletteData")
    castle_palette = parse_palette_rows(palette_path, "CastlePaletteData")

    # Background data tables are kept verbatim from level_tiles.s.
    def parse_table(text: str, name: str, stop: str) -> list[int]:
        start = text.index(name + ":")
        end = text.index(stop, start)
        result: list[int] = []
        for line in text[start:end].splitlines()[1:]:
            if ".byte" not in line:
                continue
            body = line.split(".byte", 1)[1].split(";", 1)[0]
            for token in body.split(","):
                token = token.strip()
                if token.startswith("$"):
                    result.append(int(token[1:], 16))
                elif token.startswith("%"):
                    result.append(int(token[1:], 2))
        return result

    level_text = level_path.read_text()
    back_data = parse_table(level_text, "BackSceneryData", "BackSceneryMetatiles:")
    back_tiles = parse_table(level_text, "BackSceneryMetatiles", "FSceneDataOffsets:")
    fore_data = parse_table(level_text, "ForeSceneryData", "TerrainMetatiles:")
    terrain_tiles = parse_table(level_text, "TerrainMetatiles", "TerrainRenderBits:")
    terrain_bits = parse_table(level_text, "TerrainRenderBits", ".proc AreaParserCore")

    graphics_dir = ROOT / "chr/mmc5"
    chr_files = {
        "bgWater": graphics_dir / "bg_water.chr",
        "bgGround": graphics_dir / "bg_ground.chr",
        "bgUnderground": graphics_dir / "bg_underground.chr",
        "bgCastle": graphics_dir / "bg_castle.chr",
        "mario": graphics_dir / "sprites_mario.chr",
        "misc": graphics_dir / "sprites_misc.chr",
        "enemies": graphics_dir / "sprites_enemies.chr",
    }
    hex_chr = {name: path.read_bytes().hex().upper() for name, path in chr_files.items()}

    lines = [
        "-- Generated by roblox/tools/export_data.py from this repository's SMB1 source tables.",
        "-- Do not hand-edit; rerun the exporter after changing the source assets.",
        "local D = {}",
        "D.Areas = {",
    ]
    for name in area_order:
        lines.append(f"  {name} = {luau_bytes(levels[name])},")
    lines += ["}", "D.EnemyAreas = {"]
    for name in enemy_order:
        lines.append(f"  {name} = {luau_bytes(enemies[name])},")
    lines += ["}", "D.AreaOrder = {"]
    lines.append("  " + ", ".join(f'"{name}"' for name in area_order))
    lines += ["}", "D.EnemyOrder = {"]
    lines.append("  " + ", ".join(f'"{name}"' for name in enemy_order))
    lines += ["}", "D.WorldAreas = {"]
    for world in worlds:
        lines.append("  " + luau_bytes(world, width=12) + ",")
    lines += ["}", "D.Metatiles = {"]
    for i in range(0, len(metatiles), 8):
        lines.append("  " + ", ".join("{" + ",".join(str(x) for x in t) + "}" for t in metatiles[i:i + 8]) + ",")
    lines += ["}", "D.Palettes = {"]
    for name, rows in (("water", water_palette), ("ground", ground_palette), ("underground", underground_palette), ("castle", castle_palette)):
        lines.append(f"  {name} = {{")
        lines.append("    background = {")
        for row in rows[:4]:
            lines.append("      {" + ",".join(f"0x{x:02X}" for x in row) + "},")
        lines.append("    },")
        lines.append("    sprites = {")
        for row in rows[4:8]:
            lines.append("      {" + ",".join(f"0x{x:02X}" for x in row) + "},")
        lines.append("    },")
        lines.append("  },")
    lines += ["}", "D.BGColor = {0x22, 0x22, 0x0F, 0x0F}"]
    lines.append("D.BackSceneryData = " + luau_bytes(back_data))
    lines.append("D.BackSceneryMetatiles = " + luau_bytes(back_tiles))
    lines.append("D.ForeSceneryData = " + luau_bytes(fore_data))
    lines.append("D.TerrainMetatiles = " + luau_bytes(terrain_tiles))
    lines.append("D.TerrainRenderBits = " + luau_bytes(terrain_bits))
    lines.append("D.CHR = {")
    for name, data in hex_chr.items():
        lines.append(f"  {name} = {luau_string(data)},")
    lines += ["}", "return D", ""]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines))
    return f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size:,} bytes)"


if __name__ == "__main__":
    print(render())
