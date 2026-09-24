--!strict
--[[
	Todas las claves son opcionales: una definición sólo escribe lo que difiere del
	default (Schema.luau). BowWeaponConfig es alias: BowWeapon no añade claves.
]]

export type WeaponCategory = "Main" | "Special"
export type WeaponType = "BulletWeapon" | "BowWeapon"
export type FireMode = "Automatic" | "Semiautomatic" | "Burst"

export type BaseWeaponConfig = {
	AmmoCapacity: number?,
	ReloadTime: number?,
	ReloadAnimation: string?,
	ReloadHingeAngle: number?,
	ReloadHingeOpenTime: number?,
	ReloadHingeCloseTime: number?,
	RunAnimation: string?,
	HasScope: boolean?,
	ZoomFactor: number?,
	CrosshairScale: number?,
	CrosshairSpread: number?,
	CrosshairAimSpread: number?,
	CrosshairHideTop: boolean?,
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
	AmmoPart: string?,
	NumProjectiles: number?,
	IsShotgun: boolean?,
	OptimalRange: number?,
	BulletSpeed: number?,
	GravityFactor: number?,
	MaxDistance: number?,
	MinSpread: number?,
	MaxSpread: number?,
	HipFireSpread: number?,
	ShouldMovePart: boolean?,
	TracerFadeTime: number?,
	BeamWidth0: number?,
	BeamWidth1: number?,

	-- Daño
	HitDamage: number?,
	HeadshotMultiplier: number?,
	FullDamageDistance: number?,
	ZeroDamageDistance: number?,
	ExplodeOnImpact: boolean?,
	BlastDamage: number?,
	BlastRadius: number?,
	BlastPressure: number?,
	FireZoneOnImpact: boolean?,
	FireZoneRadius: number?,
	FireZoneDuration: number?,
	FireZoneDamage: number?,

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
	BoltTravel: number?,
	BoltCycleTime: number?,
	BoltLockOnEmpty: boolean?,
	BoltDelay: number?,
	PumpTravel: number?,
	PumpCycleTime: number?,
	PumpDelay: number?,
	PumpLockOnEmpty: boolean?,
	SniperBoltTravel: number?,
	SniperBoltCycleTime: number?,
	SniperBoltDelay: number?,
	SniperBoltLockOnEmpty: boolean?,
	FiredPlaybackSpeedRange: number?,

	-- VFX
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

-- Lo que devuelve Definitions/<Category>/<Id>.luau. Category e Id los aporta el
-- registro desde la carpeta y el nombre del módulo.
export type WeaponDefinition = {
	WeaponType: WeaponType,
	Config: WeaponConfig,
}

--- Con identidad resuelta y congelada.
export type RegisteredWeapon = {
	Category: WeaponCategory,
	Id: string,
	WeaponType: WeaponType,
	Config: WeaponConfig,
}

return {}
