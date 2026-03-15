local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local SkinApplier = require(ReplicatedStorage.Shared.Systems.Appearance.SkinApplier)

local BoxManager = {}

local function getSmoothShake(tiempo, velocidad, intensidad)
    local x = math.noise(tiempo * velocidad, 0, 0) * intensidad
    local y = math.noise(0, tiempo * velocidad, 0) * intensidad
    local z = math.noise(0, 0, tiempo * velocidad) * intensidad
    return Vector3.new(x, y, z)
end

-- Colores para el destello y la luz final según la rareza
local RARITY_COLORS = {
    Common = Color3.fromRGB(200, 200, 200),
    Rare = Color3.fromRGB(111, 126, 248),
    Epic = Color3.fromRGB(174, 78, 246),
    Legendary = Color3.fromRGB(255, 170, 0)
}

function BoxManager.iniciarSecuencia(modeloOriginal, skinData, onOrbitStart)
    local Reveal = workspace.Cases:WaitForChild("Open")
    local startPart = Reveal:FindFirstChild("StartPart")
    local fallPart  = Reveal:FindFirstChild("FallPart")
    local risePart  = Reveal:FindFirstChild("RisePart")

    local camera = workspace.CurrentCamera
    local escalaOriginal = modeloOriginal:GetScale()

    local startCFrame = startPart.CFrame
    local fallCFrame  = fallPart.CFrame
    local riseCFrame  = risePart.CFrame

    local box = modeloOriginal:Clone()
    box:PivotTo(startCFrame)
    box.Parent = workspace

    local boxHighlight = Instance.new("Highlight")
    boxHighlight.FillColor = Color3.fromRGB(255, 255, 255)
    boxHighlight.OutlineColor = Color3.fromRGB(255, 255, 255)
    boxHighlight.FillTransparency = 1
    boxHighlight.OutlineTransparency = 1
    boxHighlight.Parent = box

    local camDistance = Instance.new("NumberValue")
    camDistance.Value = 55
    camera.CameraType = Enum.CameraType.Scriptable

    local bottomPos = riseCFrame.Position
    local currentFocus = bottomPos + Vector3.new(0, 2, 0)
    local isTracking = false

    local initialTargetPos = Vector3.new(bottomPos.X + camDistance.Value, bottomPos.Y + 2, bottomPos.Z + 4)
    camera.CFrame = CFrame.lookAt(initialTargetPos, currentFocus)

    local cameraShakeOffset = Vector3.new(0, 0, 0)

    -- Bucle de cámara principal
    local cameraConnection = RunService.RenderStepped:Connect(function(dt)
        if not box or not box.Parent then return end
        local boxPos = box:GetPivot().Position
        local tiempo = os.clock()

        local softSway = Vector3.new(0, math.sin(tiempo * 0.8) * 0.4, math.cos(tiempo * 0.6) * 0.4)
        local targetPos = Vector3.new(bottomPos.X + camDistance.Value, bottomPos.Y + 2, bottomPos.Z + 4) + softSway + cameraShakeOffset

        local desiredFocus = isTracking and boxPos or (bottomPos + Vector3.new(0, 2, 0))
        currentFocus = currentFocus:Lerp(desiredFocus, 1 - math.exp(-15 * dt))

        local smoothing = 1 - math.exp(-10 * dt)
        camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(targetPos, currentFocus), smoothing)
    end)

    local function tweenModel(targetCFrame, duration, style, direction)
        local cframeValue = Instance.new("CFrameValue")
        cframeValue.Value = box:GetPivot()
        local connection = cframeValue:GetPropertyChangedSignal("Value"):Connect(function()
            if box.Parent then box:PivotTo(cframeValue.Value) end
        end)
        local tween = TweenService:Create(cframeValue, TweenInfo.new(duration, style, direction), {Value = targetCFrame})
        tween:Play()
        tween.Completed:Wait()
        connection:Disconnect()
        cframeValue:Destroy()
    end

    TweenService:Create(camDistance, TweenInfo.new(1.2, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {Value = 28}):Play()

    -- 1. La caja cae
    tweenModel(fallCFrame, 0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

    -- 2. ¡IMPACTO!
    isTracking = true
    cameraShakeOffset = Vector3.new(0, -1.5, 0)

    camera.FieldOfView = 62
    TweenService:Create(camera, TweenInfo.new(0.7, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {FieldOfView = 70}):Play()

    -- Activar partículas originales de impacto
    local glowAttachment = box:FindFirstChild("Glow", true)
    local originalParticles = {}
    if glowAttachment and glowAttachment:IsA("Attachment") then
        for _, child in ipairs(glowAttachment:GetChildren()) do
            if child:IsA("ParticleEmitter") then
                child.Enabled = true
                table.insert(originalParticles, child)
            end
        end
    end

    TweenService:Create(camDistance, TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Value = 18}):Play()

    -- 3. La caja rebota hacia la posición de carga
    tweenModel(riseCFrame, 1.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

    local startTime = os.clock()
    local duracionBuildup = 2.6

    TweenService:Create(boxHighlight, TweenInfo.new(duracionBuildup, Enum.EasingStyle.Exponential, Enum.EasingDirection.In), {
        FillTransparency = 0, OutlineTransparency = 0
    }):Play()

    local buildUpConnection
    buildUpConnection = RunService.RenderStepped:Connect(function()
        local elapsed = os.clock() - startTime
        local progress = math.clamp(elapsed / duracionBuildup, 0, 1)
        local intensity = math.pow(progress, 4)

        local shakeOffset = getSmoothShake(elapsed, 40, 1.2 * intensity)
        cameraShakeOffset = getSmoothShake(elapsed + 10, 30, 1.5 * intensity)

        local heartbeat = math.abs(math.sin(elapsed * (10 + intensity * 25))) * 2
        camera.FieldOfView = 70 + (15 * intensity) - heartbeat

        local tiltAngleX = math.noise(elapsed * 20, 0, 0) * math.rad(20 * intensity)
        local tiltAngleZ = math.sin(elapsed * (40 + intensity * 30)) * math.rad(15 * intensity)

        box:PivotTo(riseCFrame * CFrame.new(shakeOffset) * CFrame.Angles(tiltAngleX, 0, tiltAngleZ))
        box:ScaleTo(escalaOriginal * (1 + (0.4 * intensity)))
    end)

    task.wait(duracionBuildup)
    buildUpConnection:Disconnect()

    -- 4. HIT-STOP
    camera.FieldOfView = 88
    task.wait(0.06)

    cameraConnection:Disconnect()

    -- Apagamos las partículas de la caja para que no interfieran con la revelación limpia
    for _, p in ipairs(originalParticles) do p.Enabled = false end

    -- 5. FADE A BLANCO Y REVELACIÓN
    local rarity = skinData and skinData.Rarity or "Common"
    local finalColor = RARITY_COLORS[rarity] or RARITY_COLORS.Common

    local flash = Instance.new("ColorCorrectionEffect", game:GetService("Lighting"))
    flash.Brightness = 0
    flash.Contrast = 0
    flash.TintColor = finalColor

    -- 5.1 Explosión rápida a blanco puro
    local flashIn = TweenService:Create(flash, TweenInfo.new(0.15, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
        Brightness = 5, Contrast = 1.5
    })

    -- Hacemos el Zoom in rápido MIENTRAS la pantalla se pone blanca
    TweenService:Create(camera, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {FieldOfView = 40}):Play()

    flashIn:Play()
    flashIn.Completed:Wait() -- 🛑 PAUSA: La pantalla está blanca cegadora aquí.

    -- 5.2 Cambio de Telón (Preparar premio mientras no se ve nada)
    for _, obj in ipairs(box:GetDescendants()) do
        if obj:IsA("BasePart") or obj:IsA("Decal") then obj.Transparency = 1 end
    end

    -- Ajustar la cámara para la revelación
    camera.FieldOfView = 65

    local floatConnection
    local skinAnimConnection
    local premio = nil
    local weaponCaseTemplate = ReplicatedStorage:FindFirstChild("WeaponCaseTemplate")

    if weaponCaseTemplate then
        premio = weaponCaseTemplate:Clone()
        premio:PivotTo(riseCFrame * CFrame.new(0, 0.2, 0))

        for _, part in premio:GetDescendants() do
            if part:IsA("BasePart") then
                part.Anchored = true
                part.CanCollide = false
            end
        end

        premio.Parent = workspace

        -- Como la pantalla ya se está aclarando, el arma ya está a su tamaño real (sin efecto popup que se pierda en el flash)
        premio:ScaleTo(0.025)

        -- Luz del premio
        local godLight = Instance.new("PointLight")
        godLight.Color = finalColor
        godLight.Range = 12
        godLight.Brightness = 4
        godLight.Shadows = true
        godLight.Parent = premio.PrimaryPart or premio:FindFirstChildWhichIsA("BasePart")
        TweenService:Create(godLight, TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {Brightness = 1.5, Range = 8}):Play()

        -- Update Rarity UI
        local partContainer = premio:FindFirstChild("PartContainer")
        if partContainer then
            for _, sideName in ipairs({"Front", "Back"}) do
                local side = partContainer:FindFirstChild(sideName)
                if side and side:FindFirstChild("Container") then
                    local rarityLabel = side.Container:FindFirstChild("Rarity")
                    if rarityLabel and rarityLabel:IsA("TextLabel") then
                        rarityLabel.Text = string.upper(rarity)
                        for _, child in ipairs(rarityLabel:GetChildren()) do
                            if child:IsA("UIGradient") then child:Destroy() end
                        end
                        rarityLabel.TextColor3 = Color3.new(1, 1, 1)

                        if rarity == "Legendary" then
                            local gradient = Instance.new("UIGradient")
                            gradient.Color = ColorSequence.new({
                                ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 236, 125)),
                                ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 102, 0)),
                            })
                            gradient.Parent = rarityLabel
                        elseif rarity == "Epic" then
                            local gradient = Instance.new("UIGradient")
                            gradient.Color = ColorSequence.new({
                                ColorSequenceKeypoint.new(0, Color3.fromRGB(237, 163, 248)),
                                ColorSequenceKeypoint.new(1, Color3.fromRGB(174, 78, 246)),
                            })
                            gradient.Parent = rarityLabel
                        elseif rarity == "Rare" then
                            local gradient = Instance.new("UIGradient")
                            gradient.Color = ColorSequence.new({
                                ColorSequenceKeypoint.new(0, Color3.fromRGB(172, 250, 245)),
                                ColorSequenceKeypoint.new(1, Color3.fromRGB(111, 126, 248)),
                            })
                            gradient.Rotation = 90
                            gradient.Parent = rarityLabel
                        else
                            rarityLabel.TextColor3 = Color3.fromRGB(145, 145, 145)
                        end
                    end
                end
            end
        end

        if skinData then
            local textures = SkinApplier.apply(premio, skinData)
            if skinData.Animated and #textures > 0 then
                skinAnimConnection = SkinApplier.startAnimation(textures, skinData, premio)
            end
        end

        -- Spin del premio (velocidad elegante: 90)
        local floatTime = 0
        floatConnection = RunService.RenderStepped:Connect(function(dt)
            if premio and premio.Parent then
                floatTime = floatTime + dt
                local spin = math.rad(floatTime * 90)
                local hoverY = math.sin(floatTime * 2.5) * 0.25
                premio:PivotTo(riseCFrame * CFrame.new(0, 0.2 + hoverY, 0) * CFrame.Angles(0, spin, 0))
            end
        end)
    end

    -- 5.3 Desvanecer el blanco para revelar el arma
    local flashOut = TweenService:Create(flash, TweenInfo.new(1.8, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {
        Brightness = 0, Contrast = 0, TintColor = Color3.new(1,1,1)
    })
    flashOut:Play()
    Debris:AddItem(flash, 2)

    local anguloOrbit = -math.pi/2
    local centroPremio = riseCFrame.Position + Vector3.new(0, 1, 0)

    if onOrbitStart then task.spawn(onOrbitStart) end

    -- Órbita de cámara final
    local orbitConnection = RunService.RenderStepped:Connect(function(dt)
        anguloOrbit = anguloOrbit + (dt * 0.35)
        local verticalBob = math.sin(os.clock() * 1.2) * 1.2
        local posicionCamara = centroPremio + Vector3.new(math.cos(anguloOrbit) * 17, 2.5 + verticalBob, math.sin(anguloOrbit) * 17)

        camera.CFrame = camera.CFrame:Lerp(CFrame.lookAt(posicionCamara, centroPremio), 1 - math.exp(-6 * dt))
    end)

    return function()
        if orbitConnection then orbitConnection:Disconnect() end
        if floatConnection then floatConnection:Disconnect() end
        if skinAnimConnection then skinAnimConnection:Disconnect() end
        if box then box:Destroy() end
        if premio then premio:Destroy() end
        camera.FieldOfView = 70
        camera.CameraType = Enum.CameraType.Custom
    end
end

return BoxManager
