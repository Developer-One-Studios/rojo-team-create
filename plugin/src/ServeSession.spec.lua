return function()
	local ServerScriptService = game:GetService("ServerScriptService")

	local Packages = script.Parent.Parent.Packages
	local Promise = require(Packages.Promise)

	local RuntimeLoader = require(script.Parent.RuntimeLoader)
	local ServeSession = require(script.Parent.ServeSession)

	-- A server whose project maps nothing but the place itself, so the runtime
	-- loader is the only thing a staged refresh can pick up.
	local function fakeApiContext()
		return {
			connect = function()
				return Promise.resolve({ rootInstanceId = "ROOT", projectName = "Test" })
			end,
			read = function()
				return Promise.resolve({
					messageCursor = 0,
					instances = {
						ROOT = {
							ClassName = "DataModel",
							Name = game.Name,
							Properties = {},
							Children = {},
							Metadata = { ignoreUnknownInstances = true },
						},
					},
				})
			end,
			setMessageCursor = function() end,
			connectWebSocket = function()
				return Promise.new(function() end)
			end,
			disconnect = function() end,
		}
	end

	local function waitFor(condition): boolean
		local deadline = os.clock() + 3
		while not condition() and os.clock() < deadline do
			task.wait(0.05)
		end
		return condition()
	end

	local function removeLoaders()
		for _, child in ServerScriptService:GetChildren() do
			if RuntimeLoader.isLoaderName(child.Name) then
				child:Destroy()
			end
		end
	end

	describe("staging", function()
		local session

		afterEach(function()
			if session ~= nil then
				session:stop()
				session = nil
			end
			removeLoaders()
		end)

		it("notices a collaborator deleting or adding the runtime loader", function()
			RuntimeLoader.writeLoader()

			session = ServeSession.new({
				apiContext = fakeApiContext(),
				twoWaySync = false,
				stageChanges = true,
			})
			session:start()

			expect(waitFor(function()
				return session:getStatus() == ServeSession.Status.Connected
			end)).to.equal(true)
			expect(session:isLoaderInstalled()).to.equal(true)

			removeLoaders()
			expect(waitFor(function()
				return not session:isLoaderInstalled()
			end)).to.equal(true)

			RuntimeLoader.writeLoader()
			expect(waitFor(function()
				return session:isLoaderInstalled()
			end)).to.equal(true)
		end)
	end)
end
