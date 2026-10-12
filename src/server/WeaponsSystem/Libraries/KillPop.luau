--!strict
-- Pop de baja (cliente): el ImageLabel WeaponsSystemGui.KillPop (a cualquier nivel)
-- hace un pop desde 0 en cada baja del killer local y se encoge tras una pausa.
-- Se anima una UIScale, no Size: crece hasta el Size que tenga en Studio.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local LocalPlayer = Players.LocalPlayer

local POP_TRANSPARENCY = 0.45

local TI_POP_IN = TweenInfo.new(0.12, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local TI_POP_OUT = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local HOLD_TIME = 0.25

local KillPop = {}

-- Una baja nueva invalida la salida diferida de la anterior.
local _token = 0

-- Se re-resuelve en cada uso: la GUI se clona de forma asíncrona y puede recrearse.
local function getKillPop(): ImageLabel?
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	local gui = playerGui and playerGui:FindFirstChild("WeaponsSystemGui")
	local pop = gui and gui:FindFirstChild("KillPop", true)
	if pop and pop:IsA("ImageLabel") then
		return pop
	end
	return nil
end

function KillPop.show()
	local pop = getKillPop()
	if not pop then return end

	_token += 1
	local myToken = _token

	-- Reusar la UIScale si la plantilla trae una: con dos, Roblox solo aplica una.
	local uiScale = pop:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	uiScale.Parent = pop
	uiScale.Scale = 0
	pop.ImageTransparency = POP_TRANSPARENCY
	pop.Visible = true
	TweenService:Create(uiScale, TI_POP_IN, { Scale = 1 }):Play()

	task.delay(TI_POP_IN.Time + HOLD_TIME, function()
		if myToken ~= _token or not pop.Parent then return end
		TweenService:Create(uiScale, TI_POP_OUT, { Scale = 0 }):Play()

		task.delay(TI_POP_OUT.Time, function()
			if myToken ~= _token then return end
			pop.Visible = false
		end)
	end)
end

-- Oculta el pop en cuanto la GUI exista, por si la plantilla viene Visible=true
-- desde Studio.
task.spawn(function()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui", 30)
	local gui = playerGui and playerGui:WaitForChild("WeaponsSystemGui", 30)
	local pop = gui and gui:FindFirstChild("KillPop", true)
	if pop and pop:IsA("ImageLabel") and _token == 0 then
		pop.Visible = false
	end
end)

return KillPop
