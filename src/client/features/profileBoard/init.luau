--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Client = script.Parent.Parent
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Janitor = require(Packages.janitor) :: any
local Fusion = require(Packages.fusion) :: any

local DataController = require(Client.core.data.DataController)

local function _resolveContainer(): Instance?
	local lobby = Workspace:FindFirstChild("Lobby")
	local profile = lobby and lobby:FindFirstChild("Profile")
	local board = profile and profile:FindFirstChild("Board")
	local surfaceGui = board and board:FindFirstChild("SurfaceGui")
	return surfaceGui and surfaceGui:FindFirstChild("Container")
end

local ProfileBoardFeature = {}

function ProfileBoardFeature.start(_menuController: any): any
	local janitor = Janitor.new()

	local container = _resolveContainer()
	if not container then
		warn("[ProfileBoard] Workspace.Lobby.Profile.Board.SurfaceGui.Container no encontrado")
		return janitor
	end

	local nameLabel = container:FindFirstChild("Name") :: TextLabel?
	local levelLabel = container:FindFirstChild("Level") :: TextLabel?
	local killsLabel = container:FindFirstChild("Kills") :: TextLabel?
	local profilePic = container:FindFirstChild("ProfilePic") :: ImageLabel?

	local localPlayer = Players.LocalPlayer

	if profilePic then
		profilePic.Image = "rbxthumb://type=AvatarHeadShot&id=" .. tostring(localPlayer.UserId) .. "&w=150&h=150"
	end

	if nameLabel then
		nameLabel.Text = localPlayer.DisplayName
	end

	local function _render()
		local stats = Fusion.peek(DataController.Stats)
		if not stats then return end

		if levelLabel then
			levelLabel.Text = "Level " .. tostring(stats.Level)
		end
		if killsLabel then
			killsLabel.Text = tostring(stats.Kills) .. " Kills"
		end
	end

	DataController:WhenReady():andThen(function()
		_render()
		local scope = Fusion.scoped(Fusion)
		janitor:Add(function()
			Fusion.doCleanup(scope)
		end, true)
		local obs = scope:Observer(DataController.Stats :: any)
		janitor:Add(obs:onBind(_render), true)
	end)

	return janitor
end

return ProfileBoardFeature
