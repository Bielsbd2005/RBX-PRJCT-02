--!strict
--[[
	El default de cada clave es EL default: BaseWeapon:getConfigValue(key) cae
	aquí cuando el arma no declara la clave, y los call-sites no repiten el literal.
	WeaponsConfig/init valida cada definición contra este esquema al cargarla.
]]

export type ValueType = "number" | "integer" | "string" | "boolean"

export type KeySpec = {
	type: ValueType,
	default: any,
	description: string,
}

export type KeySchema = { [string]: KeySpec }

local Schema = {}

local function key(valueType: ValueType, default: any, description: string): KeySpec
	return { type = valueType, default = default, description = description }
end

-- Claves que entiende cualquier arma (las lee BaseWeapon / WeaponsSystem).
Schema.Base = {
	AmmoCapacity = key("integer", 30, "Balas por cargador."),
	ReloadTime = key("number", 2, "Segundos de recarga."),
	ReloadAnimation = key("string", "RifleReload", "Track de animación de recarga."),
	RunAnimation = key("string", "Run", "Track de animación al esprintar."),
	HasScope = key("boolean", false, "Muestra la mira telescópica al apuntar."),
	ZoomFactor = key("number", 1.1, "Factor de zoom de cámara al apuntar."),
	CrosshairScale = key("number", 1, "Escala del crosshair."),
} :: KeySchema

Schema.Bullet = {
	FireMode = key("string", "Semiautomatic", "Automatic | Semiautomatic | Burst."),
	ShotCooldown = key("number", 0.1, "Segundos entre disparos. 60/ShotCooldown = balas por minuto."),
	BurstShotCooldown = key("number", nil, "Segundos entre balas de una ráfaga (sólo FireMode=Burst)."),
	NumBurstShots = key("integer", 3, "Balas por ráfaga (sólo FireMode=Burst)."),
	StartupTime = key("number", 0.2, "Retardo antes del primer disparo al mantener el gatillo."),

	ShotEffect = key("string", "Bullet", "Template en Assets.Effects.Shots."),
	NumProjectiles = key("integer", 1, "Proyectiles por disparo (escopetas > 1)."),
	BulletSpeed = key("number", 1000, "Velocidad del proyectil (studs/s)."),
	GravityFactor = key("number", 0, "Multiplicador de gravedad sobre la trayectoria (0 = recta)."),
	MaxDistance = key("number", 2000, "Alcance máximo del proyectil."),
	MinSpread = key("number", 0, "Dispersión mínima (grados)."),
	MaxSpread = key("number", 0, "Dispersión máxima (grados)."),
	ShouldMovePart = key("boolean", false, "Mueve físicamente la parte del proyectil (cohetes)."),
	TracerFadeTime = key("number", 0.3, "Segundos de desvanecido del trazador."),
	BeamWidth0 = key("number", 1.5, "Ancho inicial del beam del trazador."),
	BeamWidth1 = key("number", 1.8, "Ancho final del beam del trazador."),

	HitDamage = key("number", 10, "Daño por impacto directo."),
	FullDamageDistance = key("number", 1000, "Hasta esta distancia el daño es completo."),
	ZeroDamageDistance = key("number", 10000, "A esta distancia el daño llega a cero (falloff lineal)."),
	ExplodeOnImpact = key("boolean", false, "Explota al impactar (usa Blast*)."),
	BlastDamage = key("number", 100, "Daño en el centro de la explosión."),
	BlastRadius = key("number", 8, "Radio de la explosión (studs)."),
	FireZoneOnImpact = key("boolean", false, "Al impactar deja una zona de fuego en el suelo (flare gun)."),
	FireZoneRadius = key("number", 6, "Radio de la zona de fuego (studs)."),
	FireZoneDuration = key("number", 5, "Segundos que arde la zona de fuego."),
	FireZoneDamage = key("number", 10, "Daño por segundo a enemigos dentro de la zona de fuego."),
	BlastPressure = key("number", 10000, "Presión de la explosión (física)."),

	-- Definir ChargeRate activa el modo carga aunque sea 0.
	ChargeRate = key("number", 0, "Carga por segundo mientras se mantiene el gatillo."),
	ChargePassively = key("boolean", false, "Carga sola sin mantener el gatillo."),
	DischargeRate = key("number", 0, "Descarga por segundo al soltar."),
	FireDischarge = key("number", 1, "Carga consumida por disparo."),
	ChargingParticlesRatePerCharge = key("number", 20, "Rate de partículas por unidad de carga."),
	NumChargeCompleteParticles = key("integer", 25, "Partículas al completar la carga."),
	NumDischargeCompleteParticles = key("integer", 25, "Partículas al completar la descarga."),

	RecoilMin = key("number", 0.05, "Recoil mínimo por disparo."),
	RecoilMax = key("number", 0.5, "Recoil máximo acumulado."),
	RecoilDecay = key("number", 0.825, "Factor de decaimiento del recoil por frame."),
	RecoilDelayTime = key("number", 0.07, "Segundos antes de empezar a recuperar el recoil."),
	ShakeIntensity = key("number", 0.16, "Intensidad del shake de cámara al disparar."),
	ShakeFOVKick = key("number", 1.2, "Kick de FOV al disparar."),
	ViewKickDistance = key("number", nil, "Retroceso visual del arma (studs). Default: 0.85 si explota, 0.07 si no."),
	ViewKickPerShot = key("number", 0.8, "Acumulación de view-kick por disparo (0..1)."),
	ViewKickReturn = key("number", 13, "Velocidad de retorno del view-kick."),
	BoltTravel = key("number", 0.3, "Recorrido del cerrojo/corredera por disparo (studs). Ver docs/WEAPON-BOLT.md."),
	BoltCycleTime = key("number", nil, "Segundos de ida y vuelta del cerrojo. Default: 90% del cooldown, entre 0.04 y 0.12."),
	BoltDelay = key("number", 0, "Segundos tras el disparo antes de que el cerrojo se mueva."),
	BoltLockOnEmpty = key("boolean", true, "El cerrojo se queda atrás con el cargador vacío hasta recargar."),
	PumpTravel = key("number", 0.4, "Recorrido del Pump de la escopeta por disparo (studs)."),
	PumpCycleTime = key("number", nil, "Segundos de ida y vuelta del Pump. Default: 80% del cooldown tras el delay, entre 0.1 y 0.45."),
	PumpDelay = key("number", 0.1, "Segundos tras el disparo antes de bombear."),
	PumpLockOnEmpty = key("boolean", false, "El Pump se queda atrás con el cargador vacío hasta recargar."),
	SniperBoltTravel = key("number", 0.5, "Recorrido hacia delante del SniperBolt por disparo (studs)."),
	SniperBoltCycleTime = key("number", nil, "Segundos de ida y vuelta del SniperBolt. Default: 70% del cooldown tras el delay, entre 0.2 y 0.8."),
	SniperBoltDelay = key("number", 0.15, "Segundos tras el disparo antes de accionar el SniperBolt."),
	SniperBoltLockOnEmpty = key("boolean", false, "El SniperBolt se queda adelantado con el cargador vacío hasta recargar."),
	FiredPlaybackSpeedRange = key("number", 0.1, "Variación aleatoria del pitch del sonido de disparo."),

	MuzzleFlashTime = key("number", 0.03, "Duración del fogonazo."),
	MuzzleFlashSize0 = key("number", 1, "Tamaño mínimo del fogonazo."),
	MuzzleFlashSize1 = key("number", 1, "Tamaño máximo del fogonazo."),
	MuzzleFlashRotation0 = key("number", -math.pi, "Rotación mínima del fogonazo (rad)."),
	MuzzleFlashRotation1 = key("number", math.pi, "Rotación máxima del fogonazo (rad)."),
	NumMuzzleParticles = key("integer", 50, "Partículas en la boca del cañón por disparo."),
	NumHitParticles = key("integer", 3, "Partículas en el punto de impacto."),
	HitMarkEffect = key("string", "BulletHole", "Template en Assets.Effects.HitMarks."),
	HitMarkHeatEffect = key("boolean", true, "Brillo de calor en la marca de impacto."),
	HitParticlesUsePartColor = key("boolean", true, "Partículas de impacto con el color de la parte golpeada."),
	AlignHitMarkToNormal = key("boolean", true, "Orienta la marca de impacto a la normal de la superficie."),
	ModularHitVFX = key("boolean", true, "Usa el sistema modular de HitVFX (ver docs/HIT-VFX.md)."),

	AimTrack = key("string", "RifleAim", "Track de animación al apuntar."),
	AimZoomTrack = key("string", "RifleAimDownSights", "Track de animación al apuntar con zoom."),
} :: KeySchema

