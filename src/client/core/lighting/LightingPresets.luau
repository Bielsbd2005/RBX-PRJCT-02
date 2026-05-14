--!strict
--[[
	LightingPresets
	Definiciones declarativas del look de la iluminación. Cada preset es
	PARCIAL: solo declara las props que quiere cambiar — las demás retienen
	el valor del preset anterior.

	Patrón:
	  Preset = {
	    lighting        = { ...props de game.Lighting... },
	    atmosphere      = { ...props de Atmosphere child... },
	    colorCorrection = { ...props de ColorCorrectionEffect... },
	    bloom           = { ...props de BloomEffect... },
	  }

	Tunear los valores en este archivo — el controller los aplica con tween.
]]

export type LightingProps = {
	Ambient: Color3?,
	OutdoorAmbient: Color3?,
	Brightness: number?,
	ClockTime: number?,
	FogColor: Color3?,
	FogStart: number?,
	FogEnd: number?,
	ShadowSoftness: number?,
	EnvironmentDiffuseScale: number?,
	EnvironmentSpecularScale: number?,
}

export type AtmosphereProps = {
	Density: number?,
	Offset: number?,
	Color: Color3?,
	Decay: Color3?,
	Glare: number?,
	Haze: number?,
}

export type ColorCorrectionProps = {
	Brightness: number?,
	Contrast: number?,
	Saturation: number?,
	TintColor: Color3?,
}

export type BloomProps = {
	Intensity: number?,
	Size: number?,
	Threshold: number?,
}

export type SunRaysProps = {
	Intensity: number?,
	Spread: number?,
}

export type SkyProps = {
	SkyboxBk: string?,
	SkyboxDn: string?,
	SkyboxFt: string?,
	SkyboxLf: string?,
	SkyboxRt: string?,
	SkyboxUp: string?,
	SunAngularSize: number?,
	MoonAngularSize: number?,
	SunTextureId: string?,
	MoonTextureId: string?,
	StarCount: number?,
	CelestialBodiesShown: boolean?,
}

export type Preset = {
	lighting: LightingProps?,
	atmosphere: AtmosphereProps?,
	colorCorrection: ColorCorrectionProps?,
	bloom: BloomProps?,
	sunRays: SunRaysProps?,
	sky: SkyProps?,
}

