--[[
	CasesUI
	Handles the Cases (Loot Box) UI visualization and interaction.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

-- Fusion
local TweenService = game:GetService("TweenService")

-- Fusion
local Fusion = require(ReplicatedStorage.Packages.fusion)
local scoped = Fusion.scoped
local Children = Fusion.Children
local Value = Fusion.Value
local Computed = Fusion.Computed
local Observer = Fusion.Observer
local peek = Fusion.peek

-- Config
local LootConfig = require(ReplicatedStorage.Shared.Systems.Cases.Data.LootConfig)

-- Manager
local CameraManager = require(ReplicatedStorage.Shared.Systems.Camera.CameraManager)

-- Data
local DataController = require(ReplicatedStorage.Shared.Systems.Data.DataController)

-- Modules
local BoxAnimation = require(ReplicatedStorage.Shared.Systems.Cases.BoxAnimation)
local _LootRoller = require(ReplicatedStorage.Shared.Systems.Cases.LootRoller)
local _SkinApplier = require(ReplicatedStorage.Shared.Systems.Appearance.SkinApplier)
local ItemsData = require(ReplicatedStorage.Shared.Systems.Locker.Data.ItemsData)

-- State Management
local currentScope = nil
local _currentInstance = nil
local closeCallback = nil
local activeCleanup = nil -- Cleanup function from BoxAnimation
local isUnboxing = false

-- Helper: buscar datos de skin por nombre en ItemsData
local function findSkinData(skinName: string)
	local skins = ItemsData.Arsenal and ItemsData.Arsenal.WeaponSkins
	if not skins then return nil end
	for _, skinData in ipairs(skins) do
		if skinData.Name == skinName then
			return skinData
		end
	end
	return nil
end

local CasesUI = {}

function CasesUI.mount(scope)
	local player = Players.LocalPlayer
	local currentCase = Value(scope, nil) -- Selected case data (from LootConfig)

	local playerData = Value(scope, DataController:Get() or {})

	local isLuckySpinEnabled = Value(scope, false)
	local unboxingState = Value(scope, false) -- true durante la animación
	local showCollect = Value(scope, false) -- true solo cuando empieza la órbita
	local isCameraMoving = Value(scope, true) -- Arranca en true al abrir para proteger el tween inicial

	-- Escuchar cambios en los datos
	DataController:OnReady(function()
		playerData:set(DataController:Get())
	end)

	DataController:OnRawChange(function()
		playerData:set(DataController:Get())
		-- Resetear toggle de Lucky Spin si de repente nos quitan o ya no tenemos spins y estaba activado
		local data = peek(playerData)
		if peek(isLuckySpinEnabled) and (not data or (data.luckySpins or 0) < 1) then
			isLuckySpinEnabled:set(false)
		end
	end)

	-- Frame contenedor para los clovers (referencia directa)
	local cloverSpawnFrame = scope:New "Frame" {
		Name = "CloverSpawn",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 100,
	}

	-- Función para el efecto de la lluvia de tréboles
	local function spawnCloverRain()
		task.spawn(function()
			while peek(isLuckySpinEnabled) and currentScope ~= nil do
				if not cloverSpawnFrame or not cloverSpawnFrame.Parent then
					break
				end

				local amount = math.random(2, 4)
				for i = 1, amount do
					local clover = Instance.new("ImageLabel")
					clover.Name = "CloverRainDrop"
					clover.BackgroundTransparency = 1
					clover.Image = "rbxassetid://122370030322334"
					local sizeScale = math.random(1, 4) / 100
					clover.Size = UDim2.fromScale(sizeScale, sizeScale)
					clover.SizeConstraint = Enum.SizeConstraint.RelativeXX
					local startX = math.random()
					clover.Position = UDim2.fromScale(startX, -0.15)
					clover.Rotation = math.random(-180, 180)
					clover.ZIndex = 110
					clover.Parent = cloverSpawnFrame

					local duration = math.random(15, 25) / 10
					local endRotation = clover.Rotation + math.random(-360, 360)
					local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.In)
					local tween = TweenService:Create(clover, tweenInfo, {
						Position = UDim2.fromScale(startX, 1.2),
						Rotation = endRotation
					})
					tween:Play()
					task.delay(duration, function()
						if clover then clover:Destroy() end
					end)
				end
				task.wait(0.2)
			end
		end)
	end

	-- Función para abrir la caja (lógica de compra + animación)
	local function openCase()
		if isUnboxing or peek(isCameraMoving) then return end

		local caseData = peek(currentCase)
		if not caseData then return end

		isUnboxing = true
		unboxingState:set(true)

		-- Consumir Lucky Spin localmente para feedback inmediato
		local useLucky = peek(isLuckySpinEnabled)
		if useLucky then
			isLuckySpinEnabled:set(false)
		end

		-- Invocar al servidor
		local casesFolder = ReplicatedStorage:WaitForChild("Cases", 5)
		if not casesFolder then
			warn("[CasesUI] No se encontró la carpeta Cases en ReplicatedStorage")
			isUnboxing = false
			unboxingState:set(false)
			return
		end

		local openCaseRF = casesFolder:WaitForChild("OpenCase", 5)
		if not openCaseRF then
			warn("[CasesUI] No se encontró el RemoteFunction OpenCase")
			isUnboxing = false
			unboxingState:set(false)
			return
		end

		local result = openCaseRF:InvokeServer(caseData.Name, useLucky)

		if not result or not result.success then
			warn("[CasesUI] Error al abrir caja:", result and result.message or "Sin respuesta")
			isUnboxing = false
			unboxingState:set(false)
			return
		end

		-- Éxito: obtener datos de la skin ganadora
		local skinData = findSkinData(result.skinName)

		-- Encontrar el modelo de la caja en workspace
		local casesWorkspace = Workspace:FindFirstChild("Cases")
		local boxModel = casesWorkspace and casesWorkspace:FindFirstChild(caseData.Name)

		if not boxModel then
			warn("[CasesUI] No se encontró el modelo de caja:", caseData.Name)
			isUnboxing = false
			unboxingState:set(false)
			return
		end

		-- Ejecutar la animación con callback de órbita
		-- BoxAnimation clonará el Default weapon en RisePart y aplicará skinData (igual que Locker)
		activeCleanup = BoxAnimation.iniciarSecuencia(boxModel, skinData, function()
			showCollect:set(true)
		end)
	end

	-- Find cameras
	local casesCameras = Workspace:WaitForChild("Cameras"):WaitForChild("Cases", 5)

	-- Helper to switch camera
	local function switchToCaseCamera(caseName)
		if not casesCameras then return end
		local cameraPart = casesCameras:FindFirstChild(caseName)

		if cameraPart then
			CameraManager.setTarget(cameraPart, true, nil, 14) -- Adjust focus distance as needed
			isCameraMoving:set(true)
			task.delay(0.85, function()
				isCameraMoving:set(false)
			end)
		else
			warn("Camera not found for case:", caseName)
		end
	end

	-- Función para cerrar la animación y volver al estado normal
	local function closeUnboxing()
		if activeCleanup then
			activeCleanup()
			activeCleanup = nil
		end
		isUnboxing = false
		unboxingState:set(false)
		showCollect:set(false)

		-- Restaurar la cámara al caso actual usando el helper (que tiene el debounce del click)
		local caseData = peek(currentCase)
		if caseData then
			switchToCaseCamera(caseData.Name)
		end
	end

	-- Observer for case selection
	local obsCase = Observer(scope, currentCase)
	obsCase:onChange(function()
		local case = peek(currentCase)
		if case then
			switchToCaseCamera(case.Name)

			-- Si la caja no acepta LuckySpin, asegúrate de apagar el modo si estaba activo
			if peek(isLuckySpinEnabled) and case.LuckySpin == false then
				isLuckySpinEnabled:set(false)
			end
		end
	end)

    -- Prepare Config List for ordering
    local sortedCases = {}
    for _, data in LootConfig do
        table.insert(sortedCases, data)
    end
    -- Sort cases by Order field
    table.sort(sortedCases, function(a, b)
        local orderA = a.Order or 999
        local orderB = b.Order or 999
        return orderA < orderB
    end)

    -- Default selection
    if #sortedCases > 0 then
        currentCase:set(sortedCases[1])
    end

	local gui = scope:New "ScreenGui" {
		Name = "CasesUI",
		DisplayOrder = 10,
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player.PlayerGui,

		[Children] = {
			-- Contenedor de clovers (referencia directa que ya existe)
			cloverSpawnFrame,

			scope:New "ImageButton" {
				Name = "CloseButton",
				AnchorPoint = Vector2.new(0.5, 0.5),
				AutoButtonColor = false,
				BackgroundColor3 = Color3.fromRGB(246, 56, 70),
				Position = UDim2.fromScale(0.9665, 0.1455),
				Size = UDim2.fromScale(0.041, 0.07),
				Visible = Computed(scope, function(use)
					return not use(unboxingState)
				end),

				[Fusion.OnEvent "Activated"] = function()
					if closeCallback then
						closeCallback()
					end
				end,

				[Children] = {
					scope:New "UICorner" {
						Name = "UICorner",
						CornerRadius = UDim.new(0.15, 0),
					},

					scope:New "UIAspectRatioConstraint" {
						Name = "UIAspectRatioConstraint",
					},

					scope:New "TextLabel" {
						Name = "TextLabel",
						BackgroundColor3 = Color3.fromRGB(255, 96, 110),
						FontFace = Font.new(
							"rbxasset://fonts/families/LuckiestGuy.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						Position = UDim2.fromScale(0, -0.013),
						Size = UDim2.fromScale(1, 0.9),
						Text = "X",
						TextColor3 = Color3.new(1, 1, 1),
						TextScaled = true,

						[Children] = {
							scope:New "UICorner" {
								Name = "UICorner",
								CornerRadius = UDim.new(0.15, 0),
							},

							scope:New "UITextSizeConstraint" {
								Name = "UITextSizeConstraint",
								MaxTextSize = 40,
							},
						}
					},

					scope:New "UIStroke" {
						Name = "UIStroke",
						Thickness = 3,
					},
				}
			},

			scope:New "Frame" {
				Name = "Cases",
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0.905521, 0),
				Size = UDim2.fromScale(0.0750636, 1),
				Visible = Computed(scope, function(use)
					return not use(unboxingState)
				end),

				[Children] = {
					scope:New "UIListLayout" {
						Name = "UIListLayout",
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						Padding = UDim.new(0.06, 0),
						SortOrder = Enum.SortOrder.LayoutOrder,
						VerticalAlignment = Enum.VerticalAlignment.Center,
					},

					Computed(scope, function()
						local templates = {}
						for i, caseData in sortedCases do
							local isSelected = Computed(scope, function(use)
								local curr = use(currentCase)
								return curr and curr.Name == caseData.Name
							end)

							table.insert(templates, scope:New "ImageButton" {
								Name = "CaseTemplate",
								AnchorPoint = Vector2.new(1, 0.5),
								AutoButtonColor = false,
								BackgroundColor3 = Computed(scope, function(use)
									return use(isSelected) and Color3.fromRGB(85, 126, 239) or Color3.fromRGB(54, 54, 76)
								end),
								Image = "rbxasset://textures/ui/GuiImagePlaceholder.png",
								ImageTransparency = 1,
								LayoutOrder = i,
								Position = UDim2.fromScale(0.996157, 0.235139),
								Size = UDim2.fromScale(0.992313, 0.113131),

								[Fusion.OnEvent "Activated"] = function()
									currentCase:set(caseData)
								end,

								[Children] = {
									scope:New "UICorner" {
										Name = "UICorner",
									},

									scope:New "ImageLabel" {
										Name = "Thumb",
										BackgroundTransparency = 1,
										Image = caseData.Thumb,
										Position = UDim2.fromScale(0, -0.361591),
										ScaleType = Enum.ScaleType.Fit,
										Size = UDim2.fromScale(1, 1.02759),
									},

									scope:New "TextLabel" {
										Name = "Title",
										BackgroundTransparency = 1,
										FontFace = Font.new(
											"rbxasset://fonts/families/SourceSansPro.json",
											Enum.FontWeight.Bold,
											Enum.FontStyle.Normal
										),
										Position = UDim2.fromScale(0, 0.668258),
										Size = UDim2.fromScale(1, 0.246377),
										Text = caseData.Name,
										TextColor3 = Color3.new(1, 1, 1),
										TextScaled = true,

										[Children] = {
											scope:New "UIStroke" {
												Name = "InnerStroke",
												Thickness = 4,
											},
										}
									},

									scope:New "UIStroke" {
										Name = "BorderStroke",
										ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
										Thickness = 4,
									},

									scope:New "TextLabel" {
										Name = "Notification",
										BackgroundColor3 = Color3.fromRGB(255, 72, 80),
										FontFace = Font.new("rbxasset://fonts/families/LuckiestGuy.json"),
										Position = UDim2.fromScale(0.747777, -0.353399),
										Rotation = 14,
										Size = UDim2.fromScale(0.300669, 0.34407),
										Text = Computed(scope, function(use)
											local data = use(playerData)
											if data and data.caseSpins then
												return tostring(data.caseSpins[caseData.Name] or 0)
											end
											return "0"
										end),
										TextColor3 = Color3.new(1, 1, 1),
										TextSize = 24,
										TextWrapped = true,
										Visible = Computed(scope, function(use)
											local data = use(playerData)
											if data and data.caseSpins then
												return (data.caseSpins[caseData.Name] or 0) >= 1
											end
											return false
										end),

										[Children] = {
											scope:New "UICorner" {
												Name = "UICorner",
												CornerRadius = UDim.new(9, 9),
											},

											scope:New "UIStroke" {
												Name = "UIStroke",
												ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
												Thickness = 3,
											},
										}
									},
								}
							})
						end
						return templates
					end)
				}
			},

			scope:New "Frame" {
				Name = "ActionFrame",
				BackgroundTransparency = 1,
				Position = UDim2.fromScale(0, 0.893357),
				Size = UDim2.new(1, 0, 0.00747672, 100),
				Visible = Computed(scope, function(use)
					return not use(unboxingState)
				end),

				[Children] = {
					scope:New "UIListLayout" {
						Name = "UIListLayout",
						FillDirection = Enum.FillDirection.Horizontal,
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						Padding = UDim.new(0.02, 0),
						SortOrder = Enum.SortOrder.LayoutOrder,
					},

					scope:New "ImageButton" {
						Name = "Purchase",
						AutoButtonColor = false,
						BackgroundColor3 = Color3.fromRGB(85, 126, 239),
						Position = UDim2.fromScale(0.357693, -0.111042),
						Size = UDim2.fromOffset(269, 78),

						[Fusion.OnEvent "Activated"] = function()
							openCase()
						end,

						[Children] = {
							scope:New "UIStroke" {
								Name = "BorderStroke",
								ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
								Thickness = 4,
							},

							scope:New "UICorner" {
								Name = "UICorner",
								CornerRadius = UDim.new(0.2, 0),
							},

							scope:New "ImageLabel" {
								Name = "Currency",
								BackgroundTransparency = 1,
								Image = "rbxassetid://86111407632869",
								Position = UDim2.fromScale(0.183836, 0),
								ScaleType = Enum.ScaleType.Fit,
								Size = UDim2.fromScale(0.167856, 1),
								Visible = Computed(scope, function(use)
									local data = use(playerData)
									local curr = use(currentCase)
									local hasSpins = (data and data.caseSpins and curr and (data.caseSpins[curr.Name] or 0) >= 1)
									local isRobux = (curr and curr.Currency == "Robux")
									return not (hasSpins or isRobux)
								end),
							},

							scope:New "TextLabel" {
								Name = "Price",
								BackgroundTransparency = 1,
								FontFace = Font.new(
									"rbxasset://fonts/families/HighwayGothic.json",
									Enum.FontWeight.Bold,
									Enum.FontStyle.Normal
								),
								Position = Computed(scope, function(use)
									local data = use(playerData)
									local curr = use(currentCase)
									local hasSpins = (data and data.caseSpins and curr and (data.caseSpins[curr.Name] or 0) >= 1)
									local isRobux = (curr and curr.Currency == "Robux")
									if hasSpins or isRobux then
										return UDim2.fromScale(0, -7.82502e-07)
									end
									return UDim2.fromScale(0.385397, -7.82502e-07)
								end),
								Size = Computed(scope, function(use)
									local data = use(playerData)
									local curr = use(currentCase)
									local hasSpins = (data and data.caseSpins and curr and (data.caseSpins[curr.Name] or 0) >= 1)
									local isRobux = (curr and curr.Currency == "Robux")
									if hasSpins or isRobux then
										return UDim2.fromScale(1, 1)
									end
									return UDim2.fromOffset(165, 78)
								end),
								Text = Computed(scope, function(use)
									local data = use(playerData)
									local curr = use(currentCase)
									local hasSpins = (data and data.caseSpins and curr and (data.caseSpins[curr.Name] or 0) >= 1)
									local isRobux = (curr and curr.Currency == "Robux")

									if hasSpins then
										return "OPEN"
									elseif isRobux then
										return " " .. tostring(curr.Price) -- Usa el unicode de ROBUX
									end
									return curr and tostring(curr.Price) or "0"
								end),
								TextColor3 = Color3.new(1, 1, 1),
								TextScaled = true,
								TextXAlignment = Computed(scope, function(use)
									local data = use(playerData)
									local curr = use(currentCase)
									local hasSpins = (data and data.caseSpins and curr and (data.caseSpins[curr.Name] or 0) >= 1)
									local isRobux = (curr and curr.Currency == "Robux")
									if hasSpins or isRobux then
										return Enum.TextXAlignment.Center
									end
									return Enum.TextXAlignment.Left
								end),

								[Children] = {
									scope:New "UITextSizeConstraint" {
										Name = "UITextSizeConstraint",
										MaxTextSize = 40,
									},

									scope:New "UIStroke" {
										Name = "InnerStroke",
										Thickness = 4,
									},
								}
							},

							scope:New "TextLabel" {
								Name = "Notification",
								BackgroundColor3 = Color3.fromRGB(255, 72, 80),
								FontFace = Font.new("rbxasset://fonts/families/LuckiestGuy.json"),
								Position = UDim2.fromScale(0.909748, -0.358415),
								Rotation = 14,
								Size = UDim2.fromScale(0.159559, 0.549621),
								Text = Computed(scope, function(use)
									local data = use(playerData)
									local curr = use(currentCase)
									if data and data.caseSpins and curr then
										return tostring(data.caseSpins[curr.Name] or 0)
									end
									return "0"
								end),
								TextColor3 = Color3.new(1, 1, 1),
								TextSize = 24,
								TextWrapped = true,
								Visible = Computed(scope, function(use)
									local data = use(playerData)
									local curr = use(currentCase)
									if data and data.caseSpins and curr then
										return (data.caseSpins[curr.Name] or 0) >= 1
									end
									return false
								end),

								[Children] = {
									scope:New "UICorner" {
										Name = "UICorner",
										CornerRadius = UDim.new(9, 9),
									},

									scope:New "UIStroke" {
										Name = "UIStroke",
										ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
										Thickness = 3,
									},
								}
							},
						}
					},

					scope:New "ImageButton" {
						Name = "LuckySpin",
						AutoButtonColor = false,
						BackgroundColor3 = Color3.new(1, 1, 1),
						Position = UDim2.fromScale(0.357693, -0.111042),
						Size = UDim2.fromOffset(269, 78),
						Visible = Computed(scope, function(use)
							local curr = use(currentCase)
							-- Retorna falso SOLO si exlicitamente curr.LuckySpin es false
							return curr and curr.LuckySpin ~= false
						end),

						[Fusion.OnEvent "Activated"] = function()
							local data = peek(playerData)
							if data and (data.luckySpins or 0) >= 1 then
								-- Toggle
								local currentState = peek(isLuckySpinEnabled)
								isLuckySpinEnabled:set(not currentState)

								-- Si se acaba de activar, disparar lluvia de clovers
								if not currentState then
									spawnCloverRain()
								end
							else
								print("No tienes suficientes Lucky Spins")
							end
						end,

						[Children] = {
							scope:New "UIStroke" {
								Name = "BorderStroke",
								ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
								Thickness = 4,
							},

							scope:New "UICorner" {
								Name = "UICorner",
								CornerRadius = UDim.new(0.2, 0),
							},

							scope:New "TextLabel" {
								Name = "ActionText",
								BackgroundTransparency = 1,
								FontFace = Font.new(
									"rbxasset://fonts/families/HighwayGothic.json",
									Enum.FontWeight.Bold,
									Enum.FontStyle.Normal
								),
								Position = UDim2.fromScale(1.57283e-06, 1.93723e-06),
								Size = UDim2.fromScale(1, 1),
								Text = Computed(scope, function(use)
									local data = use(playerData)
									local isEnabled = use(isLuckySpinEnabled)

									if isEnabled then
										return "ENABLED!"
									elseif data and (data.luckySpins or 0) >= 1 then
										return "USE 1"
									end
									return "GET MORE"
								end),
								TextColor3 = Color3.new(1, 1, 1),
								TextScaled = true,

								[Children] = {
									scope:New "UITextSizeConstraint" {
										Name = "UITextSizeConstraint",
										MaxTextSize = 40,
									},

									scope:New "UIStroke" {
										Name = "InnerStroke",
										Thickness = 4,
									},
								}
							},

							scope:New "TextLabel" {
								Name = "Title",
								BackgroundTransparency = 1,
								FontFace = Font.new(
									"rbxasset://fonts/families/HighwayGothic.json",
									Enum.FontWeight.Bold,
									Enum.FontStyle.Normal
								),
								Position = UDim2.fromScale(0.234852, -0.745261),
								Size = UDim2.fromOffset(208, 45),
								Text = "Lucky Spin",
								TextColor3 = Color3.new(1, 1, 1),
								TextScaled = true,
								TextXAlignment = Enum.TextXAlignment.Left,

								[Children] = {
									scope:New "UITextSizeConstraint" {
										Name = "UITextSizeConstraint",
										MaxTextSize = 40,
									},

									scope:New "UIStroke" {
										Name = "InnerStroke",
										Thickness = 4,
									},
								}
							},

							scope:New "ImageLabel" {
								Name = "Clover",
								BackgroundTransparency = 1,
								Image = "rbxassetid://122370030322334",
								Position = UDim2.fromScale(-0.0002303, -0.745261),
								ScaleType = Enum.ScaleType.Fit,
								Size = UDim2.fromScale(0.209768, 0.585796),
							},

							scope:New "UIGradient" {
								Name = "UIGradient",
								Color = ColorSequence.new({
									ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 219, 129)),
									ColorSequenceKeypoint.new(0.53, Color3.fromRGB(18, 238, 54)),
									ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 243, 74)),
								}),
							},

							scope:New "TextLabel" {
								Name = "Notification",
								BackgroundColor3 = Color3.fromRGB(255, 72, 80),
								FontFace = Font.new("rbxasset://fonts/families/LuckiestGuy.json"),
								Position = UDim2.fromScale(0.909748, -0.358415),
								Rotation = 14,
								Size = UDim2.fromScale(0.159559, 0.549621),
								Text = Computed(scope, function(use)
									local data = use(playerData)
									return data and tostring(data.luckySpins or 0) or "0"
								end),
								TextColor3 = Color3.new(1, 1, 1),
								TextSize = 24,
								TextWrapped = true,
								Visible = Computed(scope, function(use)
									local data = use(playerData)
									return data and (data.luckySpins or 0) >= 1
								end),

								[Children] = {
									scope:New "UICorner" {
										Name = "UICorner",
										CornerRadius = UDim.new(9, 9),
									},

									scope:New "UIStroke" {
										Name = "UIStroke",
										ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
										Thickness = 3,
									},
								}
							},
						}
					},
				}
			},

			-- Botón "COLLECT" visible solo durante unboxing (tras la animación)
			scope:New "ImageButton" {
				Name = "CollectButton",
				AnchorPoint = Vector2.new(0.5, 0.5),
				AutoButtonColor = false,
				BackgroundColor3 = Color3.fromRGB(85, 239, 126),
				Position = UDim2.fromScale(0.5, 0.9),
				Size = UDim2.fromOffset(300, 80),
				Visible = Computed(scope, function(use)
					return use(showCollect)
				end),

				[Fusion.OnEvent "Activated"] = function()
					closeUnboxing()
				end,

				[Children] = {
					scope:New "UICorner" {
						Name = "UICorner",
						CornerRadius = UDim.new(0.2, 0),
					},

					scope:New "UIStroke" {
						Name = "BorderStroke",
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						Thickness = 4,
					},

					scope:New "TextLabel" {
						Name = "CollectText",
						BackgroundTransparency = 1,
						FontFace = Font.new(
							"rbxasset://fonts/families/HighwayGothic.json",
							Enum.FontWeight.Bold,
							Enum.FontStyle.Normal
						),
						Size = UDim2.fromScale(1, 1),
						Text = "COLLECT",
						TextColor3 = Color3.new(1, 1, 1),
						TextScaled = true,

						[Children] = {
							scope:New "UITextSizeConstraint" {
								Name = "UITextSizeConstraint",
								MaxTextSize = 48,
							},

							scope:New "UIStroke" {
								Name = "InnerStroke",
								Thickness = 4,
							},
						}
					},
				}
			},
		}
	}

    -- Protegemos la primera transición (al abrir el menú por primera vez)
    task.delay(0.85, function()
        if isCameraMoving then isCameraMoving:set(false) end
    end)

    return gui
end


function CasesUI.open(onCloseCallback)
    if currentScope then return end -- Already open

    closeCallback = function()
		-- Limpiar animación activa si hay una
		if activeCleanup then
			activeCleanup()
			activeCleanup = nil
		end
		isUnboxing = false
        CasesUI.close()
        if onCloseCallback then onCloseCallback() end
    end

    currentScope = scoped(Fusion)
    _currentInstance = CasesUI.mount(currentScope)
end

function CasesUI.close()
    if currentScope then
		-- Limpiar animación activa si hay una
		if activeCleanup then
			activeCleanup()
			activeCleanup = nil
		end
		isUnboxing = false
        Fusion.doCleanup(currentScope)
        currentScope = nil
        _currentInstance = nil
        closeCallback = nil
    end
end

return CasesUI
