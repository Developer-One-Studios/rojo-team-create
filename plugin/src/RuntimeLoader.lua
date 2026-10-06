--[[
	The runtime loader lets staged changes reach local playtests without ever
	leaving your machine.

	Places that opt in get a small loader script in ServerScriptService, and
	their Rojo-managed scripts are deployed turned off and tagged. When any
	server starts, the loader turns those scripts on.

	Before that, if ServerStorage contains the overlay Camera, the loader swaps
	its contents into the game. Team Create doesn't replicate a Camera's
	contents, but playtests are copied from your own DataModel, so the overlay
	only ever exists in playtests you start yourself. The plugin keeps the
	overlay up to date with your staged changes.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local Rojo = script:FindFirstAncestor("Rojo")
local Packages = Rojo.Packages

local Log = require(Packages.Log)

local InstanceMap = require(script.Parent.InstanceMap)
local PatchSet = require(script.Parent.PatchSet)
local decodeValue = require(script.Parent.Reconciler.decodeValue)
local reify = require(script.Parent.Reconciler.reify)
local setProperty = require(script.Parent.Reconciler.setProperty)

local LOADER_NAME = "ROJO_TEAM_CREATE_LOADER"
local OVERLAY_NAME = "ROJO_TEAM_CREATE_LOCAL"
local ENABLE_TAG = "RojoTeamCreateEnable"

-- Folders inside the overlay. These have to match the loader's source.
local REMOVE_FOLDER_NAME = "REMOVE"
local REPLACE_FOLDER_NAME = "REPLACE"
local ADD_FOLDER_NAME = "ADD"

-- Names from before these instances were renamed, so places that were set up
-- with an earlier build keep working and get upgraded.
local LEGACY_LOADER_NAMES = {
	RojoTeamCreateLoader = true,
}
local LEGACY_OVERLAY_NAMES = {
	RojoTeamCreateLocal = true,
}

-- This runs as a normal game script, so it can only use APIs available at
-- runtime. It must not yield, so that it finishes before any player joins.
local LOADER_SOURCE = [[
--[=[
	⛔⛔⛔ DO NOT DELETE OR EDIT THIS SCRIPT ⛔⛔⛔
]=]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local ENABLE_TAG = "RojoTeamCreateEnable"

local function attempt(description, callback)
	local success, err = pcall(callback)
	if not success then
		warn(`[ROJO_TEAM_CREATE_LOADER] Could not {description}: {err}`)
	end
end

local function getTarget(entry)
	if entry:IsA("ObjectValue") and entry.Value ~= nil and entry.Value.Parent ~= nil then
		return entry.Value
	end
	return nil
end

local overlay = ServerStorage:FindFirstChild("ROJO_TEAM_CREATE_LOCAL")
if overlay ~= nil and overlay:IsA("Camera") then
	local replacements = {}

	local removeFolder = overlay:FindFirstChild("REMOVE")
	if removeFolder ~= nil then
		for _, entry in removeFolder:GetChildren() do
			local target = getTarget(entry)
			if target ~= nil then
				attempt(`remove {target:GetFullName()}`, function()
					target:Destroy()
				end)
			end
		end
	end

	local replaceFolder = overlay:FindFirstChild("REPLACE")
	if replaceFolder ~= nil then
		for _, entry in replaceFolder:GetChildren() do
			local target = getTarget(entry)
			local replacement = entry:GetChildren()[1]
			if target ~= nil and replacement ~= nil then
				attempt(`replace {target:GetFullName()}`, function()
					for _, child in target:GetChildren() do
						child.Parent = replacement
					end
					replacement.Parent = target.Parent
					target:Destroy()
					replacements[target] = replacement
				end)
			end
		end
	end

	local addFolder = overlay:FindFirstChild("ADD")
	if addFolder ~= nil then
		for _, entry in addFolder:GetChildren() do
			local parent = if entry:IsA("ObjectValue") then entry.Value else nil
			parent = if parent ~= nil then replacements[parent] or parent else nil
			if parent ~= nil and parent.Parent ~= nil then
				for _, child in entry:GetChildren() do
					attempt(`add {child.Name} to {parent:GetFullName()}`, function()
						child.Parent = parent
					end)
				end
			end
		end
	end

	overlay:Destroy()
end

for _, object in CollectionService:GetTagged(ENABLE_TAG) do
	if object:IsA("BaseScript") then
		object.Enabled = true
	end
end

if #Players:GetPlayers() > 0 then
	warn("[ROJO_TEAM_CREATE_LOADER] A player joined before the game's scripts were turned on, so some of their scripts may not run.")
end
]]

local function withRecording(name: string, callback)
	local recording = ChangeHistoryService:TryBeginRecording(name)
	local success, err = pcall(callback)
	if recording then
		ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end
	if not success then
		error(err, 0)
	end
end

local SCRIPT_CLASSES = {
	Script = true,
	LocalScript = true,
}

local RuntimeLoader = {}

RuntimeLoader.LOADER_NAME = LOADER_NAME
RuntimeLoader.OVERLAY_NAME = OVERLAY_NAME
RuntimeLoader.ENABLE_TAG = ENABLE_TAG

function RuntimeLoader.isLoaderName(name: string): boolean
	return name == LOADER_NAME or LEGACY_LOADER_NAMES[name] == true
end

local function findLoaders(): { Script }
	local loaders = {}
	for _, child in ServerScriptService:GetChildren() do
		if RuntimeLoader.isLoaderName(child.Name) and child:IsA("Script") then
			-- Prefer loaders that already use the current name.
			if child.Name == LOADER_NAME then
				table.insert(loaders, 1, child)
			else
				table.insert(loaders, child)
			end
		end
	end

	return loaders
end

function RuntimeLoader.findLoader(): Script?
	return findLoaders()[1]
end

function RuntimeLoader.isInstalled(): boolean
	return RuntimeLoader.findLoader() ~= nil
end

--[[
	Whether an instance belongs to the runtime loader rather than to a Rojo
	project, so that syncing never deletes it as an unknown instance.
]]
function RuntimeLoader.isPluginOwned(instance: Instance): boolean
	local success, owned = pcall(function()
		return (RuntimeLoader.isLoaderName(instance.Name) and instance.Parent == ServerScriptService)
			or (
				(instance.Name == OVERLAY_NAME or LEGACY_OVERLAY_NAMES[instance.Name] == true)
				and instance.Parent == ServerStorage
			)
	end)

	return success and owned
end

function RuntimeLoader.removePluginOwnedFromPatch(patch)
	for index = #patch.removed, 1, -1 do
		local removed = patch.removed[index]
		if typeof(removed) == "Instance" and RuntimeLoader.isPluginOwned(removed) then
			table.remove(patch.removed, index)
		end
	end
end

--[[
	Creates the loader script, or updates it if it was made by an older version
	of the plugin. Returns whether anything changed.
]]
function RuntimeLoader.writeLoader(): boolean
	local loader = RuntimeLoader.findLoader()
	if
		loader ~= nil
		and loader.Name == LOADER_NAME
		and ScriptEditorService:GetEditorSource(loader) == LOADER_SOURCE
	then
		return false
	end

	withRecording("Rojo: Update runtime loader", function()
		if loader == nil then
			loader = Instance.new("Script")
			loader.Name = LOADER_NAME
			loader.Source = LOADER_SOURCE
			loader.Parent = ServerScriptService
		else
			loader.Name = LOADER_NAME
			ScriptEditorService:UpdateSourceAsync(loader, function()
				return LOADER_SOURCE
			end)
		end
	end)

	return true
end

--[[
	Removes the loader and turns every script it was starting back on, so the
	game keeps working without it.
]]
function RuntimeLoader.uninstall()
	withRecording("Rojo: Remove runtime loader", function()
		for _, object in CollectionService:GetTagged(ENABLE_TAG) do
			if object:IsA("BaseScript") then
				object.Enabled = true
			end
			object:RemoveTag(ENABLE_TAG)
		end

		local loader = RuntimeLoader.findLoader()
		if loader ~= nil then
			loader:Destroy()
		end
	end)

	RuntimeLoader.clearOverlay()
end

local function isEncodedBool(encoded, value: boolean): boolean
	return typeof(encoded) == "table" and encoded.Bool == value
end

--[[
	Changes the server's virtual instances so that scripts are deployed turned
	off, and tagged for the loader if the project has them turned on.
]]
function RuntimeLoader.transformVirtualInstances(virtualInstances, instanceMap)
	for id, virtualInstance in virtualInstances do
		if not SCRIPT_CLASSES[virtualInstance.ClassName] then
			continue
		end

		local properties = virtualInstance.Properties
		local enabledInProject = not (
			isEncodedBool(properties.Disabled, true) or isEncodedBool(properties.Enabled, false)
		)

		properties.Disabled = nil
		properties.Enabled = { Bool = false }

		-- Tags set in Studio are kept unless the project sets the tags itself,
		-- the same as for any other property Rojo doesn't manage.
		local tags
		if typeof(properties.Tags) == "table" and typeof(properties.Tags.Tags) == "table" then
			tags = table.clone(properties.Tags.Tags)
		else
			local instance = instanceMap.fromIds[id]
			tags = if instance ~= nil then instance:GetTags() else {}
		end

		local tagIndex = table.find(tags, ENABLE_TAG)
		if enabledInProject and tagIndex == nil then
			table.insert(tags, ENABLE_TAG)
		elseif not enabledInProject and tagIndex ~= nil then
			table.remove(tags, tagIndex)
		end

		properties.Tags = { Tags = tags }
	end
end

--[[
	Returns the part of a staged patch that only switches deployed scripts over
	to the loader, without any of the other staged changes.
]]
function RuntimeLoader.getScriptConversion(patch)
	local conversion = PatchSet.newEmpty()

	for _, update in patch.updated do
		local changedProperties = {}
		for _, propertyName in { "Enabled", "Tags" } do
			changedProperties[propertyName] = update.changedProperties[propertyName]
		end

		if next(changedProperties) ~= nil then
			table.insert(conversion.updated, {
				id = update.id,
				changedProperties = changedProperties,
			})
		end
	end

	return conversion
end

function RuntimeLoader.clearOverlay()
	for _, child in ServerStorage:GetChildren() do
		if (child.Name == OVERLAY_NAME or LEGACY_OVERLAY_NAMES[child.Name] == true) and child:IsA("Camera") then
			child:Destroy()
		end
	end
end

-- Source is set directly on overlay copies. They never replicate, so they
-- don't need to go through ScriptEditorService, which happens asynchronously.
local function applyProperty(instance: Instance, propertyName: string, encodedValue, instanceMap): boolean
	local decodeSuccess, value = decodeValue(encodedValue, instanceMap)
	if not decodeSuccess then
		return false
	end

	if propertyName == "Source" and instance:IsA("LuaSourceContainer") then
		return pcall(function()
			(instance :: any).Source = value
		end)
	end

	return (setProperty(instance, propertyName, value))
end

local function createEntry(folder: Instance, target: Instance): ObjectValue
	local entry = Instance.new("ObjectValue")
	entry.Name = target.Name
	entry.Value = target
	entry.Parent = folder
	return entry
end

local function canReplace(instance: Instance): boolean
	-- Services and containers like StarterPlayerScripts can't be created, so
	-- changes to them can't be swapped in at runtime.
	if instance == game or instance.Parent == game then
		return false
	end

	local success, created = pcall(Instance.new, instance.ClassName)
	if success then
		created:Destroy()
	end
	return success
end

local function buildReplacement(instance: Instance, update, instanceMap): Instance?
	local replacement
	if update.changedClassName ~= nil then
		local success, created = pcall(Instance.new, update.changedClassName)
		if not success then
			return nil
		end
		replacement = created
		replacement.Name = instance.Name
	else
		local success, copy = pcall(function()
			return instance:Clone()
		end)
		if not success or copy == nil then
			return nil
		end
		replacement = copy
		replacement:ClearAllChildren()
	end

	if update.changedName ~= nil then
		replacement.Name = update.changedName
	end

	for propertyName, encodedValue in update.changedProperties or {} do
		if not applyProperty(replacement, propertyName, encodedValue, instanceMap) then
			Log.debug("Could not include {}.{} in the staged playtest copy", instance:GetFullName(), propertyName)
		end
	end

	return replacement
end

--[[
	Rebuilds the overlay so that it matches the staged patch. Returns how many
	staged changes couldn't be included.
]]
function RuntimeLoader.writeOverlay(patch, instanceMap): number
	RuntimeLoader.clearOverlay()

	if PatchSet.isEmpty(patch) then
		return 0
	end

	local skipped = 0

	local overlay = Instance.new("Camera")
	overlay.Name = OVERLAY_NAME

	local removeFolder = Instance.new("Folder")
	removeFolder.Name = REMOVE_FOLDER_NAME
	removeFolder.Parent = overlay

	local replaceFolder = Instance.new("Folder")
	replaceFolder.Name = REPLACE_FOLDER_NAME
	replaceFolder.Parent = overlay

	local addFolder = Instance.new("Folder")
	addFolder.Name = ADD_FOLDER_NAME
	addFolder.Parent = overlay

	for _, removed in patch.removed do
		local instance = if typeof(removed) == "Instance" then removed else instanceMap.fromIds[removed]
		if instance ~= nil and not RuntimeLoader.isPluginOwned(instance) then
			createEntry(removeFolder, instance)
		end
	end

	for _, update in patch.updated do
		local instance = instanceMap.fromIds[update.id]
		if instance == nil or not canReplace(instance) then
			skipped += 1
			continue
		end

		local replacement = buildReplacement(instance, update, instanceMap)
		if replacement == nil then
			skipped += 1
			continue
		end

		replacement.Parent = createEntry(replaceFolder, instance)
	end

	-- Added instances are created with a scratch InstanceMap so they don't end
	-- up tracked by the session, while refs can still point at real instances.
	local scratchMap = InstanceMap.new(nil)
	scratchMap.fromIds = table.clone(instanceMap.fromIds)
	scratchMap.fromInstances = table.clone(instanceMap.fromInstances)

	local deferredRefs = {}
	for id, virtualInstance in patch.added do
		if patch.added[virtualInstance.Parent] ~= nil then
			continue
		end

		local parent = instanceMap.fromIds[virtualInstance.Parent]
		if parent == nil then
			skipped += 1
			continue
		end

		local failed = reify.reifyInstance(deferredRefs, scratchMap, patch.added, id, createEntry(addFolder, parent))
		skipped += PatchSet.countInstances(failed)
	end
	reify.applyDeferredRefs(scratchMap, deferredRefs, PatchSet.newEmpty())

	-- reify writes sources asynchronously, so set them directly as well.
	for id, virtualInstance in patch.added do
		local instance = scratchMap.fromIds[id]
		if instance ~= nil and virtualInstance.Properties.Source ~= nil then
			applyProperty(instance, "Source", virtualInstance.Properties.Source, instanceMap)
		end
	end
	scratchMap:stop()

	overlay.Parent = ServerStorage

	return skipped
end

return RuntimeLoader
