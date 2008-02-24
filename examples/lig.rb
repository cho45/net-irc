#!/usr/bin/env ruby
=begin

# lig.rb

Lingr IRC Gateway - IRC Gateway to Lingr ( http://www.lingr.com/ )

## Launch

	$ ruby lig.rb # daemonized

If you want to help:

	$ ruby lig.rb --help
	Usage: examples/lig.rb [opts]


	Options:
	    -p, --port [PORT=16669]          port number to listen
	    -h, --host [HOST=localhost]      host name or IP address to listen
	    -l, --log LOG                    log file
	    -a, --api_key API_KEY            Your api key on Lingr
	        --debug                      Enable debug mode

## Configuration

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	lingr {
		host: localhost
		port: 16669
		name: username@example.com (Email on Lingr)
		password: password on Lingr
		in-encoding: utf8
		out-encoding: utf8
	}

Set your email as IRC 'real name' field, and password as server password.
This does not allow anonymous connection to Lingr.
You must create a account on Lingr and get API key (ask it first time).

## Client

This gateway sends multibyte nicknames at Lingr rooms as-is.
So you should use a client which treats it correctly.

Recommended:

 * LimeChat for OSX ( http://limechat.sourceforge.net/ )
 * Irssi ( http://irssi.org/ )
 * (gateway) Tiarra ( http://coderepos.org/share/wiki/Tiarra )

## Nickname/Mask

nick -> nickname in a room.
o_id -> occupant_id (unique id in a room)
u_id -> user_id (unique user id in Lingr)

 * Anonymous User: <nick>|<o_id>!anon@lingr.com
 * Logged-in User: <nick>|<o_id>!<u_id>@lingr.com
 * Your:           <nick>|<u_id>!<u_id>@lingr.com

So you can see some nicknames in same user, but it is needed for
nickname management on client.

(Lingr allows different nicknames between rooms in a same user, but IRC not)

## Licence

Ruby's by cho45

## 備考

このクライアントで 1000speakers への応募はできません。lingr.com から行ってください。

=end

$LOAD_PATH << File.dirname(__FILE__)
$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "rubygems"
require "lingr"
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
		@real, *@copts = @real.split(/\s+/)
		@copts ||= []

		# Tiarra sends prev nick when reconnects.
		@nick.sub!(/\|.+$/, "")

		log "Hello #{@nick}, this is Lingr IRC Gateway."
		log "Client Option: #{@copts.join(", ")}"
		@log.info "Client Option: #{@copts.join(", ")}"
		@log.info "Client initialization is completed."

		@lingr = Lingr::Client.new(@opts.api_key)
		@lingr.create_session('human')
		@lingr.login(@real, @pass)
		@user_info = @lingr.get_user_info

		prefix = make_ids(@user_info)
		@user_info["prefix"] = prefix
		post @prefix, NICK, prefix.nick
	rescue Lingr::Client::APIError => e
		case e.code
		when 105
			post nil, ERR_PASSWDMISMATCH, @nick, "Password incorrect"
		else
			log "Error: #{e.code}: #{e.message}"
		end
		finish
	end

	def on_privmsg(m)
		target, message = *m.params
		if @channels.key?(target.downcase)
			@lingr.say(@channels[target.downcase][:ticket], message)
		else
			post nil, ERR_NOSUCHNICK, @user_info["prefix"].nick, target, "No such nick/channel"
		end
	rescue Lingr::Client::APIError => e
		log "Error: #{e.code}: #{e.message}"
		log "Coundn't say to #{channel}."
	end

	def on_notice(m)
		on_privmsg(m)
	end

	def on_whois(m)
		nick = m.params[0]
		chan = nil
		info = nil

		@channels.each do |k, v|
			if v[:users].key?(nick)
				chan = k
				info = v[:users][nick]
				break
			end
		end

		if chan
			prefix      = info["prefix"]
			real_name   = info["description"].to_s
			server_info = "Lingr: type:#{info["client_type"]} source:#{info["source"]}"
			channels    = [info["client_type"] == "human" ? "@#{chan}" : chan]
			me          = @user_info["prefix"]

			post nil, RPL_WHOISUSER,     me.nick, prefix.nick, prefix.user, prefix.host, "*", real_name
			post nil, RPL_WHOISSERVER,   me.nick, prefix.nick, prefix.host, server_info
			# post nil, RPL_WHOISOPERATOR, me.nick, prefix.nick, "is an IRC operator"
			# post nil, RPL_WHOISIDLE,     me.nick, prefix.nick, idle, "seconds idle"
			post nil, RPL_WHOISCHANNELS, me.nick, prefix.nick, channels.join(" ")
			post nil, RPL_ENDOFWHOIS,    me.nick, prefix.nick, "End of WHOIS list"
		else
			post nil, ERR_NOSUCHNICK, me.nick, nick, "No such nick/channel"
		end
	rescue Exception => e
		@log.error e.inspect
		e.backtrace.each do |l|
			@log.error "\t#{l}"
		end
	end

	def on_who(m)
		channel = m.params[0]
		return unless channel

		info = @channels[channel.downcase]
		me   = @user_info["prefix"]
		res  = @lingr.get_room_info(info[:chan_id], nil, info[:password])
		res["occupants"].each do |o|
			next unless o["nickname"]
			u_id, o_id, prefix = *make_ids(o, true)
			op = (o["client_type"] == "human") ? "@" : ""
			post nil, RPL_WHOREPLY, me.nick, channel, o_id, "lingr.com", "lingr.com", prefix.nick, "H*#{op}", "0 #{o["description"].to_s.gsub(/\s+/, " ")}"
		end
		post nil, RPL_ENDOFWHO, me.nick, channel
	rescue Lingr::Client::APIError => e
		log "Maybe gateway don't know password for channel #{channel}. Please part and join."
	end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		password = m.params[1]
		channels.each do |channel|
			next if @channels.key? channel.downcase
			begin
				@log.debug "Enter room -> #{channel}"
				res = @lingr.enter_room(channel.sub(/^#/, ""), @nick, password)
				res["password"] = password

				create_observer(channel, res)
			rescue Lingr::Client::APIError => e
				log "Error: #{e.code}: #{e.message}"
				log "Coundn't join to #{channel}."
				if e.code == 102
					log "Invalid session... prompt the client to reconnect"
					finish
				end
			rescue Exception => e
				@log.error e.inspect
				e.backtrace.each do |l|
					@log.error "\t#{l}"
				end
			end
		end
	end

	def on_part(m)
		channel = m.params[0]
		info    = @channels[channel.downcase]
		prefix  = @user_info["prefix"]

		if info
			info[:observer].kill
			@lingr.exit_room(info[:ticket])
			@channels.delete(channel.downcase)

			post prefix, PART, channel, "Parted"
		else
			post nil, ERR_NOSUCHCHANNEL, prefix.nick, channel, "No such channel"
		end
	end

	def on_disconnected
		@channels.each do |k, info|
			info[:observer].kill
		end
		begin
			@lingr.destroy_session
		rescue
		end
	end

	private

	def create_observer(channel, response)
		Thread.start(channel, response) do |chan, res|
			myprefix = @user_info["prefix"]
			post server_name, TOPIC, chan, "#{res["room"]["url"]} #{res["room"]["description"]}"
			@channels[chan.downcase] = {
				:ticket   => res["ticket"],
				:counter  => res["room"]["counter"],
				:o_id     => res["occupant_id"],
				:chan_id  => res["room"]["id"],
				:password => res["password"],
				:users    => res["occupants"].reject {|i| i["nickname"].nil? }.inject({}) {|r,i|
					i["prefix"] = make_ids(i)
					r.update(i["prefix"].nick => i)
				},
				:hcounter => 0,
				:observer => Thread.current,
			}
			post myprefix, JOIN, channel
			post server_name, MODE, channel, "+o", myprefix.nick
			post nil, RPL_NAMREPLY,   myprefix.nick, "=", chan, @channels[chan.downcase][:users].map{|k,v|
				v["client_type"] == "human" ? "@#{k}" : k
			}.join(" ")
			post nil, RPL_ENDOFNAMES, myprefix.nick, chan, "End of NAMES list"

			info = @channels[chan.downcase]
			while true
				begin
					@log.debug "observe_room<#{info[:counter]}><#{chan}> start <- #{myprefix}"
					res = @lingr.observe_room info[:ticket], info[:counter]

					info[:counter] = res["counter"] if res["counter"]

					(res["messages"] || []).each do |m|
						next if m["id"].to_i <= info[:hcounter]

						u_id, o_id, prefix = *make_ids(m, true)

						case m["type"]
						when "user"
							# Don't send my messages.
							unless info[:o_id] == o_id
								post prefix, PRIVMSG, chan, m["text"]
							end
						when "private"
							# TODO not sent from lingr?
							post prefix, PRIVMSG, chan, ctcp_encoding("ACTION Sent private: #{m["text"]}")

						# system:{enter,leave,nickname_changed} should not be used for nick management.
#						when "system:enter"
#							post prefix, PRIVMSG, chan, ctcp_encoding("ACTION #{m["text"]}")
#						when "system:leave"
#							post prefix, PRIVMSG, chan, ctcp_encoding("ACTION #{m["text"]}")
#						when "system:nickname_change"
#							post prefix, PRIVMSG, chan, ctcp_encoding("ACTION #{m["text"]}")
						when "system:broadcast"
							post "system.broadcast",  NOTICE, chan, m["text"]
						end

						info[:hcounter] = m["id"].to_i if m["id"]
					end

					if res["occupants"]
						enter = [], leave = []
						newusers = res["occupants"].reject {|i| i["nickname"].nil? }.inject({}) {|r,i|
							i["prefix"] = make_ids(i)
							r.update(i["prefix"].nick => i)
						}


						nickchange = newusers.inject({:new => [], :old => []}) {|r,(k,new)|
							old = info[:users].find {|l,old|
								# same occupant_id and different nickname
								# when nickname was changed and when un-authed user promoted to authed user.
								new["prefix"] != old["prefix"] && new["id"] == old["id"]
							}
							if old
								old = old[1]
								post old["prefix"], NICK, new["prefix"].nick
								r[:old] << old["prefix"].nick
								r[:new] << new["prefix"].nick
							end
							r
						}

						entered = newusers.keys - info[:users].keys - nickchange[:new]
						leaved  = info[:users].keys - newusers.keys - entered - nickchange[:old]

						leaved.each do |leave|
							leave = info[:users][leave]
							post leave["prefix"], PART, chan, ""
						end

						entered.each do |enter|
							enter  = newusers[enter]
							prefix = enter["prefix"]
							post prefix, JOIN, chan
							if enter["client_type"] == "human"
								post server_name, MODE, chan, "+o", prefix.nick
							end
						end

						info[:users] = newusers
					end


				rescue Lingr::Client::APIError => e
					case e.code
					when 100
						@log.fatal "BUG: API returns invalid HTTP method"
						exit 1
					when 102
						@log.error "BUG: API returns invalid session. Prompt the client to reconnect."
						finish
					when 104
						@log.fatal "BUG: API returns invalid response format. JSON is unsupported?"
						exit 1
					when 109
						@log.error "BUG: API returns invalid ticket. Part this channel..."
						on_part(Message.new("", PART, [chan, res["error"]["message"]]))
					when 114
						@log.fatal "BUG: API returns no counter parameter."
						exit 1
					when 120
						@log.error "Error: API returns invalid encoding. But continues."
					when 122
						@log.error "Error: API returns repeated counter. But continues."
						info[:counter] += 10
						log "Error: repeated counter. Some message may be ignored..."
					else
						# may be socket error?
						@log.debug "observe failed : #{res.inspect}"
						log "Error: #{e.code}: #{e.message}"
					end
				rescue JSON::ParserError => e
					@log.error e
					info[:counter] += 10
					log "Error: JSON::ParserError Some message may be ignored..."
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep 1
			end
		end
	end

	def log(str)
		str.gsub!(/\s/, " ")
		begin
			post nil, NOTICE, @user_info["prefix"].nick, str
		rescue
			post nil, NOTICE, @nick, str
		end
	end

	def make_ids(o, ext=false)
		u_id  = o["user_id"] || "anon"
		o_id  = o["occupant_id"] || o["id"]
		nick  = (o["default_nickname"] || o["nickname"]).gsub(/\s+/, "")
		if o["user_id"] == @user_info["user_id"]
			nick << "|#{o["user_id"]}"
		else
			nick << "|#{o["user_id"] ? o_id : "_"+o_id}"
		end
		pref = Prefix.new("#{nick}!#{u_id}@lingr.com")
		ext ? [u_id, o_id, pref] : pref
	end
end


if __FILE__ == $0
	require "rubygems"
	require "optparse"
	require "pit"

	opts = {
		:port  => 16669,
		:host  => "localhost",
		:log   => nil,
		:debug => false,
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


