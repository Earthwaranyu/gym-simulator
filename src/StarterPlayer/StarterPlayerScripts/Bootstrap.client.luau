--!strict
--[[
	Client entry point. The only LocalScript — everything else is a controller module
	under Controllers/ that the Loader discovers.

	The WaitForChild calls guarantee the shared modules have replicated before we
	index them; the direct paths afterwards are what let the type checker resolve
	the modules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

ReplicatedStorage:WaitForChild("Modules")
ReplicatedStorage:WaitForChild("Remotes")

local Loader = require(ReplicatedStorage.Modules.Loader)

Loader.AddContainer(script.Parent.Controllers)
Loader.Ignite()
