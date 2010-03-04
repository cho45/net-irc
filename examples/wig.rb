#!/usr/bin/env ruby
# vim:encoding=UTF-8:
=begin

# wig.rb

wig.rb channel: http://wassr.jp/channel/wigrb

## Launch

	$ ruby wig.rb

If you want to help:

	$ ruby wig.rb --help

## Configuration

Options specified by after irc realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	wassr {
		host: localhost
		port: 16670
		name: username@example.com athack jabber=username@example.com:jabberpasswd tid=10 ratio=10:3:5
		password: password on Wassr
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

### ratio=<timeline>:<friends>:<channel>

## License

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" unless defined? ::Encoding # json use this

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
		@counters   = {} # for jabber fav
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

		@ratio   = Struct.new(:timeline, :friends, :channel).new(*(@opts["ratio"] || "10:3:5").split(":").map {|ratio| ratio.to_f })
		@footing = @ratio.inject {|r,i| r + i }

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
				sleep freq(@ratio[:friends] / @footing)
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
				sleep freq(@ratio[:timeline] / @footing)
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
				sleep freq(@ratio[:channel] / @footing)
			end
		end
	end

	def on_disconnected
		@check_friends_thread.kill  rescue nil
		@check_timeline_thread.kill rescue nil
		@check_channel_thread.kill  rescue nil
		@im_thread.kill             rescue nil
		@im.disconnect              rescue nil
	end

	def on_privmsg(m)
		return m.ctcps.each {|ctcp| on_ctcp(m[0], ctcp) } if m.ctcp?
		retry_count = 3
		ret = nil
		target, message = *m.params
		begin
			if target =~ /^#(.+)/
				channel = Regexp.last_match[1]
				reply   = message[/\s+>(.+)$/, 1]
				reply   = reply.force_encoding("UTF-8") if reply && reply.respond_to?(:force_encoding)
				if @utf7
					message = Iconv.iconv("UTF-7", "UTF-8", message).join
					message = message.force_encoding("ASCII-8BIT") if message.respond_to?(:force_encoding)
				end
				if !reply && @opts.key?("alwaysim") && @im && @im.connected? # in jabber mode, using jabber post
					message = "##{channel} #{message}" unless "##{channel}" == main_channel
					ret = @im.deliver(jabber_bot_id, message)
					post "#{nick}!#{nick}@#{api_base.host}", TOPIC, channel, untinyurl(message)
				else
					if "##{channel}" == main_channel
						rid = rid_for(reply) if reply
						ret = api("statuses/update", {"status" => message, "reply_status_rid" => rid})
					else
						ret = api("channel_message/update", {"name_en" => channel, "body" => message})
					end
					log "Status Updated via API"
				end
			else
				# direct message
				ret = api("direct_messages/new", {"user" => target, "text" => message})
			end
			raise ApiFailed, "API failed" unless ret
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
		when "utf7"
			begin
				require "iconv"
				@utf7 = !@utf7
				log "utf7 mode: #{@utf7 ? 'on' : 'off'}"
			rescue LoadError => e
				log "Can't load iconv."
			end
		when "list"
			nick = args[0]
			@log.debug([ nick, message ])
			res = api("statuses/user_timeline", { "id" => nick }).reverse_each do |s|
				@log.debug(s)
				post nick, NOTICE, main_channel, "#{generate_status_message(s)}"
			end

			unless res
				post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			end
		when "fav"
			target = args[0]
			st     = @tmap[target]
			id     = rid_for(target)
			if st || id
				unless id
					if @im && @im.connected?
						# IM のときはいろいろめんどうなことする
						nick, count = *st
						pos = @counters[nick] - count
						@log.debug "%p %s %d/%d => %d" % [
							st,
							nick,
							count,
							@counters[nick],
							pos
						]
						res = api("statuses/user_timeline", { "id" => nick })
						raise ApiFailed, "#{nick} may be private mode" if res.empty?
						if res[pos]
							id = res[pos]["rid"]
						else
							raise ApiFailed, "#{pos} of #{nick} is not found."
						end
					else
						id = st["rid"]
					end
				end
				res = api("favorites/create/#{id}", {})
				post server_name, NOTICE, main_channel, "Fav: #{target} (#{id}): #{res["status"]}"
			else
				post server_name, NOTICE, main_channel, "No such id or status #{target}"
			end
		when "link"
			tid = args[0]
			st  = @tmap[tid]
			if st
				st["link"] = (api_base + "/#{st["user"]["screen_name"]}/statuses/#{st["id"]}").to_s unless st["link"]
				post server_name, NOTICE, main_channel, st["link"]
			else
				post server_name, NOTICE, main_channel, "No such id #{tid}"
			end
		end
	rescue ApiFailed => e
		log e.inspect
	end; private :on_ctcp

	def on_whois(m)
		nick = m.params[0]
		f = (@friends || []).find {|i| i["screen_name"] == nick }
		if f
			post server_name, RPL_WHOISUSER,   @nick, nick, nick, api_base.host, "*", "#{f["name"]} / #{f["description"]}"
			post server_name, RPL_WHOISSERVER, @nick, nick, api_base.host, api_base.to_s
			post server_name, RPL_WHOISIDLE,   @nick, nick, "0", "seconds idle"
			post server_name, RPL_ENDOFWHOIS,  @nick, nick, "End of WHOIS list"
		else
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		channels.each do |channel|
			next if channel == main_channel
			res = api("channel/exists", { "name_en" => channel.sub(/^#/, "") })
			if res["exists"]
				@channels[channel] = {
					:read => []
				}
				post "#{@nick}!#{@nick}@#{api_base.host}", JOIN, channel
			else
				post server_name, ERR_NOSUCHNICK, channel, "No such nick/channel"
			end
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
				post server_name, RPL_WHOREPLY, @nick, channel, user, host, serv, nick, "H*@", "0 #{real}"
			end
			post server_name, RPL_ENDOFWHO, @nick, channel
		when @groups.key?(channel)
			@groups[channel].each do |name|
				f = @friends.find {|i| i["screen_name"] == name }
				user = nick = f["screen_name"]
				host = serv = api_base.host
				real = f["name"]
				post server_name, RPL_WHOREPLY, @nick, channel, user, host, serv, nick, "H*@", "0 #{real}"
			end
			post server_name, RPL_ENDOFWHO, @nick, channel
		else
			post server_name, ERR_NOSUCHNICK, @nick, nick, "No such nick/channel"
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
				begin
					id = Digest::MD5.hexdigest(s["user"]["login_id"] + s["body"])
					next if @channels[channel][:read].include?(id)
					@channels[channel][:read] << id
					nick = s["user"]["login_id"]
					mesg = s["body"]

					if nick == @nick
						post nick, NOTICE, channel, mesg
					else
						message(nick, channel, mesg)
					end
				rescue Execepton => e
					post server_name, NOTICE, channel, e.inspect
				end
			end
			@channels[channel][:read] = @channels[channel][:read].last(100)
		end
	end

	def generate_status_message(status)
		s = status
		mesg = s["text"]
		@log.debug(mesg)

		begin
			require 'iconv'
			mesg = mesg.sub(/^.+ > |^.+/) {|str| Iconv.iconv("UTF-8", "UTF-7", str).join }
			mesg = "[utf7]: #{mesg}" if mesg =~ /[^a-z0-9\s]/i
		rescue LoadError
		rescue Iconv::IllegalSequence
		end

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
		friends = []
		1.upto(5) do |i|
			f = api("statuses/friends", {"page" => i.to_s})
			friends += f
			break if f.length < 100
		end
		if first && !@opts.key?("athack")
			@friends = friends
			post server_name, RPL_NAMREPLY,   @nick, "=", main_channel, @friends.map{|i| "@#{i["screen_name"]}" }.join(" ")
			post server_name, RPL_ENDOFNAMES, @nick, main_channel, "End of NAMES list"
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
							# Wassr -> 'nick(id): msg'
							body = msg.body.sub(/^(.+?)(?:\((.+?)\))?: /, "")
							if Regexp.last_match
								nick, id = Regexp.last_match.captures
								body = CGI.unescapeHTML(body)
								begin
									require 'iconv'
									body = body.sub(/^.+ > |^.+/) {|str| Iconv.iconv("UTF-8", "UTF-7", str).join }
									body = "[utf7]: #{body}" if body =~ /[^a-z0-9\s]/i
								rescue LoadError
								rescue Iconv::IllegalSequence
								end

								case
								when nick == "投稿完了"
									log "#{nick}: #{body}"
								when nick == "チャンネル投稿完了"
									log "#{nick}: #{body}"
								when body =~ /^#([a-z_]+)\s+(.+)$/i
									# channel message or not
									message(id || nick, "##{Regexp.last_match[1]}", Regexp.last_match[2])
								when nick == "photo" && body =~ %r|^http://wassr\.jp/user/([^/]+)/|
									nick = Regexp.last_match[1]
									message(nick, main_channel, body)
								else
									@counters[nick] ||= 0
									@counters[nick] += 1
									tid = @tmap.push([nick, @counters[nick]])
									message(nick, main_channel, "%s \x03%s [%s]" % [body, @opts["tid"], tid])
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
		[
			"statuses/update",
			"direct_messages/new",
			"channel_message/update",
			%r|^favorites/create|,
		].any? {|i| i === path }
	end

	def api(path, q={})
		ret           = {}
		q["source"] ||= api_source

		uri = api_base.dup
		uri.path  = "/#{path}.json"
		uri.query = q.inject([]) {|r,(k,v)| v ? r << "#{k}=#{URI.escape(v, /[^-.!~*'()\w]/n)}" : r }.join("&")


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
			ret = JSON.parse(ret.body)
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
			expanded = Net::HTTP.start(uri.host, uri.port) {|http|
				http.open_timeout = 3
				begin
					http.head(uri.request_uri, { "User-Agent" => @user_agent })["Location"] || m
				rescue Timeout::Error
					m
				end
			}
			expanded = URI(expanded)
			if %w|http https|.include? expanded.scheme 
				expanded.to_s
			else
				"#{expanded.scheme}: #{uri}"
			end
		}
	end

	# return rid of most recent matched status with text
	def rid_for(text)
		target = Regexp.new(Regexp.quote(text.strip), "i")
		status = api("statuses/friends_timeline").find {|i|
			next false if i["user_login_id"] == @nick # 自分は除外
			i["text"] =~ target
		}

		@log.debug "Looking up status contains #{text.inspect} -> #{status.inspect}"
		status ? status["rid"] : nil
	end

	class TypableMap < Hash
		Roman = %w[
			k g ky gy s z sh j t d ch n ny h b p hy by py m my y r ry w v q
		].unshift("").map do |consonant|
			case consonant
			when "y", /\A.{2}/ then %w|a u o|
			when "q"           then %w|a i e o|
			else                    %w|a i u e o|
			end.map {|vowel| "#{consonant}#{vowel}" }
		end.flatten

		def initialize(size = 1)
			@seq  = Roman
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
			@n %= @seq.size ** @size
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
		Net::IRC::Server.new(opts[:host], opts[:port], WassrIrcGateway, opts).start
#	end
end

# Local Variables:
# coding: utf-8
# End:
