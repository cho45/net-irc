#!/usr/bin/env ruby
=begin

# tig.rb

Ruby version of Twitter IRC Gateway
( http://www.misuzilla.org/dist/net/twitterircgateway/ )


## Client opts

Options specified by after irc realname.

Configuration example for tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	twitter {
		host: localhost
		port: 16668
		name: username@example.com athack
		password: password on twitter
		in-encoding: utf8
		out-encoding: utf8
	}

### athack

If `athack` client options specified,
all nick in join message is leading with @.

So if you complemente nicks (ex. irssi),
it's good for twitter like reply command (@nick).

In this case, you will see torrent of join messages after connected,
because NAMES list can't send @ leading nick (it interpreted op.)

## Licence

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "rubygems"
require "net/http"
require "net/irc"
require "uri"
require "json"
require "socket"
require "time"
require "logger"
require "yaml"
require "pathname"
require "digest/md5"

Net::HTTP.version_1_2

class TwitterIrcGateway < Net::IRC::Server::Session
	@@name     = "twittergw"
	@@version  = "0.0.0"
	@@channel  = "#twitter"
	@@api_base = URI("http://twitter.com/")

	class ApiFailed < StandardError; end

	def initialize(*args)
		super
		@groups = {}
		@channels = [] # join channels (groups)
		@config = Pathname.new(ENV["HOME"]) + ".tig"
		load_config
	end

	def on_user(m)
		super
		post @mask, JOIN, @@channel
		@real, @opts = @real.split(/\s/)
		@opts ||= []
		@log.info "Client Options: #{@opts.inspect}"

		@timeline = []
		Thread.start do
			loop do
				begin
					check_friends
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					puts e
					puts e.backtrace
				end
				sleep 10 * 60
			end
		end
		sleep 3
		Thread.start do
			loop do
				begin
					check_timeline
					# check_direct_messages
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					puts e
					puts e.backtrace
				end
				sleep 90
			end
		end
	end

	def on_privmsg(m)
		retry_count = 3
		ret = nil
		target, message = *m.params
		begin
			if target =~ /^#/
				ret = api("statuses/update.json", {"status" => message})
			else
				# direct message
				ret = api("direct_messages/new.json", {"user" => target, "text" => message})
			end
			raise ApiFailed, "api failed" unless ret
			log "Status Updated"
		rescue => e
			@log.error [retry_count, e.inspect].inspect
			if retry_count > 0
				retry_count -= 1
				@log.debug "Retry to setting status..."
				retry
			else
				log "Some Error Happened on Sending #{message}. #{e}"
			end
		end
	end

	def on_whois(m)
		nick = m.params[0]
		f = (@friends || []).find {|i| i["screen_name"] == nick }
		if f
			post nil, RPL_WHOISUSER,   nick, nick, nick, @@api_base.host, "*", NKF.nkf("-j", "#{f["name"]} / #{f["description"]}")
			post nil, RPL_WHOISSERVER, nick, @@api_base.host, @@api_base.to_s
			post nil, RPL_WHOISIDLE,   nick, "0", "seconds idle"
			post nil, RPL_ENDOFWHOIS,  nick, "End of WHOIS list"
		else
			post nil, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	def on_who(m)
		channel = m.params[0]
		case
		when channel == @@channel
			#     "<channel> <user> <host> <server> <nick> 
			#         ( "H" / "G" > ["*"] [ ( "@" / "+" ) ] 
			#             :<hopcount> <real name>"
			@friends.each do |f|
				user = nick = f["screen_name"]
				host = serv = @@api_base.host
				real = f["name"]
				post nil, RPL_WHOREPLY, channel, user, host, serv, nick, "H", "0 #{real}"
			end
			post nil, RPL_ENDOFWHO, channel
		when @groups.key?(channel)
			@groups[channel].each do |name|
				f = @friends.find {|i| i["screen_name"] == name }
				user = nick = f["screen_name"]
				host = serv = @@api_base.host
				real = f["name"]
				post nil, RPL_WHOREPLY, channel, user, host, serv, nick, "H", "0 #{real}"
			end
			post nil, RPL_ENDOFWHO, channel
		else
			post nil, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		channels.each do |channel|
			next if channel == @@channel

			@channels << channel
			@channels.uniq!
			post "#{@nick}!#{@nick}@#{@@api_base.host}", JOIN, channel
			save_config
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel == @@channel

		@channels.delete(channel)
		post @nick, PART, channel, "Ignore group #{channel}, but setting is alive yet."
	end

	def on_invite(m)
		nick, channel = *m.params
		return if channel == @@channel

		if (@friends || []).find {|i| i["screen_name"] == nick }
			((@groups[channel] ||= []) << nick).uniq!
			post "#{nick}!#{nick}@#{@@api_base.host}", JOIN, channel
			save_config
		else
			post ERR_NOSUCHNICK, nil, nick, "No such nick/channel"
		end
	end

	def on_kick(m)
		channel, nick, mes = *m.params
		return if channel == @@channel

		if (@friends || []).find {|i| i["screen_name"] == nick }
			(@groups[channel] ||= []).delete(nick)
			post nick, PART, channel
			save_config
		else
			post ERR_NOSUCHNICK, nil, nick, "No such nick/channel"
		end
	end

	private
	def check_timeline
		first = true unless @prev_time
		@prev_time = Time.at(0) if first
		api("statuses/friends_timeline.json", {"since" => [@prev_time.httpdate] }).reverse_each do |s|
			nick = s["user"]["screen_name"]
			mesg = s["text"]
			time = Time.parse(s["created_at"]) rescue Time.now
			m = { "&quot;" => "\"", "&lt;"=> "<", "&gt;"=> ">", "&amp;"=> "&", "\n" => " "}
			mesg.gsub!(/(#{m.keys.join("|")})/) { m[$1] }

			digest = Digest::MD5.hexdigest("#{nick}::#{mesg}")
			unless @timeline.include?(digest)
				@timeline << digest
				@log.debug [nick, mesg, time].inspect
				if nick == @nick # 自分のときは topic に
					post nick, TOPIC, @@channel, mesg
				else
					message(nick, @@channel, mesg)
				end
				@groups.each do |channel,members|
					if members.include?(nick)
						message(nick, channel, mesg)
					end
				end
			end
		end
		@timeline  = @timeline.last(100)
		@prev_time = Time.now
	end

	def check_direct_messages
		first = true unless @prev_time_d
		@prev_time_d = Time.now if first
		api("direct_messages.json", {"since" => [@prev_time_d.httpdate] }).reverse_each do |s|
			nick = s["sender_screen_name"]
			mesg = s["text"]
			time = Time.parse(s["created_at"])
			@log.debug [nick, mesg, time].inspect
			message(nick, @nick, mesg)
		end
		@prev_time_d = Time.now
	end

	def check_friends
		first = true unless @friends
		@friends ||= []
		friends = api("statuses/friends.json")
		if first && !@opts.include?("athack")
			@friends = friends
			post nil, RPL_NAMREPLY,   @@name, @nick, "=", @@channel, @friends.map{|i| i["screen_name"] }.join(" ")
			post nil, RPL_ENDOFNAMES, @@name, @nick, @@channel, "End of NAMES list"
		else
			prv_friends = @friends.map {|i| i["screen_name"] }
			now_friends = friends.map {|i| i["screen_name"] }
			(now_friends - prv_friends).each do |join|
				join = "@#{join}" if @opts.include?("athack")
				post "#{join}!#{join}@#{@@api_base.host}", JOIN, @@channel
			end
			(prv_friends - now_friends).each do |part|
				part = "@#{part}" if @opts.include?("athack")
				post "#{part}!#{part}@#{@@api_base.host}", PART, @@channel, ""
			end
			@friends = friends
		end
	end

	def save_config
		config = {
			:channels => @channels,
			:groups => @groups,
		}
		@config.open("w") do |f|
			YAML.dump(config, f)
		end
	end

	def load_config
		@config.open do |f|
			config = YAML.load(f)
			@channels = config[:channels]
			@groups   = config[:groups]
		end
	rescue Errno::ENOENT
	end

	def api(path, q={})
		ret = {}
		q["source"] = "tigrb"
		q = q.inject([]) {|r,(k,v)| v.inject(r) {|r,i| r << "#{k}=#{URI.escape(i, /./)}" } }.join("&")
		uri = @@api_base + "/#{path}?#{q}"
		@log.debug uri.inspect
		Net::HTTP.start(uri.host, uri.port) do |http|
			header = {
				'Authorization' => "Basic " + ["#{@real}:#{@pass}"].pack("m"),
			}
			case path
			when "statuses/update.json", "direct_messages/new.json"
				ret = http.post(uri.request_uri, q, header)
			else
				ret = http.get(uri.request_uri, header)
			end
		end
		@log.debug ret.inspect
		case ret.code
		when "200"
			JSON.parse(ret.body)
		when "304"
			[]
		else
			raise ApiFailed, "Server Returned #{ret.code}"
		end
	rescue Errno::ETIMEDOUT, JSON::ParserError, IOError, Timeout::Error, Errno::ECONNRESET => e
		raise ApiFailed, e.inspect
	end

	def message(sender, target, str)
#			str.gsub!(/&#(x)?([0-9a-f]+);/i) do |m|
#				[$1 ? $2.hex : $2.to_i].pack("U")
#			end
		str = untinyurl(str)
		sender =  "#{sender}!#{sender}@#{@@api_base.host}"
		post sender, PRIVMSG, target, str
	end

	def log(str)
		str.gsub!(/\n/, " ")
		post @@name, NOTICE, @@channel, str
	end

	def untinyurl(text)
		text.gsub(%r|http://tinyurl.com/[0-9a-z=]+|i) {|m|
			uri = URI(m)
			Net::HTTP.start(uri.host, uri.port) {|http|
				http.head(uri.request_uri)["Location"]
			}
		}
	end
end

if __FILE__ == $0
	Net::IRC::Server.new("localhost", 16668, TwitterIrcGateway).start
end



