--!strict
-- Special/Flare: pistola de bengalas; el impacto deja una zona de fuego (FireZone.luau).
-- Este fichero es la fuente de verdad. Claves y defaults: Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 1,
		BulletSpeed = 220,
		FireZoneDamage = 10,
		FireZoneDuration = 5,
		FireZoneOnImpact = true,
		FireZoneRadius = 6,
		GravityFactor = 0.6,
		HitDamage = 15,
		HitMarkEffect = "Scorch",
		MaxDistance = 400,
		RecoilDecay = 0.85,
		RecoilMin = 0.3,
		ReloadHingeAngle = -60,
		ReloadTime = 1.8,
		ShotCooldown = 1,
		ShotEffect = "Flare",
		TracerFadeTime = 0.4,
	},
} :: Types.WeaponDefinition
