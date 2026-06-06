--!strict
-- Scope.luau (Client/Server Library)
-- Gestiona la mira de francotirador (Scope) y los efectos de viñeta (Vignette) de daño y eliminación.

local TweenService = game:GetService("TweenService")

local VIGNETTE_KILL_COLOR = Color3.fromRGB(0, 172, 237)
local VIGNETTE_HEALTH_COLOR = Color3.fromRGB(255, 0, 0)

type VignetteNode = {
	instance: GuiObject,
	type: "Image" | "Text" | "Background" | "Stroke",
}

local function buildVignetteNodeList(root: Instance): { VignetteNode }
	local list: { VignetteNode } = {}
	local function traverse(obj: Instance)
		if obj:IsA("GuiObject") then
			local nodeType = nil
			if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
				nodeType = "Image"
			elseif obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
				nodeType = "Text"
			else
				nodeType = "Background"
			end
			table.insert(list, { instance = obj, type = nodeType })
		elseif obj:IsA("UIStroke") then
			table.insert(list, { instance = obj :: any, type = "Stroke" })
		end
		for _, child in ipairs(obj:GetChildren()) do
			traverse(child)
		end
	end
	traverse(root)
	return list
end

local function applyVignetteAlpha(nodes: { VignetteNode }, alpha: number)
	for _, node in ipairs(nodes) do
		local inst = node.instance
		if node.type == "Image" then
			inst.ImageTransparency = alpha
		elseif node.type == "Text" then
			inst.TextTransparency = alpha
			inst.TextStrokeTransparency = math.clamp(alpha, 0, 1)
		elseif node.type == "Background" then
			inst.BackgroundTransparency = alpha
		elseif node.type == "Stroke" then
			(inst :: any).Transparency = alpha
		end
	end
end

local function applyVignetteColor(nodes: { VignetteNode }, color: Color3)
	for _, node in ipairs(nodes) do
		local inst = node.instance
		if node.type == "Image" then
			inst.ImageColor3 = color
		elseif node.type == "Text" or node.type == "Background" then
			inst.BackgroundColor3 = color
		elseif node.type == "Stroke" then
			(inst :: any).Color = color
		end
	end
end

local Scope = {}
Scope.__index = Scope

function Scope.new(weaponsGui: any)
	local self = setmetatable({}, Scope)
	self.weaponsGui = weaponsGui

	self.scopeEnabled = false
	self.vignetteHideToken = 0
	self.vignetteDisplayTime = 0.45

	self._vignetteNodes = nil
	self.vignetteKillAlphaDriver = nil
	self.vignetteHealthAlphaDriver = nil
	self.vignetteStateConn = nil
	self.vignetteHealthConn = nil
	self.vignetteFadeTween = nil

	return self
end

function Scope:setup(gui: ScreenGui)
	self.scopeFrame = gui:WaitForChild("Scope") :: GuiObject
	self.vignette = gui:FindFirstChild("Vignette") :: GuiObject?
	if not self.vignette then
		self.vignette = gui:FindFirstChild("KillContainer") :: GuiObject?
	end

	if self.vignette and self.vignette:IsA("GuiObject") then
		self.vignette.Visible = false

		self.vignetteKillAlphaDriver = self.vignette:FindFirstChild("KillAlphaDriver") :: NumberValue?
		if not self.vignetteKillAlphaDriver then
			local val = Instance.new("NumberValue")
			val.Name = "KillAlphaDriver"
			val.Value = 0
			val.Parent = self.vignette
			self.vignetteKillAlphaDriver = val
		end
		self.vignetteKillAlphaDriver.Value = 0

		self.vignetteHealthAlphaDriver = self.vignette:FindFirstChild("HealthAlphaDriver") :: NumberValue?
		if not self.vignetteHealthAlphaDriver then
			local val = Instance.new("NumberValue")
			val.Name = "HealthAlphaDriver"
			val.Value = 0
			val.Parent = self.vignette
			self.vignetteHealthAlphaDriver = val
		end
		self.vignetteHealthAlphaDriver.Value = self.vignetteHealthAlphaDriver.Value or 0

		self._vignetteNodes = buildVignetteNodeList(self.vignette)

		local function refreshVignette()
			if not self.vignette or not self._vignetteNodes then
				return
			end
			local killAlpha = if self.vignetteKillAlphaDriver then self.vignetteKillAlphaDriver.Value else 0
			local healthAlpha = if self.vignetteHealthAlphaDriver then self.vignetteHealthAlphaDriver.Value else 0
			local visibleAlpha = math.max(killAlpha, healthAlpha)
			if visibleAlpha <= 0 then
				applyVignetteAlpha(self._vignetteNodes, 1)
				self.vignette.Visible = false
				return
			end

			local color = if killAlpha >= healthAlpha then VIGNETTE_KILL_COLOR else VIGNETTE_HEALTH_COLOR
			applyVignetteColor(self._vignetteNodes, color)
			applyVignetteAlpha(self._vignetteNodes, 1 - math.clamp(visibleAlpha, 0, 1))
			self.vignette.Visible = true
		end

		self.vignetteStateConn = self.vignetteKillAlphaDriver.Changed:Connect(refreshVignette)
		self.vignetteHealthConn = self.vignetteHealthAlphaDriver.Changed:Connect(refreshVignette)
		refreshVignette()
	end
end

function Scope:setScopeEnabled(scopeEnabled: boolean)
	self.scopeEnabled = scopeEnabled
	if self.scopeFrame then
		self.scopeFrame.Visible = scopeEnabled
	end
end

function Scope:hideKillContainer(immediate: boolean)
	if not self.vignette then return end
	self.vignetteHideToken += 1
	if self.vignetteFadeTween then
		self.vignetteFadeTween:Cancel()
		self.vignetteFadeTween = nil
	end

	if immediate then
		if self.vignetteKillAlphaDriver then
			self.vignetteKillAlphaDriver.Value = 0
		elseif self._vignetteNodes then
			applyVignetteAlpha(self._vignetteNodes, 1)
		end
		if not self.vignetteHealthAlphaDriver or self.vignetteHealthAlphaDriver.Value <= 0 then
			self.vignette.Visible = false
		end
		return
	end

	local hideToken = self.vignetteHideToken
	local alphaDriver = self.vignetteKillAlphaDriver
	if alphaDriver then
		self.vignetteFadeTween = TweenService:Create(alphaDriver, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Value = 0 })
		self.vignetteFadeTween:Play()
		self.vignetteFadeTween.Completed:Once(function()
			if self.vignetteHideToken ~= hideToken or not self.vignette then
				return
			end
			if not self.vignetteHealthAlphaDriver or self.vignetteHealthAlphaDriver.Value <= 0 then
				self.vignette.Visible = false
			end
			self.vignetteFadeTween = nil
		end)
	elseif self._vignetteNodes then
		applyVignetteAlpha(self._vignetteNodes, 1)
		self.vignette.Visible = false
	end
end

function Scope:showKillContainer()
	if self.vignetteKillAlphaDriver then
		self.vignetteKillAlphaDriver.Value = 0
	end
end

function Scope:Destroy()
	if self.vignetteStateConn then
		self.vignetteStateConn:Disconnect()
		self.vignetteStateConn = nil
	end
	if self.vignetteHealthConn then
		self.vignetteHealthConn:Disconnect()
		self.vignetteHealthConn = nil
	end
	if self.vignetteFadeTween then
		self.vignetteFadeTween:Cancel()
		self.vignetteFadeTween = nil
	end
end

return Scope
