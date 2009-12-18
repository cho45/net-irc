#!/usr/bin/env ruby
# vim:encoding=UTF-8:
$KCODE = "u" unless defined? ::Encoding # json use this
=begin

# tig.rb

Ruby version of TwitterIrcGateway
<http://www.misuzilla.org/dist/net/twitterircgateway/>

## Launch

	$ ruby tig.rb

If you want to help:

	$ ruby tig.rb --help

## Configuration

Options specified by after IRC realname.

Configuration example for Tiarra <http://coderepos.org/share/wiki/Tiarra>.

	general {
		server-in-encoding: utf8
		server-out-encoding: utf8
		client-in-encoding: utf8
		client-out-encoding: utf8
	}

	networks {
		name: tig
	}

	tig {
		server: localhost 16668
		password: password on Twitter
		# Recommended
		name: username mentions tid

		# Same as TwitterIrcGateway.exe.config.sample
		#   (90, 360 and 300 seconds)
		#name: username dm ratio=4:1 maxlimit=50
		#name: username dm ratio=20:5:6 maxlimit=62 mentions
		#
		# <http://cheebow.info/chemt/archives/2009/04/posttwit.html>
		#   (60, 360 and 150 seconds)
		#name: username dm ratio=30:5:12 maxlimit=94 mentions
		#
		# <http://cheebow.info/chemt/archives/2009/07/api150rhtwit.html>
		#   (36, 360 and 150 seconds)
		#name: username dm ratio=50:5:12 maxlimit=134 mentions
		#
		# for Jabber
		#name: username jabber=username@example.com:jabberpasswd
	}

### athack

If `athack` client option specified,
all nick in join message is leading with @.

So if you complemente nicks (e.g. Irssi),
it's good for Twitter like reply command (@nick).

In this case, you will see torrent of join messages after connected,
because NAMES list can't send @ leading nick (it interpreted op.)

### tid[=<color:10>[,<bgcolor>]]

Apply ID to each message for make favorites by CTCP ACTION.

	/me fav [ID...]

<color> and <bgcolor> can be

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
use Jabber to get friends timeline.

You must setup im notifing settings in the site and
install "xmpp4r-simple" gem.

	$ sudo gem install xmpp4r-simple

Be careful for managing password.

### alwaysim

Use IM instead of any APIs (e.g. post)

### ratio=<timeline>:<dm>[:<mentions>]

"121:6:20" by default.

	/me ratios

	   Ratio | Timeline |   DM  | Mentions |
	---------+----------+-------+----------|
	       1 |      24s |   N/A |      N/A |
	   141:6 |      26s |   10m OR N/A     |
	  135:12 |      27s |    5m OR N/A     |
	 135:6:6 |      27s |   10m |      10m |
	---------+----------+-------+----------|
	121:6:20 |      30s |   10m |       3m |
	---------+----------+-------+----------|
	     4:1 |      31s |  2m1s |      N/A |
	 50:5:12 |      49s | 8m12s |    3m25s |
	  20:5:6 |      57s | 3m48s |    3m10s |
	 30:5:12 |      58s | 5m45s |    2m24s |
	   1:1:1 |    1m13s | 1m13s |    1m13s |
	---------------------------------------+
	                    (Hourly limit: 150)

### dm[=<ratio>]

### mentions[=<ratio>]

### maxlimit=<hourly_limit>

### clientspoofing

### httpproxy=[<user>[:<password>]@]<address>[:<port>]

### main_channel=<channel:#twitter>

### api_source=<source>

### check_friends_interval=<seconds:3600>

### check_updates_interval=<seconds:86400>

Set 0 to disable checking.

### old_style_reply

### tmap_size=<number:10404>

### strftime=<format:%m-%d %H:%M>

### untiny_whole_urls

### bitlify=<username>:<apikey>:<minlength:20>

### unuify

### shuffled_tmap

### ll=<lat>,<long>

### with_retweets

## Extended commands through the CTCP ACTION

### list (ls)

	/me list NICK [NUMBER]

### fav (favorite, favourite, unfav, unfavorite, unfavourite)

	/me fav [ID...]
	/me unfav [ID...]
	/me fav! [ID...]
	/me fav NICK

### link (ln, url, u)

	/me link ID [ID...]

### destroy (del, delete, miss, oops, remove, rm)

	/me destroy [ID...]

### in (location)

	/me in Sugamo, Tokyo, Japan

### reply (re, mention)

	/me reply ID blah, blah...

### retweet (rt)

	/me retweet ID (blah, blah...)

### utf7 (utf-7)

	/me utf7

### name

	/me name My Name

### description (desc)

	/me description blah, blah...

### spoof

	/me spoof
	/me spoo[o...]f
	/me spoof tigrb twitterircgateway twitt web mobileweb

### bot (drone)

	/me bot NICK [NICK...]

### spam
report user as spammer

	/me spam <NICK>|<ID>

## Feed

<http://coderepos.org/share/log/lang/ruby/net-irc/trunk/examples/tig.rb?limit=100&mode=stop_on_copy&format=rss>

## License

Ruby's by cho45

=end

case
when File.directory?("lib")
	$LOAD_PATH << "lib"
when File.directory?(File.expand_path("lib", ".."))
	$LOAD_PATH << File.expand_path("lib", "..")
end

require "rubygems"
require "net/irc"
require "net/https"
require "uri"
require "time"
require "logger"
require "yaml"
require "pathname"
require "ostruct"
require "json"

begin
	require "iconv"
	require "punycode"
rescue LoadError
end

module Net::IRC::Constants; RPL_WHOISBOT = "335"; RPL_CREATEONTIME = "329"; end

