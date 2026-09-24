--!strict
--[[
	Tag VIP delante del nombre en el chat (TextChatService). OnIncomingMessage admite
	un solo callback por cliente: si otro sistema necesita decorar mensajes, que
	pase por aquí.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local VipTag = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("utils"):WaitForChild("VipTag"))

local VipChatTag = {}

function VipChatTag.start(): () -> ()
	TextChatService.OnIncomingMessage = function(message: TextChatMessage): TextChatMessageProperties
		local properties = Instance.new("TextChatMessageProperties")
		local source = message.TextSource
		if source and VipTag.isVIP(Players:GetPlayerByUserId(source.UserId)) then
			properties.PrefixText = `{VipTag.RICH_TEXT} {message.PrefixText}`
		end
		return properties
	end

	return function()
		TextChatService.OnIncomingMessage = nil
	end
end

return VipChatTag
