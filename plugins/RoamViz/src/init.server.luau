--!strict
--[[
	RoamViz — plugin de Studio para visualizar el pool de RoamPoints que
	consumen los bots (src/server/AI/nav/RoamGraph.luau).

	Recordá lo que ESTE plugin NO hace, porque tu sistema no lo tiene:
	  • NO dibuja conexiones/beams entre puntos: el pool es plano, sin orden ni
	    referencias entre nodos.
	  • NO dibuja la ruta bot→destino: esa la calcula PathfindingService en
	    runtime y no es una recta.

	Lo que SÍ hace:
	  • Marcadores esféricos sobre cada BasePart de <Mapa>/AINav/RoamPoints.
	  • Anillos de alcance (RoamMinDist / RoamMaxDist) alrededor del punto que
	    tengas seleccionado en el Explorer — la corona entre ambos es la zona
	    real de picking (pickRandomNavigablePoint elige uniforme en [min,max]).
	  • Puntos de spawn del mapa (BaseParts de <Mapa>/Spawns) con una FLECHA que
	    apunta hacia donde mirará quien aparezca ahí — jugadores y NPCs de IA por
	    igual (SpawnService/AIService colocan el body con root.CFrame =
	    spawnPoint.CFrame, conservando la orientación del spawn).

	Regeneración manual (un clic) — sin realtime, para no cargar el editor.
	El único guiño reactivo: si el toggle de anillos está activo, se redibujan
	al cambiar la selección de Studio (barato: 2 discos).
]]

local Selection = game:GetService("Selection")

local Config = require(script.Config)
local Scanner = require(script.Scanner)
local Renderer = require(script.Renderer)
local PathViz = require(script.PathViz)
local UI = require(script.UI)

local state = Config.load(plugin)
local renderer = Renderer.new()
local pathViz = PathViz.new()

-- Generación de job de pathfinding: bumpearla cancela cualquier cómputo en
-- vuelo (los task.spawn chequean `gen ~= pathJobGen` y abortan). Evita que dos
-- jobs solapados escriban rutas mezcladas y permite cancelar con Limpiar.
local pathJobGen = 0
local YIELD_EVERY = 8 -- computes entre task.wait (no congelar Studio)

-- toolbar + botón
local toolbar = plugin:CreateToolbar("RoamViz")
local toggleButton = toolbar:CreateButton(
	"RoamViz",
	"Visualizar RoamPoints, anillos de alcance y puntos de spawn (con orientación)",
	"rbxasset://textures/AnimationEditor/icon_checkmark.png"
)
toggleButton.ClickableWhenViewportHidden = true

-- dock widget
local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right, -- dock state
	false, -- inicialmente cerrado
	false, -- override enabled
	300, -- ancho por defecto
	520, -- alto por defecto
	260, -- ancho mínimo
	360 -- alto mínimo
)
local widget = plugin:CreateDockWidgetPluginGui("RoamViz_Widget", widgetInfo)
widget.Title = "RoamViz"
widget.Name = "RoamViz"

local ui: UI.UI

-- ---- render pipeline -------------------------------------------------------

-- Devuelve el centro para los anillos: el primer BasePart seleccionado en el
-- Explorer que sea descendiente del RoamPoints del mapa activo. Si no hay,
-- devuelve nil (no se dibujan anillos).
local function ringCenter(mapRoot: Instance): Vector3?
	local roamFolder = Scanner.findRoamPointsFolder(mapRoot)
	if not roamFolder then
		return nil
	end
	for _, obj in Selection:Get() do
		if obj:IsA("BasePart") and obj:IsDescendantOf(roamFolder) then
			return obj.Position
		end
	end
	return nil
end