class TwitterIrcGateway < Net::IRC::Server::Session
	@@ctcp_action_commands = []

	class << self
		def ctcp_action(*commands, &block)
			name = "+ctcp_action_#{commands.inspect}"
			define_method(name, block)
			commands.each do |command|
				@@ctcp_action_commands << [command, name]
			end
		end
	end

	def server_name
		"twittergw"
	end

	def server_version
		@server_version ||= instance_eval {
			head = `git rev-parse HEAD 2>/dev/null`.chomp
			head.empty?? "unknown" : head
		}
	end

	def available_user_modes
		"o"
	end

	def available_channel_modes
		"mnti"
	end

	def main_channel
		@opts.main_channel || "#twitter"
	end

	def api_base(secure = true)
		URI("http#{"s" if secure}://twitter.com/")
	end

	def api_source
		"#{@opts.api_source || "tigrb"}"
	end

	def jabber_bot_id
		"twitter@twitter.com"
	end

	def hourly_limit
		150
	end

	class APIFailed < StandardError; end

	MAX_MODE_PARAMS = 3
	WSP_REGEX       = Regexp.new("\\r\\n|[\\r\\n\\t#{"\\u00A0\\u1680\\u180E\\u2002-\\u200D\\u202F\\u205F\\u2060\\uFEFF" if "\u0000" == "\000"}]")

	def initialize(*args)
		super
		@channels      = {}
		@nicknames     = {}
		@drones        = []
		@etags         = {}
		@consums       = []
		@follower_ids  = []
		@limit         = hourly_limit
		@friends       =
		@sources       =
		@rsuffix_regex =
		@im            =
		@im_thread     =
		@utf7          =
		@httpproxy     = nil
		@ratelimit     = RateLimit.new(150)
		@cert_store = OpenSSL::X509::Store.new
		@cert_store.set_default_paths
	end

	def on_user(m)
		super

		@real, *@opts = (@opts.name || @real).split(" ")
		@opts = @opts.inject({}) do |r, i|
			key, value = i.split("=", 2)
			key = "mentions" if key == "replies" # backcompat
			r.update key => case value
				when nil                      then true
				when /\A\d+\z/                then value.to_i
				when /\A(?:\d+\.\d*|\.\d+)\z/ then value.to_f
				else                               value
			end
		end
		@opts = OpenStruct.new(@opts)
		@opts.httpproxy.sub!(/\A(?:([^:@]+)(?::([^@]+))?@)?([^:]+)(?::(\d+))?\z/) do
			@httpproxy = OpenStruct.new({
				:user => $1, :password => $2, :address => $3, :port => $4.to_i,
			})
			$&.sub(/[^:@]+(?=@)/, "********")
		end if @opts.httpproxy

		retry_count = 0
		begin
			@me = api("account/update_profile") #api("account/verify_credentials")
		rescue APIFailed => e
			@log.error e.inspect
			sleep 1
			retry_count += 1
			retry if retry_count < 3
			log "Failed to access API 3 times." <<
			    " Please check your username/email and password combination, " <<
			    " Twitter Status <http://status.twitter.com/> and try again later."
			finish
		end

		@prefix = prefix(@me)
		@user   = @prefix.user
		@host   = @prefix.host

		#post NICK, @me.screen_name if @nick != @me.screen_name
		post server_name, MODE, @nick, "+o"
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+mto", @nick
		post server_name, MODE, main_channel, "+q", @nick
		if @me.status
			@me.status.user = @me
			post @prefix, TOPIC, main_channel, generate_status_message(@me.status.text)
		end

		if @opts.jabber
			jid, pass = @opts.jabber.split(":", 2)
			@opts.jabber.replace("jabber=#{jid}:********")
			if jabber_bot_id
				begin
					require "xmpp4r-simple"
					start_jabber(jid, pass)
				rescue LoadError
					log "Failed to start Jabber."
					log 'Installl "xmpp4r-simple" gem or check your ID/pass.'
					finish
				end
			else
				@opts.delete_field :jabber
				log "This gateway does not support Jabber bot."
			end
		end

		log "Client options: #{@opts.marshal_dump.inspect}"
		@log.info "Client options: #{@opts.inspect}"

		@opts.tid = begin
			c = @opts.tid # expect: 0..15, true, "0,1"
			b = nil
			c, b = c.split(",", 2).map {|i| i.to_i } if c.respond_to? :split
			c = 10 unless (0 .. 15).include? c # 10: teal
			if (0 .. 15).include?(b)
				"\003%.2d,%.2d[%%s]\017" % [c, b]
			else
				"\003%.2d[%%s]\017"      % c
			end
		end if @opts.tid

		check_friends
		@ratelimit.register(:check_friends, 3600)
		@check_friends_thread = Thread.start do
			loop do
				sleep @rate.interval(:check_friends)
				begin
					check_friends
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
			end
		end

		return if @opts.jabber

		@timeline = TypableMap.new(@opts.tmap_size     || 10_404,
		                           @opts.shuffled_tmap || false)

		if @opts.clientspoofing
			update_sources
		else
			@sources = [api_source]
		end

		update_redundant_suffix
		@check_updates_thread = Thread.start do
			sleep 30

			loop do
				begin
					@log.info "check_updates"
					update_redundant_suffix
					check_updates
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep 0.01 * (90 + rand(21)) *
				      (@opts.check_updates_interval || 86400) # 0.9 ... 1.1 day
			end

			sleep @opts.check_updates_interval || 86400
		end

		@ratelimit.register(:timeline, 30)
		@check_timeline_thread = Thread.start do
			sleep 2 * (@me.friends_count / 100.0).ceil
			sleep 10

			loop do
				begin
					if check_timeline
						@ratelimit.incr(:timeline)
					else
						@ratelimit.decr(:timeline)
					end
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep @ratelimit.interval(:timeline)
			end
		end

		@ratelimit.register(:dm, 600)
		@check_dms_thread = Thread.start do
			loop do
				begin
					if check_direct_messages
						@ratelimit.incr(:dm)
					else
						@ratelimit.decr(:dm)
					end
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep @ratelimit.interval(:dm)
			end
		end if @opts.dm

		@ratelimit.register(:mentions, 180)
		@check_mentions_thread = Thread.start do
			sleep @ratelimit.interval(:timeline)

			loop do
				begin
					if check_mentions
						@ratelimit.incr(:mentions)
					else
						@ratelimit.decr(:mentions)
					end
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep @ratelimit.interval(:mentions)
			end
		end if @opts.mentions

		@ratelimit.register(:lists, 60 * 60)
		@check_lists_thread = Thread.start do
			sleep 60
			Thread.current[:last_updated] = Time.at(0)
			loop do
				begin
					@log.info "LISTS update now..."
					if check_lists
						@ratelimit.incr(:lists)
					else
						@ratelimit.decr(:lists)
					end
					Thread.current[:last_updated] = Time.now

					sleep @ratelimit.interval(:lists)
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
					sleep 60
				end
			end
		end

		@ratelimit.register(:lists_status, 60 * 5)
		@check_lists_status_thread = Thread.start do
			Thread.current[:last_updated] = Time.at(0)
			loop do
				begin
					@log.info "lists/status update now... #{@channels.size}"
					## TODO 各リストにつき limit が必要
					if check_lists_status
						@ratelimit.incr(:lists_status)
					else
						@ratelimit.decr(:lists_status)
					end
					Thread.current[:last_updated] = Time.now
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep @ratelimit.register(:lists_status)
			end
		end

	end

	def on_disconnected
		@check_friends_thread.kill      rescue nil
		@check_timeline_thread.kill     rescue nil
		@check_mentions_thread.kill     rescue nil
		@check_dms_thread.kill          rescue nil
		@check_updates_thread.kill      rescue nil
		@check_lists_thread.kill        rescue nil
		@check_lists_status_thread.kill rescue nil
		@im_thread.kill                 rescue nil
		@im.disconnect                  rescue nil
	end

	def on_privmsg(m)
		target, mesg = *m.params

		m.ctcps.each {|ctcp| on_ctcp(target, ctcp) } if m.ctcp?

		return if mesg.empty?
		return on_ctcp_action(target, mesg) if mesg.sub!(/\A +/, "") #and @opts.direct_action

		command, params = mesg.split(" ", 2)
		case command.downcase # TODO: escape recursive
		when "d", "dm"
			screen_name, mesg = params.split(" ", 2)
			unless screen_name or mesg
				log 'Send "d NICK message" to send a direct (private) message.' <<
				    " You may reply to a direct message the same way."
				return
			end
			m.params[0] = screen_name.sub(/\A@/, "")
			m.params[1] = mesg #.rstrip
			return on_privmsg(m)
		# TODO
		#when "f", "follow"
		#when "on"
		#when "off" # BUG if no args
		#when "g", "get"
		#when "w", "whois"
		#when "n", "nudge" # BUG if no args
		#when "*", "fav"
		#when "delete"
		#when "stats" # no args
		#when "leave"
		#when "invite"
		end unless command.nil?

		mesg = escape_http_urls(mesg)
		mesg = @opts.unuify ? unuify(mesg) : bitlify(mesg)
		mesg = Iconv.iconv("UTF-7", "UTF-8", mesg).join.encoding!("ASCII-8BIT") if @utf7

		ret         = nil
		retry_count = 3
		begin
			case
			when target.ch?
				if @opts.alwaysim and @im and @im.connected? # in Jabber mode, using Jabber post
					ret = @im.deliver(jabber_bot_id, mesg)
					post @prefix, TOPIC, main_channel, mesg
				else
					previous = @me.status
					if previous and
					   ((Time.now - Time.parse(previous.created_at)).to_i < 60 rescue true) and
					   mesg.strip == previous.text
						log "You can't submit the same status twice in a row."
						return
					end

					q = { :status => mesg, :source => source }

					if @opts.old_style_reply and mesg[/\A@(?>([A-Za-z0-9_]{1,15}))[^A-Za-z0-9_]/]
						if user = friend($1) || api("users/show/#{$1}")
							unless user.status
								user = api("users/show/#{user.id}", {},
								           { :authenticate => user.protected })
							end
							if user.status
								q.update :in_reply_to_status_id => user.status.id
							end
						end
					end
					if @opts.ll
						lat, long = @opts.ll.split(",", 2)
						q.update :lat  => lat.to_f
						q.update :long => long.to_f
					end

					ret = api("statuses/update", q)
					log oops(ret) if ret.truncated
					ret.user.status = ret
					@me = ret.user
					log "Status updated"
				end
			when target.screen_name? # Direct message
				ret = api("direct_messages/new", { :screen_name => target, :text => mesg })
				post server_name, NOTICE, @nick, "Your direct message has been sent to #{target}."
			else
				post server_name, ERR_NOSUCHNICK, target, "No such nick/channel"
			end
		rescue => e
			@log.error [retry_count, e.inspect].inspect
			if retry_count > 0
				retry_count -= 1
				@log.debug "Retry to setting status..."
				retry
			end
			log "Some Error Happened on Sending #{mesg}. #{e}"
		end
	end

	def on_whois(m)
		nick = m.params[0]
		unless nick.screen_name?
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			return
		end

		unless user = user(nick)
			if api("users/username_available", { :username => nick }).valid
			# TODO: 404 suspended
				post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
				return
			end
			user = api("users/show/#{nick}", {}, { :authenticate => false })
		end

		prefix    = prefix(user)
		desc      = user.name
		desc      = "#{desc} / #{user.description}".gsub(/\s+/, " ") if user.description and not user.description.empty?
		signon_at = Time.parse(user.created_at).to_i rescue 0
		idle_sec  = (Time.now - (user.status ? Time.parse(user.status.created_at) : signon_at)).to_i rescue 0
		location  = user.location
		location  = "SoMa neighborhood of San Francisco, CA" if location.nil? or location.empty?
		post server_name, RPL_WHOISUSER,   @nick, nick, prefix.user, prefix.host, "*", desc
		post server_name, RPL_WHOISSERVER, @nick, nick, api_base.host, location
		post server_name, RPL_WHOISIDLE,   @nick, nick, "#{idle_sec}", "#{signon_at}", "seconds idle, signon time"
		post server_name, RPL_ENDOFWHOIS,  @nick, nick, "End of WHOIS list"
		if @drones.include?(user.id)
			post server_name, RPL_WHOISBOT, @nick, nick, "is a \002Bot\002 on #{server_name}"
		end
	end

	def on_who(m)
		channel  = m.params[0]
		whoreply = Proc.new do |ch, user|
			#     "<channel> <user> <host> <server> <nick>
			#         ( "H" / "G" > ["*"] [ ( "@" / "+" ) ]
			#             :<hopcount> <real name>"
			prefix = prefix(user)
			server = api_base.host
			mode   = case prefix.nick
				when @nick                     then "~"
				#when @drones.include?(user.id) then "%" # FIXME
				else                                "+"
			end
			hop  = prefix.host.count("/")
			real = user.name
			post server_name, RPL_WHOREPLY, @nick,
			     ch, prefix.user, prefix.host, server, prefix.nick, "H*#{mode}", "#{hop} #{real}"
		end

		case
		when channel.casecmp(main_channel).zero?
			users = [@me]
			users.concat @friends.reverse if @friends
			users.each {|friend| whoreply.call channel, friend }
			post server_name, RPL_ENDOFWHO, @nick, channel
		when (@channels.key?(channel) and @friends)
			@channels[channel][:members].each do |user|
				whoreply.call channel, user
			end
			post server_name, RPL_ENDOFWHO, @nick, channel
		else
			post server_name, ERR_NOSUCHNICK, @nick, "No such nick/channel"
		end
	end

	def on_join(m)
		channels = m.params[0].split(/ *, */)
		channels.each do |channel|
			channel = channel.split(" ", 2).first
			next if channel.casecmp(main_channel).zero?

