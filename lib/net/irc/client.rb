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
		@prefix = Prefix.new(m[1][/\S+$/])
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

	# For managing channel
	def on_rpl_namreply(m)
		type    = m[1]
		channel = m[2]
		init_channel(channel)

		@channels.synchronize do
			m[3].split(/\s+/).each do |u|
				_, mode, nick = *u.match(/^([@+]?)(.+)/)

				@channels[channel][:users] << nick
				@channels[channel][:users].uniq!
				
				op = @server_config.mode_parser.mark_to_op(mode)
				if op
					@channels[channel][:modes] << [op, nick]
				end
			end

			case type
			when "@" # secret
				@channels[channel][:modes] << [:s, nil]
			when "*" # private
				@channels[channel][:modes] << [:p, nil]
			when "=" # public
			end

			@channels[channel][:modes].uniq!
		end
	end

	# For managing channel
	def on_part(m)
		nick    = m.prefix.nick
		channel = m[0]
		init_channel(channel)

		@channels.synchronize do
			info = @channels[channel]
			if info
				info[:users].delete(nick)
				info[:modes].delete_if {|u|
					u[1] == nick
				}
			end
		end
	end

	# For managing channel
	def on_quit(m)
		nick = m.prefix.nick

		@channels.synchronize do
			@channels.each do |channel, info|
				info[:users].delete(nick)
				info[:modes].delete_if {|u|
					u[1] == nick
				}
			end
		end
	end

	# For managing channel
	def on_kick(m)
		users = m[1].split(/,/)

		@channels.synchronize do
			m[0].split(/,/).each do |chan|
				init_channel(chan)
				info = @channels[chan]
				if info
					users.each do |nick|
						info[:users].delete(nick)
						info[:modes].delete_if {|u|
							u[1] == nick
						}
					end
				end
			end
		end
	end

	# For managing channel
	def on_join(m)
		nick    = m.prefix.nick
		channel = m[0]

		@channels.synchronize do
			init_channel(channel)

			@channels[channel][:users] << nick
			@channels[channel][:users].uniq!
		end
	end

	# For managing channel
	def on_mode(m)
		channel = m[0]
		@channels.synchronize do
			init_channel(channel)

			mode = @server_config.mode_parser.parse(m)
			mode[:negative].each do |m|
				@channels[channel][:modes].delete(m)
			end

			mode[:positive].each do |m|
				@channels[channel][:modes] << m
			end

			@channels[channel][:modes].uniq!
			[mode[:negative], mode[:positive]]
		end
	end

	# For managing channel
	def init_channel(channel)
		@channels[channel] ||= {
			:modes => [],
			:users => [],
		}
	end

	# Do nothing.
	# This is for avoiding error on calling super.
	# So you can always call super at subclass.
	def method_missing(name, *args)
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
			s ? s.gsub(/[\r\n]/, " ") : ""
		})

		@log.debug "SEND: #{m.to_s.chomp}"
		@socket << m
	end
end # Client
