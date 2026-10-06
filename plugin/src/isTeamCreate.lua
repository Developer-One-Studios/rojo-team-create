local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

--[[
	Whether this plugin is running in the edit DataModel of a Team Create
	session. In edit mode, Players is only populated by Team Create
	collaborators.
]]
local function isTeamCreate(): boolean
	return RunService:IsEdit() and #Players:GetPlayers() > 0
end

return isTeamCreate
