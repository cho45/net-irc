module Net::IRC::Message::ModeParser::RFC1459
	Channel  = Net::IRC::Message::ModeParser.new(%w|o l b v k|, {
		:o => "give/take channel operator privileges",
		:p => "private channel flag",
		:s => "select channel flag",
		:i => "invite-only channel flag",
		:t => "topic settable by channel operator only flag",
		:n => "no messages to channel from clients on the outside",
		:m => "moderated channel",
		:l => "set the user limit to channel",
		:b => "set a ban mask to keep users out",
		:v => "give/take the ability to speak on a moderated channel",
		:k => "set a channel key (password)",
	})
	User    = Net::IRC::Message::ModeParser.new(%w||, {
		:i => "marks a users as invisible",
		:s => "marks a user for receipt of server notices",
		:w => "user receives wallops",
		:o => "operator flag",
	})
end
