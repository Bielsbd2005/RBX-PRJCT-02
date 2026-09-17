--!strict
--[[
	Config del pipeline de telemetría HTTP (única salida de analítica: el
	AnalyticsService de Roblox no tiene API de lectura). TelemetryService no hardcodea números.

	Vive en server/core y no en shared para que el cliente no vea ni el NOMBRE
	del secreto ni los parámetros de reintento.

	Requisitos: "Allow HTTP Requests" en Game Settings; la clave en el Secrets
	Store bajo el nombre `SecretKey` (HttpService:GetSecret devuelve un objeto
	opaco). Studio alcanza `localhost`; un servidor publicado no.
]]

local RunService = game:GetService("RunService")

export type TelemetryConfigType = {
	Enabled: boolean,
	IngestUrl: string,
	SecretKey: string,
	GameVersion: string,

	BatchMaxEvents: number,
	FlushIntervalSeconds: number,
	ServerFlushSeconds: number,
	QueueMaxEvents: number,
	RequestTimeoutSeconds: number,

	MaxRetries: number,
	BackoffBaseSeconds: number,
	BackoffMaxSeconds: number,
	CircuitBreakerThreshold: number,
	CircuitBreakerCooldownSeconds: number,

	ShutdownGraceSeconds: number,
	ShutdownDeadlineSeconds: number,

	Debug: boolean,
}

local TelemetryConfig: TelemetryConfigType = {
	-- En false, TelemetryService es un no-op completo (no encola, ni loops, ni requests).
	Enabled = true,

	-- Base del servicio de ingesta. El endpoint concreto es `/api/v1/telemetry/batch`.
	IngestUrl = "https://telemetria.bielsbd.com",

	-- Nombre de la entrada en el Secrets Store, NO el valor del secreto.
	SecretKey = "gunners_telemetry_key",

	-- Se envía en cada evento para poder segmentar métricas por release.
	GameVersion = "0.1.0",

	-- Un batch sale cuando se llena (BatchMaxEvents) o cuando vence el timer
	-- (FlushIntervalSeconds), lo que ocurra antes.
	BatchMaxEvents = 20,
	FlushIntervalSeconds = 5,

	-- Segundos entre SERVER_FLUSH agregados.
	ServerFlushSeconds = 300,

	-- Cola acotada: al desbordar se descarta lo MÁS VIEJO. La telemetría nunca
	-- puede hacer crecer la memoria del servidor sin límite.
	QueueMaxEvents = 200,

	RequestTimeoutSeconds = 10,

	-- El backoff lleva jitter obligatorio: sin él todos los servidores reintentarían
	-- en sincronía si la ingesta cae.
	MaxRetries = 4,
	BackoffBaseSeconds = 2,
	BackoffMaxSeconds = 30,

	-- Tras N fallos consecutivos no se intenta durante el cooldown (presupuesto HTTP).
	CircuitBreakerThreshold = 8,
	CircuitBreakerCooldownSeconds = 60,

	-- Roblox corre los callbacks de BindToClose en paralelo dentro de la ventana de ~30s:
	--   Grace   → esperar a que ProfileUnloading encole los SESSION_END.
	--   Deadline→ tope duro para drenar la cola.
	ShutdownGraceSeconds = 2,
	ShutdownDeadlineSeconds = 10,

	-- Logs verbosos de batches. Dejar en false en producción.
	Debug = false,
}

-- Solo en Studio. Probar aquí en vez de tocar los valores de producción: subir
-- un ServerFlushSeconds bajo multiplicaría las peticiones de todos los servidores.
local STUDIO_OVERRIDES: { [string]: any } = {
	Debug = true,
	ServerFlushSeconds = 20,
	FlushIntervalSeconds = 2,
}

if RunService:IsStudio() then
	for key, value in STUDIO_OVERRIDES do
		(TelemetryConfig :: any)[key] = value
	end
end

return table.freeze(TelemetryConfig)
