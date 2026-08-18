--!strict
--[[
	Scanner — descubre mapas y RoamPoints replicando EXACTAMENTE la lógica de
	autoría de RoamGraph.luau (src/server/AI/nav/RoamGraph.luau):

	  Workspace/Maps/<MapName>/AINav/RoamPoints/
	  Cada DESCENDIENTE BasePart es un punto (usa GetDescendants, no GetChildren).

	No inventa conexiones ni orden: el pool es plano, sin numeración. Si algún
	día RoamGraph cambia la ruta de autoría, este módulo es el único lugar a
	tocar en el plugin.
]]

local Scanner = {}

local MAPS_FOLDER_NAME = "Maps"
local AINAV_NAME = "AINav"
local ROAMPOINTS_NAME = "RoamPoints"
local SPAWNS_NAME = "Spawns"

-- Devuelve la carpeta Workspace.Maps o nil.
function Scanner.getMapsFolder(): Instance?
	return workspace:FindFirstChild(MAPS_FOLDER_NAME)
end

-- Lista los mapas candidatos: hijos directos de Workspace.Maps que tengan
-- AINav/RoamPoints. Si no existe Maps, cae a escanear el propio Workspace por
-- cualquier objeto con AINav/RoamPoints (tolerante a proyectos sin Maps/).
function Scanner.listMaps(): { Instance }
	local maps: { Instance } = {}
	local mapsFolder = Scanner.getMapsFolder()
	local roots = mapsFolder and mapsFolder:GetChildren() or workspace:GetChildren()
	for _, root in roots do
		if Scanner.findRoamPointsFolder(root) then
			table.insert(maps, root)
		end
	end
	return maps
end

-- Espeja RoamGraph._findAINavFolder: mapRoot/AINav/RoamPoints.
function Scanner.findRoamPointsFolder(mapRoot: Instance): Instance?
	local aiNav = mapRoot:FindFirstChild(AINAV_NAME)
	if not aiNav then
		return nil
	end
	return aiNav:FindFirstChild(ROAMPOINTS_NAME)
end

-- Espeja RoamGraph._readAuthoredPoints: todos los descendientes BasePart.
-- Devuelve las Parts (no solo posiciones) para poder adornarlas y leer sus
-- atributos Tags/Weight si querés inspeccionarlos.
function Scanner.readPoints(mapRoot: Instance): { BasePart }
	local points: { BasePart } = {}
	local folder = Scanner.findRoamPointsFolder(mapRoot)
	if not folder then
		return points
	end
	for _, child in folder:GetDescendants() do
		if child:IsA("BasePart") then
			table.insert(points, child)
		end
	end
	return points
end

-- Puntos de aparición del mapa: BaseParts descendientes de <Mapa>/Spawns.
-- Espeja EXACTAMENTE SpawnService.GetSpawnPoints (FindFirstChild("Spawns", true)
-- + todos los descendientes BasePart). Ahí aparecen JUGADORES y NPCs de IA por
-- igual: SpawnService/AIService los colocan con root.CFrame = spawnPoint.CFrame
-- (+offset en Y), y la orientación de aparición es el yaw de la part (SpawnService
-- estampa SpawnYaw = atan2(-look.X,-look.Z), respetado por ShoulderCamera y bots).
-- Devolvemos las Parts para leer su posición Y orientación al dibujar la flecha.
function Scanner.listSpawnPoints(mapRoot: Instance): { BasePart }
	local spawns: { BasePart } = {}
	local spawnsRoot = mapRoot:FindFirstChild(SPAWNS_NAME, true)
	if not spawnsRoot then
		return spawns
	end
	for _, node in spawnsRoot:GetDescendants() do
		if node:IsA("BasePart") then
			table.insert(spawns, node)
		end
	end
	return spawns
end

return Scanner
