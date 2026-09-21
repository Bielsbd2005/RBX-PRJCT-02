--!strict
-- Revólver: la especial de precisión entre la pistola de inicio y la Laser. Dos al
-- cuerpo o una a la cabeza (50 × 2), seis balas, retroceso fuerte, recarga lenta y daño
-- que cae pasados 60 studs: premia apuntar y castiga rociar. Este fichero es la fuente
-- de verdad de sus stats. Claves y defaults: Schema.luau.
-- PENDIENTE: el Tool ServerStorage.WeaponTools.Special.Revolver; su entrada de
-- ItemsConfig sigue comentada hasta que exista.
local Types = require(script.Parent.Parent.Parent.Types)

return {
	WeaponType = "BulletWeapon",
	Config = {
		AmmoCapacity = 6,
		FireMode = "Semiautomatic",
		FullDamageDistance = 60,
		GravityFactor = 0.5,
		HitDamage = 50,
		MaxSpread = 0.15,
		MuzzleFlashSize0 = 1,
		MuzzleFlashSize1 = 1.3,
		RecoilDecay = 0.8,
		RecoilMax = 1,
		RecoilMin = 0.7,
		ReloadTime = 2.4,
		ShotCooldown = 0.45,
		ZeroDamageDistance = 200,
		ZoomFactor = 1.25,
	},
} :: Types.WeaponDefinition