# auto rejoin のとき勝手に作って困るのでコメントアウト。
# create するまえに、必ず check_lists するようにしないと。
#			name = channel[1..-1]
#			unless @channels.find{|c| c.slug == name }
#				@log.info "create list: #{name}"
#				api("1/#{@me.screen_name}/lists",{'name' => name })
#			end
#			post @prefix, JOIN, channel
#			post server_name, MODE, channel, "+mtio", @nick
#			post server_name, MODE, channel, "+q", @nick
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel.casecmp(main_channel).zero?

# いきなり delete とか危険なのでコメントアウト
# IRC Gateway 側に流れない、という挙動にし、delete するには ctcp を必要に
#		name = channel[1..-1]
#		@log.info "delete list: #{name}"
#		api("1/#{@me.screen_name}/lists/#{name}",{'_method' => 'DELETE' }) rescue nil
#		post @prefix, PART, channel, "Ignore group #{channel}, but setting is alive yet."
	end

	def on_invite(m)
		nick, channel = *m.params
		if not nick.screen_name? or @nick.casecmp(nick).zero?
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel" # or yourself
			return
		end

		friend = friend(nick)

		case
		when channel.casecmp(main_channel).zero?
			case
			when friend #TODO
			when api("users/username_available", { :username => nick }).valid
				post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			else
				user = api("friendships/create/#{nick}")
				join main_channel, [user]
				@friends << user if @friends
				@me.friends_count += 1
			end
		when friend
			slug = channel[1..-1]
			api("/1/#{@me.screen_name}/#{slug}/members",{'id'=>friend.id})
			@channels[channel][:members] << friend
			join(channel, [friend])
		else
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	def on_kick(m)
		channel, nick, msg = *m.params

		if channel.casecmp(main_channel).zero?
			@friends.delete_if do |friend|
				if friend.screen_name.casecmp(nick).zero?
					user = api("friendships/destroy/#{friend.id}")
					if user.is_a? User
						post prefix(user), PART, main_channel, "Removed: #{msg}"
						@me.friends_count -= 1
					end
				end
			end if @friends
		else
			friend = friend(nick)
			if friend
				slug = channel[1..-1]
				api("/1/#{@me.screen_name}/#{slug}/members",{'id'=>friend.id, '_method'=>'DELETE'})
				@channels[channel][:members].delete_if{|u| u.screen_name == friend.screen_name }
				post prefix(friend), PART, channel, "Removed: #{msg}"
			else
				post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			end
		end
	end

	#def on_nick(m)
	#	@nicknames[@nick] = m.params[0]
	#end

	def on_topic(m)
		channel = m.params[0]
		return if not channel.casecmp(main_channel).zero? or @me.status.nil?

		return if not @opts.mesautofix
		begin
			require "levenshtein"
			topic    = m.params[1]
			previous = @me.status
			return unless previous

			distance = Levenshtein.normalized_distance(previous.text, topic)
			return if distance.zero?

			status = api("statuses/update", { :status => topic, :source => source })
			log oops(ret) if status.truncated
			status.user.status = status
			@me = status.user

			if distance < 0.5
				deleted = api("statuses/destroy/#{previous.id}")
				@timeline.delete_if {|tid, s| s.id == deleted.id }
				log "Similar update in previous. Conclude that it has error."
				log "And overwrite previous as new status: #{status.text}"
			else
				log "Status updated"
			end
		rescue LoadError
		end
	end

	def on_mode(m)
		channel = m.params[0]

		unless m.params[1]
			case
			when channel.ch?
				mode = "+mt"
				mode += "i" unless channel.casecmp(main_channel).zero?
				post server_name, RPL_CHANNELMODEIS, @nick, channel, mode
				#post server_name, RPL_CREATEONTIME, @nick, channel, 0
			when channel.casecmp(@nick).zero?
				post server_name, RPL_UMODEIS, @nick, @nick, "+o"
			end
		end
	end

	private
	def on_ctcp(target, mesg)
		type, mesg = mesg.split(" ", 2)
		method = "on_ctcp_#{type.downcase}".to_sym
		send(method, target, mesg) if respond_to? method, true
	end

	def on_ctcp_action(target, mesg)
		#return unless main_channel.casecmp(target).zero?
		command, *args = mesg.split(" ")
		if command
			command.downcase!

			@@ctcp_action_commands.each do |define, name|
				if define === command
					send(name, target, mesg, Regexp.last_match || command, args)
					break
				end
			end
		else
			commands = @@ctcp_action_commands.map {|define, name|
				define
			}.select {|define|
				define.is_a? String
			}

			log "[tig.rb] CTCP ACTION COMMANDS:"
			commands.each_slice(5) do |c|
				log c.join(" ")
			end
		end

	rescue APIFailed => e
		log e.inspect
	rescue Exception => e
		log e.inspect
		e.backtrace.each do |l|
			@log.error "\t#{l}"
		end
	end

	ctcp_action "reload" do |target, mesg, command, args|
		load File.expand_path(__FILE__)
		current = server_version
		@server_version = nil
		log "Reloaded tig.rb. New: #{server_version} <- Old: #{current}"
		post server_name, RPL_MYINFO, @nick, "#{server_name} #{server_version} #{available_user_modes} #{available_channel_modes}"
	end

	ctcp_action "call" do |target, mesg, command, args|
		if args.size < 2
			log "/me call <Twitter_screen_name> as <IRC_nickname>"
			return
		end
		screen_name = args[0]
		nickname    = args[2] || args[1] # allow omitting "as"
		if nickname == "is" and
		   deleted_nick = @nicknames.delete(screen_name)
			log %Q{Removed the nickname "#{deleted_nick}" for #{screen_name}}
		else
			@nicknames[screen_name] = nickname
			log "Call #{screen_name} as #{nickname}"
		end
	end

	ctcp_action "debug" do |target, mesg, command, args|
		code = args.join(" ")
		begin
			log instance_eval(code).inspect
		rescue Exception => e
			log e.inspect
		end
	end

	ctcp_action "utf-7", "utf7" do |target, mesg, command, args|
		unless defined? ::Iconv
			log "Can't load iconv."
			return
		end
		@utf7 = !@utf7
		log "UTF-7 mode: #{@utf7 ? 'on' : 'off'}"
	end

	ctcp_action "list", "ls" do |target, mesg, command, args|
		if args.empty?
			log "/me list <NICK> [<NUM>]"
			return
		end
		nick = args.first
		if not nick.screen_name? or
		   api("users/username_available", { :username => nick }).valid
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			return
		end
		id           = nick
		authenticate = false
		if user = friend(nick)
			id           = user.id
			nick         = user.screen_name
			authenticate = user.protected
		end
		unless (1..200).include?(count = args[1].to_i)
			count = 20
		end
		begin
			res = api("statuses/user_timeline/#{id}",
					  { :count => count }, { :authenticate => authenticate })
		rescue APIFailed
			#log "#{nick} has protected their updates."
			return
		end
		res.reverse_each do |s|
			message(s, target, nil, nil, NOTICE)
		end
	end

	ctcp_action %r/\A(un)?fav(?:ou?rite)?(!)?\z/ do |target, mesg, command, args|
		# fav, unfav, favorite, unfavorite, favourite, unfavourite
		method   = command[1].nil? ? "create" : "destroy"
		force    = !!command[2]
		entered  = command[0].capitalize
		statuses = []
		if args.empty?
			if method == "create"
				if status = @timeline.last
					statuses << status
				else
					#log ""
					return
				end
			else
				@favorites ||= api("favorites").reverse
				if @favorites.empty?
					log "You've never favorite yet. No favorites to unfavorite."
					return
				end
				statuses.push @favorites.last
			end
		else
			args.each do |tid_or_nick|
				case
				when status = @timeline[tid = tid_or_nick]
					statuses.push status
				when friend = friend(nick = tid_or_nick)
					if friend.status
						statuses.push friend.status
					else
						log "#{tid_or_nick} has no status."
					end
				else
					# PRIVMSG: fav nick
					log "No such ID/NICK #{@opts.tid % tid_or_nick}"
				end
			end
		end
		@favorites ||= []
		statuses.each do |s|
			if not force and method == "create" and
			   @favorites.find {|i| i.id == s.id }
				log "The status is already favorited! <#{permalink(s)}>"
				next
			end
			res = api("favorites/#{method}/#{s.id}")
			log "#{entered}: #{res.user.screen_name}: #{generate_status_message(res.text)}"
			if method == "create"
				@favorites.push res
			else
				@favorites.delete_if {|i| i.id == res.id }
			end
		end
	end

	ctcp_action "link", "ln", /\Au(?:rl)?\z/ do |target, mesg, command, args|
		args.each do |tid|
			if status = @timeline[tid]
				log "#{@opts.tid % tid}: #{permalink(status)}"
			else
				log "No such ID #{@opts.tid % tid}"
			end
		end
	end

	ctcp_action "ratio", "ratios" do |target, mesg, command, args|
		log "Intervals: #{@ratelimit.inspect}"
	end

	ctcp_action "rm", %r/\A(?:de(?:stroy|l(?:ete)?)|miss|oops|r(?:emove|m))\z/ do |target, mesg, command, args|
	# destroy, delete, del, remove, rm, miss, oops
		statuses = []
		if args.empty? and @me.status
			statuses.push @me.status
		else
			args.each do |tid|
				if status = @timeline[tid]
					if status.user.id == @me.id
						statuses.push status
					else
						log "The status you specified by the ID #{@opts.tid % tid} is not yours."
					end
				else
					log "No such ID #{@opts.tid % tid}"
				end
			end
		end
		b = false
		statuses.each do |st|
			res = api("statuses/destroy/#{st.id}")
			@timeline.delete_if {|tid, s| s.id == res.id }
			b = @me.status && @me.status.id == res.id
			log "Destroyed: #{res.text}"
		end
		Thread.start do
			sleep 2
			@me = api("account/update_profile") #api("account/verify_credentials")
			if @me.status
				@me.status.user = @me
				msg = generate_status_message(@me.status.text)
				@timeline.any? do |tid, s|
					if s.id == @me.status.id
						msg << " " << @opts.tid % tid
					end
				end
				post @prefix, TOPIC, main_channel, msg
			end
		end if b
	end

	ctcp_action "name" do |target, mesg, command, args|
		name = mesg.split(" ", 2)[1]
		unless name.nil?
			@me = api("account/update_profile", { :name => name })
			@me.status.user = @me if @me.status
			log "You are named #{@me.name}."
		end
	end

	ctcp_action "email" do |target, mesg, command, args|
		# FIXME
		email = args.first
		unless email.nil?
			@me = api("account/update_profile", { :email => email })
			@me.status.user = @me if @me.status
		end
	end

	ctcp_action "url" do |target, mesg, command, args|
		# FIXME
		url = args.first || ""
		@me = api("account/update_profile", { :url => url })
		@me.status.user = @me if @me.status
	end

	ctcp_action "in", "location" do |target, mesg, command, args|
		location = mesg.split(" ", 2)[1] || ""
		@me = api("account/update_profile", { :location => location })
		@me.status.user = @me if @me.status
		location = (@me.location and @me.location.empty?) ? "nowhere" : "in #{@me.location}"
		log "You are #{location} now."
	end

	ctcp_action %r/\Adesc(?:ription)?\z/ do |target, mesg, command, args|
		# FIXME
		description = mesg.split(" ", 2)[1] || ""
		@me = api("account/update_profile", { :description => description })
		@me.status.user = @me if @me.status
	end

	ctcp_action %r/\A(?:mention|re(?:ply)?)\z/ do |target, mesg, command, args|
		# reply, re, mention
		tid = args.first
		if status = @timeline[tid]
			text = mesg.split(" ", 3)[2]
			screen_name = "@#{status.user.screen_name}"
			if text.nil? or not text.include?(screen_name)
				text = "#{screen_name} #{text}"
			end
			ret = api("statuses/update", {
				:status => text,
				:source => source,
				:in_reply_to_status_id => status.id
			})
			log oops(ret) if ret.truncated
			msg = generate_status_message(status.text)
			url = permalink(status)
			log "Status updated (In reply to #{@opts.tid % tid}: #{msg} <#{url}>)"
			ret.user.status = ret
			@me = ret.user
		end
	end

	ctcp_action %r/\Aspoo(o+)?f\z/ do |target, mesg, command, args|
		if args.empty?
			Thread.start do
				update_sources(command[1].nil?? 0 : command[1].size)
			end
			return
		end
		names = []
		@sources = args.map do |arg|
			names << "=#{arg}"
			case arg.upcase
			when "WEB" then ""
			when "API" then nil
			else            arg
			end
		end
		log(names.inject([]) do |r, name|
			s = r.join(", ")
			if s.size < 400
				r << name
			else
				log s
				[name]
			end
		end.join(", "))
	end

	ctcp_action "bot", "drone" do |target, mesg, command, args|
		if args.empty?
			log "/me bot <NICK> [<NICK>...]"
			return
		end
		args.each do |bot|
			user = friend(bot)
			unless user
				post server_name, ERR_NOSUCHNICK, bot, "No such nick/channel"
				next
			end
			if @drones.delete(user.id)
				mode = "-#{mode}"
				log "#{bot} is no longer a bot."
			else
				@drones << user.id
				mode = "+#{mode}"
				log "Marks #{bot} as a bot."
			end
		end
	end

	ctcp_action "home", "h" do |target, mesg, command, args|
		if args.empty?
			log "/me home <NICK>"
			return
		end
		nick = args.first
		if not nick.screen_name? or
		   api("users/username_available", { :username => nick }).valid
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			return
		end
		log "http://twitter.com/#{nick}"
	end

	ctcp_action "retweet", "rt" do |target, mesg, command, args|
		if args.empty?
			log "/me #{command} <ID> blah blah"
			return
		end
		tid = args.first
		if status = @timeline[tid]
			if args.size >= 2
				comment = mesg.split(" ", 3)[2] + " "
			else
				comment = ""
			end
			screen_name = "@#{status.user.screen_name}"
			rt_message = generate_status_message(status.text)
			text = "#{comment}RT #{screen_name}: #{rt_message}"
			ret = api("statuses/update", { :status => text, :source => source })
			log oops(ret) if ret.truncated
			log "Status updated (RT to #{@opts.tid % tid}: #{text})"
			ret.user.status = ret
			@me = ret.user
		end
	end

	ctcp_action "spam" do |target, mesg, command, args|
		if args.empty?
			log "/me spam <NICK>|<ID>"
			return
		end
		nick_or_tid = args.first
		if status = @timeline[nick_or_tid]
			screen_name = status.user.screen_name
		else
			if not nick.screen_name? or
			   api("users/username_available", { :username => nick }).valid
				post server_name, ERR_NOSUCHNICK, nick, "No such nick"
				return
			end
			screen_name = nick_or_tid
		end
		api("report_spam", { :screen_name => screen_name })
		log "reported user \"#{screen_name}\" as spammer"
	end

	def on_ctcp_clientinfo(target, msg)
		if user = user(target)
			post prefix(user), NOTICE, @nick, ctcp_encode("CLIENTINFO :CLIENTINFO USERINFO VERSION TIME")
		end
	end

	def on_ctcp_userinfo(target, msg)
		user = user(target)
		if user and not user.description.empty?
			post prefix(user), NOTICE, @nick, ctcp_encode("USERINFO :#{user.description}")
		end
	end

	def on_ctcp_version(target, msg)
		user = user(target)
		if user and user.status
			source = user.status.source
			version = source.gsub(/<[^>]*>/, "").strip
			version << " <#{$1}>" if / href="([^"]+)/ === source
			post prefix(user), NOTICE, @nick, ctcp_encode("VERSION :#{version}")
		end
	end

	def on_ctcp_time(target, msg)
		if user = user(target)
			offset = user.utc_offset
			post prefix(user), NOTICE, @nick, ctcp_encode("TIME :%s%s (%s)" % [
				(Time.now + offset).utc.iso8601[0, 19],
				"%+.2d:%.2d" % (offset/60).divmod(60),
				user.time_zone,
			])
		end
	end

	def check_lists
		updated = false
		until @friends
			@log.debug "waiting retrieving friends..."
			sleep 1
		end

		lists = page("1/#{@me.screen_name}/lists", :lists, true)

		# expend lists.size API count
		channels = {}
		lists.each do |list|
			begin
				name = (list.user.screen_name == @me.screen_name) ?
					   "##{list.slug}" : 
					   "##{list.user.screen_name}^#{list.slug}"
				members = page("1/#{@me.screen_name}/#{list.slug}/members", :users, true)
				log "Miss match member_count '%s', lists:%d vs members:%s" % [ list.slug, list.member_count, members.size ] unless list.member_count == members.size
				if list.member_count - members.size > 10
					log "Miss match count is over 10. skip this list: #{list.slug}"
					next
				end

				channel = {
					:name      => name,
					:list      => list,
					:members   => members,
					:inclusion => (members - @friends).empty?
				}

				new = channel[:members]
				old = @channels.fetch(channel[:name], { :members => [] })[:members]

				# deleted user
				(old - new).each do|user|
					post prefix(user), PART, name, "Removed: #{user.screen_name}"
					updated = true
				end

				# new user
				joined = join(name, new - old)
				updated = true unless joined.empty?

				channels[name] = channel
			rescue APIFailed => e
				log e.inspect
			end
		end

		# unfollowed
		(@channels.keys - channels.keys).each do |name|
			post @prefix, PART, name, "No longer follow the list #{name}"
			updated = true
		end

		# followed
		(channels.keys - @channels.keys).each do |name|
			post @prefix, JOIN, name
			post server_name, MODE, name, "+mtio", @nick
			post server_name, MODE, name, "+q", @nick
			updated = true
		end

		@channels = channels
		updated
	end

	def check_lists_status
		friends = @friends || []
		@channels.each do |name, channel|
			# タイムラインに全員含まれているならとってこなくてもよいが
			# そうでなければ個別にとってくる必要がある。
			next if channel[:inclusion]

			list = channel[:list]
			@log.debug "retrieve #{name} statuses"
			res = api("1/#{list.user.screen_name}/lists/#{list.id}/statuses", {
				:since_id => channel[:last_id]
			})
			res.reverse_each do |s|
				next if channel[:members].include? s.user
				command = (s.user.id == @me.id) ?  NOTICE : PRIVMSG
				command = channel[:last_id]     ? command : NOTICE
				# TODO tid
				message(s, name, nil, nil, command)
			end
			channel[:last_id] = res.first.id
		end
	end

	def check_friends
		@follower_ids = page("followers/ids/#{@me.id}", :ids)
		p @follower_ids

		if @friends.nil?
			@friends = page("statuses/friends/#{@me.id}", :users)
			if @opts.athack
				join main_channel, @friends
			else
				rest = @friends.map do |i|
					prefix = "+" #@drones.include?(i.id) ? "%" : "+" # FIXME ~&%
					"#{prefix}#{i.screen_name}"
				end.reverse.inject("~#{@nick}") do |r, nick|
					if r.size < 400
						r << " " << nick
					else
						post server_name, RPL_NAMREPLY, @nick, "=", main_channel, r
						nick
					end
				end
				post server_name, RPL_NAMREPLY, @nick, "=", main_channel, rest
				post server_name, RPL_ENDOFNAMES, @nick, main_channel, "End of NAMES list"
			end
		else
			@me = api("account/update_profile") #api("account/verify_credentials")
			if @me.friends_count != @friends.size
				new_ids    = page("friends/ids/#{@me.id}", :ids)
				friend_ids = @friends.reverse.map {|friend| friend.id }

				(friend_ids - new_ids).each do |id|
					@friends.delete_if do |friend|
						if friend.id == id
							post prefix(friend), PART, main_channel, ""
						end
					end
				end

				new_ids -= friend_ids
				unless new_ids.empty?
					new_friends = page("statuses/friends/#{@me.id}", :users)
					join main_channel, new_friends.delete_if {|friend|
						@friends.any? {|i| i.id == friend.id }
					}.reverse
					@friends.concat new_friends
				end
			end
		end
	end

	def check_timeline
		updated = false

		cmd  = PRIVMSG
		path = "statuses/#{@opts.with_retweets ? "home" : "friends"}_timeline"
		q    = { :count => 200 }
		@latest_id ||= nil

		case
		when @latest_id
			q.update(:since_id => @latest_id)
		when is_first_retrieve = !@me.statuses_count.zero? && !@me.friends_count.zero?
		#	cmd = NOTICE # デバッグするときめんどくさいので
			q.update(:count => 20)
		end

		api(path, q).reverse_each do |status|
			id = @latest_id = status.id
			next if @timeline.any? {|tid, s| s.id == id }

			status.user.status = status
			user = status.user
			tid  = @timeline.push(status)
			tid  = nil unless @opts.tid

			@log.debug [id, user.screen_name, status.text].inspect

			if user.id == @me.id
				mesg = generate_status_message(status.text)
				mesg << " " << @opts.tid % tid if tid
				post @prefix, TOPIC, main_channel, mesg

				@me = user
			else
				if @friends
					b = false
					@friends.each_with_index do |friend, i|
						if b = friend.id == user.id
							if friend.screen_name != user.screen_name
								post prefix(friend), NICK, user.screen_name
							end
							@friends[i] = user
							break
						end
					end
					unless b
						join main_channel, [user]
						@friends << user
						@me.friends_count += 1
					end
				end

				message(status, main_channel, tid, nil, cmd)
			end
			@channels.each do |name, channel|
				if channel[:members].find{|m| m.screen_name == user.screen_name }
					message(status, name, tid, nil, (user.id == @me.id) ? NOTICE : cmd)
				end
			end
			updated = true
		end

		updated
	end

	def check_direct_messages
		updated = false
		@prev_dm_id ||= nil
		q = @prev_dm_id ? { :count => 200, :since_id => @prev_dm_id } \
		                : { :count => 1 }
		api("direct_messages", q).reverse_each do |mesg|
			unless @prev_dm_id &&= mesg.id
				@prev_dm_id = mesg.id
				next
			end

			id   = mesg.id
			user = mesg.sender
			tid  = nil
			text = mesg.text
			@log.debug [id, user.screen_name, text].inspect
			message(user, @nick, tid, text)
			updated = true
		end
		updated
	end

	def check_mentions
		updated = false

		return if @timeline.empty?
		@prev_mention_id ||= @timeline.last.id
		api("statuses/mentions", {
			:count    => 200,
			:since_id => @prev_mention_id
		}).reverse_each do |mention|
			id = @prev_mention_id = mention.id
			next if @timeline.any? {|tid, s| s.id == id }

			mention.user.status = mention
			user = mention.user
			tid  = @timeline.push(mention)
			tid  = nil unless @opts.tid

			@log.debug [id, user.screen_name, mention.text].inspect
			message(mention, main_channel, tid)

			@friends.each_with_index do |friend, i|
				if friend.id == user.id
					@friends[i] = user
					break
				end
			end if @friends
			updated = true
		end
		updated
	end

	def check_updates
		uri = URI("http://github.com/api/v1/json/cho45/net-irc/commits/master")
		@log.debug uri.inspect
		res = http(uri).request(http_req(:get, uri))

		commits = JSON.parse(res.body)['commits']
		latest  = commits.first['id'][/^[0-9a-z]{40}$/]

		raise "github API changed?" unless latest

		is_in_local_repos = system("git rev-parse --verify #{latest} 2>/dev/null")
		unless is_in_local_repos
			current  = commits.map {|i| i['id'] }.index(server_version)
			messages = commits[0..current].map {|i| i['message'] }

			log "\002New version is available.\017 run 'git pull'."
			messages[0, 3].each do |m|
				log "  \002#{m[/.+/]}\017"
			end
			log "  ... and more. check it: http://bit.ly/79d33W" if messages.size > 3
		end
	rescue Errno::ECONNREFUSED, Timeout::Error => e
		@log.error "Failed to get the latest revision of tig.rb from #{uri.host}: #{e.inspect}"
	end

	def join(channel, users)
		params = []
		users.each do |user|
			prefix = prefix(user)
			post prefix, JOIN, channel
			case
			when user.protected
				params << ["v", prefix.nick]
			when ! @follower_ids.include?(user.id)
				params << ["o", prefix.nick]
			end
			next if params.size < MAX_MODE_PARAMS

			post server_name, MODE, channel, "+#{params.map {|m,_| m }.join}", *params.map {|_,n| n}
			params = []
		end
		post server_name, MODE, channel, "+#{params.map {|m,_| m }.join}", *params.map {|_,n| n} unless params.empty?
		users
	end

	def start_jabber(jid, pass)
		@log.info "Logging-in with #{jid} -> jabber_bot_id: #{jabber_bot_id}"
		@im = Jabber::Simple.new(jid, pass)
		@im.add(jabber_bot_id)
		@im_thread = Thread.start do
			require "cgi"

			loop do
				begin
					@im.received_messages.each do |msg|
						@log.debug [msg.from, msg.body].inspect
						if msg.from.strip == jabber_bot_id
							# Twitter -> 'id: msg'
							body = msg.body.sub(/\A(.+?)(?:\(([^()]+)\))?: /, "")
							body = decode_utf7(body)

							if Regexp.last_match
								nick, id = Regexp.last_match.captures
								body = untinyurl(CGI.unescapeHTML(body))
								user = nick
								nick = id || nick
								nick = @nicknames[nick] || nick
								post "#{nick}!#{user}@#{api_base.host}", PRIVMSG, main_channel, body
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

	def require_post?(path,query)
		case path
		when %r{
			\A
			(?: status(?:es)?/update \z
			  | direct_messages/new \z
			  | friendships/create/
			  | account/(?: end_session \z | update_ )
			  | favou?ri(?: ing | tes )/create/
			  | notifications/
			  | blocks/create/
			  | report_spam )
		}x
			true
		when %r{
			\A
			(?: 1/#{@me.screen_name} )
		}x
			query.key? 'name' or query.key? '_method' or query.key? 'id'
		end
	end

	#def require_put?(path)
	#	%r{ \A status(?:es)?/retweet (?:/|\z) }x === path
	#end

	def api(path, query = {}, opts = {})
		path.sub!(%r{\A/+}, "")

		authenticate = opts.fetch(:authenticate, true)

		uri = api_base(authenticate)
		uri.path += path
		uri.path += ".json" if path != "users/username_available"
		uri.query = query.to_query_str unless query.empty?

		header      = {}
		credentials = authenticate ? [@real, @pass] : nil
		req         = case
			when path.include?("/destroy/")
				http_req :delete, uri, header, credentials
			when require_post?(path,query)
				http_req :post,   uri, header, credentials
			#when require_put?(path)
			#	http_req :put,    uri, header, credentials
			else
				http_req :get,    uri, header, credentials
		end

		@log.debug [req.method, uri.to_s]
		ret = http(uri, 30, 30).request req

		#@etags[uri.to_s] = ret["ETag"]

		case
		when authenticate
			hourly_limit = ret["X-RateLimit-Limit"].to_i
			unless hourly_limit.zero?
				if @limit != hourly_limit
					msg = "The rate limit per hour was changed: #{@limit} to #{hourly_limit}"
					log msg
					@log.info msg
					@limit = hourly_limit
				end

				#if req.is_a?(Net::HTTP::Get) and not %w{
				if not %w{
					statuses/friends_timeline
					direct_messages
					statuses/mentions
				}.include?(path) and not ret.is_a?(Net::HTTPServerError)
					expired_on = Time.parse(ret["Date"]) rescue Time.now
					expired_on += 3636 # 1.01 hours in seconds later
					@consums << expired_on
				end
			end
		when ret["X-RateLimit-Remaining"]
			@limit_remaining_for_ip = ret["X-RateLimit-Remaining"].to_i
			@log.debug "IP based limit: #{@limit_remaining_for_ip}"
		end

		case ret
		when Net::HTTPOK # 200
			# Avoid Twitter's invalid JSON
			json = ret.body.strip.sub(/\A(?:false|true)\z/, "[\\&]")

			res = JSON.parse json
			if res.is_a?(Hash) and res["error"] # and not res["response"]
				if @error != res["error"]
					@error = res["error"]
					log @error
				end
				raise APIFailed, res["error"]
			end
			res.to_tig_struct
		when Net::HTTPNoContent,  # 204
		     Net::HTTPNotModified # 304
			[]
		when Net::HTTPBadRequest # 400: exceeded the rate limitation
			if ret.key?("X-RateLimit-Reset")
				s = ret["X-RateLimit-Reset"].to_i - Time.now.to_i
				if s > 0
					log "RateLimit: #{(s / 60.0).ceil} min remaining to get timeline"
					sleep (s > 60 * 10) ? 60 * 10 : s # 10 分に一回はとってくるように
				end
			end
			raise APIFailed, "#{ret.code}: #{ret.message}"
		when Net::HTTPUnauthorized # 401
			raise APIFailed, "#{ret.code}: #{ret.message}"
		else
			raise APIFailed, "Server Returned #{ret.code} #{ret.message}"
		end
	rescue Errno::ETIMEDOUT, JSON::ParserError, IOError, Timeout::Error, Errno::ECONNRESET => e
		raise APIFailed, e.inspect
	end

	def page(path, name, authenticate = false, &block)
		@limit_remaining_for_ip ||= 52
		limit = 0.98 * @limit_remaining_for_ip # 98% of IP based rate limit
		r     = []
		cursor = -1
		1.upto(limit) do |num|
			# next_cursor にアクセスするとNot found が返ってくることがあるので，その時はbreak
			ret = api(path, { :cursor => cursor }, { :authenticate => authenticate }) rescue break
			arr = ret[name.to_s]
			r.concat arr
			cursor = ret[:next_cursor]
			break if cursor.zero?
		end
		r
	end

	def generate_status_message(mesg)
		mesg = decode_utf7(mesg)
		mesg.delete!("\000\001")
		mesg.gsub!("&gt;", ">")
		mesg.gsub!("&lt;", "<")
		mesg.gsub!(WSP_REGEX, " ")
		mesg = untinyurl(mesg)
		mesg.sub!(@rsuffix_regex, "") if @rsuffix_regex
		mesg.strip
	end

	def friend(id)
		return nil unless @friends
		if id.is_a? String
			@friends.find {|i| i.screen_name.casecmp(id).zero? }
		else
			@friends.find {|i| i.id == id }
		end
	end

	def user(id)
		if id.is_a? String
			@nick.casecmp(id).zero? ? @me : friend(id)
		else
			@me.id == id ? @me : friend(id)
		end
	end

	def prefix(u)
		nick = u.screen_name
		nick = "@#{nick}" if @opts.athack
		user = "id=%.9d" % u.id
		host = api_base.host
		host += "/protected" if u.protected
		host += "/bot"       if @drones.include?(u.id)

		Prefix.new("#{nick}!#{user}@#{host}")
	end

	def message(struct, target, tid = nil, str = nil, command = PRIVMSG)
		unless str
			status = struct.is_a?(Status) ? struct : struct.status
			str = status.text
			if command != PRIVMSG
				time = Time.parse(status.created_at) rescue Time.now
				str  = "#{time.strftime(@opts.strftime || "%m-%d %H:%M")} #{str}" # TODO: color
			end
		end
		user        = (struct.is_a?(User) ? struct : struct.user).dup
		screen_name = user.screen_name

		user.screen_name = @nicknames[screen_name] || screen_name
		prefix = prefix(user)
		str    = generate_status_message(str)
		str    = "#{str} #{@opts.tid % tid}" if tid

		post prefix, command, target, str
	end

	def log(str)
		post server_name, NOTICE, main_channel, str.gsub(/\r\n|[\r\n]/, " ")
	end

	def decode_utf7(str)
		return str unless defined? ::Iconv and str.include?("+")

		str.sub!(/\A(?:.+ > |.+\z)/) { Iconv.iconv("UTF-8", "UTF-7", $&).join }
		#FIXME str = "[utf7]: #{str}" if str =~ /[^a-z0-9\s]/i
		str
	rescue Iconv::IllegalSequence
		str
	rescue => e
		@log.error e
		str
	end

	def untinyurl(text)
		text.gsub(@opts.untiny_whole_urls ? URI.regexp(%w[http https]) : %r{
			http:// (?:
				(?: bit\.ly | (?: tin | rub) yurl\.com | j\.mp
				  | is\.gd | cli\.gs | tr\.im | u\.nu | airme\.us
				  | ff\.im | twurl.nl | bkite\.com | tumblr\.com
				  | pic\.gd | sn\.im | digg\.com )
				/ [0-9a-z=-]+ |
				blip\.fm/~ (?> [0-9a-z]+) (?! /) |
				flic\.kr/[a-z0-9/]+
			)
		}ix) {|url| "#{resolve_http_redirect(URI(url)) || url}" }
	end

	def bitlify(text)
		login, key, len = @opts.bitlify.split(":", 3) if @opts.bitlify
		len      = (len || 20).to_i
		longurls = URI.extract(text, %w[http https]).uniq.map do |url|
			URI.rstrip url
		end.reject do |url|
			url.size < len
		end
		return text if longurls.empty?

		bitly = URI("http://api.bit.ly/shorten")
		if login and key
			bitly.path  = "/shorten"
			bitly.query = {
				:version => "2.0.1", :format => "json", :longUrl => longurls,
			}.to_query_str(";")
			@log.debug bitly
			req = http_req(:get, bitly, {}, [login, key])
			res = http(bitly, 5, 10).request(req)
			res = JSON.parse(res.body)
			res = res["results"]

			longurls.each do |longurl|
				text.gsub!(longurl) do
					res[$&] && res[$&]["shortUrl"] || $&
				end
			end
		else
			bitly.path = "/api"
			longurls.each do |longurl|
				bitly.query = { :url => longurl }.to_query_str
				@log.debug bitly
				req = http_req(:get, bitly)
				res = http(bitly, 5, 5).request(req)
				text.gsub!(longurl, res.body)
			end
		end

		text
	rescue => e
		@log.error e
		text
	end

	def unuify(text)
		unu_url = "http://u.nu/"
		unu     = URI("#{unu_url}unu-api-simple")
		size    = unu_url.size

		text.gsub(URI.regexp(%w[http https])) do |url|
			url = URI.rstrip url
			if url.size < size + 5 or url[0, size] == unu_url
				return url
			end

			unu.query = { :url => url }.to_query_str
			@log.debug unu

			res = http(unu, 5, 5).request(http_req(:get, unu)).body

			if res[0, 12] == unu_url
				res
			else
				raise res.split("|")
			end
		end
	rescue => e
		@log.error e
		text
	end

	def escape_http_urls(text)
		original_text = text.encoding!("UTF-8").dup

		if defined? ::Punycode
			# TODO: Nameprep
			text.gsub!(%r{(https?://)([^\x00-\x2C\x2F\x3A-\x40\x5B-\x60\x7B-\x7F]+)}) do
				domain = $2
				# Dots:
				#   * U+002E (full stop)           * U+3002 (ideographic full stop)
				#   * U+FF0E (fullwidth full stop) * U+FF61 (halfwidth ideographic full stop)
				# => /[.\u3002\uFF0E\uFF61] # Ruby 1.9 /x
				$1 + domain.split(/\.|\343\200\202|\357\274\216|\357\275\241/).map do |label|
					break [domain] if /\A-|[\x00-\x2C\x2E\x2F\x3A-\x40\x5B-\x60\x7B-\x7F]|-\z/ === label
					next label unless /[^-A-Za-z0-9]/ === label
					punycode = Punycode.encode(label)
					break [domain] if punycode.size > 59
					"xn--#{punycode}"
				end.join(".")
			end
			if text != original_text
				log "Punycode encoded: #{text}"
				original_text = text.dup
			end
		end

		urls = []
		text.split(/[\s<>]+/).each do |str|
			next if /%[0-9A-Fa-f]{2}/ === str
			# URI::UNSAFE + "#"
			escaped_str = URI.escape(str, %r{[^-_.!~*'()a-zA-Z0-9;/?:@&=+$,\[\]#]})
			URI.extract(escaped_str, %w[http https]).each do |url|
				uri = URI(URI.rstrip(url))
				if not urls.include?(uri.to_s) and exist_uri?(uri)
					urls << uri.to_s
				end
			end if escaped_str != str
		end
		urls.each do |url|
			unescaped_url = URI.unescape(url).encoding!("UTF-8")
			text.gsub!(unescaped_url, url)
		end
		log "Percent encoded: #{text}" if text != original_text

		text.encoding!("ASCII-8BIT")
	rescue => e
		@log.error e
		text
	end

	def exist_uri?(uri, limit = 1)
		ret = nil
		#raise "Not supported." unless uri.is_a?(URI::HTTP)
		return ret if limit.zero? or uri.nil? or not uri.is_a?(URI::HTTP)
		@log.debug uri.inspect

		req = http_req :head, uri
		http(uri, 3, 2).request(req) do |res|
			ret = case res
				when Net::HTTPSuccess
					true
				when Net::HTTPRedirection
					uri = resolve_http_redirect(uri)
					exist_uri?(uri, limit - 1)
				when Net::HTTPClientError
					false
				#when Net::HTTPServerError
				#	nil
				else
					nil
			end
		end

		ret
	rescue => e
		@log.error e.inspect
		ret
	end

	def resolve_http_redirect(uri, limit = 3)
		return uri if limit.zero? or uri.nil?
		@log.debug uri.inspect

		req = http_req :head, uri
		http(uri, 3, 2).request(req) do |res|
			break if not res.is_a?(Net::HTTPRedirection) or
			         not res.key?("Location")
			begin
				location = URI(res["Location"])
			rescue URI::InvalidURIError
			end
			unless location.is_a? URI::HTTP
				begin
					location = URI.join(uri.to_s, res["Location"])
				rescue URI::InvalidURIError, URI::BadURIError
					# FIXME
				end
			end
			uri = resolve_http_redirect(location, limit - 1)
		end

		uri
	rescue => e
		@log.error e.inspect
		uri
	end

	def update_sources(n = 0)
		if @sources and @sources.size > 1 and n.zero?
			log "tig.rb"
			@sources = [api_source]
			return @sources
		end

		uri = URI("http://wedata.net/databases/TwitterSources/items.json")
		@log.debug uri.inspect
		json    = http(uri).request(http_req(:get, uri)).body
		sources = JSON.parse json
		sources.map! {|item| [item["data"]["source"], item["name"]] }
		sources.push ["", "web"]
		sources.push [nil, "API"]

		sources = Array.new(n) do
			sources.delete_at(rand(sources.size))
		end if (1 ... sources.size).include?(n)

		log(sources.inject([]) do |r, src|
			s = r.join(", ")
			if s.size < 400
				r << src[1]
			else
				log s
				[src[1]]
			end
		end.join(", ")) if @sources

		@sources = sources.map {|src| src[0] }
	rescue => e
		@log.error e.inspect
		log "An error occured while loading #{uri.host}."
		@sources ||= [api_source]
	end

	def update_redundant_suffix
		uri = URI("http://svn.coderepos.org/share/platform/twitterircgateway/suffixesblacklist.txt")
		@log.debug uri.inspect
		res = http(uri).request(http_req(:get, uri))
		@etags[uri.to_s] = res["ETag"]
		return if res.is_a? Net::HTTPNotModified
		source = res.body
		source.encoding!("UTF-8") if source.respond_to?(:encoding) and source.encoding == Encoding::BINARY
		@rsuffix_regex = /#{Regexp.union(*source.split)}\z/
	rescue Errno::ECONNREFUSED, Timeout::Error => e
		@log.error "Failed to get the redundant suffix blacklist from #{uri.host}: #{e.inspect}"
	end

	def http(uri, open_timeout = nil, read_timeout = 60)
		http = case
			when @httpproxy
				Net::HTTP.new(uri.host, uri.port, @httpproxy.address, @httpproxy.port,
				                                  @httpproxy.user, @httpproxy.password)
			when ENV["HTTP_PROXY"], ENV["http_proxy"]
				proxy = URI(ENV["HTTP_PROXY"] || ENV["http_proxy"])
				Net::HTTP.new(uri.host, uri.port, proxy.host, proxy.port,
				                                  proxy.user, proxy.password)
			else
				Net::HTTP.new(uri.host, uri.port)
		end
		http.open_timeout = open_timeout if open_timeout # nil by default
		http.read_timeout = read_timeout if read_timeout # 60 by default
		if uri.is_a? URI::HTTPS
			http.use_ssl     = true
			http.cert_store = @cert_store
			http.verify_mode = OpenSSL::SSL::VERIFY_PEER
		end
		http
	rescue => e
		@log.error e
	end

	def http_req(method, uri, header = {}, credentials = nil)
		accepts = ["*/*;q=0.1"]
		#require "mime/types"; accepts.unshift MIME::Types.of(uri.path).first.simplified
		types   = { "json" => "application/json", "txt" => "text/plain" }
		ext     = uri.path[/[^.]+\z/]
		accepts.unshift types[ext] if types.key?(ext)
		user_agent = "#{self.class}/#{server_version} (#{File.basename(__FILE__)}; net-irc) Ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM})"

		header["User-Agent"]      ||= user_agent
		header["Accept"]          ||= accepts.join(",")
		header["Accept-Charset"]  ||= "UTF-8,*;q=0.0" if ext != "json"
		#header["Accept-Language"] ||= @opts.lang # "en-us,en;q=0.9,ja;q=0.5"
		header["If-None-Match"]   ||= @etags[uri.to_s] if @etags[uri.to_s]

		req = case method.to_s.downcase.to_sym
		when :get
			Net::HTTP::Get.new    uri.request_uri, header
		when :head
			Net::HTTP::Head.new   uri.request_uri, header
		when :post
			Net::HTTP::Post.new   uri.path,        header
		when :put
			Net::HTTP::Put.new    uri.path,        header
		when :delete
			Net::HTTP::Delete.new uri.request_uri, header
		else # raise ""
		end
		if req.request_body_permitted?
			req["Content-Type"] ||= "application/x-www-form-urlencoded"
			req.body = uri.query
		end
		req.basic_auth(*credentials) if credentials
		req
	rescue => e
		@log.error e
	end

	def oops(status)
		"Oops! Your update was over 140 characters. We sent the short version" <<
		" to your friends (they can view the entire update on the Web <" <<
		permalink(status) << ">)."
	end

	def permalink(struct)
		path = struct.is_a?(Status) ? "#{struct.user.screen_name}/statuses/#{struct.id}" \
		                            : struct.screen_name
		"http://twitter.com/#{path}"
	end

	def source
		@sources[rand(@sources.size)]
	end

	def initial_message
		super
		post server_name, RPL_ISUPPORT, @nick,
		     "PREFIX=(qov)~@%+", "CHANTYPES=#", "CHANMODES=#{available_channel_modes}",
		     "MODES=#{MAX_MODE_PARAMS}", "NICKLEN=15", "TOPICLEN=420", "CHANNELLEN=50",
		     "NETWORK=Twitter",
		     "are supported by this server"
	end

	User   = Struct.new(:id, :name, :screen_name, :location, :description, :url,
	                    :following, :notifications, :protected, :time_zone,
	                    :utc_offset, :created_at, :friends_count, :followers_count,
	                    :statuses_count, :favourites_count, :verified, :geo_enabled,
	                    :profile_image_url, :profile_background_color, :profile_text_color,
	                    :profile_link_color, :profile_sidebar_fill_color,
	                    :profile_sidebar_border_color, :profile_background_image_url,
	                    :profile_background_tile, :status)
	Status = Struct.new(:id, :text, :source, :created_at, :truncated, :favorited, :geo,
	                    :in_reply_to_status_id, :in_reply_to_user_id,
	                    :in_reply_to_screen_name, :user)
	DM     = Struct.new(:id, :text, :created_at,
	                    :sender_id, :sender_screen_name, :sender,
	                    :recipient_id, :recipient_screen_name, :recipient)
	Geo    = Struct.new(:type, :coordinates, :geometries, :geometry, :properties, :id,
	                    :crs, :name, :href, :bbox, :features)
	List   = Struct.new(:mode, :uri, :slug, :member_count, :full_name, :name, :id, :subscriber_count, :user)

	class User
		def hash
			self.id
		end

		def eql?(other)
			self.id == other.id
		end

		def ==(other)
			self.id == other.id
		end
	end

	class TypableMap < Hash
		#Roman = %w[
		#	k g ky gy s z sh j t d ch n ny h b p hy by py m my y r ry w v q
		#].unshift("").map do |consonant|
		#	case consonant
		#	when "h", "q"  then %w|a i   e o|
		#	when /[hy]$/   then %w|a   u   o|
		#	else                %w|a i u e o|
		#	end.map {|vowel| "#{consonant}#{vowel}" }
		#end.flatten
		Roman = %w[
			  a   i   u   e   o  ka  ki  ku  ke  ko  sa shi  su  se  so
			 ta chi tsu  te  to  na  ni  nu  ne  no  ha  hi  fu  he  ho
			 ma  mi  mu  me  mo  ya      yu      yo  ra  ri  ru  re  ro
			 wa              wo   n
			 ga  gi  gu  ge  go  za  ji  zu  ze  zo  da          de  do
			 ba  bi  bu  be  bo  pa  pi  pu  pe  po
			kya     kyu     kyo sha     shu     sho cha     chu     cho
			nya     nyu     nyo hya     hyu     hyo mya     myu     myo
			rya     ryu     ryo
			gya     gyu     gyo  ja      ju      jo bya     byu     byo
			pya     pyu     pyo
		].freeze

		def initialize(size = nil, shuffle = false)
			if shuffle
				@seq = Roman.dup
				if @seq.respond_to?(:shuffle!)
					@seq.shuffle!
				else
					@seq = Array.new(@seq.size) { @seq.delete_at(rand(@seq.size)) }
				end
				@seq.freeze
			else
				@seq = Roman
			end
			@n    = 0
			@size = size || @seq.size
		end

		def generate(n)
			ret = []
			begin
				n, r = n.divmod(@seq.size)
				ret << @seq[r]
			end while n > 0
			ret.reverse.join #.gsub(/n(?=[bmp])/, "m")
		end

		def push(obj)
			id = generate(@n)
			self[id] = obj
			@n += 1
			@n %= @size
			id
		end
		alias :<< :push

		def clear
			@n = 0
			super
		end

		def first
			@size.times do |i|
				id = generate((@n + i) % @size)
				return self[id] if key? id
			end unless empty?
			nil
		end

		def last
			@size.times do |i|
				id = generate((@n - 1 - i) % @size)
				return self[id] if key? id
			end unless empty?
			nil
		end

		private :[]=
	end

	class RateLimit
		def initialize(limit)
			@limit = limit
			@rates = {}
		end

		def register(name, init_second=60)
			@rates[name.to_sym] = {
				:init => init_second.to_f,
				:rate => init_second.to_f,
			}
		end

		def unregister(name)
			@rates.delete(name)
		end

		def inspect
			"#<%s:0x%08x %s>" % [self.class, self.__id__,
				@rates.keys.map {|name| "#{name}:#{interval(name)}" }.join(' ')
			]
		end

		def interval(name)
			rate  = (3600.0 / @rates[name][:rate]) / @rates.values.inject(0) {|r,i| r + 3600.0 / i[:rate] }
			count = @limit * rate
			(3600 / count).to_i
		end

		def incr(name)
			@rates[name][:rate] /= 2
			@rates[name][:rate]  = 10   if @rates[name][:rate] < 10
		end

		def decr(name)
			@rates[name][:rate] *= 2
			@rates[name][:rate]  = 3600 if @rates[name][:rate] > 3600
		end
	end

end

class Array
	def to_tig_struct
		map do |v|
			v.respond_to?(:to_tig_struct) ? v.to_tig_struct : v
		end
	end
end

class Hash
	def to_tig_struct
		if empty?
			#warn "" if $VERBOSE
			#raise Error
			return nil
		end

		struct = case
			when struct_of?(TwitterIrcGateway::User)
				TwitterIrcGateway::User.new
			when struct_of?(TwitterIrcGateway::Status)
				TwitterIrcGateway::Status.new
			when struct_of?(TwitterIrcGateway::DM)
				TwitterIrcGateway::DM.new
			when struct_of?(TwitterIrcGateway::Geo)
				TwitterIrcGateway::Geo.new
			when struct_of?(TwitterIrcGateway::List)
				TwitterIrcGateway::List.new
			else
				members = keys
				members.concat TwitterIrcGateway::User.members
				members.concat TwitterIrcGateway::Status.members
				members.concat TwitterIrcGateway::DM.members
				members.concat TwitterIrcGateway::Geo.members
				members.concat TwitterIrcGateway::List.members
				members.map! {|m| m.to_sym }
				members.uniq!
				Struct.new(*members).new
		end
		each do |k, v|
			struct[k.to_sym] = v.respond_to?(:to_tig_struct) ? v.to_tig_struct : v
		end
		struct
	end

	# { :f  => "v" }    #=> "f=v"
	# { "f" => [1, 2] } #=> "f=1&f=2"
	# { "f" => "" }     #=> "f="
	# { "f" => nil }    #=> "f"
	def to_query_str separator = "&"
		inject([]) do |r, (k, v)|
			k = URI.encode_component k.to_s
			(v.is_a?(Array) ? v : [v]).each do |i|
				if i.nil?
					r << k
				else
					r << "#{k}=#{URI.encode_component i.to_s}"
				end
			end
			r
		end.join separator
	end

	private
	def struct_of? struct
		(keys - struct.members.map {|m| m.to_s }).size.zero?
	end
end

class String
	def ch?
		/\A[&#+!][^ \007,]{1,50}\z/ === self
	end

	def screen_name?
		/\A[A-Za-z0-9_]{1,15}\z/ === self
	end

	def encoding! enc
		return self unless respond_to? :force_encoding
		force_encoding enc
	end
end

module URI::Escape
	alias :_orig_escape :escape

	if defined? ::RUBY_REVISION and RUBY_REVISION < 24544
		# URI.escape("あ１") #=> "%E3%81%82\xEF\xBC\x91"
		# URI("file:///４")  #=> #<URI::Generic:0x9d09db0 URL:file:/４>
		#   "\\d" -> "[0-9]" for Ruby 1.9
		def escape str, unsafe = %r{[^-_.!~*'()a-zA-Z0-9;/?:@&=+$,\[\]]}
			_orig_escape(str, unsafe)
		end
		alias :encode :escape
	end

	def encode_component str, unsafe = /[^-_.!~*'()a-zA-Z0-9 ]/
		_orig_escape(str, unsafe).tr(" ", "+")
	end

	def rstrip str
		str.sub(%r{
			(?: ( / [^/?#()]* (?: \( [^/?#()]* \) [^/?#()]* )* ) \) [^/?#()]*
			  | \.
			) \z
		}x, "\\1")
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

	#def daemonize(foreground = false)
	#	[:INT, :TERM, :HUP].each do |sig|
	#		Signal.trap sig, "EXIT"
	#	end
	#	return yield if $DEBUG or foreground
	#	Process.fork do
	#		Process.setsid
	#		Dir.chdir "/"
	#		STDIN.reopen  "/dev/null"
	#		STDOUT.reopen "/dev/null", "a"
	#		STDERR.reopen STDOUT
	#		yield
	#	end
	#	exit! 0
	#end

	#daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], TwitterIrcGateway, opts).start
	#end
end
