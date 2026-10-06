local StudioService = game:GetService("StudioService")
local RunService = game:GetService("RunService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local SerializationService = game:GetService("SerializationService")
local Selection = game:GetService("Selection")
local HttpService = game:GetService("HttpService")
local ScriptEditorService = game:GetService("ScriptEditorService")
local ServerScriptService = game:GetService("ServerScriptService")

local Packages = script.Parent.Parent.Packages
local Log = require(Packages.Log)
local Fmt = require(Packages.Fmt)
local t = require(Packages.t)
local Promise = require(Packages.Promise)
local Timer = require(script.Parent.Timer)

local ChangeBatcher = require(script.Parent.ChangeBatcher)
local encodePatchUpdate = require(script.Parent.ChangeBatcher.encodePatchUpdate)
local InstanceMap = require(script.Parent.InstanceMap)
local PatchSet = require(script.Parent.PatchSet)
local Reconciler = require(script.Parent.Reconciler)
local strict = require(script.Parent.strict)
local Settings = require(script.Parent.Settings)
local StagedPlaytest = require(script.Parent.StagedPlaytest)
local RuntimeLoader = require(script.Parent.RuntimeLoader)
local orderSwaps = require(script.Parent.orderSwaps)
local decodeValue = require(script.Parent.Reconciler.decodeValue)

-- File changes tend to arrive in bursts, so wait briefly before recomputing the
-- staged changes so that a burst only causes one refresh.
local STAGED_REFRESH_DELAY = 0.25

-- How long a staged playtest waits for script sources to be written before
-- starting anyway.
local SOURCE_WRITE_TIMEOUT = 5

-- The most a session waits before restoring a deleted runtime loader.
local LOADER_RESTORE_JITTER = 2

local Status = strict("Session.Status", {
	NotStarted = "NotStarted",
	Connecting = "Connecting",
	Connected = "Connected",
	Disconnected = "Disconnected",
})

local function debugPatch(object)
	return Fmt.debugify(object, function(patch, output)
		output:writeLine("Patch {{")
		output:indent()

		for removed in ipairs(patch.removed) do
			output:writeLine("Remove ID {}", removed)
		end

		for id, added in pairs(patch.added) do
			output:writeLine("Add ID {} {:#?}", id, added)
		end

		for _, updated in ipairs(patch.updated) do
			output:writeLine("Update ID {} {:#?}", updated.id, updated)
		end

		output:unindent()
		output:write("}")
	end)
end

local function attemptReparent(instance, parent)
	return pcall(function()
		instance.Parent = parent
	end)
end

--[[
	Studio keeps resetting the DataModel's name, so renaming it to the project
	name would stay staged forever. Nothing depends on that name, so it is
	removed from staged patches.
]]
local function removeDataModelRename(patch, instanceMap)
	local gameId = instanceMap.fromInstances[game]

	for index = #patch.updated, 1, -1 do
		local update = patch.updated[index]
		if update.id ~= gameId or update.changedName == nil then
			continue
		end

		update.changedName = nil
		if update.changedClassName == nil and next(update.changedProperties) == nil then
			table.remove(patch.updated, index)
		end
	end
end

--[[
	Script sources are written with ScriptEditorService, which happens in
	another thread and isn't part of ChangeHistoryService recordings. These
	helpers let staged playtests wait for and revert source changes themselves.
]]
local function backUpStagedSources(patch, instanceMap)
	local backups = {}

	for _, update in patch.updated do
		local instance = instanceMap.fromIds[update.id]
		if
			update.changedClassName == nil
			and update.changedProperties.Source ~= nil
			and instance ~= nil
			and instance:IsA("LuaSourceContainer")
		then
			table.insert(backups, {
				instance = instance,
				source = ScriptEditorService:GetEditorSource(instance),
			})
		end
	end

	return backups
end

local function getExpectedSources(patch, instanceMap)
	local expected = {}

	local function addExpected(id, encodedSource)
		local instance = instanceMap.fromIds[id]
		if encodedSource == nil or instance == nil or not instance:IsA("LuaSourceContainer") then
			return
		end

		local success, source = decodeValue(encodedSource, instanceMap)
		if success then
			table.insert(expected, {
				instance = instance,
				source = source,
			})
		end
	end

	for id, virtualInstance in patch.added do
		addExpected(id, virtualInstance.Properties.Source)
	end
	for _, update in patch.updated do
		addExpected(update.id, update.changedProperties.Source)
	end

	return expected
end

local function waitForSources(expected, timeout)
	local deadline = os.clock() + timeout

	while true do
		local pending = false
		for _, entry in expected do
			if ScriptEditorService:GetEditorSource(entry.instance) ~= entry.source then
				pending = true
				break
			end
		end

		if not pending then
			return true
		elseif os.clock() > deadline then
			return false
		end

		task.wait()
	end
end

local function rejectIfModelProject(patch, instanceMap)
	for _, update in patch.updated do
		if update.id == instanceMap.fromInstances[game] and update.changedClassName ~= nil then
			-- Non-place projects will try to update the classname of game from DataModel to
			-- something like Folder, ModuleScript, etc. This would fail, so we exit with a clear
			-- message instead of crashing.
			return Promise.reject(
				"Cannot sync a model as a place."
					.. "\nEnsure Rojo is serving a project file that has a DataModel at the root of its tree and try again."
					.. "\nSee project file docs: https://rojo.space/docs/v7/project-format/"
			)
		end
	end

	return nil
end

local ServeSession = {}
ServeSession.__index = ServeSession

ServeSession.Status = Status

local validateServeOptions = t.strictInterface({
	apiContext = t.table,
	twoWaySync = t.boolean,
	-- When true, changes from the server are staged instead of being written
	-- to the DataModel. They are only written by `deployStaged`, and are
	-- temporarily included in playtests started by `startStagedPlaytest`.
	stageChanges = t.optional(t.boolean),
})

function ServeSession.new(options)
	assert(validateServeOptions(options))

	local stageChanges = options.stageChanges == true

	-- Declare self ahead of time to capture it in a closure
	local self
	local function onInstanceChanged(instance, propertyName)
		if self.__stageChanges then
			-- Someone changed an instance Rojo manages, possibly a collaborator
			-- deploying their own changes, so what we have staged is now stale.
			self:__scheduleStagedRefresh()
			return
		end

		if not self.__twoWaySync then
			return
		end

		self.__changeBatcher:add(instance, propertyName)
	end

	local function onChangesFlushed(patch)
		self.__apiContext:write(patch)
	end

	local instanceMap = InstanceMap.new(onInstanceChanged)
	local changeBatcher = ChangeBatcher.new(instanceMap, onChangesFlushed)
	local reconciler = Reconciler.new(instanceMap)

	local connections = {}

	local connection = StudioService:GetPropertyChangedSignal("ActiveScript"):Connect(function()
		local activeScript = StudioService.ActiveScript

		if activeScript ~= nil then
			self:__onActiveScriptChanged(activeScript)
		end
	end)
	table.insert(connections, connection)

	if stageChanges then
		-- A collaborator adding or removing the runtime loader changes how
		-- staged changes are computed and tested.
		local function onServerScriptServiceChildChanged(child)
			if child.Name == RuntimeLoader.LOADER_NAME then
				self:__scheduleStagedRefresh()
			end
		end
		table.insert(connections, ServerScriptService.ChildAdded:Connect(onServerScriptServiceChildChanged))
		table.insert(connections, ServerScriptService.ChildRemoved:Connect(onServerScriptServiceChildChanged))
	end

	self = {
		__status = Status.NotStarted,
		__apiContext = options.apiContext,
		-- Two-way sync would write collaborators' deployed changes over our
		-- files, so it can't be combined with staging.
		__twoWaySync = options.twoWaySync and not stageChanges,
		__stageChanges = stageChanges,
		__onInstanceChanged = onInstanceChanged,
		__rootInstanceId = nil,
		__reconciler = reconciler,
		__instanceMap = instanceMap,
		__changeBatcher = changeBatcher,
		__statusChangedCallback = nil,
		__stagedChangedCallback = nil,
		__stagedPatch = PatchSet.newEmpty(),
		__stagedRefreshScheduled = false,
		__stagedRefreshSequence = 0,
		__stagedBusy = false,
		__loaderInstalled = false,
		__lastOverlaySkipped = nil,
		__connections = connections,
		__precommitCallbacks = {},
		__postcommitCallbacks = {},
		__updateLoadingText = function() end,
	}

	setmetatable(self, ServeSession)

	return self
end

function ServeSession:__fmtDebug(output)
	output:writeLine("ServeSession {{")
	output:indent()

	output:writeLine("API Context: {:#?}", self.__apiContext)
	output:writeLine("Instances: {:#?}", self.__instanceMap)

	output:unindent()
	output:write("}")
end

function ServeSession:getStatus()
	return self.__status
end

function ServeSession:onStatusChanged(callback)
	self.__statusChangedCallback = callback
end

function ServeSession:isStaging(): boolean
	return self.__stageChanges
end

--[[
	Sets a function to call whenever the staged changes are recomputed. It is
	called with the staged PatchSet and the InstanceMap it refers to.
]]
function ServeSession:onStagedChanged(callback)
	self.__stagedChangedCallback = callback
end

function ServeSession:getStagedPatch()
	return self.__stagedPatch
end

function ServeSession:setConfirmCallback(callback)
	self.__userConfirmCallback = callback
end

function ServeSession:setUpdateLoadingTextCallback(callback)
	self.__updateLoadingText = callback
end

function ServeSession:setLoadingText(text: string)
	self.__updateLoadingText(text)
end

--[=[
	Hooks a function to run before patch application.
	The provided function is called with the incoming patch and an InstanceMap
	as parameters.
]=]
function ServeSession:hookPrecommit(callback)
	table.insert(self.__precommitCallbacks, callback)
	Log.trace("Added precommit callback: {}", callback)

	return function()
		-- Remove the callback from the list
		for i, cb in self.__precommitCallbacks do
			if cb == callback then
				table.remove(self.__precommitCallbacks, i)
				Log.trace("Removed precommit callback: {}", callback)
				break
			end
		end
	end
end

--[=[
	Hooks a function to run after patch application.
	The provided function is called with the applied patch, the current
	InstanceMap, and a PatchSet containing any unapplied changes.
]=]
function ServeSession:hookPostcommit(callback)
	table.insert(self.__postcommitCallbacks, callback)
	Log.trace("Added postcommit callback: {}", callback)

	return function()
		-- Remove the callback from the list
		for i, cb in self.__postcommitCallbacks do
			if cb == callback then
				table.remove(self.__postcommitCallbacks, i)
				Log.trace("Removed postcommit callback: {}", callback)
				break
			end
		end
	end
end

function ServeSession:start()
	self:__setStatus(Status.Connecting)
	self:setLoadingText("Connecting to server...")

	self.__apiContext
		:connect()
		:andThen(function(serverInfo)
			self.__rootInstanceId = serverInfo.rootInstanceId
			self:setLoadingText("Loading initial data from server...")
			return self:__initialSync(serverInfo):andThen(function()
				self:setLoadingText("Starting sync loop...")
				self:__setStatus(Status.Connected, serverInfo.projectName)
				if not self.__stageChanges then
					-- A staging session is attached to a place that's already
					-- published, so it should keep its real IDs.
					self:__applyGameAndPlaceId(serverInfo)
				end

				return self.__apiContext:connectWebSocket({
					["messages"] = function(messagesPacket)
						if self.__status == Status.Disconnected then
							return
						end

						Log.debug("Received {} messages from Rojo server", #messagesPacket.messages)

						if self.__stageChanges then
							-- Recomputing from the full tree is simpler than
							-- tracking messages against a DataModel we never
							-- write to, and it picks up DataModel changes too.
							self.__apiContext:setMessageCursor(messagesPacket.messageCursor)
							self:__scheduleStagedRefresh()
							return
						end

						for _, message in messagesPacket.messages do
							self:__applyPatch(message)
						end
						self.__apiContext:setMessageCursor(messagesPacket.messageCursor)
					end,
				})
			end)
		end)
		:catch(function(err)
			if self.__status ~= Status.Disconnected then
				self:__stopInternal(err)
			end
		end)
end

function ServeSession:stop()
	self:__stopInternal()
end

function ServeSession:__applyGameAndPlaceId(serverInfo)
	if serverInfo.gameId ~= nil then
		game:SetUniverseId(serverInfo.gameId)
	end

	if serverInfo.placeId ~= nil then
		game:SetPlaceId(serverInfo.placeId)
	end
end

function ServeSession:__onActiveScriptChanged(activeScript)
	if not Settings:get("openScriptsExternally") then
		Log.trace("Not opening script {} because feature not enabled.", activeScript)

		return
	end

	if self.__status ~= Status.Connected then
		Log.trace("Not opening script {} because session is not connected.", activeScript)

		return
	end

	local scriptId = self.__instanceMap.fromInstances[activeScript]
	if scriptId == nil then
		Log.trace("Not opening script {} because it is not known by Rojo.", activeScript)

		return
	end

	Log.debug("Trying to open script {} externally...", activeScript)

	-- Force-close the script inside Studio... with a small delay in the middle
	-- to prevent Studio from crashing.
	spawn(function()
		local existingParent = activeScript.Parent
		activeScript.Parent = nil

		for _ = 1, 3 do
			RunService.Heartbeat:Wait()
		end

		activeScript.Parent = existingParent
	end)

	-- Notify the Rojo server to open this script
	self.__apiContext:open(scriptId)
end

function ServeSession:__replaceInstances(idList)
	if #idList == 0 then
		return true, PatchSet.newEmpty()
	end
	-- It would be annoying if selection went away, so we try to preserve it.
	local selection = Selection:Get()
	local selectionMap = {}
	for i, instance in selection do
		selectionMap[instance] = i
	end

	-- TODO: Should we do this in multiple requests so we can more granularly mark failures?
	local modelSuccess, replacements = self.__apiContext
		:serialize(idList)
		:andThen(function(response)
			Log.debug("Deserializing results from serialize endpoint")
			local objects = SerializationService:DeserializeInstancesAsync(response.modelContents)
			if not objects[1] then
				return Promise.reject("Serialize endpoint did not deserialize into any Instances")
			end
			if #objects[1]:GetChildren() ~= #idList then
				return Promise.reject("Serialize endpoint did not return the correct number of Instances")
			end

			local instanceMap = {}
			for _, item in objects[1]:GetChildren() do
				instanceMap[item.Name] = item.Value
			end
			return instanceMap
		end)
		:await()

	local refSuccess, refPatch = self.__apiContext
		:refPatch(idList)
		:andThen(function(response)
			return response.patch
		end)
		:await()

	if not (modelSuccess and refSuccess) then
		return false
	end

	-- Roblox appends to GetChildren() on every reparent, so the order in which
	-- we re-parent replacements determines their final sibling order.
	-- We process ancestors before descendants (so each replacement's
	-- parent already exists when we re-parent it) and siblings in their original
	-- GetChildren() order. Because the loop below moves the old instance's
	-- children into the replacement *before* re-parenting the replacement, this
	-- rebuilds GetChildren() exactly as it was before the swap.
	local swaps = {}
	for id, replacement in replacements do
		local oldInstance = self.__instanceMap.fromIds[id]
		if not oldInstance then
			-- TODO: Why would this happen?
			Log.warn("Instance {} not found in InstanceMap during sync replacement", id)
			continue
		end

		table.insert(swaps, {
			id = id,
			replacement = replacement,
			oldInstance = oldInstance,
		})
	end

	for _, swap in orderSwaps(swaps) do
		local id, replacement, oldInstance = swap.id, swap.replacement, swap.oldInstance

		self.__instanceMap:insert(id, replacement)
		Log.trace("Swapping Instance {} out via api/models/ endpoint", id)
		local oldParent = oldInstance.Parent
		for _, child in oldInstance:GetChildren() do
			-- Some children cannot be reparented, such as a TouchTransmitter
			local reparentSuccess, reparentError = attemptReparent(child, replacement)
			if not reparentSuccess then
				Log.warn(
					"Could not reparent child {} of instance {} during sync replacement: {}",
					child.Name,
					oldInstance.Name,
					reparentError
				)
			end
		end

		-- ChangeHistoryService doesn't like it if an Instance has been
		-- Destroyed. So, we have to accept the potential memory hit and
		-- just set the parent to `nil`.
		local deleteSuccess, deleteError = attemptReparent(oldInstance, nil)
		local replaceSuccess, replaceError = attemptReparent(replacement, oldParent)

		if not (deleteSuccess and replaceSuccess) then
			Log.warn(
				"Could not swap instances {} and {} during sync replacement: {}",
				oldInstance.Name,
				replacement.Name,
				(deleteError or "") .. "\n" .. (replaceError or "")
			)

			-- We need to revert the failed swap to avoid losing the old instance and children.
			for _, child in replacement:GetChildren() do
				attemptReparent(child, oldInstance)
			end
			attemptReparent(oldInstance, oldParent)

			-- Our replacement should never have existed in the first place, so we can just destroy it.
			replacement:Destroy()
			continue
		end

		if selectionMap[oldInstance] then
			-- This is a bit funky, but it saves the order of Selection
			-- which might matter for some use cases.
			selection[selectionMap[oldInstance]] = replacement
		end
	end

	local patchApplySuccess, unappliedPatch = pcall(self.__reconciler.applyPatch, self.__reconciler, refPatch)
	if patchApplySuccess then
		Selection:Set(selection)
		return true, unappliedPatch
	else
		error(unappliedPatch)
	end
end

function ServeSession:__applyPatch(patch)
	local patchTimestamp = DateTime.now():FormatLocalTime("LTS", "en-us")
	local historyRecording = ChangeHistoryService:TryBeginRecording("Rojo: Patch " .. patchTimestamp)
	if not historyRecording then
		-- There can only be one recording at a time
		Log.debug("Failed to begin history recording for " .. patchTimestamp .. ". Another recording is in progress.")
	end

	Timer.start("precommitCallbacks")
	-- Precommit callbacks must be serial in order to obey the contract that
	-- they execute before commit
	for _, callback in self.__precommitCallbacks do
		local success, err = pcall(callback, patch, self.__instanceMap)
		if not success then
			Log.warn("Precommit hook errored: {}", err)
		end
	end
	Timer.stop()

	local patchApplySuccess, unappliedPatch = pcall(self.__reconciler.applyPatch, self.__reconciler, patch)
	if not patchApplySuccess then
		if historyRecording then
			ChangeHistoryService:FinishRecording(historyRecording, Enum.FinishRecordingOperation.Commit)
		end
		-- This might make a weird stack trace but the only way applyPatch can
		-- fail is if a bug occurs so it's probably fine.
		error(unappliedPatch)
	end

	if Settings:get("enableSyncFallback") and not PatchSet.isEmpty(unappliedPatch) then
		-- Some changes did not apply, let's try replacing them instead
		local addedIdList = PatchSet.addedIdList(unappliedPatch)
		local updatedIdList = PatchSet.updatedIdList(unappliedPatch)

		Log.debug("ServeSession:__replaceInstances(unappliedPatch.added)")
		Timer.start("ServeSession:__replaceInstances(unappliedPatch.added)")
		local addSuccess, unappliedAddedRefs = self:__replaceInstances(addedIdList)
		Timer.stop()

		Log.debug("ServeSession:__replaceInstances(unappliedPatch.updated)")
		Timer.start("ServeSession:__replaceInstances(unappliedPatch.updated)")
		local updateSuccess, unappliedUpdateRefs = self:__replaceInstances(updatedIdList)
		Timer.stop()

		-- Update the unapplied patch to reflect which Instances were replaced successfully
		if addSuccess then
			table.clear(unappliedPatch.added)
			PatchSet.assign(unappliedPatch, unappliedAddedRefs)
		end
		if updateSuccess then
			table.clear(unappliedPatch.updated)
			PatchSet.assign(unappliedPatch, unappliedUpdateRefs)
		end
	end

	if not PatchSet.isEmpty(unappliedPatch) then
		Log.debug(
			"Could not apply all changes requested by the Rojo server:\n{}",
			PatchSet.humanSummary(self.__instanceMap, unappliedPatch)
		)
	end

	Timer.start("postcommitCallbacks")
	-- Postcommit callbacks can be called with spawn since regardless of firing order, they are
	-- guaranteed to be called after the commit
	for _, callback in self.__postcommitCallbacks do
		task.spawn(function()
			local success, err = pcall(callback, patch, self.__instanceMap, unappliedPatch)
			if not success then
				Log.warn("Postcommit hook errored: {}", err)
			end
		end)
	end
	Timer.stop()

	if historyRecording then
		ChangeHistoryService:FinishRecording(historyRecording, Enum.FinishRecordingOperation.Commit)
	end

	return unappliedPatch
end

--[[
	Reads the full tree from the server and diffs it against the DataModel
	without changing anything. Returns the staged patch along with the
	InstanceMap and Reconciler that the patch refers to.
]]
--[[
	Puts the runtime loader back if it was deleted while scripts still depend on
	it, since none of those scripts would start anywhere without it. Waits a
	random moment first so that collaborators who are all connected don't each
	add a copy.
]]
function ServeSession:__repairLoader()
	RuntimeLoader.removeDuplicateLoaders()

	if not RuntimeLoader.isMissing() then
		return
	end

	task.wait(math.random() * LOADER_RESTORE_JITTER)
	if self.__status == Status.Disconnected or not RuntimeLoader.isMissing() then
		return
	end

	RuntimeLoader.writeLoader()
	Log.warn(
		"The runtime loader was deleted, so Rojo put it back. To stop using it,"
			.. " run 'Rojo: Remove Runtime Loader', which also turns its scripts back on."
	)

	if self.__loaderRestoredCallback ~= nil then
		task.spawn(self.__loaderRestoredCallback)
	end
end

function ServeSession:onLoaderRestored(callback)
	self.__loaderRestoredCallback = callback
end

function ServeSession:__computeStaged()
	local rootId = self.__rootInstanceId

	return Promise.try(function()
		self:__repairLoader()
	end)
		:andThen(function()
			return self.__apiContext:read({ rootId })
		end)
		:andThen(function(readResponseBody)
			local instanceMap = InstanceMap.new(self.__onInstanceChanged)
			local reconciler = Reconciler.new(instanceMap)

			reconciler:hydrate(readResponseBody.instances, rootId, game)

			-- With the runtime loader, deployed scripts are turned off and tagged
			-- instead, so that's the form the place should be compared against.
			local loaderInstalled = RuntimeLoader.isInstalled()
			if loaderInstalled then
				RuntimeLoader.transformVirtualInstances(readResponseBody.instances, instanceMap)
			end

			local success, patch = reconciler:diff(readResponseBody.instances, rootId, game)
			if not success then
				instanceMap:stop()
				return Promise.reject("Could not compute staged changes: " .. tostring(patch))
			end

			local modelRejection = rejectIfModelProject(patch, instanceMap)
			if modelRejection then
				instanceMap:stop()
				return modelRejection
			end

			removeDataModelRename(patch, instanceMap)
			RuntimeLoader.removePluginOwnedFromPatch(patch)

			return {
				patch = patch,
				instanceMap = instanceMap,
				reconciler = reconciler,
				messageCursor = readResponseBody.messageCursor,
				loaderInstalled = loaderInstalled,
			}
		end)
end

function ServeSession:__adoptStaged(staged)
	-- Any refresh still in flight was computed from older data.
	self.__stagedRefreshSequence += 1

	local oldInstanceMap = self.__instanceMap
	self.__instanceMap = staged.instanceMap
	self.__reconciler = staged.reconciler
	self.__stagedPatch = staged.patch

	if oldInstanceMap ~= staged.instanceMap then
		oldInstanceMap:stop()
	end

	self.__loaderInstalled = staged.loaderInstalled == true
	self:__updateOverlay(staged.patch, staged.instanceMap)

	Log.trace("Staged changes: {:#?}", debugPatch(staged.patch))

	if self.__stagedChangedCallback ~= nil then
		task.spawn(self.__stagedChangedCallback, staged.patch, staged.instanceMap)
	end
end

--[[
	Keeps the runtime loader's overlay matching the staged changes, so that
	any playtest, including ones started with Studio's own Play button,
	includes them.
]]
function ServeSession:__updateOverlay(patch, instanceMap)
	if not self.__loaderInstalled then
		RuntimeLoader.clearOverlay()
		return
	end

	local success, skippedOrError = pcall(RuntimeLoader.writeOverlay, patch, instanceMap)
	if not success then
		Log.warn("Could not prepare staged changes for playtests: {}", skippedOrError)
	elseif skippedOrError ~= self.__lastOverlaySkipped and skippedOrError > 0 then
		Log.warn(
			"{} staged changes can't be included in playtests until they're deployed,"
				.. " because they change services or other instances that can't be copied.",
			skippedOrError
		)
	end

	self.__lastOverlaySkipped = if success then skippedOrError else nil
end

function ServeSession:isLoaderInstalled(): boolean
	return self.__loaderInstalled == true
end

--[[
	Recomputes the staged changes. Returns a Promise that resolves with the
	staged patch.
]]
function ServeSession:refreshStaged()
	if not self.__stageChanges then
		return Promise.reject("This session is not staging changes")
	end

	self.__stagedRefreshSequence += 1
	local sequence = self.__stagedRefreshSequence

	return self:__computeStaged():andThen(function(staged)
		if sequence ~= self.__stagedRefreshSequence or self.__stagedBusy or self.__status == Status.Disconnected then
			-- Something newer replaced this result, or the DataModel is in
			-- the middle of a deploy or playtest and the result is unreliable.
			staged.instanceMap:stop()
			return self.__stagedPatch
		end

		self:__adoptStaged(staged)
		return staged.patch
	end)
end

function ServeSession:__scheduleStagedRefresh()
	if self.__stagedRefreshScheduled or self.__stagedBusy then
		return
	end

	self.__stagedRefreshScheduled = true
	task.delay(STAGED_REFRESH_DELAY, function()
		self.__stagedRefreshScheduled = false

		if self.__status ~= Status.Connected or self.__stagedBusy then
			return
		end

		self:refreshStaged():catch(function(err)
			Log.warn("Could not refresh staged changes: {}", err)
		end)
	end)
end

--[[
	Runs `callback` with freshly computed staged changes while preventing
	background refreshes from replacing the InstanceMap underneath it. Staged
	changes are recomputed again afterwards, since the callback may have
	changed the DataModel. `prepare` runs before the staged changes are
	computed.
]]
function ServeSession:__withFreshStaged(callback, prepare: (() -> ())?)
	if not self.__stageChanges then
		return Promise.reject("This session is not staging changes")
	end
	if self.__status ~= Status.Connected then
		return Promise.reject("Rojo is not connected")
	end
	if self.__stagedBusy then
		return Promise.reject("Rojo is still deploying or starting a playtest")
	end

	self.__stagedBusy = true

	return Promise.try(function()
		if prepare ~= nil then
			prepare()
		end
	end)
		:andThen(function()
			return self:__computeStaged()
		end)
		:andThen(function(staged)
			self:__adoptStaged(staged)
			return callback(staged.patch)
		end)
		:finally(function()
			self.__stagedBusy = false

			if self.__status == Status.Connected then
				self:refreshStaged():catch(function(err)
					Log.warn("Could not refresh staged changes: {}", err)
				end)
			end
		end)
end

--[[
	Writes all staged changes to the DataModel, which replicates them to Team
	Create collaborators and saves them with the place. Resolves with the patch
	that was deployed and the parts of it that could not be applied.
]]
function ServeSession:deployStaged()
	return self:__withFreshStaged(function(patch)
		if self.__loaderInstalled then
			-- A newer plugin may have changed how the loader works.
			RuntimeLoader.writeLoader()
		end

		if PatchSet.isEmpty(patch) then
			return patch, PatchSet.newEmpty()
		end

		local unappliedPatch = self:__applyPatch(patch)
		return patch, unappliedPatch
	end)
end

--[[
	Adds the runtime loader to the place and switches the deployed scripts over
	to it, without deploying any other staged changes. Resolves with how many
	scripts were switched over.
]]
function ServeSession:setUpRuntimeLoader()
	return self:__withFreshStaged(function(patch)
		-- The loader exists by now, so the staged patch includes turning each
		-- deployed script off and tagging it. Only that part is deployed.
		local conversion = RuntimeLoader.getScriptConversion(patch)
		if not PatchSet.isEmpty(conversion) then
			self:__applyPatch(conversion)
		end

		return PatchSet.countInstances(conversion)
	end, function()
		RuntimeLoader.writeLoader()
	end)
end

--[[
	Removes the runtime loader from the place and turns the scripts it was
	starting back on.
]]
function ServeSession:removeRuntimeLoader()
	return self:__withFreshStaged(function()
		RuntimeLoader.uninstall()
	end)
end

--[[
	Starts a local playtest that includes the staged changes without leaving
	them in the DataModel. `mode` is a StagedPlaytest.Mode.

	The changes have to be applied to the edit DataModel until Studio has taken
	its snapshot for the playtest. Team Create replicates them during that
	window, and then replicates the revert. Resolves with the staged patch and
	how waiting for the snapshot ended.
]]
function ServeSession:startStagedPlaytest(mode)
	if not StagedPlaytest.isEditModeActive() then
		return Promise.reject("A playtest is already running")
	end

	return self:__withFreshStaged(function(patch)
		local token = HttpService:GenerateGUID(false)
		local args = StagedPlaytest.createArgs(token, self.__apiContext.__baseUrl)

		-- The runtime loader puts the staged changes into every playtest by
		-- itself, so there's nothing to apply.
		if self.__loaderInstalled or PatchSet.isEmpty(patch) then
			StagedPlaytest.launch(mode, args)
			return patch, if self.__loaderInstalled then "loader" else "empty"
		end

		local recording = ChangeHistoryService:TryBeginRecording("Rojo: Staged playtest")
		if not recording then
			return Promise.reject("Could not start a staged playtest because another change is being recorded")
		end

		local sourceBackups = backUpStagedSources(patch, self.__instanceMap)

		-- Cancelling the recording undoes everything we're about to do except
		-- for script sources, which we put back ourselves.
		local reverted = false
		local function revert()
			if reverted then
				return
			end
			reverted = true
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Cancel)

			for _, backup in sourceBackups do
				local success, err = pcall(
					ScriptEditorService.UpdateSourceAsync,
					ScriptEditorService,
					backup.instance,
					function()
						return backup.source
					end
				)
				if not success then
					Log.warn("Could not restore the source of {}: {}", backup.instance:GetFullName(), err)
				end
			end
		end

		local applySuccess, unappliedPatch = pcall(self.__reconciler.applyPatch, self.__reconciler, patch)
		if not applySuccess then
			revert()
			return Promise.reject(unappliedPatch)
		end

		if not PatchSet.isEmpty(unappliedPatch) then
			Log.warn(
				"Some staged changes could not be included in the playtest:\n{}",
				PatchSet.humanSummary(self.__instanceMap, unappliedPatch)
			)
		end

		-- Source writes finish in another thread, and the playtest would miss
		-- any that haven't landed by the time Studio takes its snapshot.
		if not waitForSources(getExpectedSources(patch, self.__instanceMap), SOURCE_WRITE_TIMEOUT) then
			Log.warn("Some staged script sources may not be included in the playtest")
		end

		local startTime = os.clock()
		local handle = StagedPlaytest.launch(mode, args)

		return StagedPlaytest.waitForSnapshot(token, handle)
			:andThen(function(outcome)
				revert()

				Log.debug(
					"Reverted staged playtest changes after {}s ({})",
					string.format("%.2f", os.clock() - startTime),
					outcome
				)

				if handle.error ~= nil then
					return Promise.reject(handle.error)
				end

				if outcome == "timeout" then
					Log.warn(
						"Rojo did not hear back from the playtest, so it reverted the staged changes after a timeout."
							.. " Make sure the Rojo plugin is allowed to run in playtests."
					)
				end

				return patch, outcome
			end)
			:catch(function(err)
				revert()
				return Promise.reject(err)
			end)
	end)
end

function ServeSession:__initialSync(serverInfo)
	if self.__stageChanges then
		-- Nothing gets written to the DataModel while staging, so there is
		-- nothing to confirm.
		return self:__computeStaged():andThen(function(staged)
			self.__apiContext:setMessageCursor(staged.messageCursor)
			self:__adoptStaged(staged)
		end)
	end

	return self.__apiContext:read({ serverInfo.rootInstanceId }):andThen(function(readResponseBody)
		-- Tell the API Context that we're up-to-date with the version of
		-- the tree defined in this response.
		self.__apiContext:setMessageCursor(readResponseBody.messageCursor)

		-- For any instances that line up with the Rojo server's view, start
		-- tracking them in the reconciler.
		Log.trace("Matching existing Roblox instances to Rojo IDs")
		self:setLoadingText("Hydrating instance map...")
		self.__reconciler:hydrate(readResponseBody.instances, serverInfo.rootInstanceId, game)

		-- Calculate the initial patch to apply to the DataModel to catch us
		-- up to what Rojo thinks the place should look like.
		Log.trace("Computing changes that plugin needs to make to catch up to server...")
		self:setLoadingText("Finding differences between server and Studio...")
		local success, catchUpPatch =
			self.__reconciler:diff(readResponseBody.instances, serverInfo.rootInstanceId, game)

		if not success then
			Log.error("Could not compute a diff to catch up to the Rojo server: {:#?}", catchUpPatch)
		end

		local modelRejection = rejectIfModelProject(catchUpPatch, self.__instanceMap)
		if modelRejection then
			return modelRejection
		end

		Log.trace("Computed hydration patch: {:#?}", debugPatch(catchUpPatch))

		local userDecision = "Accept"
		if self.__userConfirmCallback ~= nil then
			userDecision = self.__userConfirmCallback(self.__instanceMap, catchUpPatch, serverInfo)
		end

		if userDecision == "Abort" then
			return Promise.reject("Aborted Rojo sync operation")
		elseif userDecision == "Reject" then
			if not self.__twoWaySync then
				return Promise.reject("Cannot reject sync operation without two-way sync enabled")
			end
			-- The user wants their studio DOM to write back to their Rojo DOM
			-- so we will reverse the patch and send it back

			local inversePatch = PatchSet.newEmpty()

			-- Send back the current properties
			for _, change in catchUpPatch.updated do
				local instance = self.__instanceMap.fromIds[change.id]
				if not instance then
					continue
				end

				local update = encodePatchUpdate(instance, change.id, change.changedProperties)
				table.insert(inversePatch.updated, update)
			end
			-- Add the removed instances back to Rojo
			-- selene:allow(empty_if, unused_variable, empty_loop)
			for _, instance in catchUpPatch.removed do
				-- TODO: Generate ID for our instance and add it to inversePatch.added
			end
			-- Remove the additions we've rejected
			for id, _change in catchUpPatch.added do
				table.insert(inversePatch.removed, id)
			end

			return self.__apiContext:write(inversePatch)
		elseif userDecision == "Accept" then
			self:__applyPatch(catchUpPatch)
			return Promise.resolve()
		else
			return Promise.reject("Invalid user decision: " .. userDecision)
		end
	end)
end

function ServeSession:__stopInternal(err)
	self:__setStatus(Status.Disconnected, err)
	self.__apiContext:disconnect()
	self.__instanceMap:stop()
	self.__changeBatcher:stop()

	for _, connection in ipairs(self.__connections) do
		connection:Disconnect()
	end
	self.__connections = {}

	if self.__stageChanges then
		-- Without a session, playtests should use the deployed code.
		RuntimeLoader.clearOverlay()
	end
end

function ServeSession:__setStatus(status, detail)
	self.__status = status

	if self.__statusChangedCallback ~= nil then
		self.__statusChangedCallback(status, detail)
	end
end

return ServeSession
