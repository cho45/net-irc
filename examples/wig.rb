#!/usr/bin/env ruby
=begin

# wig.rb

## Launch

	$ ruby wig.rb

If you want to help:

	$ ruby wig.rb --help

## Configuration

Options specified by after irc realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	wassr {
		host: localhost
		port: 16668
		name: username@example.com athack jabber=username@example.com:jabberpasswd tid=10 ratio=32:1:6 replies
		password: password on wassr
		in-encoding: utf8
		out-encoding: utf8
	}

### athack

If `athack` client option specified,
all nick in join message is leading with @.

So if you complemente nicks (ex. Irssi),
it's good for Twitter like reply command (@nick).

In this case, you will see torrent of join messages after connected,
because NAMES list can't send @ leading nick (it interpreted op.)

### tid=<color>

Apply id to each message for make favorites by CTCP ACTION.

	/me fav id

<color> can be

	0  => white
	1  => black
	2  => blue         navy
	3  => green
	4  => red
	5  => brown        maroon
	6  => purple
	7  => orange       olive
	8  => yellow
	9  => lightgreen   lime
	10 => teal
	11 => lightcyan    cyan aqua
	12 => lightblue    royal
	13 => pink         lightpurple fuchsia
	14 => grey
	15 => lightgrey    silver


### jabber=<jid>:<pass>

If `jabber=<jid>:<pass>` option specified,
use jabber to get friends timeline.

You must setup im notifing settings in the site and
install "xmpp4r-simple" gem.

	$ sudo gem install xmpp4r-simple

Be careful for managing password.

### alwaysim

Use IM instead of any APIs (ex. post)

### ratio=<timeline>:<friends>[:<replies>]

### replies[=<ratio>]

### checkrls[=<interval seconds>]

## License

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

require "rubygems"
require "net/irc"
require "net/http"
require "uri"
require "json"
require "socket"
require "time"
require "logger"
require "yaml"
require "pathname"
require "cgi"
require "digest/md5"

Net::HTTP.version_1_2

