--!strict
-- Tipos de KillEffectVisuals, aparte para que los handlers (visuals/killEffects/*)
-- los usen sin un require circular con él.

export type Cleanup = Instance | RBXScriptConnection | thread | () -> ()

export type Ctx = {
	char: Model,
	-- GetServerTimeNow() al morir.
	startedAt: number,
	-- s desde la muerte.
	age: () -> number,
	-- Si llega a tiempo de lo puntual (sonido, ráfagas): no lo repite quien entra tarde
	-- o recibe el cadáver por streaming.
	isFresh: (tolerance: number?) -> boolean,
	-- Se destruye / desconecta / cancela / llama al terminar el contexto.
	add: (item: Cleanup) -> (),
	-- fn(fadeTime) cuando el cadáver empieza a fundirse (bots, RagdollCleanup); al
	-- momento si ya se estaba fundiendo.
	onFadeOut: (fn: (fadeTime: number) -> ()) -> (),
	finish: () -> (),
}

export type Handler = {
	play: ((char: Model, ctx: Ctx) -> ())?,
	start: (() -> ())?,
	stop: (() -> ())?,
}

return {}
