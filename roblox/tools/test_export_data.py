#!/usr/bin/env python3
"""Verify the checked-in Luau data against its assembly and CHR sources."""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPORTER_PATH = ROOT / "roblox/tools/export_data.py"
spec = importlib.util.spec_from_file_location("smb_export_data", EXPORTER_PATH)
if spec is None or spec.loader is None:
    raise RuntimeError("Could not import export_data.py")
exporter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = exporter
spec.loader.exec_module(exporter)


class ExportMismatch(AssertionError):
    pass


def extract_table(source: str, name: str) -> str:
    match = re.search(rf"\bD\.{re.escape(name)}\s*=\s*\{{", source)
    if not match:
        raise ExportMismatch(f"Missing D.{name} table")
    opening = match.end() - 1
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise ExportMismatch(f"Unclosed D.{name} table")


def extract_braced(source: str, opening: int) -> tuple[str, int]:
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index], index + 1
    raise ExportMismatch("Unclosed nested Luau table")


def named_tables(source: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for match in re.finditer(r"(?m)^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*\{", source):
        opening = match.end() - 1
        body, _ = extract_braced(source, opening)
        result[match.group(1)] = body
    return result


def hex_values(source: str) -> list[int]:
    return [int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]+)", source)]


def compare(name: str, actual, expected) -> None:
    if actual != expected:
        raise ExportMismatch(f"{name} differs from its source data")


def parse_asm_table(path: Path, label: str, stop: str) -> list[int]:
    text = path.read_text()
    start = text.index(label + ":")
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
            elif token:
                raise ExportMismatch(f"Unexpected token {token!r} in {label}")
    return result


def main() -> None:
    generated_path = ROOT / "roblox/src/ReplicatedStorage/SMBData.lua"
    generated = generated_path.read_text()
    area_source = ROOT / "src/level_tiles.s"
    common_source = ROOT / "src/common.s"
    render_source = ROOT / "src/screen_render.s"
    palette_source = ROOT / "src/reset.s"

    areas = exporter.section_arrays(area_source, ";AREA OBJECT DATA", "; Individual metatile data", "L_")
    enemies = exporter.section_arrays(area_source, ";ENEMY OBJECT DATA", ";AREA OBJECT DATA", "E_")
    area_order = exporter.parse_area_orders(area_source, "AreaDataAddr")
    enemy_order = exporter.parse_area_orders(area_source, "EnemyDataAddr")
    world_areas = exporter.parse_world_areas(common_source)

    generated_areas = named_tables(extract_table(generated, "Areas"))
    generated_enemies = named_tables(extract_table(generated, "EnemyAreas"))
    compare("Area labels", list(generated_areas), area_order)
    compare("Enemy labels", list(generated_enemies), enemy_order)
    for name in area_order:
        compare(f"Area bytes {name}", hex_values(generated_areas[name]), areas[name])
    for name in enemy_order:
        compare(f"Enemy bytes {name}", hex_values(generated_enemies[name]), enemies[name])

    compare("Area pointer order", re.findall(r'"([^\"]+)"', extract_table(generated, "AreaOrder")), area_order)
    compare("Enemy pointer order", re.findall(r'"([^\"]+)"', extract_table(generated, "EnemyOrder")), enemy_order)
    generated_worlds = [hex_values(body) for body in re.findall(r"\{([^{}]*)\}", extract_table(generated, "WorldAreas"))]
    compare("World-area pointers", generated_worlds, world_areas)

    metatiles = [
        [int(value) for value in row.split(",")]
        for row in re.findall(r"\{([0-9,]+)\}", extract_table(generated, "Metatiles"))
    ]
    compare("Metatile definitions", metatiles, exporter.parse_metatiles(render_source))

    source_palettes = {
        "water": exporter.parse_palette_rows(palette_source, "WaterPaletteData"),
        "ground": exporter.parse_palette_rows(palette_source, "GroundPaletteData"),
        "underground": exporter.parse_palette_rows(palette_source, "UndergroundPaletteData"),
        "castle": exporter.parse_palette_rows(palette_source, "CastlePaletteData"),
    }
    exported_palettes = named_tables(extract_table(generated, "Palettes"))
    for name, source_rows in source_palettes.items():
        palette = named_tables(exported_palettes[name])
        exported_rows = []
        for key in ("background", "sprites"):
            exported_rows.extend(
                [hex_values(row) for row in re.findall(r"\{([^{}]*)\}", palette[key])]
            )
        compare(f"{name} palette rows", exported_rows, source_rows)

    source_tables = {
        "BackSceneryData": parse_asm_table(area_source, "BackSceneryData", "BackSceneryMetatiles:"),
        "BackSceneryMetatiles": parse_asm_table(area_source, "BackSceneryMetatiles", "FSceneDataOffsets:"),
        "ForeSceneryData": parse_asm_table(area_source, "ForeSceneryData", "TerrainMetatiles:"),
        "TerrainMetatiles": parse_asm_table(area_source, "TerrainMetatiles", "TerrainRenderBits:"),
        "TerrainRenderBits": parse_asm_table(area_source, "TerrainRenderBits", ".proc AreaParserCore"),
    }
    for name, expected in source_tables.items():
        compare(name, hex_values(extract_table(generated, name)), expected)

    chr_tables = extract_table(generated, "CHR")
    chr_paths = {
        "bgWater": "bg_water.chr",
        "bgGround": "bg_ground.chr",
        "bgUnderground": "bg_underground.chr",
        "bgCastle": "bg_castle.chr",
        "mario": "sprites_mario.chr",
        "misc": "sprites_misc.chr",
        "enemies": "sprites_enemies.chr",
    }
    for name, filename in chr_paths.items():
        match = re.search(
            rf"(?m)^[ \t]*{re.escape(name)}[ \t]*=[ \t]*(.*?)[ \t]*,\s*$",
            chr_tables,
            re.DOTALL,
        )
        if not match:
            raise ExportMismatch(f"Missing CHR export {name}")
        exported_hex = "".join(re.findall(r'"([0-9A-Fa-f]+)"', match.group(1))).lower()
        source_hex = (ROOT / "chr/mmc5" / filename).read_bytes().hex()
        compare(f"CHR asset {filename}", exported_hex, source_hex)

    print(
        "Export validation passed: "
        f"{len(area_order)} areas, {len(enemy_order)} enemy streams, "
        f"{len(world_areas)} world routes, {len(metatiles)} metatiles, "
        f"{sum(len(rows) for rows in source_palettes.values())} palette rows, "
        f"{len(chr_paths)} CHR assets."
    )


if __name__ == "__main__":
    try:
        main()
    except (ExportMismatch, ValueError, KeyError, IndexError) as error:
        print(f"Export validation failed: {error}", file=sys.stderr)
        sys.exit(1)
