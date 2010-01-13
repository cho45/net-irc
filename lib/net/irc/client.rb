class Net::IRC::Client
	include Net::IRC
	include Constants

	attr_reader :host, :port, :opts
	attr_reader :prefix, :channels

	def initialize(host, port, opts={})
		@host          = host
		@port          = port
		@opts          = OpenStruct.new(opts)
		@log           = @opts.logger || Logger.new($stdout)
		@server_config = Message::ServerConfig.new
		@channels = {
#			"#channel" => {
#				:modes => [],
#				:users => [],
#			}
		}
		@channels.extend(MonitorMixin)
	end

	# Connect to server and start loop.
	def start
		# reset config
		@server_config = Message::ServerConfig.new
		@socket = TCPSocket.open(@host, @port)
		on_connected
		post PASS, @opts.pass if @opts.pass
		post NICK, @opts.nick
		post USER, @opts.user, "0", "*", @opts.real
		while l = @socket.gets
			begin
				@log.debug "RECEIVE: #{l.chomp}"
				m = Message.parse(l)
				next if on_message(m) === true
				name = "on_#{(COMMANDS[m.command.upcase] || m.command).downcase}"
				send(name, m) if respond_to?(name)
			rescue Exception => e
				warn e
				warn e.backtrace.join("\r\t")
				raise
			rescue Message::InvalidMessage
				@log.error "MessageParse: " + l.inspect
			end
		end
	rescue IOError
	ensure
		finish
	end

	# Close connection to server.
	def finish
		begin
			@socket.close
		rescue
		end
		on_disconnected
	end

	# Catch all messages.
	# If this method return true, aother callback will not be called.
	def on_message(m)
	end

	# Default RPL_WELCOME callback.
	# This sets @prefix from the message.
	def on_rpl_welcome(m)
		@prefix = Prefix.new(m[1][/\S+\z/])
	end

	# Default RPL_ISUPPORT callback.
	# This detects server's configurations.
	def on_rpl_isupport(m)
		@server_config.set(m)
	end

	# Default PING callback. Response PONG.
	def on_ping(m)
		post PONG, @prefix ? @prefix.nick : ""
	end

	# Call when socket connected.
	def on_connected
	end

	# Call when socket closed.
	def on_disconnected
	end

	private

	# Post message to server.
	#
	#     include Net::IRC::Constants
	#     post PRIVMSG, "#channel", "foobar"
	def post(command, *params)
		m = Message.new(nil, command, params.map {|s|
			if s
				s.force_encoding("ASCII-8BIT") if s.respond_to? :force_encoding
				#s.gsub(/\r\n|[\r\n]/, " ")
				s.tr("\r\n", " ")
			else
				""
			end
		})

		@log.debug "SEND: #{m.to_s.chomp}"
		@socket << m
	end
end # Client
