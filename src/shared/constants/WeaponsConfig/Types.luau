--!strict
--[[
	WeaponsConfig/Types.luau
	Tipos de la configuración de combate de las armas.

	Cada TIPO de arma (WeaponType) tiene su propio conjunto de parámetros:
	  • BaseWeaponConfig   — lo que entiende BaseWeapon (cargador, recarga,
	                         animaciones, mira).
	  • BulletWeaponConfig — BaseWeaponConfig + balística, daño, recoil, VFX.
	  • BowWeaponConfig    — BowWeapon hereda de BulletWeapon y no añade claves
	                         propias; se mantiene como alias para que una
	                         definición pueda declararse con su tipo real.

	Todas las claves son opcionales: una definición sólo escribe lo que
	difiere del default (ver Schema.luau).
]]

export type WeaponCategory = "Main" | "Special"
export type WeaponType = "BulletWeapon" | "BowWeapon"
export type FireMode = "Automatic" | "Semiautomatic" | "Burst"

export type BaseWeaponConfig = {
	AmmoCapacity: number?,
	ReloadTime: number?,
	ReloadAnimation: string?,
	RunAnimation: string?,
	HasScope: boolean?,
	ZoomFactor: number?,
	CrosshairScale: number?,
}

export type BulletWeaponConfig = BaseWeaponConfig & {
	-- Cadencia / modo de disparo
	FireMode: FireMode?,
	ShotCooldown: number?,
	BurstShotCooldown: number?,
	NumBurstShots: number?,
	StartupTime: number?,

	-- Proyectil
	ShotEffect: string?,
	NumProjectiles: number?,
	BulletSpeed: number?,
	GravityFactor: number?,
	MaxDistance: number?,
	MinSpread: number?,
	MaxSpread: number?,
	ShouldMovePart: boolean?,
	TracerFadeTime: number?,
	BeamWidth0: number?,
	BeamWidth1: number?,

	-- Daño
	HitDamage: number?,
	FullDamageDistance: number?,
	ZeroDamageDistance: number?,
	ExplodeOnImpact: boolean?,
	BlastDamage: number?,
	BlastRadius: number?,
	BlastPressure: number?,

	-- Carga (armas de carga tipo railgun/arco)
	ChargeRate: number?,
	ChargePassively: boolean?,
	DischargeRate: number?,
	FireDischarge: number?,
	ChargingParticlesRatePerCharge: number?,
	NumChargeCompleteParticles: number?,
	NumDischargeCompleteParticles: number?,

	-- Recoil / feel
	RecoilMin: number?,
	RecoilMax: number?,
	RecoilDecay: number?,
	RecoilDelayTime: number?,
	ShakeIntensity: number?,
	ShakeFOVKick: number?,
	ViewKickDistance: number?,
	ViewKickPerShot: number?,
	ViewKickReturn: number?,
	FiredPlaybackSpeedRange: number?,

	-- VFX
	MuzzleFlashTime: number?,
	MuzzleFlashSize0: number?,
	MuzzleFlashSize1: number?,
	MuzzleFlashRotation0: number?,
	MuzzleFlashRotation1: number?,
	NumMuzzleParticles: number?,
	NumHitParticles: number?,
	HitMarkEffect: string?,
	HitMarkHeatEffect: boolean?,
	HitParticlesUsePartColor: boolean?,
	AlignHitMarkToNormal: boolean?,
	ModularHitVFX: boolean?,

	-- Animaciones
	AimTrack: string?,
	AimZoomTrack: string?,
}

export type BowWeaponConfig = BulletWeaponConfig

export type WeaponConfig = BulletWeaponConfig

--[[
	Lo que devuelve cada fichero de Definitions/<Category>/<Id>.luau.
	Category e Id NO se escriben en el fichero: los aporta el registro a partir
	de la carpeta y el nombre del módulo, así no pueden desincronizarse.
]]
export type WeaponDefinition = {
	WeaponType: WeaponType,
	Config: WeaponConfig,
}

--- Definición ya registrada (con identidad resuelta y congelada).
export type RegisteredWeapon = {
	Category: WeaponCategory,
	Id: string,
	WeaponType: WeaponType,
	Config: WeaponConfig,
}

-- Sólo tipos: el valor devuelto es irrelevante.
return {}
