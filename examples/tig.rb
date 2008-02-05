#!/usr/bin/env ruby
=begin

# tig.rb

Ruby version of TwitterIrcGateway
( http://www.misuzilla.org/dist/net/twitterircgateway/ )

## Launch

	$ ruby tig.rb # daemonized

If you want to help:

	$ ruby tig.rb --help

## Configuration

Options specified by after irc realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	twitter {
		host: localhost
		port: 16668
		name: username@example.com athack
		password: password on Twitter
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

### jabber=<jid>:<pass>

If `jabber=<jid>:<pass>` option specified,
use jabber to get friends timeline.

You must setup im notifing settings in the site and
install 'xmpp4r-simple' gem.

	$ sudo gem install xmpp4r-simple

Be careful for managing password.


## Licence

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

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

	class ApiFailed < StandardError; end

	def initialize(*args)
		super
		@groups = {}
		@channels = [] # join channels (groups)
		@user_agent = "#{self.class}/#{server_version} (tig.rb)"
		@config = Pathname.new(ENV["HOME"]) + ".tig"
		load_config
	end

	def on_user(m)
		super
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick

		@real, *@opts = @real.split(/\s+/)
		@opts ||= []

		jabber = @opts.find {|i| i =~ /^jabber=(\S+?):(\S+)/ }
		if jabber
			jid, pass = Regexp.last_match.captures
			jabber.replace("jabber=#{jid}:********")
			if jabber_bot_id
				begin
					require "xmpp4r-simple"
					start_jabber(jid, pass)
				rescue LoadError
					log "Failed to start Jabber."
					log "Installl 'xmpp4r-simple' gem or check your id/pass."
					finish
				end
			else
				jabber = nil
				log "This gateway does not support Jabber bot."
			end
		end

		@log.info "Client Options: #{@opts.inspect}"

		@timeline = []
		Thread.start do
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
				sleep 10 * 60
			end
		end
		sleep 3

		return if jabber

		Thread.start do
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
				ret = api("statuses/update", {"status" => message})
			else
				# direct message
				ret = api("direct_messages/new", {"user" => target, "text" => message})
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
		first = true unless @prev_time
		@prev_time = Time.at(0) if first
		api("statuses/friends_timeline", {"since" => [@prev_time.httpdate]}).reverse_each do |s|
			nick = s["user"]["screen_name"]
			mesg = s["text"]
			# display photo url(wassr only)
			if s.has_key?('photo_url')
				mesg += " #{s['photo_url']}"
			end
			# time = Time.parse(s["created_at"]) rescue Time.now
			m = { "&quot;" => "\"", "&lt;"=> "<", "&gt;"=> ">", "&amp;"=> "&", "\n" => " "}
			mesg.gsub!(/(#{m.keys.join("|")})/) { m[$1] }

			digest = Digest::MD5.hexdigest("#{nick}::#{mesg}")
			unless @timeline.include?(digest)
				@timeline << digest
				@log.debug [nick, mesg]
				if nick == @nick # 自分のときは topic に
					post nick, TOPIC, main_channel, mesg
				else
					message(nick, main_channel, mesg)
				end
				@groups.each do |channel,members|
					if members.include?(nick)
						message(nick, channel, mesg)
					end
				end
			end
		end
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline  = @timeline.last(100)
		@prev_time = Time.now
	end

	def check_direct_messages
		first = true unless @prev_time_d
		@prev_time_d = Time.now if first
		api("direct_messages", {"since" => [@prev_time_d.httpdate] }).reverse_each do |s|
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
		if first && !@opts.include?("athack")
			@friends = friends
			post nil, RPL_NAMREPLY,   @nick, "=", main_channel, @friends.map{|i| "@#{i["screen_name"]}" }.join(" ")
			post nil, RPL_ENDOFNAMES, @nick, main_channel, "End of NAMES list"
		else
			prv_friends = @friends.map {|i| i["screen_name"] }
			now_friends = friends.map {|i| i["screen_name"] }
			(now_friends - prv_friends).each do |join|
				join = "@#{join}" if @opts.include?("athack")
				post "#{join}!#{join}@#{api_base.host}", JOIN, main_channel
			end
			(prv_friends - now_friends).each do |part|
				part = "@#{part}" if @opts.include?("athack")
				post "#{part}!#{part}@#{api_base.host}", PART, main_channel, ""
			end
			@friends = friends
		end
	end

	def start_jabber(jid, pass)
		@log.info "Logging-in with #{jid} -> jabber_bot_id: #{jabber_bot_id}"
		im = Jabber::Simple.new(jid, pass)
		im.add(jabber_bot_id)
		Thread.start do
			loop do
				begin
					im.received_messages.each do |msg|
						@log.debug msg.inspect
						if msg.from.strip == jabber_bot_id
							body = msg.body.sub(/^(.+)(?:\((.+?)\))?: /, "")
							if Regexp.last_match
								nick, id = Regexp.last_match.captures
								message(nick, main_channel, body)
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
		path = path.sub(%r{^/*}, '/') << '.json'
		q["source"] = api_source
		q = q.inject([]) {|r,(k,v)| v.inject(r) {|r,i| r << "#{k}=#{URI.escape(i, /[^-.!~*'()\w]/n)}" } }.join("&")
		uri = api_base.dup
		uri.path  = path
		uri.query = q
		@log.debug uri.inspect
		Net::HTTP.start(uri.host, uri.port) do |http|
			header = {
				'Authorization' => "Basic " + ["#{@real}:#{@pass}"].pack("m"),
				'User-Agent'    => @user_agent,
			}
			case path
			when "/statuses/update.json", "/direct_messages/new.json"
				ret = http.post(uri.request_uri, q, header)
			else
				ret = http.get(uri.request_uri, header)
			end
		end
		@log.debug ret.inspect
		case ret.code
		when "200"
			JSON.parse(ret.body.gsub(/'(y(?:es)?|n(?:o)?|true|false|null)'/, '"\1"'))
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
		sender =  "#{sender}!#{sender}@#{api_base.host}"
		post sender, PRIVMSG, target, str
	end

	def log(str)
		str.gsub!(/\n/, " ")
		post server_name, NOTICE, main_channel, str
	end

	def untinyurl(text)
		text.gsub(%r|http://(preview\.)?tinyurl\.com/[0-9a-z=]+|i) {|m|
			uri = URI(m)
			uri.host = uri.host.sub($1, '') if $1
			Net::HTTP.start(uri.host, uri.port) {|http|
				http.open_timeout = 3
				begin
					http.head(uri.request_uri, { 'User-Agent' => @user_agent })["Location"]
				rescue Timeout::Error
					m
				end
			}
		}
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port  => 16668,
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

	daemonize(opts[:debug]) do
		Net::IRC::Server.new(opts[:host], opts[:port], TwitterIrcGateway, opts).start
	end
end

