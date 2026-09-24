--!optimize 2
--!strict

export type NamespaceData = {
	packets: {[string]: any},
	structs: {[number]: {[string]: any}},
}

-- Externally used for defining packets
export type PacketProperties<T> = {
	CallbackBehavior: {
		AllowMultiple: boolean,
		SpawnThread: boolean,
		[any]: never,
	}?,
	ReliabilityType: nil | "Reliable" | "Unreliable",
	Value: T,
	[any]: never,
}

-- Used internally for
export type ChannelData = {
	cursor: number,
	size: number,
	references: {unknown},
	buff: buffer,
}

-- Used internally for serializing and deserializing all data types
export type DataTypeInterface<T> = {
	Length: number?,
	Read: (b: buffer, cursor: number) -> (T, number),
	Write: (value: T) -> (),
}

-- Somewhat public facing: used as return result in definePacket
type Packet<T> = {
	SendToAll: (data: T) -> (),
	SendTo: (data: T, target: Player) -> (),
	SendToList: (data: T, targets: {Player}) -> (),
	SendToAllExcept: (data: T, exceptions: Player) -> (),

	Wait: () -> T,
	Send: (data: T, target: Player?) -> (),
	Listen: (callback: (data: T, player: Player?) -> ()) -> () -> (),
	Connect: (callback: (data: T, player: Player?) -> ()) -> () -> (),
}

-- Library type
export type ByteNet = {
	DefinePacket: <T>(properties: PacketProperties<T>) -> Packet<T>,
	DefineNamespace: <T>(name: string, namespace: () -> T) -> T,

	Struct: <T>(format: T) -> T,
	Bool: boolean,
	Array: <T>(value: T) -> {[number]: T},
	Optional: <T>(value: T) -> T?,
	Inst: Instance,
	Nothing: nil,
	Unknown: unknown,
	Uint8: number,
	Uint16: number,
	Uint32: number,
	Int8: number,
	Int16: number,
	Int32: number,
	Float32: number,
	Float64: number,
	String: string,
	Vec3: Vector3,
	Vec2: Vector2,
	Buff: buffer,
	CFrame: CFrame,
	Map: <K, V>(key: K, value: V) -> {[K]: V},

	Boolean: boolean,
	Instance: Instance,
	Buffer: buffer,
	Nil: nil,
	Vector3: Vector3,
	Vector2: Vector2,
}

return false
