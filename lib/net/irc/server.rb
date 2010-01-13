class Net::IRC::Server
	# Server global state for accessing Server::Session
	attr_accessor :state
	attr_accessor :sessions

	def initialize(host, port, session_class, opts={})
		@host          = host
		@port          = port
		@session_class = session_class
		@opts          = OpenStruct.new(opts)
		@sessions      = []
		@state         = {}
	end

	# Start server loop.
	def start
		@serv = TCPServer.new(@host, @port)
		@log  = @opts.logger || Logger.new($stdout)
		@log.info "Host: #{@host} Port:#{@port}"
		@accept = Thread.start do
			loop do
				Thread.start(@serv.accept) do |s|
					begin
						@log.info "Client connected, new session starting..."
						s = @session_class.new(self, s, @log, @opts)
						@sessions << s
						s.start
					rescue Exception => e
						puts e
						puts e.backtrace
					ensure
						@sessions.delete(s)
					end
				end
			end
		end
		@accept.join
	end

	# Close all sessions.
	def finish
		Thread.exclusive do
			@accept.kill
			begin
				@serv.close
			rescue
			end
			@sessions.each do |s|
				s.finish
			end
		end
	end


	class Session
		include Net::IRC
		include Constants

		attr_reader :prefix, :nick, :real, :host

		# Override subclass.
		def server_name
			"net-irc"
		end

		# Override subclass.
		def server_version
			"0.0.0"
		end

		# Override subclass.
		def available_user_modes
			"eixwy"
		end

		# Override subclass.
		def available_channel_modes
			"spknm"
		end

		def initialize(server, socket, logger, opts={})
			@server, @socket, @log, @opts = server, socket, logger, opts
		end

		def self.start(*args)
			new(*args).start
		end

		# Start session loop.
		def start
			on_connected
			while l = @socket.gets
				begin
					@log.debug "RECEIVE: #{l.chomp}"
					m = Message.parse(l)
					next if on_message(m) === true

					name = "on_#{(COMMANDS[m.command.upcase] || m.command).downcase}"
					send(name, m) if respond_to?(name)

					break if m.command == QUIT
				rescue Message::InvalidMessage
					@log.error "MessageParse: " + l.inspect
				end
			end
		rescue IOError
		ensure
			finish
		end

		# Close this session.
		def finish
			begin
				@socket.close
			rescue
			end
			on_disconnected
		end

		# Default PASS callback.
		# Set @pass.
		def on_pass(m)
			@pass = m.params[0]
		end

		# Default NICK callback.
		# Set @nick.
		def on_nick(m)
			@nick = m.params[0]
			@prefix = Prefix.new("#{@nick}!#{@user}@#{@host}") if defined? @prefix
		end

		# Default USER callback.
		# Set @user, @real, @host and call initial_message.
		def on_user(m)
			@user, @real = m.params[0], m.params[3]
			@nick ||= @user
			@host = @socket.peeraddr[2]
			@prefix = Prefix.new("#{@nick}!#{@user}@#{@host}")
			initial_message
		end

		# Call when socket connected.
		def on_connected
		end

		# Call when socket closed.
		def on_disconnected
		end

		# Catch all messages.
		# If this method return true, aother callback will not be called.
		def on_message(m)
		end

		# Default PING callback. Response PONG.
		def on_ping(m)
			post server_name, PONG, m.params[0]
		end

		private
		# Post message to server.
		#
		#     include Net::IRC::Constants
		#     post prefix, PRIVMSG, "#channel", "foobar"
		def post(prefix, command, *params)
			m = Message.new(prefix, command, params.map {|s|
				#s.gsub(/\r\n|[\r\n]/, " ")
				s.tr("\r\n", " ")
			})
			@log.debug "SEND: #{m.to_s.chomp}"
			@socket << m
		rescue IOError
			finish
		end

		# Call when client connected.
		# Send RPL_WELCOME sequence. If you want to customize, override this method at subclass.
		def initial_message
			post server_name, RPL_WELCOME,  @nick, "Welcome to the Internet Relay Network #{@prefix}"
			post server_name, RPL_YOURHOST, @nick, "Your host is #{server_name}, running version #{server_version}"
			post server_name, RPL_CREATED,  @nick, "This server was created #{Time.now}"
			post server_name, RPL_MYINFO,   @nick, "#{server_name} #{server_version} #{available_user_modes} #{available_channel_modes}"
		end
	end
end # Server
