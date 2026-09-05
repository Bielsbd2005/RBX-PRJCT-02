--!strict
-- Main/AK. Migrado desde la Configuration del Tool
-- ServerStorage.WeaponTools.Main.AK, que ya no la lleva: este fichero ES
-- la fuente de verdad. Claves y defaults: WeaponsConfig/Schema.luau.
local Types = require(script.Parent.Parent.Parent.Types)

--[[
	AK y Groza eran LA MISMA ARMA con dos nombres.

	Antes de este cambio compartían modo de fuego, gravedad, dispersión (0.6),
	retroceso y tamaño de fogonazo, y se diferenciaban en un punto de daño y
	diez milisegundos de cadencia — 111,1 DPS la AK contra 112,0 la Groza. Es
	decir: la AK costaba 250 y pedía nivel 3 para dar MENOS daño por segundo
	que la Groza, que cuesta 150 y se vende desde el nivel 0. Estrictamente
	peor y más cara: nadie con Groza tenía motivo para comprarla salvo por el
	aspecto, y una tienda con un artículo dominado enseña al jugador que los
	precios no significan nada.

	La corrección da a cada una un papel en vez de igualarlas:
	  • Groza (150, nivel 0) — el rifle de entrada. Cadencia alta, daño bajo,
	    sin tocar: es el primer arma que compra todo el mundo.
	  • AK (250, nivel 3) — el rifle de golpe y puntería. 17 de daño (mata en
	    6 balas en vez de 8) con la cadencia más lenta de las dos, y la
	    dispersión más cerrada del escalón Common.

	La escalera de daño por segundo del arsenal principal queda monótona con el
	precio, que es lo que hace legible una tienda:
	    Default 107,7 · Groza 112,0 · AK 125,9 · Tommy 137,5
]]
return {
	WeaponType = "BulletWeapon",
	Config = {
		FireMode = "Automatic",
		GravityFactor = 0.5,
		HitDamage = 17,
		-- La más cerrada del escalón Common (Groza y Default van a 0.6 y 0.8):
		-- es el eje en el que la AK compra su precio, además del daño.
		MaxSpread = 0.45,
		MuzzleFlashSize0 = 1.1,
		MuzzleFlashSize1 = 1.4,
		RecoilDecay = 0.81,
		RecoilMax = 0.1,
		RecoilMin = 0.1,
		-- Sin tocar: la AK pega más fuerte, no más rápido. Es lo que la separa
		-- de la Groza en vez de dominarla en todos los ejes.
		ShotCooldown = 0.135,
	},
} :: Types.WeaponDefinition