local Presets: { [string]: Preset } = {
	-- Lobby: cálido y luminoso, con un toque de bloom para que el preview
	-- del personaje se vea con presencia.
	Lobby = {
		lighting = {
			Ambient = Color3.fromRGB(70, 70, 80),
			OutdoorAmbient = Color3.fromRGB(120, 120, 140),
			Brightness = 2,
			ClockTime = 14,
			FogStart = 0,
			FogEnd = 1000,
			FogColor = Color3.fromRGB(192, 192, 200),
		},
		atmosphere = {
			Density = 0.3,
			Offset = 0.25,
			Color = Color3.fromRGB(199, 199, 199),
			Decay = Color3.fromRGB(106, 112, 125),
			Glare = 0.4,
			Haze = 1.2,
		},
		colorCorrection = {
			Brightness = 0,
			Contrast = 0.05,
			Saturation = 0,
			TintColor = Color3.fromRGB(255, 255, 255),
		},
		bloom = {
			Intensity = 0.4,
			Size = 24,
			Threshold = 0.95,
		},
	},

	-- Match: más neutro y un punto más contrastado para gameplay claro.
	Match = {
		lighting = {
			Ambient = Color3.fromRGB(110, 121, 134),
			OutdoorAmbient = Color3.fromRGB(250, 192, 165),
			Brightness = 2.25,
			ClockTime = 14.5,
			FogStart = 0,
			FogEnd = 0,
			FogColor = Color3.fromRGB(210, 210, 220),
		},
		atmosphere = {
			Density = 0.262,
			Offset = 0,
			Color = Color3.fromRGB(123, 216, 251),
			Decay = Color3.fromRGB(212, 220, 255),
			Glare = 0.5,
			Haze = 1.91,
		},
		colorCorrection = {
			Brightness = 0.02,
			Contrast = 0.4,
			Saturation = 0.34,
			TintColor = Color3.fromRGB(255, 255, 255),
		},
		bloom = {
			Intensity = 1,
			Size = 24,
			Threshold = 2,
		},
		sunRays = {
        	Intensity = 0.01,
        	Spread = 0.1,
      	},
	},

	-- Match_Canyon: cañón desértico — golden hour, ambiente cálido,
	-- polvo en suspensión. Punto de partida para tunear; sustituye a `Match`.
	Match_Canyon = {
		lighting = {
			Ambient = Color3.fromRGB(120, 100, 90),
			OutdoorAmbient = Color3.fromRGB(255, 190, 140),
			Brightness = 2.4,
			ClockTime = 16.5,
			FogStart = 0,
			FogEnd = 0,
			FogColor = Color3.fromRGB(230, 190, 150),
		},
		atmosphere = {
			Density = 0.32,
			Offset = 0.15,
			Color = Color3.fromRGB(235, 195, 145),
			Decay = Color3.fromRGB(180, 130, 90),
			Glare = 0.7,
			Haze = 2.4,
		},
		colorCorrection = {
			Brightness = 0.03,
			Contrast = 0.35,
			Saturation = 0.4,
			TintColor = Color3.fromRGB(255, 240, 220),
		},
		bloom = {
			Intensity = 1.1,
			Size = 24,
			Threshold = 1.9,
		},
		sunRays = {
			Intensity = 0.18,
			Spread = 0.6,
		},
	},

	-- Match_Factory: industrial — más frío, contraste alto, atmósfera plomiza.
	Match_Factory = {
		lighting = {
			Ambient = Color3.fromRGB(95, 105, 120),
			OutdoorAmbient = Color3.fromRGB(180, 190, 210),
			Brightness = 2,
			ClockTime = 13,
			FogStart = 0,
			FogEnd = 0,
			FogColor = Color3.fromRGB(190, 195, 205),
		},
		atmosphere = {
			Density = 0.34,
			Offset = 0.05,
			Color = Color3.fromRGB(180, 195, 210),
			Decay = Color3.fromRGB(140, 150, 165),
			Glare = 0.35,
			Haze = 2.1,
		},
		colorCorrection = {
			Brightness = 0,
			Contrast = 0.45,
			Saturation = 0.15,
			TintColor = Color3.fromRGB(235, 240, 250),
		},
		bloom = {
			Intensity = 0.85,
			Size = 24,
			Threshold = 2,
		},
		sunRays = {
			Intensity = 0.05,
			Spread = 0.3,
		},
	},

	-- Match_Rooftops: urbano de mediodía — neutro, brillante, bloom marcado
	-- para los reflejos de cristal/metal de los edificios.
	Match_Rooftops = {
		lighting = {
			Ambient = Color3.fromRGB(110, 120, 135),
			OutdoorAmbient = Color3.fromRGB(245, 230, 215),
			Brightness = 2.5,
			ClockTime = 12.5,
			FogStart = 0,
			FogEnd = 0,
			FogColor = Color3.fromRGB(220, 225, 235),
		},
		atmosphere = {
			Density = 0.25,
			Offset = 0,
			Color = Color3.fromRGB(150, 200, 240),
			Decay = Color3.fromRGB(220, 225, 240),
			Glare = 0.55,
			Haze = 1.6,
		},
		colorCorrection = {
			Brightness = 0.02,
			Contrast = 0.4,
			Saturation = 0.3,
			TintColor = Color3.fromRGB(255, 255, 255),
		},
		bloom = {
			Intensity = 1.3,
			Size = 26,
			Threshold = 1.8,
		},
		sunRays = {
			Intensity = 0.12,
			Spread = 0.5,
		},
	},

	-- Locker: showcase. Ambiente más oscuro/contrastado para que los wraps
	-- y armas con bloom destaquen, ligero tinte cool para look "premium".
	Locker = {
		lighting = {
			Ambient = Color3.fromRGB(50, 50, 60),
			OutdoorAmbient = Color3.fromRGB(80, 80, 100),
			Brightness = 1.6,
			ClockTime = 12,
			FogStart = 0,
			FogEnd = 800,
			FogColor = Color3.fromRGB(150, 150, 165),
		},
		atmosphere = {
			Density = 0.4,
			Offset = 0.2,
			Color = Color3.fromRGB(190, 195, 210),
			Decay = Color3.fromRGB(95, 100, 115),
			Glare = 0.3,
			Haze = 1.6,
		},
		colorCorrection = {
			Brightness = -0.05,
			Contrast = 0.18,
			Saturation = 0.05,
			TintColor = Color3.fromRGB(245, 245, 255),
		},
		bloom = {
			Intensity = 0.7,
			Size = 28,
			Threshold = 0.85,
		},
	},
}

return Presets
