class Net::IRC::Message
	include Net::IRC

	class InvalidMessage < Net::IRC::IRCException; end

	attr_reader :prefix, :command, :params

	# Parse string and return new Message.
	# If the string is invalid message, this method raises Net::IRC::Message::InvalidMessage.
	def self.parse(str)
		_, prefix, command, *rest = *PATTERN::MESSAGE_PATTERN.match(str)
		raise InvalidMessage, "Invalid message: #{str.dump}" unless _

		case
		when rest[0] && !rest[0].empty?
			middle, trailer, = *rest
		when rest[2] && !rest[2].empty?
			middle, trailer, = *rest[2, 2]
		when rest[1]
			params  = []
			trailer = rest[1]
		when rest[3]
			params  = []
			trailer = rest[3]
		else
			params  = []
		end

		params ||= middle.split(/ /)[1..-1]
		params << trailer if trailer

		new(prefix, command, params)
	end

	def initialize(prefix, command, params)
		@prefix  = Prefix.new(prefix.to_s)
		@command = command
		@params  = params
	end

	# Same as @params[n].
	def [](n)
		@params[n]
	end

	# Iterate params.
	def each(&block)
		@params.each(&block)
	end

	# Stringfy message to raw IRC message.
	def to_s
		str = ""

		str << ":#{@prefix} " unless @prefix.empty?
		str << @command

		if @params
			f = false
			@params.each do |param|
				str << " "
				if !f && (param.size == 0 || / / =~ param || /^:/ =~ param)
					str << ":#{param}"
					f = true
				else
					str << param
				end
			end
		end

		str << "\x0D\x0A"

		str
	end
	alias to_str to_s

	# Same as params.
	def to_a
		@params.dup
	end

	# If the message is CTCP, return true.
	def ctcp?
		message = @params[1]
		message[0] == 1 && message[message.length-1] == 1
	end

	def inspect
		'#<%s:0x%x prefix:%s command:%s params:%s>' % [
			self.class,
			self.object_id,
			@prefix,
			@command,
			@params.inspect
		]
	end

	autoload :ModeParser, "net/irc/message/modeparser"
	autoload :ServerConfig, "net/irc/message/serverconfig"
	autoload :ISupportModeParser, "net/irc/message/isupportmodeparser"
end # Message