local function merge(...: KeySchema): KeySchema
	local out: KeySchema = {}
	for _, schema in { ... } do
		for name, spec in schema do
			out[name] = spec
		end
	end
	return out
end

Schema.ByWeaponType = {
	BulletWeapon = merge(Schema.Base, Schema.Bullet),
	BowWeapon = merge(Schema.Base, Schema.Bullet),
} :: { [string]: KeySchema }

function Schema.IsWeaponType(weaponType: any): boolean
	return type(weaponType) == "string" and Schema.ByWeaponType[weaponType] ~= nil
end

function Schema.GetKeySpec(weaponType: string, keyName: string): KeySpec?
	local schema = Schema.ByWeaponType[weaponType]
	return if schema then schema[keyName] else nil
end

function Schema.GetDefault(weaponType: string, keyName: string): any
	local spec = Schema.GetKeySpec(weaponType, keyName)
	return if spec then spec.default else nil
end

local function matchesType(valueType: ValueType, value: any): boolean
	if valueType == "integer" then
		return type(value) == "number" and value == value and math.floor(value) == value
	elseif valueType == "number" then
		return type(value) == "number" and value == value
	end
	return type(value) == valueType
end

-- Claves desconocidas son error: una clave mal escrita nunca se leería y el
-- arma jugaría silenciosamente con defaults.
function Schema.Validate(weaponType: string, config: { [string]: any }): { string }
	local problems: { string } = {}
	local schema = Schema.ByWeaponType[weaponType]
	if not schema then
		table.insert(problems, string.format("WeaponType desconocido: %s", tostring(weaponType)))
		return problems
	end

	for keyName, value in config do
		local spec = schema[keyName]
		if not spec then
			table.insert(problems, string.format("clave desconocida para %s: %s", weaponType, tostring(keyName)))
		elseif not matchesType(spec.type, value) then
			table.insert(problems, string.format("%s debe ser %s, es %s (%s)", tostring(keyName), spec.type, typeof(value), tostring(value)))
		end
	end

	return problems
end

return Schema
