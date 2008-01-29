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
		@real, @copts = @real.split(/\s/)
		@copts ||= []

		log "Hello #{@nick}, this is Lingr IRC Gateway."
		log "Client Option: #{@copts.join(", ")}"
		@log.info "Client Option: #{@copts.join(", ")}"
		@log.info "Client initialization is completed."

		@lingr = Lingr::ApiClient.new(@opts.api_key)
		@lingr.create_session('human')
		@lingr.login(@real, @pass)
		@user_info = @lingr.get_user_info[:response]
	end

	def on_privmsg(m)
		target, message = *m.params
		@lingr.say(@channels[target.downcase][:ticket], message)
	end

	def on_whois(m)
		nick = m.params[0]
		# TODO
	end

	def on_who(m)
		channel = m.params[0]
		info    = @channels[channel.downcase]
		res = @lingr.get_room_info(info[:chan_id], nil, info[:password])
		if res[:succeeded]
			res = res[:response]
			res["occupants"].each do |o|
				u_id, o_id, nick = *make_ids(o)
				post nil, RPL_WHOREPLY, channel, o_id, "lingr.com", "lingr.com", nick, "H", "0 #{o["description"].to_s.gsub(/\s+/, " ")}"
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
			@log.debug "Enter room -> #{channel}"
			res = @lingr.enter_room(channel.sub(/^#/, ""), @nick, password)
			if res[:succeeded]
				res[:response]["password"] = password
				o_id = res[:response]["occupant_id"]
				post "#{@nick}!#{o_id}@lingr.com", JOIN, channel
				create_observer(channel, res[:response])
			else
				log "Error: #{(res && rese['error']) ? res[:response]["error"]["message"] : "socket error"}"
			end
		end
	end

	def on_part(m)
		channel = m.params[0]
		info = @channels[channel].downcase

		if info
			info[:observer].kill
			@lingr.exit_room(info[:ticket])
			@channels.delete(channel.downcase)
			post @nick, PART, channel, "Parted"
		end
	end

	private

	def create_observer(channel, response)
		Thread.start(channel, response) do |chan, res|
			begin
				post server_name, TOPIC, chan, "#{res["room"]["url"]} #{res["room"]["description"]}"
				@channels[chan.downcase] = {
					:ticket   => res["ticket"],
					:counter  => res["counter"],
					:o_id     => res["occupant_id"],
					:chan_id  => res["room"]["id"],
					:password => res["password"],
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

							u_id, o_id, nick = *make_ids(m)

							case m["type"]
							when "user"
								if first
									post nick, NOTICE, chan, m["text"]
								else
									post nick, PRIVMSG, chan, m["text"] unless info[:o_id] == o_id
								end
							when "private"
								# TODO
								post nick, PRIVMSG, chan, "\x01ACTION Sent private: #{m["text"]}\x01" unless info[:o_id] == o_id
							when "system:enter"
								post "#{nick}!#{o_id}@lingr.com", JOIN, chan unless nick == @nick
							when "system:leave"
								#post "#{nick}!#{o_id}@lingr.com", PART, chan unless nick == @nick
							when "system:nickname_change"
								post nick, NOTICE, chan, m["text"]
							when "system:broadcast"
								post nil,  NOTICE, chan, m["text"]
							end

							info[:hcounter] = m["id"].to_i if m["id"]
						end

						if res["occupants"]
							res["occupants"].each do |o|
								# new_roster[o["id"]] = o["nickname"]
								if o["nickname"]
									nick = o["nickname"]
									o_id = m["occupant_id"]
									post "#{nick}!#{o_id}@lingr.com", JOIN, chan
								end
							end
						end
					else
						@log.debug "observe failed : #{res[:response].inspect}"
						log "Error: #{(res && res['error']) ? res[:response]["error"]["message"] : "socket error"}"
					end
					first = false
				end
			rescue Exception => e
				puts e
				puts e.backtrace
			end
		end
	end

	def log(str)
		str.gsub!(/\s/, " ")
		post nil, NOTICE, @nick, str
	end

	def make_ids(o)
		u_id = o["user_id"]
		o_id = o["occupant_id"] || o["id"]
		nick = o["nickname"].gsub(/\s+/, "") + "^#{u_id || "anon"}"
		[u_id, o_id, nick]
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
			on("-p", "--port [PORT=#{opts[:port]}]", "listen port number") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "listen host") do |host|
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
		"api_key" => "API key of lingr"
	})["api_key"] unless opts[:api_key]

	daemonize(opts[:debug]) do
		Net::IRC::Server.new(opts[:host], opts[:port], LingrIrcGateway, opts).start
	end

end


