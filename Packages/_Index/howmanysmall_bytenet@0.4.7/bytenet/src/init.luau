--!optimize 2
--!strict

local RunService = game:GetService("RunService")

local array = require(script.dataTypes.array)
local bool = require(script.dataTypes.bool)
local buff = require(script.dataTypes.buff)
local cframe = require(script.dataTypes.cframe)
local clientProcess = require(script.process.client)
local definePacket = require(script.packets.definePacket)
local float32 = require(script.dataTypes.float32)
local float64 = require(script.dataTypes.float64)
local inst = require(script.dataTypes.inst)
local int16 = require(script.dataTypes.int16)
local int32 = require(script.dataTypes.int32)
local int8 = require(script.dataTypes.int8)
local map = require(script.dataTypes.map)
local namespace = require(script.namespaces.namespace)
local nothing = require(script.dataTypes.nothing)
local optional = require(script.dataTypes.optional)
local serverProcess = require(script.process.server)
local string = require(script.dataTypes.string)
local struct = require(script.dataTypes.struct)
local types = require(script.types)
local uint16 = require(script.dataTypes.uint16)
local uint32 = require(script.dataTypes.uint32)
local uint8 = require(script.dataTypes.uint8)
local unknown = require(script.dataTypes.unknown)
local values = require(script.replicated.values)
local vec2 = require(script.dataTypes.vec2)
local vec3 = require(script.dataTypes.vec3)

values.start()

if RunService:IsServer() then
	serverProcess.start()
else
	clientProcess.start()
end

local byteBoolean = bool()
local byteBuffer = buff()
local byteInstance = inst()
local byteNothing = nothing()
local byteVector2 = vec2()
local byteVector3 = vec3()

return (
	table.freeze({
		DefinePacket = definePacket;
		DefineNamespace = namespace;

		Array = array;
		Bool = byteBoolean;
		Buff = byteBuffer;
		CFrame = cframe();
		Float32 = float32();
		Float64 = float64();
		Inst = byteInstance;
		Int16 = int16();
		Int32 = int32();
		Int8 = int8();
		Map = map;
		Nothing = byteNothing;
		Optional = optional;
		String = string();
		Struct = struct;
		Uint16 = uint16();
		Uint32 = uint32();
		Uint8 = uint8();
		Unknown = unknown();
		Vec2 = byteVector2;
		Vec3 = byteVector3;

		Boolean = byteBoolean;
		Buffer = byteBuffer;
		Instance = byteInstance;
		Nil = byteNothing;
		Vector2 = byteVector2;
		Vector3 = byteVector3;
	}) :: any
) :: types.ByteNet