local function regenerate()
	renderer:clear()
	local mapRoot = ui:getSelectedMap()
	if not mapRoot then
		ui:setStatus("Seleccioná un mapa de la lista.")
		return
	end
	if not mapRoot.Parent then
		ui:setStatus("El mapa seleccionado ya no existe. Refrescá.")
		return
	end

	local points = Scanner.readPoints(mapRoot)
	renderer:drawMarkers(points, state)

	local ringInfo = ""
	if state.showRings then
		local center = ringCenter(mapRoot)
		if center then
			renderer:drawRings(center, state)
			ringInfo = " · anillos sobre punto seleccionado"
		else
			ringInfo = " · (seleccioná un RoamPoint en el Explorer para ver anillos)"
		end
	end

	-- Puntos de spawn del mapa (BaseParts de <Mapa>/Spawns): esfera + flecha hacia
	-- donde mirará quien aparezca (jugadores y NPCs de IA), ver Renderer/Scanner.
	local spawnInfo = ""
	if state.showSpawns then
		local spawns = Scanner.listSpawnPoints(mapRoot)
		renderer:drawSpawnPoints(spawns)
		if #spawns > 0 then
			spawnInfo = string.format(" · %d punto(s) de spawn con orientación", #spawns)
		else
			spawnInfo = " · (sin carpeta 'Spawns' en el mapa)"
		end
	end

	ui:setStatus(string.format("Mapa '%s': %d RoamPoints dibujados.%s%s", mapRoot.Name, #points, ringInfo, spawnInfo))
end

-- ---- preview de rutas reales (pathfinding) ---------------------------------

-- Primer BasePart seleccionado en el Explorer que pertenezca al RoamPoints del
-- mapa activo, o nil.
local function selectedRoamPoint(mapRoot: Instance): BasePart?
	local roamFolder = Scanner.findRoamPointsFolder(mapRoot)
	if not roamFolder then
		return nil
	end
	for _, obj in Selection:Get() do
		if obj:IsA("BasePart") and obj:IsDescendantOf(roamFolder) then
			return obj
		end
	end
	return nil
end

-- Rutas desde el punto seleccionado a sus vecinos dentro de [min,max] studs
-- (mismo anillo euclídeo que usa pickRandomNavigablePoint). O(N) computes.
local function drawFromSelected()
	local mapRoot = ui:getSelectedMap()
	if not mapRoot or not mapRoot.Parent then
		ui:setStatus("Seleccioná un mapa válido.")
		return
	end
	local fromPart = selectedRoamPoint(mapRoot)
	if not fromPart then
		ui:setStatus("Seleccioná un RoamPoint en el Explorer para trazar sus rutas.")
		return
	end

	local origin = fromPart.Position
	local targets: { Vector3 } = {}
	for _, p in Scanner.readPoints(mapRoot) do
		if p ~= fromPart then
			local d = (p.Position - origin).Magnitude
			if d >= state.roamMinDist and d <= state.roamMaxDist then
				table.insert(targets, p.Position)
			end
		end
	end

	pathJobGen += 1
	local gen = pathJobGen
	pathViz:clear()
	task.spawn(function()
		local drawn, failed = 0, 0
		for i, target in targets do
			if gen ~= pathJobGen then
				return
			end
			local wps = pathViz:computePath(origin, target)
			if gen ~= pathJobGen then
				return
			end
			if wps then
				pathViz:drawPath(wps, state)
				drawn += 1
			else
				failed += 1
			end
			if i % YIELD_EVERY == 0 then
				ui:setStatus(string.format("Rutas desde '%s': %d/%d…", fromPart.Name, i, #targets))
				task.wait()
			end
		end
		ui:setStatus(string.format(
			"Rutas desde '%s': %d dibujadas, %d inalcanzables (de %d vecinos en [%d,%d]).",
			fromPart.Name, drawn, failed, #targets, state.roamMinDist, state.roamMaxDist
		))
	end)
end

-- Malla podada: todos los pares con distancia euclídea en [min,max], acotada a
-- `maxPaths`, con yield y progreso. El listado de pares es O(N²) pero solo son
-- checks de distancia; lo caro (ComputeAsync) queda topado.
local function drawMesh()
	local mapRoot = ui:getSelectedMap()
	if not mapRoot or not mapRoot.Parent then
		ui:setStatus("Seleccioná un mapa válido.")
		return
	end

	local points = Scanner.readPoints(mapRoot)
	local pairList: { { Vector3 } } = {}
	for i = 1, #points do
		for j = i + 1, #points do
			local d = (points[i].Position - points[j].Position).Magnitude
			if d >= state.roamMinDist and d <= state.roamMaxDist then
				table.insert(pairList, { points[i].Position, points[j].Position })
			end
		end
	end

	local total = #pairList
	local capped = math.min(total, state.maxPaths)

	pathJobGen += 1
	local gen = pathJobGen
	pathViz:clear()
	task.spawn(function()
		local drawn, failed = 0, 0
		for k = 1, capped do
			if gen ~= pathJobGen then
				return
			end
			local pr = pairList[k]
			local wps = pathViz:computePath(pr[1], pr[2])
			if gen ~= pathJobGen then
				return
			end
			if wps then
				pathViz:drawPath(wps, state)
				drawn += 1
			else
				failed += 1
			end
			if k % YIELD_EVERY == 0 then
				ui:setStatus(string.format("Malla: %d/%d rutas…", k, capped))
				task.wait()
			end
		end
		local capNote = ""
		if total > capped then
			capNote = string.format(" · TOPE alcanzado (%d de %d pares; subí 'Máx. rutas')", capped, total)
		end
		ui:setStatus(string.format(
			"Malla: %d dibujadas, %d inalcanzables, de %d pares en [%d,%d].%s",
			drawn, failed, capped, state.roamMinDist, state.roamMaxDist, capNote
		))
	end)
end

-- Cancela cualquier job en vuelo y borra las rutas dibujadas.
local function clearPaths()
	pathJobGen += 1
	pathViz:clear()
end

-- ---- construir UI ----------------------------------------------------------

ui = UI.new(widget, state, {
	onRefreshMaps = function()
		return Scanner.listMaps()
	end,
	onSelectMap = function()
		regenerate()
	end,
	onRegenerate = function()
		regenerate()
	end,
	onClear = function()
		renderer:clear()
		clearPaths()
		ui:setStatus("Adornments limpiados.")
	end,
	onStateChanged = function(newState)
		state = newState
		Config.save(plugin, state)
	end,
	onDrawFromSelected = function()
		drawFromSelected()
	end,
	onDrawMesh = function()
		drawMesh()
	end,
	onClearPaths = function()
		clearPaths()
		ui:setStatus("Rutas limpiadas.")
	end,
})

-- redibujar anillos al cambiar la selección (solo si el toggle está activo)
local selectionConn = Selection.SelectionChanged:Connect(function()
	if widget.Enabled and state.showRings and ui:getSelectedMap() then
		regenerate()
	end
end)

-- ---- toggle del widget -----------------------------------------------------

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
	toggleButton:SetActive(widget.Enabled)
end)

widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
	if widget.Enabled then
		ui:_populateMaps()
	else
		renderer:clear()
		clearPaths()
	end
end)

-- ---- limpieza al descargar -------------------------------------------------

plugin.Unloading:Connect(function()
	pathJobGen += 1 -- cancela jobs en vuelo
	selectionConn:Disconnect()
	ui:destroy() -- desconecta el listener de tema de Studio
	renderer:destroy()
	pathViz:destroy()
end)
