return function()
	local RuntimeLoader = require(script.Parent.RuntimeLoader)
	local InstanceMap = require(script.Parent.InstanceMap)
	local PatchSet = require(script.Parent.PatchSet)

	local TAG = RuntimeLoader.ENABLE_TAG

	local function virtualScript(className, properties)
		return {
			ClassName = className,
			Name = "Script",
			Properties = properties or {},
			Children = {},
		}
	end

	describe("transformVirtualInstances", function()
		it("turns scripts off and tags them for the loader", function()
			local virtualInstances = {
				SCRIPT = virtualScript("Script"),
				LOCAL = virtualScript("LocalScript"),
			}

			RuntimeLoader.transformVirtualInstances(virtualInstances, InstanceMap.new())

			for _, virtualInstance in virtualInstances do
				expect(virtualInstance.Properties.Enabled.Bool).to.equal(false)
				expect(virtualInstance.Properties.Tags.Tags[1]).to.equal(TAG)
			end
		end)

		it("doesn't tag scripts the project turns off", function()
			local virtualInstances = {
				DISABLED = virtualScript("Script", { Disabled = { Bool = true } }),
				NOT_ENABLED = virtualScript("Script", { Enabled = { Bool = false } }),
			}

			RuntimeLoader.transformVirtualInstances(virtualInstances, InstanceMap.new())

			for _, virtualInstance in virtualInstances do
				expect(virtualInstance.Properties.Enabled.Bool).to.equal(false)
				expect(virtualInstance.Properties.Disabled).to.equal(nil)
				expect(table.find(virtualInstance.Properties.Tags.Tags, TAG)).to.equal(nil)
			end
		end)

		it("keeps tags the script already has", function()
			local instance = Instance.new("Script")
			instance:AddTag("Existing")

			local instanceMap = InstanceMap.new()
			instanceMap:insert("SCRIPT", instance)

			local virtualInstances = {
				SCRIPT = virtualScript("Script"),
			}

			RuntimeLoader.transformVirtualInstances(virtualInstances, instanceMap)

			-- The existing order is kept so the diff doesn't see a change.
			local tags = virtualInstances.SCRIPT.Properties.Tags.Tags
			expect(#tags).to.equal(2)
			expect(tags[1]).to.equal("Existing")
			expect(tags[2]).to.equal(TAG)

			instanceMap:stop()
			instance:Destroy()
		end)

		it("leaves other classes alone", function()
			local virtualInstances = {
				MODULE = virtualScript("ModuleScript"),
				FOLDER = virtualScript("Folder"),
			}

			RuntimeLoader.transformVirtualInstances(virtualInstances, InstanceMap.new())

			for _, virtualInstance in virtualInstances do
				expect(next(virtualInstance.Properties)).to.equal(nil)
			end
		end)
	end)

	describe("getScriptConversion", function()
		it("keeps only the changes that switch scripts over to the loader", function()
			local patch = PatchSet.newEmpty()
			patch.added.NEW = virtualScript("Script")
			table.insert(patch.removed, "OLD")
			table.insert(patch.updated, {
				id = "SCRIPT",
				changedProperties = {
					Source = { String = "print('staged')" },
					Enabled = { Bool = false },
					Tags = { Tags = { TAG } },
				},
			})
			table.insert(patch.updated, {
				id = "MODULE",
				changedProperties = {
					Source = { String = "return 1" },
				},
			})

			local conversion = RuntimeLoader.getScriptConversion(patch)

			expect(next(conversion.added)).to.equal(nil)
			expect(#conversion.removed).to.equal(0)
			expect(#conversion.updated).to.equal(1)

			local update = conversion.updated[1]
			expect(update.id).to.equal("SCRIPT")
			expect(update.changedProperties.Source).to.equal(nil)
			expect(update.changedProperties.Enabled.Bool).to.equal(false)
			expect(update.changedProperties.Tags.Tags[1]).to.equal(TAG)
		end)
	end)

	describe("removePluginOwnedFromPatch", function()
		it("never removes the loader or the overlay", function()
			local loader = Instance.new("Script")
			loader.Name = RuntimeLoader.LOADER_NAME
			loader.Parent = game:GetService("ServerScriptService")

			local other = Instance.new("Folder")

			local patch = PatchSet.newEmpty()
			table.insert(patch.removed, loader)
			table.insert(patch.removed, other)
			table.insert(patch.removed, "SOME_ID")

			RuntimeLoader.removePluginOwnedFromPatch(patch)

			expect(#patch.removed).to.equal(2)
			expect(table.find(patch.removed, loader)).to.equal(nil)

			loader:Destroy()
			other:Destroy()
		end)
	end)

	describe("status", function()
		local ServerStorage = game:GetService("ServerStorage")

		afterEach(function()
			RuntimeLoader.clearStatus()
		end)

		it("writes what the session is doing to a Camera that is never saved", function()
			RuntimeLoader.writeStatus({
				projectName = "Fixture",
				staging = true,
				stagedCount = 3,
				skippedCount = 2,
				skippedPaths = { "Lighting", "SoundService" },
			})

			local camera = ServerStorage:FindFirstChild(RuntimeLoader.STATUS_NAME)
			expect(camera).to.be.ok()
			expect(camera:IsA("Camera")).to.equal(true)
			expect(camera.Archivable).to.equal(false)
			expect(camera:GetAttribute("Connected")).to.equal(true)
			expect(camera:GetAttribute("ProjectName")).to.equal("Fixture")
			expect(camera:GetAttribute("Staging")).to.equal(true)
			expect(camera:GetAttribute("StagedCount")).to.equal(3)
			expect(camera:GetAttribute("SkippedCount")).to.equal(2)
			expect(camera:GetAttribute("SkippedPaths")).to.equal("Lighting\nSoundService")
			expect(typeof(camera:GetAttribute("RefreshedAt"))).to.equal("number")
		end)

		it("updates the one Camera, counts as the plugin's own, and clears", function()
			local status = { staging = false, stagedCount = 0, skippedCount = 0, skippedPaths = {} }
			RuntimeLoader.writeStatus(status)
			RuntimeLoader.writeStatus(status)

			local found = 0
			for _, child in ServerStorage:GetChildren() do
				if child.Name == RuntimeLoader.STATUS_NAME then
					found += 1
				end
			end
			expect(found).to.equal(1)
			expect(RuntimeLoader.isPluginOwned(ServerStorage:FindFirstChild(RuntimeLoader.STATUS_NAME))).to.equal(true)

			RuntimeLoader.clearStatus()
			expect(ServerStorage:FindFirstChild(RuntimeLoader.STATUS_NAME)).to.equal(nil)
		end)
	end)

	describe("writeOverlay", function()
		afterEach(function()
			RuntimeLoader.clearOverlay()
		end)

		it("counts an update whose instance is unknown without naming it or failing", function()
			local instanceMap = InstanceMap.new(nil)
			local patch = PatchSet.newEmpty()
			table.insert(patch.updated, { id = "MISSING", changedProperties = {} })

			local skipped, skippedPaths = RuntimeLoader.writeOverlay(patch, instanceMap)
			expect(skipped).to.equal(1)
			expect(#skippedPaths).to.equal(0)
			instanceMap:stop()
		end)

		it("names a service it cannot copy, and returns nothing for an empty patch", function()
			local instanceMap = InstanceMap.new(nil)
			instanceMap:insert("LIGHTING", game:GetService("Lighting"))
			local patch = PatchSet.newEmpty()
			table.insert(patch.updated, { id = "LIGHTING", changedProperties = {} })

			local skipped, skippedPaths = RuntimeLoader.writeOverlay(patch, instanceMap)
			expect(skipped).to.equal(1)
			expect(skippedPaths[1]).to.equal("Lighting")

			local emptySkipped, emptyPaths = RuntimeLoader.writeOverlay(PatchSet.newEmpty(), instanceMap)
			expect(emptySkipped).to.equal(0)
			expect(#emptyPaths).to.equal(0)
			instanceMap:stop()
		end)
	end)
end
