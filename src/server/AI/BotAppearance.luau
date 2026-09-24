--!strict
--[[
	Apariencia de un bot (outfit + hat + face + weapon + wrap) y el banner de su
	tarjeta de muerte (no se aplica al rig).

	- `roll()` se llama una vez por identidad (_assignIdentity de AIService) y se
	  cachea en la BotIdentity: el mismo bot mantiene su apariencia todo el match.
	- `apply()` se llama tras clonar el rig en _spawnOneBot; no limpia accesorios
	  porque los rigs vienen frescos del pool.
	- Los pools se filtran al load contra los assets reales (hats en Shared.Locker.Hats,
	  bodies en Shared.Bodies, Tools en ServerStorage.WeaponTools, las MISMAS que clonan
	  los jugadores) para no warnar por templates ausentes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemsConfig = require(Shared.constants.ItemsConfig)
local ItemDefaults = require(Shared.constants.ItemDefaults)
local CosmeticsTemplates = require(Shared.Locker.CosmeticsTemplates)
local BotPersonality = require(script.Parent:WaitForChild("BotPersonality"))

local BotAppearance = {}

export type BotAppearance = {
	outfitId: string?,
	hatId: string?,
	faceId: string?,
	wrapId: string?,
	weaponId: string?,
	-- Id en ItemsConfig.Banners. Siempre definido: Default si no hay ninguno de
	-- las rarezas de su personalidad.
	bannerId: string,
}

local BODIES_ROOT_NAME = "Bodies"

local BOT_APPEARANCE_HAT_ATTRIBUTE = "BotAppearanceHat"

-- Pools construidos al load: solo se requirea desde el servidor, donde Shared ya está replicado.

local function _buildHatPool(): { string }
	local pool: { string } = {}
	local hatsConfig = ItemsConfig.Hats
	if type(hatsConfig) ~= "table" then
		return pool
	end
	-- Vía findHatTemplate: los assets se nombran por el `Name` del catálogo, no por el id.
	for hatId in hatsConfig do
		if CosmeticsTemplates.findHatTemplate(hatId) ~= nil then
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
	local root = Shared:FindFirstChild(BODIES_ROOT_NAME)
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
	-- Solo outfits con Model real en Shared.Bodies, para no warnar si falta el .rbxm.
	for outfitId in outfitsConfig do
		local node = bodiesRoot:FindFirstChild(outfitId)
		if node and node:IsA("Model") then
			table.insert(pool, outfitId)
		end
	end
	return pool
end

local WEAPON_TOOLS_ROOT_NAME = "WeaponTools"
local WEAPON_MAIN_CATEGORY = "Main"

-- Misma resolución que LoadoutService._findLoadoutToolTemplate: ruta canónica
-- ServerStorage.WeaponTools.Main.<weaponId>, con fallback a WeaponTools.<weaponId>.
local function _findWeaponToolTemplate(weaponId: string): Tool?
	local root = ServerStorage:FindFirstChild(WEAPON_TOOLS_ROOT_NAME)
	if not root then
		return nil
	end
	local byCategory = root:FindFirstChild(WEAPON_MAIN_CATEGORY)
	local node = (if byCategory then byCategory:FindFirstChild(weaponId) else nil)
		or root:FindFirstChild(weaponId)
	if node and node:IsA("Tool") then
		return node :: Tool
	end
	return nil
end

local function _buildWeaponPool(): { string }
	local pool: { string } = {}
	local mainConfig = (ItemsConfig :: any).Main
	if type(mainConfig) ~= "table" then
		return pool
	end
	for weaponId in mainConfig do
		if _findWeaponToolTemplate(weaponId) ~= nil then
			table.insert(pool, weaponId)
		end
	end
	return pool
end

local _hatPool = _buildHatPool()
local _facePool = _buildFacePool()
local _wrapPool = _buildWrapPool()
local _outfitPool = _buildOutfitPool()
local _weaponPool = _buildWeaponPool()

local function _pickRandom(pool: { string }): string?
	local n = #pool
	if n == 0 then
		return nil
	end
	return pool[math.random(1, n)]
end

-- Banner según el poder adquisitivo de la personalidad: casi todos llevan el
-- Default y solo `bannerProbability` saca uno de `bannerRarities`.
local function _rollBannerId(personality: BotPersonality.Personality): string
	if math.random() >= personality.bannerProbability then
		return ItemDefaults.ITEM_ID
	end
	local pool: { string } = {}
	for bannerId, definition in ItemsConfig.Banners do
		if bannerId ~= ItemDefaults.ITEM_ID and personality.bannerRarities[definition.Rarity] then
			table.insert(pool, bannerId)
		end
	end
	return _pickRandom(pool) or ItemDefaults.ITEM_ID
end

-- ── API ───────────────────────────────────────────────────────────

function BotAppearance.roll(personality: BotPersonality.Personality): BotAppearance
	-- Si un pool queda vacío tras filtrar, _pickRandom devuelve nil y aguas abajo se
	-- trata como "sin override" (face/wrap del template, sin hat).
	local hatPool    = BotPersonality.filterByRarity(_hatPool,    "Hats",        personality)
	local facePool   = BotPersonality.filterByRarity(_facePool,   "Faces",       personality)
	local wrapPool   = BotPersonality.filterByRarity(_wrapPool,   "WeaponWraps", personality)
	local outfitPool = BotPersonality.filterByRarity(_outfitPool, "Outfits",     personality)
	-- Un Noob (Common) carga el arma de inicio; tiers altos sacan el catálogo entero.
	local weaponPool = BotPersonality.filterByRarity(_weaponPool, "Main", personality)
	-- Sin ninguna Tool de su rareza en ServerStorage el bot se quedaría sin arma (y sin
	-- disparar): mejor cualquier Main que haya.
	if #weaponPool == 0 then
		weaponPool = _weaponPool
	end

	local hatId: string? = nil
	if #hatPool > 0 and math.random() < personality.hatProbability then
		hatId = _pickRandom(hatPool)
	end

	return {
		outfitId = _pickRandom(outfitPool),
		hatId = hatId,
		faceId = _pickRandom(facePool),
		wrapId = _pickRandom(wrapPool),
		weaponId = _pickRandom(weaponPool),
		bannerId = _rollBannerId(personality),
	}
end

--- Tool template real del arma (la misma que clonan los jugadores) por id.
--- nil/ausente → el bot se queda sin arma (BotAI avisa).
function BotAppearance.findWeaponTemplate(weaponId: string?): Tool?
	if not weaponId or weaponId == "" then
		return nil
	end
	return _findWeaponToolTemplate(weaponId)
end

--- Model del body por outfitId; AIService clona el rig del bot desde aquí.
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
			CosmeticsTemplates.attachHatToCharacter(character, hatClone)
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
