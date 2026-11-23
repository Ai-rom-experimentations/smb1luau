#!/usr/bin/env python3
"""Pack the Roblox Luau sources into an editable Studio .rbxlx place.

This is a small offline alternative to `rojo build` for this project's
service layout. The emitted XML place opens directly in Roblox Studio.
"""
from __future__ import annotations

import argparse
from pathlib import Path
from xml.sax.saxutils import escape
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


def xml_text(value: str) -> str:
    return escape(value, {"\r": "&#13;"})


def prop(tag: str, name: str, value: str) -> str:
    return f'<{tag} name="{name}">{xml_text(value)}</{tag}>'


def item(
    class_name: str,
    referent: str,
    name: str,
    children: list[str] | None = None,
    source: str | None = None,
    extra_properties: list[str] | None = None,
    indent: int = 0,
) -> str:
    prefix = " " * indent
    properties = [prop("string", "Name", name)]
    properties.extend(extra_properties or [])
    if class_name == "LocalScript":
        properties.append('<bool name="Disabled">false</bool>')
    if source is not None:
        properties.append(prop("ProtectedString", "Source", source))

    parts = [
        f'{prefix}<Item class="{class_name}" referent="{referent}">',
        f"{prefix}  <Properties>",
    ]
    # A Source property's text may contain newlines; prefix only its XML tag so
    # the Luau source itself is preserved byte-for-byte inside the XML text.
    parts.extend(f"{prefix}    {value}" for value in properties)
    parts.append(f"{prefix}  </Properties>")
    parts.extend(children or [])
    parts.append(f"{prefix}</Item>")
    return "\n".join(parts)


def identity_frame(name: str) -> str:
    values = {
        "X": "0", "Y": "0", "Z": "0",
        "R00": "1", "R01": "0", "R02": "0",
        "R10": "0", "R11": "1", "R12": "0",
        "R20": "0", "R21": "0", "R22": "1",
    }
    inner = "".join(f"<{key}>{value}</{key}>" for key, value in values.items())
    return f'<CoordinateFrame name="{name}">{inner}</CoordinateFrame>'


def validate_place(output: Path) -> None:
    root = ET.parse(output).getroot()
    instances = list(root.iter("Item"))
    referents = [instance.get("referent") for instance in instances]
    if len(referents) != len(set(referents)):
        raise ValueError("Duplicate Roblox instance referents in generated place")

    def instance_name(instance: ET.Element) -> str:
        name = instance.find("./Properties/string[@name='Name']")
        return "" if name is None else name.text or ""

    by_class_name = {(instance.get("class"), instance_name(instance)): instance for instance in instances}
    for name in ("SMBData", "SMBWorld", "SMBRenderer", "SMBGame"):
        instance = by_class_name.get(("ModuleScript", name))
        source = None if instance is None else instance.find("./Properties/ProtectedString[@name='Source']")
        expected = (ROOT / f"roblox/src/ReplicatedStorage/{name}.lua").read_text(encoding="utf-8")
        if source is None or source.text != expected:
            raise ValueError(f"Generated ModuleScript source mismatch: {name}")

    client = by_class_name.get(("LocalScript", "SMBClient"))
    client_source = None if client is None else client.find("./Properties/ProtectedString[@name='Source']")
    expected_client = (
        ROOT / "roblox/src/StarterPlayer/StarterPlayerScripts/SMBClient.client.lua"
    ).read_text(encoding="utf-8")
    if client_source is None or client_source.text != expected_client:
        raise ValueError("Generated LocalScript source mismatch: SMBClient")

    workspace = by_class_name.get(("Workspace", "Workspace"))
    current_camera = None if workspace is None else workspace.find("./Properties/Ref[@name='CurrentCamera']")
    camera = by_class_name.get(("Camera", "Camera"))
    if current_camera is None or camera is None or current_camera.text != camera.get("referent"):
        raise ValueError("Workspace.CurrentCamera does not reference the place camera")

    starter_player = by_class_name.get(("StarterPlayer", "StarterPlayer"))
    scripts = None if starter_player is None else starter_player.find("./Item[@class='StarterPlayerScripts']")
    if scripts is None or scripts.find("./Item[@class='LocalScript']") is None:
        raise ValueError("SMBClient is not under StarterPlayerScripts")
    print("validated place XML: 4 ModuleScripts, LocalScript source, service tree and camera reference.")


def build_place(output: Path) -> None:
    replicated_root = ROOT / "roblox/src/ReplicatedStorage"
    module_items = []
    for index, name in enumerate(("SMBData", "SMBWorld", "SMBRenderer", "SMBGame"), start=101):
        source = (replicated_root / f"{name}.lua").read_text(encoding="utf-8")
        module_items.append(item("ModuleScript", f"RBX{index:04d}", name, source=source, indent=4))

    client_source = (
        ROOT / "roblox/src/StarterPlayer/StarterPlayerScripts/SMBClient.client.lua"
    ).read_text(encoding="utf-8")
    client = item("LocalScript", "RBX0202", "SMBClient", source=client_source, indent=6)
    starter_player_scripts = item(
        "StarterPlayerScripts", "RBX0201", "StarterPlayerScripts", [client], indent=4
    )
    starter_player = item("StarterPlayer", "RBX0203", "StarterPlayer", [starter_player_scripts], indent=2)
    replicated_storage = item(
        "ReplicatedStorage", "RBX0301", "ReplicatedStorage", module_items, indent=2
    )

    camera = item(
        "Camera",
        "RBX0022",
        "Camera",
        extra_properties=[
            identity_frame("CFrame"),
            identity_frame("Focus"),
            '<token name="CameraType">0</token>',
            '<float name="FieldOfView">70</float>',
        ],
        indent=4,
    )
    workspace = item(
        "Workspace",
        "RBX0010",
        "Workspace",
        [camera],
        extra_properties=[
            '<Ref name="CurrentCamera">RBX0022</Ref>',
            '<bool name="ExplicitAutoJoints">true</bool>',
        ],
        indent=2,
    )

    # Include the standard services a fresh place normally exposes. Workspace
    # stays empty apart from its camera because this game is presented in a GUI.
    services = [
        workspace,
        item("Players", "RBX0011", "Players", indent=2),
        item("Lighting", "RBX0012", "Lighting", indent=2),
        item("ReplicatedFirst", "RBX0013", "ReplicatedFirst", indent=2),
        replicated_storage,
        item("ServerScriptService", "RBX0014", "ServerScriptService", indent=2),
        item("ServerStorage", "RBX0015", "ServerStorage", indent=2),
        item("StarterGui", "RBX0016", "StarterGui", indent=2),
        item("StarterPack", "RBX0017", "StarterPack", indent=2),
        starter_player,
        item("Teams", "RBX0018", "Teams", indent=2),
        item("SoundService", "RBX0019", "SoundService", indent=2),
        item("Chat", "RBX0020", "Chat", indent=2),
        item("TextChatService", "RBX0021", "TextChatService", indent=2),
    ]

    document = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
        '  <External>null</External>',
        '  <External>nil</External>',
    ]
    document.extend(services)
    document.append("</roblox>")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(document) + "\n", encoding="utf-8")
    label = output.relative_to(ROOT) if output.is_relative_to(ROOT) else output
    print(f"wrote {label} ({output.stat().st_size:,} bytes)")
    validate_place(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=ROOT / "roblox/SMB1Luau.rbxlx",
        help="output path (default: roblox/SMB1Luau.rbxlx)",
    )
    args = parser.parse_args()
    output = args.output if args.output.is_absolute() else ROOT / args.output
    build_place(output)


if __name__ == "__main__":
    main()
