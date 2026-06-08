--!strict
-- Scope.luau (Client/Server Library)
-- Gestiona la mira de francotirador (Scope) y los efectos de viñeta (Vignette) de daño y curación.

local VIGNETTE_DAMAGE_COLOR = Color3.fromRGB(255, 0, 0) -- rojo, vida baja
local VIGNETTE_HEAL_COLOR = Color3.fromRGB(0, 255, 128) -- verde, curación

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

	self._vignetteNodes = nil
	self.vignetteHealthAlphaDriver = nil -- rojo, vida baja
	self.vignetteHealAlphaDriver = nil -- verde, curación
	self.vignetteHealthConn = nil
	self.vignetteHealConn = nil

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

		self.vignetteHealthAlphaDriver = self.vignette:FindFirstChild("HealthAlphaDriver") :: NumberValue?
		if not self.vignetteHealthAlphaDriver then
			local val = Instance.new("NumberValue")
			val.Name = "HealthAlphaDriver"
			val.Value = 0
			val.Parent = self.vignette
			self.vignetteHealthAlphaDriver = val
		end
		self.vignetteHealthAlphaDriver.Value = self.vignetteHealthAlphaDriver.Value or 0

		self.vignetteHealAlphaDriver = self.vignette:FindFirstChild("HealAlphaDriver") :: NumberValue?
		if not self.vignetteHealAlphaDriver then
			local val = Instance.new("NumberValue")
			val.Name = "HealAlphaDriver"
			val.Value = 0
			val.Parent = self.vignette
			self.vignetteHealAlphaDriver = val
		end
		self.vignetteHealAlphaDriver.Value = self.vignetteHealAlphaDriver.Value or 0

		self._vignetteNodes = buildVignetteNodeList(self.vignette)

		-- Combina los dos efectos: gana el de mayor alpha y su color tiñe el
		-- vignette. Prioridad en empate: daño (rojo) > heal (verde).
		local function refreshVignette()
			if not self.vignette or not self._vignetteNodes then
				return
			end
			local healthAlpha = if self.vignetteHealthAlphaDriver then self.vignetteHealthAlphaDriver.Value else 0
			local healAlpha = if self.vignetteHealAlphaDriver then self.vignetteHealAlphaDriver.Value else 0
			local visibleAlpha = math.max(healthAlpha, healAlpha)
			if visibleAlpha <= 0 then
				applyVignetteAlpha(self._vignetteNodes, 1)
				self.vignette.Visible = false
				return
			end

			local color = if healthAlpha >= healAlpha then VIGNETTE_DAMAGE_COLOR else VIGNETTE_HEAL_COLOR
			applyVignetteColor(self._vignetteNodes, color)
			applyVignetteAlpha(self._vignetteNodes, 1 - math.clamp(visibleAlpha, 0, 1))
			self.vignette.Visible = true
		end

		self.vignetteHealthConn = self.vignetteHealthAlphaDriver.Changed:Connect(refreshVignette)
		self.vignetteHealConn = self.vignetteHealAlphaDriver.Changed:Connect(refreshVignette)
		refreshVignette()
	end
end

function Scope:setScopeEnabled(scopeEnabled: boolean)
	self.scopeEnabled = scopeEnabled
	if self.scopeFrame then
		self.scopeFrame.Visible = scopeEnabled
	end
end

function Scope:Destroy()
	if self.vignetteHealthConn then
		self.vignetteHealthConn:Disconnect()
		self.vignetteHealthConn = nil
	end
	if self.vignetteHealConn then
		self.vignetteHealConn:Disconnect()
		self.vignetteHealConn = nil
	end
end

return Scope
