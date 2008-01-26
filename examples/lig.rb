#!/usr/bin/env ruby

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "rubygems"

# http://svn.lingr.com/api/toolkits/ruby/infoteria/api_client.rb
require 'api_client'

require "net/irc"
require "pit"


class LingrIrcGateway < Net::IRC::Server::Session
	@@name     = "lingrgw"
	@@version  = "0.0.0"

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
		@lingr.say(@channels[target][:ticket], message)
	end

	def on_whois(m)
		nick = m.params[0]
		# TODO
	end

	def on_who(m)
		channel = m.params[0]
		res = @lingr.get_room_info(@channels[channel][:chan_id], nil, @channels[channel][:password])
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
			next if @channels.key? channel
			@log.debug "Enter room -> #{channel}"
			res = @lingr.enter_room(channel.sub(/^#/, ""), @nick, password)
			if res[:succeeded]
				res[:response]["password"] = password
				o_id = res[:response]["occupant_id"]
				post "#{@nick}!#{o_id}@lingr.com", JOIN, channel
				create_observer(channel, res[:response])
			else
				log "Error: #{(response && response['error']) ? res[:response]["error"]["message"] : "socket error"}"
			end
		end
	end

	def on_part(m)
		channel = m.params[0]

		if @channels[channel]
			@channels[channel][:observer].kill
			@lingr.exit_room(@channels[channel][:ticket])
			@channels.delete(channel)
			post @nick, PART, channel, "Parted"
		end
	end

	private

	def create_observer(channel, response)
		Thread.start(channel, response) do |chan, res|
			begin
				post @@name, TOPIC, chan, "#{res["room"]["url"]} #{res["room"]["description"]}"
				@channels[chan] = {
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
					info = @channels[chan]
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
						log "Error: #{(response && response['error']) ? res[:response]["error"]["message"] : "socket error"}"
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
		post nil, "NOTICE", @nick, str
	end

	def make_ids(o)
		u_id = o["user_id"]
		o_id = o["occupant_id"] || o["id"]
		nick = o["nickname"].gsub(/\s+/, "") + "^#{u_id || "anon"}"
		[u_id, o_id, nick]
	end
end

@config = Pit.get("lig.rb", :require => {
	"api_key" => "API key of lingr"
})

Net::IRC::Server.new("localhost", 16669, LingrIrcGateway, {
	:api_key => @config["api_key"]
}).start

