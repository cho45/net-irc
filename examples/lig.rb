#!/usr/bin/env ruby

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "rubygems"

# http://svn.lingr.com/api/toolkits/ruby/infoteria/api_client.rb
begin
	require "api_client"
rescue LoadError
	require "net/http"
	require "uri"
	File.open("api_client.rb", "w") do |f|
		f.puts Net::HTTP.get(URI("http://svn.lingr.com/api/toolkits/ruby/infoteria/api_client.rb"))
	end
	require "api_client"
end

require "net/irc"
require "pit"


class LingrIrcGateway < Net::IRC::Server::Session
	def server_name
		"lingrgw"
	end

	def server_version
		"0.0.0"
	end

	def initialize(*args)
		super
		@channels = {}
	end

	def on_user(m)
		super
		@real, @copts = @real.split(/\s+/)
		@copts ||= []

		log "Hello #{@nick}, this is Lingr IRC Gateway."
		log "Client Option: #{@copts.join(", ")}"
		@log.info "Client Option: #{@copts.join(", ")}"
		@log.info "Client initialization is completed."

		@lingr = Lingr::ApiClient.new(@opts.api_key)
		@lingr.create_session('human')
		@lingr.login(@real, @pass)
		@user_info = @lingr.get_user_info[:response]

		u_id, o_id, prefix = *make_ids(@user_info)
		post @prefix, NICK, prefix.nick
	end

	def on_privmsg(m)
		target, message = *m.params
		res = @lingr.say(@channels[target.downcase][:ticket], message)
		unless res[:succeeded]
			log "Error: #{(res && res[:response]["error"]) ? res[:response]["error"]["message"] : "socket error"}"
			log "Coundn't say to #{channel}."
		end
	end

	def on_whois(m)
		nick = m.params[0]
		chan = nil
		pref = nil

		@channels.each do |k, v|
			if v[:users].key?(nick)
				chan = k
				pref = v[:users][nick]
				break
			end
		end

		if chan
			real_name   = pref
			server_info = "Lingr"
			channels    = [chan]
			u_id, o_id, me = *make_ids(@user_info)

			post nil, RPL_WHOISUSER,     me.nick, pref.nick, pref.user, pref.host, "*", real_name
			post nil, RPL_WHOISSERVER,   me.nick, pref.nick, pref.nick, pref.host, server_info
			# post nil, RPL_WHOISOPERATOR, me.nick, pref.nick, "is an IRC operator"
			# post nil, RPL_WHOISIDLE,     me.nick, pref.nick, idle, "seconds idle"
			post nil, RPL_WHOISCHANNELS, me.nick, pref.nick, channels.map {|i| "@#{i}" }.join(" ")
			post nil, RPL_ENDOFWHOIS,    me.nick, pref.nick, "End of WHOIS list"
		end
	end

	def on_who(m)
		channel = m.params[0]
		return unless channel

		info    = @channels[channel.downcase]
		res = @lingr.get_room_info(info[:chan_id], nil, info[:password])
		if res[:succeeded]
			res = res[:response]
			res["occupants"].each do |o|
				u_id, o_id, prefix = *make_ids(o)
				post nil, RPL_WHOREPLY, channel, o_id, "lingr.com", "lingr.com", prefix.nick, "H", "0 #{o["description"].to_s.gsub(/\s+/, " ")}"
			end
			post nil, RPL_ENDOFWHO, channel
		else
			log "Maybe gateway don't know password for channel #{channel}. Please part and join."
		end
	end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		password = m.params[1]
		channels.each do |channel|
			next if @channels.key? channel.downcase
			begin
				@log.debug "Enter room -> #{channel}"
				res = @lingr.enter_room(channel.sub(/^#/, ""), @nick, password)
				if res[:succeeded]
					res[:response]["password"] = password

					u_id, o_id, prefix = *make_ids(@user_info)
					post prefix, JOIN, channel
					post server_name, MODE, channel, "+o", prefix.nick

					create_observer(channel, res[:response])
				else
					log "Error: #{(res && res[:response]["error"]) ? res[:response]["error"]["message"] : "socket error"}"
					log "Coundn't join to #{channel}."
				end
			rescue Exception => e
				@log.error e.message
				e.backtrace.each do |l|
					@log.error "\t#{l}"
				end
			end
		end
	end

	def on_part(m)
		channel = m.params[0]
		info = @channels[channel.downcase]

		if info
			info[:observer].kill
			@lingr.exit_room(info[:ticket])
			@channels.delete(channel.downcase)

			u_id, o_id, prefix = *make_ids(@user_info)
			post prefix, PART, channel, "Parted"
		end
	end

	private

	def create_observer(channel, response)
		Thread.start(channel, response) do |chan, res|
			begin
				myu_id, myo_id, myprefix = *make_ids(@user_info)
				post server_name, TOPIC, chan, "#{res["room"]["url"]} #{res["room"]["description"]}"
				@channels[chan.downcase] = {
					:ticket   => res["ticket"],
					:counter  => res["counter"],
					:o_id     => res["occupant_id"],
					:chan_id  => res["room"]["id"],
					:password => res["password"],
					:users    => { myprefix.nick => myprefix },
					:hcounter => 0,
					:observer => Thread.current,
				}
				first = true
				while true
					info = @channels[chan.downcase]
					res = @lingr.observe_room info[:ticket], info[:counter]
					@log.debug "observe_room returned"
					if res[:succeeded]
						info[:counter] = res[:response]["counter"] if res[:response]["counter"]
						(res[:response]["messages"] || []).each do |m|
							next if m["id"].to_i <= info[:hcounter]

							u_id, o_id, prefix = *make_ids(m)

							case m["type"]
							when "user"
								if first
									post prefix, NOTICE, chan, m["text"]
								else
									post prefix, PRIVMSG, chan, m["text"] unless info[:o_id] == o_id
								end
							when "private"
								# TODO
								post prefix, PRIVMSG, chan, "\x01ACTION Sent private: #{m["text"]}\x01" unless info[:o_id] == o_id
							when "system:enter"
								unless prefix.nick == myprefix.nick
									post prefix, JOIN, chan
									post server_name, MODE, chan, "+o", prefix.nick
									info[:users][prefix.nick] = prefix
								end
							when "system:leave"
								unless prefix.nick == myprefix.nick
									post prefix, PART, chan
									info[:users].delete(prefix.nick)
								end
							when "system:nickname_change"
								m["nickname"] = m["new_nickname"]
								_, _, newprefix = *make_ids(m)
								post prefix, NICK, newprefix.nick
							when "system:broadcast"
								post "system.broadcast",  NOTICE, chan, m["text"]
							end

							info[:hcounter] = m["id"].to_i if m["id"]
						end

						if res["occupants"]
							res["occupants"].each do |o|
								# new_roster[o["id"]] = o["nickname"]
								if o["nickname"]
									nick = o["nickname"]
									u_id, o_id, prefix = make_ids(o)

									post prefix, JOIN, chan
									post server_name, MODE, chan, "+o", prefix.nick
									info[:users][prefix.nick] = prefix
								end
							end
						end
					else
						@log.debug "observe failed : #{res[:response].inspect}"
						log "Error: #{(res && res[:response]["error"]) ? res[:response]["error"]["message"] : "socket error"}"
					end
					first = false
				end
			rescue Exception => e
				@log.error e.message
				e.backtrace.each do |l|
					@log.error "\t#{l}"
				end
			end
		end
	end

	def log(str)
		str.gsub!(/\s/, " ")
		begin
			myu_id, myo_id, myprefix = *make_ids(@user_info)
			post nil, NOTICE, myprefix.nick, str
		rescue
			post nil, NOTICE, @nick, str
		end
	end

	def make_ids(o)
		u_id  = o["user_id"] || "anon"
		o_id  = o["occupant_id"] || o["id"]
		nick  = (o["default_nickname"] || o["nickname"]).gsub(/\s+/, "") 
		if o["user_id"] == @user_info["user_id"]
			nick << "|#{o["user_id"]}"
		else
			nick << "|#{o["user_id"] ? o_id : "_"+o_id}"
		end
		pref = Prefix.new("#{nick}!#{u_id}@lingr.com")
		[u_id, o_id, pref]
	end
end


if __FILE__ == $0
	require "rubygems"
	require "optparse"
	require "pit"

	opts = {
		:port   => 16669,
		:host   => "localhost",
		:debug  => false,
		:log    => nil,
		:debug  => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner  = <<-EOB.gsub(/^\t+/, "")
				Usage: #{$0} [opts]

			EOB

			separator ""

			separator "Options:"
			on("-p", "--port [PORT=#{opts[:port]}]", "port number to listen") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "host name or IP address to listen") do |host|
				opts[:host] = host
			end

			on("-l", "--log LOG", "log file") do |log|
				opts[:log] = log
			end

			on("-a", "--api_key API_KEY", "Your api key on Lingr") do |key|
				opts[:api_key] = key
			end

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

	def daemonize(debug=false)
		return yield if $DEBUG || debug
		Process.fork do
			Process.setsid
			Dir.chdir "/"
			trap("SIGINT")  { exit! 0 }
			trap("SIGTERM") { exit! 0 }
			trap("SIGHUP")  { exit! 0 }
			File.open("/dev/null") {|f|
				STDIN.reopen  f
				STDOUT.reopen f
				STDERR.reopen f
			}
			yield
		end
		exit! 0
	end

	opts[:api_key] = Pit.get("lig.rb", :require => {
		"api_key" => "API key of Lingr"
	})["api_key"] unless opts[:api_key]

	daemonize(opts[:debug]) do
		Net::IRC::Server.new(opts[:host], opts[:port], LingrIrcGateway, opts).start
	end

end


