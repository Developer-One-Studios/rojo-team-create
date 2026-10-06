--[[
	Helpers for running a local playtest that includes staged changes.

	Studio's Play button snapshots the edit DataModel, and game scripts inside
	the playtest start running before any plugin is loaded into it. That means
	the only way to get staged changes into a playtest is for them to be in the
	edit DataModel at the moment Studio takes its snapshot. The edit plugin
	applies them, starts the test with StudioTestService, and then waits for the
	plugin inside the playtest server to report that it has loaded. By then the
	snapshot has been taken, so the edit plugin can revert its changes.

	The two plugin instances live in different DataModels, so they communicate
	through the test args (edit -> playtest) and plugin settings
	(playtest -> edit).
]]

local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local plugin = plugin or script:FindFirstAncestorWhichIsA("Plugin")
local Rojo = script:FindFirstAncestor("Rojo")
local Packages = Rojo.Packages

local Log = require(Packages.Log)
local Promise = require(Packages.Promise)

local READY_SETTING = "Rojo_stagedPlaytestReady"
local ARGS_TOKEN_KEY = "RojoStagedPlaytest"
local ARGS_URL_KEY = "RojoServerUrl"

-- How long to keep staged changes in the edit DataModel if the playtest never
-- reports back, e.g. because the plugin is disabled in playtests.
local SNAPSHOT_TIMEOUT = 20
local POLL_INTERVAL = 0.05

local StagedPlaytest = {}

StagedPlaytest.Mode = {
	Play = "Play",
	Run = "Run",
}

function StagedPlaytest.createArgs(token: string, serverUrl: string?)
	return {
		[ARGS_TOKEN_KEY] = token,
		[ARGS_URL_KEY] = serverUrl,
	}
end

--[[
	Reads staged playtest info out of a test args value. Returns nil if the args
	were not created by `createArgs`.
]]
function StagedPlaytest.parseArgs(args: any): { token: string, serverUrl: string? }?
	if typeof(args) ~= "table" or typeof(args[ARGS_TOKEN_KEY]) ~= "string" then
		return nil
	end

	local serverUrl = args[ARGS_URL_KEY]
	if typeof(serverUrl) ~= "string" then
		serverUrl = nil
	end

	return {
		token = args[ARGS_TOKEN_KEY],
		serverUrl = serverUrl,
	}
end

--[[
	Returns the staged playtest info for the playtest this plugin is running in,
	or nil if this is not a staged playtest.
]]
function StagedPlaytest.getCurrent()
	if not RunService:IsRunning() then
		return nil
	end

	local success, args = pcall(StudioTestService.GetTestArgs, StudioTestService)
	if not success then
		return nil
	end

	return StagedPlaytest.parseArgs(args)
end

function StagedPlaytest.isEditModeActive(): boolean
	local success, active = pcall(function()
		return StudioTestService.EditModeActive
	end)

	-- Older Studio versions without this property can't start staged
	-- playtests anyway, so treat them as idle.
	return not success or active
end

--[[
	Called by the plugin inside a playtest server as early as possible. The edit
	plugin waits for this before reverting the staged changes it applied.
]]
function StagedPlaytest.signalReadyIfStaged()
	if not (plugin and RunService:IsRunning() and RunService:IsServer()) then
		return
	end

	local current = StagedPlaytest.getCurrent()
	if current == nil then
		return
	end

	Log.trace("Signalling that staged playtest {} has loaded", current.token)
	plugin:SetSetting(READY_SETTING, current.token)
end

--[[
	Starts a playtest in a new thread. Returns a handle that tracks whether the
	playtest has finished, since the StudioTestService calls yield until then.
]]
function StagedPlaytest.launch(mode: string, args: any)
	local handle = {
		finished = false,
		error = nil,
	}

	task.spawn(function()
		local success, err = pcall(function()
			if mode == StagedPlaytest.Mode.Run then
				return StudioTestService:ExecuteRunModeAsync(args)
			else
				return StudioTestService:ExecutePlayModeAsync(args)
			end
		end)

		if not success then
			handle.error = err
			Log.warn("Could not start playtest: {}", err)
		end
		handle.finished = true
	end)

	return handle
end

--[[
	Resolves once the playtest identified by `token` has loaded, or once it is
	safe to assume it never will. Resolves with "ready", "finished" or "timeout".
]]
function StagedPlaytest.waitForSnapshot(token: string, handle)
	return Promise.new(function(resolve)
		local startTime = os.clock()

		while true do
			if plugin and plugin:GetSetting(READY_SETTING) == token then
				resolve("ready")
				break
			elseif handle.finished then
				resolve("finished")
				break
			elseif os.clock() - startTime > SNAPSHOT_TIMEOUT then
				resolve("timeout")
				break
			end

			task.wait(POLL_INTERVAL)
		end

		if plugin then
			plugin:SetSetting(READY_SETTING, nil)
		end
	end)
end

return StagedPlaytest
