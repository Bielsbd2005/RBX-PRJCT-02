--!strict
--[[
	BotAppearance.luau
	Genera y aplica apariencia (hat + face + weapon wrap) a un bot.

	Diseño:
	- `roll()` se llama una vez por identidad (en _assignIdentity de AIService).
	  El resultado se cachea en la BotIdentity, así una misma identidad
	  recuperada del recycle pool (= mismo bot tras morir) mantiene la misma
	  apariencia durante todo el match.
	- `apply()` se llama tras clonar el rig en _spawnOneBot. Idempotente sobre
	  el character (no acumula accesorios entre vidas porque los rigs vienen
	  frescos del pool).
	- Filtros de catálogo se computan una sola vez al load:
	    * Hats: intersección de ItemsConfig.Hats con los .rbxm reales presentes
	      en Shared.Locker.Hats. Evita warns de templates ausentes.
	    * Faces: todas las entradas de ItemsConfig.Faces (decals, sin templates).
	    * Wraps: todas las entradas de ItemsConfig.WeaponWraps.
	- Coste: una clonación de Accessory + un set de Decal.Texture + un set de
	  Texture sobre WeaponModel.PrimaryPart por spawn. Aplicado una vez, nunca
	  per-frame.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local CosmeticsTemplates = require(Shared.Locker.CosmeticsTemplates)

local BotAppearance = {}

export type BotAppearance = {
	outfitId: string?,
	hatId: string?,
	faceId: string?,
	wrapId: string?,
}

local BODIES_ROOT_NAME = "Bodies"

local BOT_APPEARANCE_HAT_ATTRIBUTE = "BotAppearanceHat"

-- ── Pools de sampling ────────────────────────────────────────────
-- Construidos al load del módulo. AIService corre en el servidor y este
-- módulo se requirea sólo desde allí, así que Shared.Locker.Hats está
-- garantizado disponible al required-time (ReplicatedStorage replica primero).

local function _buildHatPool(): { string }
	local pool: { string } = {}
	local locker = Shared:FindFirstChild("Locker")
	local hatsRoot = locker and locker:FindFirstChild("Hats")
	if not hatsRoot then
		return pool
	end
	local hatsConfig = ItemsConfig.Hats
	if type(hatsConfig) ~= "table" then
		return pool
	end
	for hatId in hatsConfig do
		if hatsRoot:FindFirstChild(hatId) ~= nil then
			table.insert(pool, hatId)
		end
	end
	return pool
end

local function _buildFacePool(): { string }
	local pool: { string } = {}
	local facesConfig = ItemsConfig.Faces
	if type(facesConfig) ~= "table" then
		return pool
	end
	for faceId in facesConfig do
		table.insert(pool, faceId)
	end
	return pool
end

local function _buildWrapPool(): { string }
	local pool: { string } = {}
	local wrapsConfig = ItemsConfig.WeaponWraps
	if type(wrapsConfig) ~= "table" then
		return pool
	end
	for wrapId in wrapsConfig do
		table.insert(pool, wrapId)
	end
	return pool
end

local function _getBodiesRoot(): Folder?
	local root = ServerStorage:FindFirstChild(BODIES_ROOT_NAME)
	if root and root:IsA("Folder") then
		return root :: Folder
	end
	return nil
end

local function _buildOutfitPool(): { string }
	local pool: { string } = {}
	local bodiesRoot = _getBodiesRoot()
	if not bodiesRoot then
		return pool
	end
	local outfitsConfig = ItemsConfig.Outfits
	if type(outfitsConfig) ~= "table" then
		return pool
	end
	-- Intersect ItemsConfig.Outfits con los Models reales en ServerStorage.Bodies
	-- para no warnar cuando un outfit existe en config pero falta .rbxm.
	for outfitId in outfitsConfig do
		local node = bodiesRoot:FindFirstChild(outfitId)
		if node and node:IsA("Model") then
			table.insert(pool, outfitId)
		end
	end
	return pool
end

local _hatPool = _buildHatPool()
local _facePool = _buildFacePool()
local _wrapPool = _buildWrapPool()
local _outfitPool = _buildOutfitPool()

-- Probabilidad de que un bot lleve sombrero. Sin esto, todos los bots
-- llevarían siempre uno (los 3 .rbxm actuales), poco creíble.
local HAT_PROBABILITY = 0.65

local function _pickRandom(pool: { string }): string?
	local n = #pool
	if n == 0 then
		return nil
	end
	return pool[math.random(1, n)]
end

-- ── API ───────────────────────────────────────────────────────────

function BotAppearance.roll(): BotAppearance
	local hatId: string? = nil
	if #_hatPool > 0 and math.random() < HAT_PROBABILITY then
		hatId = _pickRandom(_hatPool)
	end

	return {
		outfitId = _pickRandom(_outfitPool),
		hatId = hatId,
		faceId = _pickRandom(_facePool),
		wrapId = _pickRandom(_wrapPool),
	}
end

--- Devuelve el Model del body por outfitId, o nil si no existe.
--- Usado por AIService para clonar el rig del bot.
function BotAppearance.findBodyTemplate(outfitId: string?): Model?
	if not outfitId or outfitId == "" then
		return nil
	end
	local bodiesRoot = _getBodiesRoot()
	if not bodiesRoot then
		return nil
	end
	local body = bodiesRoot:FindFirstChild(outfitId)
	if body and body:IsA("Model") then
		return body :: Model
	end
	return nil
end

--- Devuelve la lista de outfitIds con body presente. Usado por AIService
--- para pre-calentar el pool de rigs (uno por outfit disponible).
function BotAppearance.getAvailableOutfitIds(): { string }
	-- Devolvemos una copia para que el caller no muerda la lista interna.
	local copy = table.create(#_outfitPool)
	for _, id in _outfitPool do
		table.insert(copy, id)
	end
	return copy
end

function BotAppearance.apply(character: Model, appearance: BotAppearance?)
	if not appearance then
		return
	end

	local hatId = appearance.hatId
	if hatId then
		local hatTemplate = CosmeticsTemplates.findHatTemplate(hatId)
		if hatTemplate then
			local hatClone = hatTemplate:Clone()
			hatClone:SetAttribute(BOT_APPEARANCE_HAT_ATTRIBUTE, true)
			hatClone.Parent = character
		end
	end

	local faceId = appearance.faceId
	if faceId then
		local headNode = character:FindFirstChild("Head")
		if headNode and headNode:IsA("BasePart") then
			CosmeticsTemplates.applyFaceToHead(headNode :: BasePart, faceId)
		end
	end
end

function BotAppearance.applyWrapToTool(tool: Tool, wrapId: string?)
	if not wrapId then
		return
	end
	CosmeticsTemplates.applyWeaponWrapToTool(tool, wrapId)
end

return BotAppearance
