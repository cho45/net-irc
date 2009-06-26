
module Net::IRC::Client::ChannelManager
	# For managing channel
	def on_rpl_namreply(m)
		type    = m[1]
		channel = m[2]
		init_channel(channel)

		@channels.synchronize do
			m[3].split(" ").each do |u|
				_, mode, nick = *u.match(/\A([@+]?)(.+)/)

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
		users = m[1].split(",")

		@channels.synchronize do
			m[0].split(",").each do |chan|
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
	def on_nick(m)
		oldnick = m.prefix.nick
		newnick = m[0]

		@channels.synchronize do
			@channels.each do |channel, info|
				info[:users].map! {|i|
					(i == oldnick) ? newnick : i
				}
				info[:modes].map! {|mode, target|
					(target == oldnick) ? [mode, newnick] : [mode, target]
				}
			end
		end
	end

	# For managing channel
	def on_mode(m)
		channel = m[0]
		@channels.synchronize do
			init_channel(channel)

			modes = @server_config.mode_parser.parse(m)
			modes[:negative].each do |mode|
				@channels[channel][:modes].delete(mode)
			end

			modes[:positive].each do |mode|
				@channels[channel][:modes] << mode
			end

			@channels[channel][:modes].uniq!
			[modes[:negative], modes[:positive]]
		end
	end

	# For managing channel
	def init_channel(channel)
		@channels[channel] ||= {
			:modes => [],
			:users => [],
		}
	end

end

