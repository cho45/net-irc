class Net::IRC::Message::ModeParser

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

	autoload :RFC1459,  "net/irc/message/modeparser/rfc1459"
	autoload :Hyperion, "net/irc/message/modeparser/hyperion"
	autoload :ISupport, "net/irc/message/modeparser/isupport"
end
