class Net::IRC::Message::ServerConfig
	attr_reader :mode_parser

	def initialize
		@config = {}
		@mode_parser = Net::IRC::Message::ModeParser.new
	end

	def set(arg)
		params = arg.kind_of?(Net::IRC::Message) ? arg.to_a : arg.split(" ")

		params[1..-1].each do |s|
			case s
			when /\A:?are supported by this server\z/
				# Ignore
			when /\A([^=]+)=(.*)\z/
				key = Regexp.last_match[1].to_sym
				value = Regexp.last_match[2]
				@config[key] = value
				@mode_parser.set(key, value) if key == :CHANMODES || key == :PREFIX
			else
				@config[s] = true
			end
		end
	end

	def [](key)
		@config[key]
	end
end
