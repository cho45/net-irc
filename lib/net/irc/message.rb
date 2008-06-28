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
		@params
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

	class ModeParser

		def initialize(require_arg, definition)
			@require_arg = require_arg.map {|i| i.to_sym }
			@definition  = definition
		end

		def parse(arg)
			params = arg.kind_of?(Net::IRC::Message) ? arg.to_a : arg.split(/\s+/)

			ret =  {
				:positive => [],
				:negative => [],
			}

			current = nil, arg_pos = 0
			params[1].each_byte do |c|
				sym = c.chr.to_sym
				case sym
				when :+
					current = ret[:positive]
				when :-
					current = ret[:negative]
				else
					case
					when @require_arg.include?(sym)
						current << [sym, params[arg_pos + 2]]
						arg_pos += 1
					when @definition.key?(sym)
						current << [sym, nil]
					else
						# fallback, should raise exception
						# but not for convenience
						current << [sym, nil]
					end
				end
			end

			ret
		end

		module RFC1459
			Channel  = ModeParser.new(%w|o l b v k|, {
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
			User    = ModeParser.new(%w||, {
				:i => "marks a users as invisible",
				:s => "marks a user for receipt of server notices",
				:w => "user receives wallops",
				:o => "operator flag",
			})
		end
	end
end # Message
