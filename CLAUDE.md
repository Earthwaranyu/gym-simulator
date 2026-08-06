# CLAUDE.md - Gym Simulator Architecture Rules

## Tech Stack
- Language: Luau (`--!strict` mode required on all scripts)
- Environment: Rojo sync to Roblox Studio
- Version Control: Git 
- Data Management: ProfileStore (loleris's supported successor to ProfileService, which is archived)

## Core Game Mechanics & Architecture
1. **The 5 Core Stats**: Arms, Chest, Back, Core, Legs.
2. **Massive Numbers**: Stats scale into the Billions and Trillions. Use a Number/Suffix abbreviation module.
3. **Client-Server Boundary**: Client handles UI/inputs. Server handles stat math, the automatic training loop, and DataStores.
4. **Muscle Deformation**: Avatar scaling relies on `NumberValue` instances inside the player's character model to drive server-sided MeshPart scaling.
5. **Player can pvp**: Players can kill other players while they are training to annoy them. Training is automatic on proximity (no stamina, no clicking), so a hit knocks the victim off the machine and resets their combo.
6. **Player can avoid pvp**: Players can avoid pvp by buying immortal potion for 1 hour costing 19 robux per potion. We can have 1 day potion for 79 robux also. Players can buy VIP gamepass costing 199 robux which give you 1 hour immortal potion per day. Player who drink immortal potion will have a barrier between body.
7. **Player can have reputation**: Criminal, guardian, Hero, etc.
8. **In the tab bar**: it shows that player overall power, and reputation.

## Project Structure
- `src/ServerScriptService/Core/`: Server managers (Data, Equipment, Progression).
- `src/ReplicatedStorage/Modules/`: Shared logic (Number formatters, Equipment configurations).
- `src/StarterPlayer/StarterPlayerScripts/`: Client controllers (Input, UI, animations).


## Git
You commit one checklist per one commit but don't make you as a contributor or co-contributor just omit the co-author things.