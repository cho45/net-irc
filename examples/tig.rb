#!/usr/bin/env ruby
=begin

# tig.rb

Ruby version of TwitterIrcGateway
( http://www.misuzilla.org/dist/net/twitterircgateway/ )

## Launch

	$ ruby tig.rb

If you want to help:

	$ ruby tig.rb --help

## Configuration

Options specified by after irc realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	twitter {
		host: localhost
		port: 16668
		name: username@example.com athack jabber=username@example.com:jabberpasswd tid=10 ratio=32:1 replies=6
		password: password on Twitter
		in-encoding: utf8
		out-encoding: utf8
	}

### athack

If `athack` client option specified,
all nick in join message is leading with @.

So if you complemente nicks (e.g. Irssi),
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

Use IM instead of any APIs (e.g. post)

### ratio=<timeline>:<friends>

### replies[=<ratio>]

### maxlimit=<hourly limit>

### checkrls=<interval seconds>

## License

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

require "rubygems"
require "net/irc"
require "net/http"
require "net/https"
require "uri"
require "json"
require "socket"
require "time"
require "logger"
require "yaml"
require "pathname"
require "cgi"

Net::HTTP.version_1_2

class TwitterIrcGateway < Net::IRC::Server::Session
	def server_name
		"twittergw"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#twitter"
	end

	def api_base
		URI("http://twitter.com/")
	end

	def api_source
		"tigrb"
	end

	def jabber_bot_id
		"twitter@twitter.com"
	end

	def hourly_limit
		60
	end

	class ApiFailed < StandardError; end

	def initialize(*args)
		super
		@groups     = {}
		@channels   = [] # joined channels (groups)
		@user_agent = "#{self.class}/#{server_version} (tig.rb)"
		@config     = Pathname.new(ENV["HOME"]) + ".tig"
		@map        = nil
		load_config
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick

		@real, *@opts = @opts.name || @real.split(/\s+/)
		@opts = @opts.inject({}) {|r,i|
			key, value = i.split("=")
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

		@hourly_limit = hourly_limit

		@check_rate_limit_thread = Thread.start do
			loop do
				begin
					check_rate_limit
				rescue ApiFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep @opts["checkrls"] || 3600 # 1 hour
			end
		end
		sleep 5

		@ratio = Struct.new(:timeline, :friends, :replies).new(*(@opts["ratio"] || "10:3").split(":").map {|ratio| ratio.to_f })
		@ratio[:replies] = @opts.key?("replies") ? (@opts["replies"] || 5).to_f : 0.0

		footing = @ratio.inject {|sum, ratio| sum + ratio }

		@ratio.each_pair {|m, v| @ratio[m] = v / footing }

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
				sleep freq(@ratio[:friends])
			end
		end

		return if @opts["jabber"]

		sleep 3
		@check_timeline_thread = Thread.start do
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
				sleep freq(@ratio[:timeline])
			end
		end

		return unless @opts.key?("replies")

		sleep 10
		@check_replies_thread = Thread.start do
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
				sleep freq(@ratio[:replies])
			end
		end
	end

	def on_disconnected
		@check_friends_thread.kill    rescue nil
		@check_replies_thread.kill    rescue nil
		@check_timeline_thread.kill   rescue nil
		@check_rate_limit_thread.kill rescue nil
		@im_thread.kill               rescue nil
		@im.disconnect                rescue nil
	end

	def on_privmsg(m)
		return on_ctcp(m[0], ctcp_decoding(m[1])) if m.ctcp?
		retry_count = 3
		ret = nil
		target, message = *m.params
		begin
			if target =~ /^#/
				if @opts.key?("alwaysim") && @im && @im.connected? # in jabber mode, using jabber post
					ret = @im.deliver(jabber_bot_id, message)
					post "#{nick}!#{nick}@#{api_base.host}", TOPIC, main_channel, untinyurl(message)
				else
					ret = api("statuses/update", {"status" => message})
				end
			else
				# direct message
				ret = api("direct_messages/new", {"user" => target, "text" => message})
			end
			raise ApiFailed, "API failed" unless ret
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
#		when "ratios", "ratio"
#			if args.size < 2 ||
#			   @opts.key?("replies") && args.size < 3
#				return post nil, NOTICE, main_channel, "/me ratios <timeline> <frends>[ <replies>]"
#			end
#			ratios = args.map {|ratio| ratio.to_f }
#			if ratios.any? {|ratio| ratio <= 0.0 }
#				return post nil, NOTICE, main_channel, "Ratios must be greater than 0."
#			end
#			footing = ratios.inject {|sum, ratio| sum + ratio }
#			@ratio[:timeline] = ratios[0]
#			@ratio[:friends]  = ratios[1]
#			@ratio[:replies]  = ratios[2] || 0.0
#			@ratio.each_pair {|m, v| @ratio[m] = v / footing }
#			intervals = @ratio.map {|ratio| freq ratio }
#			post nil, NOTICE, main_channel, "Intervals: #{intervals.join(", ")}"
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

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		channels.each do |channel|
			next if channel == main_channel

			@channels << channel
			@channels.uniq!
			post "#{@nick}!#{@nick}@#{api_base.host}", JOIN, channel
			post server_name, MODE, channel, "+o", @nick
			save_config
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel == main_channel

		@channels.delete(channel)
		post @nick, PART, channel, "Ignore group #{channel}, but setting is alive yet."
	end

	def on_invite(m)
		nick, channel = *m.params
		return if channel == main_channel

		if (@friends || []).find {|i| i["screen_name"] == nick }
			((@groups[channel] ||= []) << nick).uniq!
			post "#{nick}!#{nick}@#{api_base.host}", JOIN, channel
			post server_name, MODE, channel, "+o", nick
			save_config
		else
			post ERR_NOSUCHNICK, nil, nick, "No such nick/channel"
		end
	end

	def on_kick(m)
		channel, nick, mes = *m.params
		return if channel == main_channel

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
		@prev_time ||= Time.at(0)
		api("statuses/friends_timeline", {"since" => @prev_time.httpdate}).reverse_each do |s|
			id = s["id"] || s["rid"]
			next if id.nil? || @timeline.include?(id)
			@timeline << id
			nick = s["user"]["screen_name"]
			mesg = generate_status_message(s)

			tid = @tmap.push(s)

			@log.debug [id, nick, mesg]
			if nick == @nick # 自分のときは TOPIC に
				post "#{nick}!#{nick}@#{api_base.host}", TOPIC, main_channel, untinyurl(mesg)
			else
				if @opts["tid"]
					message(nick, main_channel, "%s \x03%s [%s]" % [mesg, @opts["tid"], tid])
				else
					message(nick, main_channel, "%s" % [mesg, tid])
				end
			end
			@groups.each do |channel, members|
				if members.include?(nick)
					message(nick, channel, "%s [%s]" % [mesg, tid])
				end
			end
		end
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline  = @timeline.last(100)
		@prev_time = Time.now
	end

	def generate_status_message(status)
		s = status
		mesg = s["text"]
		@log.debug(mesg)

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

			# Twitter API bug?
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

	def check_rate_limit
		@log.debug rate_limit = api("account/rate_limit_status")
		if @hourly_limit != rate_limit["hourly_limit"]
			msg = "Rate limit was changed: #{@hourly_limit} to #{rate_limit["hourly_limit"]}"
			log msg
			@log.info msg
			@hourly_limit = rate_limit["hourly_limit"]
		end
		# rate_limit["remaining_hits"] < 1
		# rate_limit["reset_time_in_seconds"] - Time.now.to_i
	end

	def freq(ratio)
		max   = (@opts["maxlimit"] || 300).to_i
		limit = @hourly_limit < max ? @hourly_limit : max
		f     = 3600 / (limit * ratio).round
		@log.debug "Frequency: #{f}"
		f
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
							# Twitter -> 'id: msg'
							body = msg.body.sub(/^(.+?)(?:\((.+?)\))?: /, "")
							if Regexp.last_match
								nick, id = Regexp.last_match.captures
								body = CGI.unescapeHTML(body)
								message(id || nick, main_channel, body)
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

	def save_config
		config = {
			:channels => @channels,
			:groups   => @groups,
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
		ret     = {}
		headers = {
			"User-Agent"    => @user_agent,
			"Authorization" => "Basic " + ["#{@real}:#{@pass}"].pack("m"),
		}
		headers["If-Modified-Since"] = q["since"] if q.key?("since")

		q["source"] ||= api_source
		q = q.inject([]) {|r,(k,v)| v.inject(r) {|r,i| r << "#{k}=#{URI.escape(i, /[^-.!~*'()\w]/n)}" } }.join("&")

		uri = api_base.dup
		uri.path  = path.sub(%r{^/*}, "/") << ".json"
		uri.query = q

		@log.debug uri.inspect
		http = Net::HTTP.new(uri.host, uri.port)
		if uri.scheme == "https"
			http.use_ssl     = true
			http.verify_mode = OpenSSL::SSL::VERIFY_NONE # FIXME
		end
		http.start do
			case uri.path
			when "/statuses/update.json", "/direct_messages/new.json"
				ret = http.post(uri.request_uri, q, headers)
			else
				ret = http.get(uri.request_uri, headers)
			end
		end

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
#		str.gsub!(/&#(x)?([0-9a-f]+);/i) do
#			[$1 ? $2.hex : $2.to_i].pack("U")
#		end
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
		:port  => 16668,
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

#	def daemonize(foreground=false)
#		trap("SIGINT")  { exit! 0 }
#		trap("SIGTERM") { exit! 0 }
#		trap("SIGHUP")  { exit! 0 }
#		return yield if $DEBUG || foreground
#		Process.fork do
#			Process.setsid
#			Dir.chdir "/"
#			File.open("/dev/null") {|f|
#				STDIN.reopen  f
#				STDOUT.reopen f
#				STDERR.reopen f
#			}
#			yield
#		end
#		exit! 0
#	end

#	daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], TwitterIrcGateway, opts).start
#	end
end

# Local Variables:
# coding: utf-8
# End:
