#!/usr/bin/env ruby
=begin
# hig.rb

## Launch

	$ ruby hig.rb

If you want to help:

	$ ruby hig.rb --help

## Configuration

Options specified by after irc realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	haiku {
		host: localhost
		port: 16679
		name: username@example.com athack jabber=username@example.com:jabberpasswd tid=10 ratio=10:3:5
		password: password on Haiku
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

class HaikuIrcGateway < Net::IRC::Server::Session
	def server_name
		"haikugw"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#haiku"
	end

	def api_base
		URI(ENV["HAIKU_BASE"] || "http://h.hatena.ne.jp/api/")
	end

	def api_source
		"hig.rb"
	end

	def jabber_bot_id
		nil
	end

	def hourly_limit
		60
	end

	class ApiFailed < StandardError; end

	def initialize(*args)
		super
		@channels   = {}
		@user_agent = "#{self.class}/#{server_version} (hig.rb)"
		@map        = nil
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

		timeline_ratio, friends_ratio, channel_ratio = (@opts["ratio"] || "10:3:5").split(":").map {|ratio| ratio.to_i }
		footing = (timeline_ratio + friends_ratio + channel_ratio).to_f

		@timeline = []
		@check_follows_thread = Thread.start do
			loop do
				begin
					check_friends
					check_keywords
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
			sleep 10
			loop do
				begin
					check_timeline
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
	end

	def on_disconnected
		@check_follows_thread.kill  rescue nil
		@check_timeline_thread.kill rescue nil
		@im_thread.kill             rescue nil
		@im.disconnect              rescue nil
	end

	def on_privmsg(m)
		return on_ctcp(m[0], ctcp_decoding(m[1])) if m.ctcp?
		retry_count = 3
		ret = nil
		target, message = *m.params
		begin
			channel = target.sub(/^#/, "")
			reply   = message[/\s+>(.+)$/, 1]
			if !reply && @opts.key?("alwaysim") && @im && @im.connected? # in jabber mode, using jabber post
				message = "##{channel} #{message}" unless "##{channel}" == main_channel
				ret = @im.deliver(jabber_bot_id, message)
				post "#{nick}!#{nick}@#{api_base.host}", TOPIC, channel, message
			else
				channel = "" if "##{channel}" == main_channel
				rid = rid_for(reply) if reply
				ret = api("statuses/update", {"status" => message, "in_reply_to_status_id" => rid, "keyword" => channel})
				log "Status Updated via API"
			end
			raise ApiFailed, "API failed" unless ret
			check_timeline
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
				post nick, NOTICE, main_channel, s
			end

			unless res
				post nil, ERR_NOSUCHNICK, nick, "No such nick/channel"
			end
		when "fav"
			target = args[0]
			st  = @tmap[target]
			id  = rid_for(target)
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
							id = res[pos]["id"]
						else
							raise ApiFailed, "#{pos} of #{nick} is not found."
						end
					else
						id = st["id"]
					end
				end
				res = api("favorites/create/#{id}", {})
				post nil, NOTICE, main_channel, "Fav: #{res["screen_name"]}: #{res["text"]}"
			else
				post nil, NOTICE, main_channel, "No such id or status #{target}"
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
			begin
				api("keywords/create/#{URI.escape(channel.sub(/^#/, ""))}.json")
				@channels[channel] = {
					:read => []
				}
				post "#{@nick}!#{@nick}@#{api_base.host}", JOIN, channel
			rescue => e
				@log.debug e.inspect
				post nil, ERR_NOSUCHNICK, nick, "No such nick/channel"
			end
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel == main_channel
		@channels.delete(channel)
		api("keywords/destroy/#{URI.escape(channel.sub(/^#/, ""))}.json")
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
		api("statuses/public_timeline", {"since" => @prev_time.httpdate }).reverse_each do |s|
			begin
				id = s["id"]
				next if id.nil? || @timeline.include?(id)
				@timeline << id
				nick = s["user"]["id"]
				mesg = generate_status_message(s)

				tid = @tmap.push(s)

				@log.debug [id, nick, mesg]

				channel = "##{s["keyword"]}"
				case
				when s["keyword"].match(/^id:/)
					channel = main_channel
				when !@channels.keys.include?(channel)
					channel = main_channel
					mesg = "%s: %s" % [s["keyword"], mesg]
				end

				if nick == @nick # 自分のときは topic に
					post "#{nick}!#{nick}@#{api_base.host}", TOPIC, channel, mesg
				else
					if @opts["tid"]
						message(nick, channel, "%s \x03%s [%s]" % [mesg, @opts["tid"], tid])
					else
						message(nick, channel, "%s" % [mesg, tid])
					end
				end
			rescue => e
				@log.debug "Error: %p" % e
			end
		end
		@prev_time = Time.now
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline  = @timeline.last(100)
	end

	def generate_status_message(s)
		mesg = s["text"]
		mesg.sub!("#{s["keyword"]}=", "") unless s["keyword"] =~ /^id:/
		mesg << " > #{s["in_reply_to_user_id"]}" unless s["in_reply_to_user_id"].empty?

		@log.debug(mesg)
		mesg
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

	def check_keywords
		keywords = api("statuses/keywords").map {|i| "##{i["title"]}" }
		current  = @channels.keys
		current.delete main_channel

		(current - keywords).each do |part|
			@channels.delete(part)
			post "#{@nick}!#{@nick}@#{api_base.host}", PART, part
		end

		(keywords - current).each do |join|
			@channels[join] = {
				:read => []
			}
			post "#{@nick}!#{@nick}@#{api_base.host}", JOIN, join
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
							# Haiku -> 'nick(id): msg'
							body = msg.body.sub(/^(.+?)(?:\((.+?)\))?: /, "")
							if Regexp.last_match
								nick, id = Regexp.last_match.captures
								body = CGI.unescapeHTML(body)

								case
								when nick == "投稿完了"
									log "#{nick}: #{body}"
								when nick == "チャンネル投稿完了"
									log "#{nick}: #{body}"
								when body =~ /^#([a-z_]+)\s+(.+)$/i
									# channel message or not
									message(id || nick, "##{Regexp.last_match[1]}", Regexp.last_match[2])
								when nick == "photo" && body =~ %r|^http://haiku\.jp/user/([^/]+)/|
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
			%r|/update|,
			%r|/create|,
			%r|/destroy|,
		].any? {|i| i === path }
	end

	def api(path, q={})
		ret           = {}
		q["source"] ||= api_source

		uri = api_base.dup
		uri.path  = "/api/#{path}.json"
		uri.query = q.inject([]) {|r,(k,v)| v ? r << "#{k}=#{URI.escape(v, /[^:,-.!~*'()\w]/n)}" : r }.join("&")


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
			ret = JSON.parse(ret.body.gsub(/:'/, ':"').gsub(/',/, '",').gsub(/'(y(?:es)?|no?|true|false|null)'/, '"\1"'))
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
		sender = "#{sender}!#{sender}@#{api_base.host}"
		post sender, PRIVMSG, target, str.gsub(/\s+/, " ")
	end

	def log(str)
		str.gsub!(/\n/, " ")
		post server_name, NOTICE, main_channel, str
	end

	# return rid of most recent matched status with text
	def rid_for(text)
		target = Regexp.new(Regexp.quote(text.strip), "i")
		status = api("statuses/public_timeline").find {|i|
			next false if i["user"]["name"] == @nick # 自分は除外
			i["text"] =~ target
		}

		@log.debug "Looking up status contains #{text.inspect} -> #{status.inspect}"
		status ? status["id"] : nil
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
		:port  => 16679,
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
		Net::IRC::Server.new(opts[:host], opts[:port], HaikuIrcGateway, opts).start
#	end
end

# Local Variables:
# coding: utf-8
# End:
