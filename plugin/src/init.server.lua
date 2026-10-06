if not plugin then
	return
end

-- The edit DataModel is holding staged changes in Team Create until this runs,
-- so do it before anything slower like mounting the UI.
require(script.StagedPlaytest).signalReadyIfStaged()

local Rojo = script:FindFirstAncestor("Rojo")
local Packages = Rojo.Packages

local Log = require(Packages.Log)
local Roact = require(Packages.Roact)

local Settings = require(script.Settings)
local Config = require(script.Config)
local App = require(script.App)

Log.setLogLevelThunk(function()
	return Log.Level[Settings:get("logLevel")] or Log.Level.Info
end)

local app = Roact.createElement(App, {
	plugin = plugin,
})
local tree = Roact.mount(app, game:GetService("CoreGui"), "Rojo Team Create UI")

plugin.Unloading:Connect(function()
	Roact.unmount(tree)
end)

if Config.isDevBuild then
	local TestEZ = require(script.Parent.TestEZ)

	require(script.runTests)(TestEZ)
end