class WassrIrcGateway < Net::IRC::Server::Session
	def server_name
		"wassrgw"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#wassr"
	end

	def api_base
		URI("http://api.wassr.jp/")
	end

	def api_source
		"wig.rb"
	end

	def jabber_bot_id
		"wassr-bot@wassr.jp"
	end

	def hourly_limit
		60
	end

	class ApiFailed < StandardError; end

	def initialize(*args)
		super
		@channels   = {}
		@user_agent = "#{self.class}/#{server_version} (wig.rb)"
		@map        = nil
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick

		@real, *@opts = @opts.name || @real.split(/\s+/)
		@opts = @opts.inject({}) {|r,i|
			key, value = i.split(/=/)
			r.update(key => value)
		}
		@tmap = TypableMap.new

		if @opts["jabber"]
			jid, pass = @opts["jabber"].split(":", 2)
			@opts["jabber"].replace("jabber=#{jid}:********")
			if jabber_bot_id
				begin
					require "xmpp4r-simple"
					start_jabber(jid, pass)
				rescue LoadError
					log "Failed to start Jabber."
					log 'Installl "xmpp4r-simple" gem or check your id/pass.'
					finish
				end
			else
				@opts.delete("jabber")
				log "This gateway does not support Jabber bot."
			end
		end

		log "Client Options: #{@opts.inspect}"
		@log.info "Client Options: #{@opts.inspect}"

		timeline_ratio, friends_ratio, channel_ratio = (@opts["ratio"] || "10:3:5").split(":", 3).map {|ratio| ratio.to_i }
		footing = (timeline_ratio + friends_ratio + channel_ratio).to_f

		if @opts.key?("replies")
			replies_ratio ||= (@opts["replies"] || 5).to_i
			footing += replies_ratio
		end

		@timeline = []
		@check_friends_thread = Thread.start do
			loop do
				begin
					check_friends
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep freq(friends_ratio / footing)
			end
		end

		return if @opts["jabber"]

		@check_timeline_thread = Thread.start do
			sleep 3
			loop do
				begin
					check_timeline
					# check_direct_messages
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep freq(timeline_ratio / footing)
			end
		end

		@check_channel_thread = Thread.start do
			sleep 5
			Thread.abort_on_exception= true
			loop do
				begin
					check_channel
					# check_direct_messages
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep freq(channel_ratio / footing)
			end
		end

		return unless @opts.key?("replies")

		@check_replies_thread = Thread.start do
			sleep 10
			loop do
				begin
					check_replies
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep freq(replies_ratio / footing)
			end
		end
	end

	def on_disconnected
		@check_friends_thread.kill    rescue nil
		@check_replies_thread.kill    rescue nil
		@check_timeline_thread.kill   rescue nil
		@check_channel_thread.kill    rescue nil
		@im_thread.kill               rescue nil
		@im.disconnect                rescue nil
	end

	def on_privmsg(m)
		return on_ctcp(m[0], ctcp_decoding(m[1])) if m.ctcp?
		retry_count = 3
		ret = nil
		target, message = *m.params
		begin
			if target =~ /^#(.+)/
				channel = Regexp.last_match[1]
				if @opts.key?("alwaysim") && @im && @im.connected? # in jabber mode, using jabber post
					message = "##{channel} #{message}" unless channel == main_channel
					ret = @im.deliver(jabber_bot_id, message)
					post "#{nick}!#{nick}@#{api_base.host}", TOPIC, channel, untinyurl(message)
				else
					if channel == main_channel
						ret = api("statuses/update", {"status" => message})
					else
						ret = api("channel_message/update", {"name_en" => channel, "body" => message})
					end
				end
			else
				# direct message
				ret = api("direct_messages/new", {"user" => target, "text" => message})
			end
			raise ApiFailed, "api failed" unless ret
			log "Status Updated" unless @im && @im.connected?
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

	def on_ctcp(target, message)
		_, command, *args = message.split(/\s+/)
		case command
		when "list"
			nick = args[0]
			@log.debug([ nick, message ])
			res = api("statuses/user_timeline", { "id" => nick }).reverse_each do |s|
				@log.debug(s)
				post nick, NOTICE, main_channel, "#{generate_status_message(s)}"
			end

			unless res
				post nil, ERR_NOSUCHNICK, nick, "No such nick/channel"
			end
		when "fav"
			tid = args[0]
			st  = @tmap[tid]
			if st
				id = st["id"] || st["rid"]
				res = api("favorites/create/#{id}", {})
				post nil, NOTICE, main_channel, "Fav: #{res["screen_name"]}: #{res["text"]}"
			else
				post nil, NOTICE, main_channel, "No such id #{tid}"
			end
		when "link"
			tid = args[0]
			st  = @tmap[tid]
			if st
				st["link"] = (api_base + "/#{st["user"]["screen_name"]}/statuses/#{st["id"]}").to_s unless st["link"]
				post nil, NOTICE, main_channel, st["link"]
			else
				post nil, NOTICE, main_channel, "No such id #{tid}"
			end
		end
	rescue ApiFailed => e
		log e.inspect
	end

	def on_whois(m)
		nick = m.params[0]
		f = (@friends || []).find {|i| i["screen_name"] == nick }
		if f
			post nil, RPL_WHOISUSER,   @nick, nick, nick, api_base.host, "*", "#{f["name"]} / #{f["description"]}"
			post nil, RPL_WHOISSERVER, @nick, nick, api_base.host, api_base.to_s
			post nil, RPL_WHOISIDLE,   @nick, nick, "0", "seconds idle"
			post nil, RPL_ENDOFWHOIS,  @nick, nick, "End of WHOIS list"
		else
			post nil, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		channels.each do |channel|
			next if channel == main_channel
			@channels[channel] = {
				:read => []
			}
			post "#{@nick}!#{@nick}@#{api_base.host}", JOIN, channel
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel == main_channel
		@channels.delete(channel)
		post "#{@nick}!#{@nick}@#{api_base.host}", PART, channel
	end

	def on_who(m)
		channel = m.params[0]
		case
		when channel == main_channel
			#     "<channel> <user> <host> <server> <nick>
			#         ( "H" / "G" > ["*"] [ ( "@" / "+" ) ]
			#             :<hopcount> <real name>"
			@friends.each do |f|
				user = nick = f["screen_name"]
				host = serv = api_base.host
				real = f["name"]
				post nil, RPL_WHOREPLY, @nick, channel, user, host, serv, nick, "H*@", "0 #{real}"
			end
			post nil, RPL_ENDOFWHO, @nick, channel
		when @groups.key?(channel)
			@groups[channel].each do |name|
				f = @friends.find {|i| i["screen_name"] == name }
				user = nick = f["screen_name"]
				host = serv = api_base.host
				real = f["name"]
				post nil, RPL_WHOREPLY, @nick, channel, user, host, serv, nick, "H*@", "0 #{real}"
			end
			post nil, RPL_ENDOFWHO, @nick, channel
		else
			post nil, ERR_NOSUCHNICK, @nick, nick, "No such nick/channel"
		end
	end

	private
	def check_timeline
		@prev_time ||= Time.at(0)
		api("statuses/friends_timeline", {"since" => @prev_time.httpdate}).reverse_each do |s|
			id = s["id"] || s["rid"]
			next if id.nil? || @timeline.include?(id)
			@timeline << id
			nick = s["user_login_id"]
			mesg = generate_status_message(s)

			tid = @tmap.push(s)

			@log.debug [id, nick, mesg]
			if nick == @nick # 自分のときは topic に
				post "#{nick}!#{nick}@#{api_base.host}", TOPIC, main_channel, untinyurl(mesg)
			else
				if @opts["tid"]
					message(nick, main_channel, "%s \x03%s [%s]" % [mesg, @opts["tid"], tid])
				else
					message(nick, main_channel, "%s" % [mesg, tid])
				end
			end
		end
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline  = @timeline.last(100)
		@prev_time = Time.now
	end

	def check_channel
		@channels.keys.each do |channel|
			@log.debug "getting channel -> #{channel}..."
			api("channel_message/list", { "name_en" => channel.sub(/^#/, "") }).reverse_each do |s|
				id = Digest::MD5.hexdigest(s["user"]["login_id"] + s["body"])
				next @channels[channel][:read].include?(id)
				@channels[channel][:read] << id
				nick = s["user"]["login_id"]
				mesg = s["body"]

				if nick == @nick
					# TODO
				else
					message(nick, channel, mesg)
				end
			end
			@channels[channel][:read] = @channels[channel][:read].last(100)
		end
	end

	def generate_status_message(status)
		s = status
		mesg = s["text"]
		@log.debug(mesg)

		# added @user in no use @user reply message (Wassr only)
		if s.has_key?("reply_status_url") and s["reply_status_url"] and s["text"] !~ /^@.*/ and %r{([^/]+)/statuses/[^/]+}.match(s["reply_status_url"])
			reply_user_id = $1
			mesg = "@#{reply_user_id} #{mesg}"
		end
		# display area name (Wassr only)
		if s.has_key?("areaname") and s["areaname"]
			mesg += " L: #{s["areaname"]}"
		end
		# display photo URL (Wassr only)
		if s.has_key?("photo_url") and s["photo_url"]
			mesg += " #{s["photo_url"]}"
		end

		# time = Time.parse(s["created_at"]) rescue Time.now
		m = { "&quot;" => "\"", "&lt;"=> "<", "&gt;"=> ">", "&amp;"=> "&", "\n" => " "}
		mesg.gsub!(/(#{m.keys.join("|")})/) { m[$1] }
		mesg
	end

	def check_replies
		@prev_time_r ||= Time.now
		api("statuses/replies").reverse_each do |s|
			id = s["id"] || s["rid"]
			next if id.nil? || @timeline.include?(id)
			time = Time.parse(s["created_at"]) rescue next
			next if time < @prev_time_r
			@timeline << id
			nick = s["user_login_id"] || s["user"]["screen_name"]
			mesg = generate_status_message(s)

			tid = @tmap.push(s)

			@log.debug [id, nick, mesg]
			if @opts["tid"]
				message(nick, main_channel, "%s \x03%s [%s]" % [mesg, @opts["tid"], tid])
			else
				message(nick, main_channel, "%s" % mesg)
			end
		end
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline    = @timeline.last(100)
		@prev_time_r = Time.now
	end

	def check_direct_messages
		@prev_time_d ||= Time.now
		api("direct_messages", {"since" => @prev_time_d.httpdate}).reverse_each do |s|
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
		friends = api("statuses/friends")
		if first && !@opts.key?("athack")
			@friends = friends
			post nil, RPL_NAMREPLY,   @nick, "=", main_channel, @friends.map{|i| "@#{i["screen_name"]}" }.join(" ")
			post nil, RPL_ENDOFNAMES, @nick, main_channel, "End of NAMES list"
		else
			prv_friends = @friends.map {|i| i["screen_name"] }
			now_friends = friends.map {|i| i["screen_name"] }

			# Twitter api bug?
			return if !first && (now_friends.length - prv_friends.length).abs > 10

			(now_friends - prv_friends).each do |join|
				join = "@#{join}" if @opts.key?("athack")
				post "#{join}!#{join}@#{api_base.host}", JOIN, main_channel
			end
			(prv_friends - now_friends).each do |part|
				part = "@#{part}" if @opts.key?("athack")
				post "#{part}!#{part}@#{api_base.host}", PART, main_channel, ""
			end
			@friends = friends
		end
	end

	def freq(ratio)
		ret = 3600 / (hourly_limit * ratio).round
		@log.debug "Frequency: #{ret}"
		ret
	end

	def start_jabber(jid, pass)
		@log.info "Logging-in with #{jid} -> jabber_bot_id: #{jabber_bot_id}"
		@im = Jabber::Simple.new(jid, pass)
		@im.add(jabber_bot_id)
		@im_thread = Thread.start do
			loop do
				begin
					@im.received_messages.each do |msg|
						@log.debug [msg.from, msg.body]
						if msg.from.strip == jabber_bot_id
							# Wassr   -> 'nick(id): msg'
							body = msg.body.sub(/^(.+?)(?:\((.+?)\))?: /, "")
							if Regexp.last_match
								nick, id = Regexp.last_match.captures
								body = CGI.unescapeHTML(body)

								# channel message or not
								if body =~ /^#([a-z_]+)\s+(.+)$/i
									message(id || nick, Regexp.last_match[1], Regexp.last_match[2])
								else
									message(id || nick, main_channel, body)
								end
							end
						end
					end
				rescue Exception => e
					@log.error "Error on Jabber loop: #{e.inspect}"
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep 1
			end
		end
	end

	def require_post?(path)
		%w|statuses/update direct_messages/new channel_message/update|.include?(path)
	end

	def api(path, q={})
		ret           = {}
		q["source"] ||= api_source

		uri = api_base.dup
		uri.path  = "/#{path}.json"
		uri.query = q.inject([]) {|r,(k,v)| v.inject(r) {|r,i| r << "#{k}=#{URI.escape(i, /[^-.!~*'()\w]/n)}" } }.join("&")


		req = nil
		if require_post?(path)
			req = Net::HTTP::Post.new(uri.path)
			req.body = uri.query
		else
			req = Net::HTTP::Get.new(uri.request_uri)
		end
		req.basic_auth(@real, @pass)
		req["User-Agent"]        = @user_agent
		req["If-Modified-Since"] = q["since"] if q.key?("since")

		@log.debug uri.inspect
		ret = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }

		case ret
		when Net::HTTPOK # 200
			ret = JSON.parse(ret.body.gsub(/'(y(?:es)?|no?|true|false|null)'/, '"\1"'))
			raise ApiFailed, "Server Returned Error: #{ret["error"]}" if ret.kind_of?(Hash) && ret["error"]
			ret
		when Net::HTTPNotModified # 304
			[]
		when Net::HTTPBadRequest # 400
			# exceeded the rate limitation
			raise ApiFailed, "#{ret.code}: #{ret.message}"
		else
			raise ApiFailed, "Server Returned #{ret.code} #{ret.message}"
		end
	rescue Errno::ETIMEDOUT, JSON::ParserError, IOError, Timeout::Error, Errno::ECONNRESET => e
		raise ApiFailed, e.inspect
	end

	def message(sender, target, str)
		str    = untinyurl(str)
		sender = "#{sender}!#{sender}@#{api_base.host}"
		post sender, PRIVMSG, target, str
	end

	def log(str)
		str.gsub!(/\n/, " ")
		post server_name, NOTICE, main_channel, str
	end

	def untinyurl(text)
		text.gsub(%r|http://(preview\.)?tinyurl\.com/[0-9a-z=]+|i) {|m|
			uri = URI(m)
			uri.host = uri.host.sub($1, "") if $1
			Net::HTTP.start(uri.host, uri.port) {|http|
				http.open_timeout = 3
				begin
					http.head(uri.request_uri, { "User-Agent" => @user_agent })["Location"] || m
				rescue Timeout::Error
					m
				end
			}
		}
	end

	class TypableMap < Hash
		Roma = %w|k g ky gy s z sh j t d ch n ny h b p hy by py m my y r ry w v q|.unshift("").map {|consonant|
			case
			when consonant.size > 1, consonant == "y"
				%w|a u o|
			when consonant == "q"
				%w|a i e o|
			else
				%w|a i u e o|
			end.map {|vowel| "#{consonant}#{vowel}" }
		}.flatten

		def initialize(size=1)
			@seq  = Roma
			@map  = {}
			@n    = 0
			@size = size
		end

		def generate(n)
			ret = []
			begin
				n, r = n.divmod(@seq.size)
				ret << @seq[r]
			end while n > 0
			ret.reverse.join
		end

		def push(obj)
			id = generate(@n)
			self[id] = obj
			@n += 1
			@n = @n % (@seq.size ** @size)
			id
		end
		alias << push

		def clear
			@n = 0
			super
		end

		private :[]=
		undef update, merge, merge!, replace
	end


end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 16670,
		:host  => "localhost",
		:log   => nil,
		:debug => false,
		:foreground => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner = <<-EOB.gsub(/^\t+/, "")
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

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			on("-f", "--foreground", "run foreground") do |foreground|
				opts[:log]        = $stdout
				opts[:foreground] = true
			end

			on("-n", "--name [user name or email address]") do |name|
				opts[:name] = name
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

	def daemonize(foreground=false)
		trap("SIGINT")  { exit! 0 }
		trap("SIGTERM") { exit! 0 }
		trap("SIGHUP")  { exit! 0 }
		return yield if $DEBUG || foreground
		Process.fork do
			Process.setsid
			Dir.chdir "/"
			File.open("/dev/null") {|f|
				STDIN.reopen  f
				STDOUT.reopen f
				STDERR.reopen f
			}
			yield
		end
		exit! 0
	end

#	daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], WassrIrcGateway, opts).start
#	end
end

# Local Variables:
# coding: utf-8
# End:
