return function()
	local StagedPlaytest = require(script.Parent.StagedPlaytest)

	describe("parseArgs", function()
		it("reads back the args created by createArgs", function()
			local args = StagedPlaytest.createArgs("some-token", "http://localhost:34872")
			local parsed = StagedPlaytest.parseArgs(args)

			expect(parsed).to.be.ok()
			expect(parsed.token).to.equal("some-token")
			expect(parsed.serverUrl).to.equal("http://localhost:34872")
		end)

		it("allows the server URL to be missing", function()
			local parsed = StagedPlaytest.parseArgs(StagedPlaytest.createArgs("some-token", nil))

			expect(parsed).to.be.ok()
			expect(parsed.token).to.equal("some-token")
			expect(parsed.serverUrl).to.equal(nil)
		end)

		it("ignores test args that were not created by Rojo", function()
			-- Playtests can be started by other plugins with their own args.
			expect(StagedPlaytest.parseArgs(nil)).to.equal(nil)
			expect(StagedPlaytest.parseArgs("some-token")).to.equal(nil)
			expect(StagedPlaytest.parseArgs({ token = "some-token" })).to.equal(nil)
			expect(StagedPlaytest.parseArgs({ RojoStagedPlaytest = 5 })).to.equal(nil)
		end)

		it("ignores a server URL that is not a string", function()
			local parsed = StagedPlaytest.parseArgs({
				RojoStagedPlaytest = "some-token",
				RojoServerUrl = 34872,
			})

			expect(parsed).to.be.ok()
			expect(parsed.serverUrl).to.equal(nil)
		end)
	end)

	describe("getCurrent", function()
		it("returns nil outside of a running playtest", function()
			-- Specs run in edit mode or in a test place, neither of which was
			-- started as a staged playtest.
			expect(StagedPlaytest.getCurrent()).to.equal(nil)
		end)
	end)
end
