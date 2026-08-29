--!strict
--[[
	cut_body_mesh — authors the player body, once, from Studio's command bar.

	Paste this into the command bar in **Edit** mode (not Play) and run it. It cuts
	the generated whole-body mesh into R15 parts and leaves them in
	ReplicatedStorage.BodyRig, which is saved with the place and is what players
	actually wear. Re-run it whenever `BodyMeshConfig` changes.

	Why this is an authoring step rather than something the game does on its own:

	EditableMesh draws on a memory budget that is far smaller on a game client than
	in Studio's edit session. Measured on this project: the fourteen pieces build
	without complaint in Edit (6,208 vertices) and cannot be allocated at all in
	Play. It is not a size problem that tuning fixes — a MeshPart keeps a *live*
	dependency on the EditableMesh it came from, so the pieces have to stay
	allocated for as long as the body exists, and that is the one shape the client
	budget cannot afford. Cutting once here sidesteps it entirely: the finished
	MeshParts are ordinary instances that clone freely.

	The cut itself lives in `BodyMeshBuilder` so this script and the game's runtime
	fallback can never drift apart.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BodyMeshBuilder = require(ReplicatedStorage.Modules.BodyMeshBuilder)
local BodyMeshConfig = require(ReplicatedStorage.Modules.BodyMeshConfig)

local existing = ReplicatedStorage:FindFirstChild("BodyRig")
if existing ~= nil then
	existing:Destroy()
end

local folder = BodyMeshBuilder.Cut()
folder.Name = "BodyRig"
folder:SetAttribute("SourceMeshAssetId", BodyMeshConfig.SOURCE_ASSET_ID)

-- Anchored so the pieces sit still in the place file; the controller clears this
-- on the clones it welds to a character.
for _, part in folder:GetChildren() do
	if part:IsA("BasePart") then
		part.Anchored = true
	end
end

folder.Parent = ReplicatedStorage

print(`cut_body_mesh: wrote {#folder:GetChildren()} parts to ReplicatedStorage.BodyRig — save the place to keep them`)
