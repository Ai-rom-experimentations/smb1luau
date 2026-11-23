# SMB1 Luau prototype

This folder contains a source-data-driven, single-player Roblox client for the SMB1Base source tree. It renders an NES-sized framebuffer from the checked-in CHR/metatile tables and decodes area/enemy records from the assembly data. The first gameplay runtime now supports walking, running, jumping, collisions, blocks/rewards, coins, basic enemies, fireballs, warp-pipe links, flagpole/course transitions, keyboard/gamepad input, and touch buttons.

The project is still a prototype, not a verified 1:1 port. Some area-object art and special enemy behavior are approximate; bonus-room/vine behavior, precise NES physics, full Bowser/bridge routines, sound, multiplayer, and persistence are not implemented. `SMBRenderer.lua` uses Roblox `AssetService:CreateEditableImage`, so Studio compatibility still needs to be confirmed in a real place.

## Open the ready-to-test place

Open [`SMB1Luau.rbxlx`](SMB1Luau.rbxlx) directly in Roblox Studio, then press **Play**. This is Roblox's editable XML place format; if you specifically need the binary `.rbxl` format, open it in Studio and use **File → Save to File As**.

In Studio, open **Game Settings → Security** and enable **Allow Mesh & Image APIs**. The renderer shows a setup message if `EditableImage` creation is unavailable. No Roblox character is needed; the game runs in a full-screen GUI.

To regenerate the place after changing Luau files, run `python3 roblox/tools/build_place_xml.py`. For live Rojo sync instead, install the Rojo CLI and Studio plugin, run `rojo serve roblox/default.project.json` from the repository root, and connect the plugin. You can also build with `rojo build roblox/default.project.json -o roblox/SMB1Luau.rbxlx`. Other generated place files are ignored; the requested `SMB1Luau.rbxlx` is retained as the ready-to-test artifact.

## Controls

- Move: arrow keys or A/D; W/S or up/down also navigate the title menu.
- Jump: Space, Z, or gamepad A.
- Run / fire: Shift or X; fireballs require the fire-flower state.
- Enter / gamepad Start: start, pause, or resume.
- Escape or P: pause/resume.
- Mobile: on-screen left, right, run, and jump buttons.
- Down while standing on a linked warp pipe: enter the pipe.

## Source data and checks

`tools/export_data.py` regenerates `src/ReplicatedStorage/SMBData.lua` from the area/enemy arrays, palette tables, metatile definitions, and `chr/mmc5` binary graphics. Run `python3 roblox/tools/test_export_data.py` to compare the generated Lua tables and CHR hex against those source assets. `SMBWorld.lua` and the gameplay runtime still need a Roblox Studio playtest; the repository has no bundled Studio/Roblox runtime.
