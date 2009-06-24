#!/usr/bin/env ruby
# vim:fileencoding=UTF-8:
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

"80:3:15" by default.

	/me ratios

	   ratio | timeline |   dm  | mentions |
	---------+----------+-------+----------|
	       1 |      37s |   N/A |      N/A |
	    46:3 |      39s |   10m OR N/A     |
	    43:6 |      42s |    5m OR N/A     |
	  43:3:3 |      42s |   10m |      10m |
	---------+----------+-------+----------|
	 80:3:15 |      45s |   20m |       4m |
	---------+----------+-------+----------|
	     4:1 |      46s |  3m4s |      N/A |
	  20:5:6 |      57s | 3m48s |    3m10s |
	 30:5:12 |      58s | 5m45s |    2m24s |
	 31:4:15 |       1m | 7m30s |       2m |
	   1:1:1 |    1m50s | 1m50s |    1m50s |
	---------------------------------------+

### dm[=<ratio>]

### mentions[=<ratio>]

### maxlimit=<hourly_limit>

### clientspoofing

### httpproxy=[<user>[:<password>]@]<address>[:<port>]

### main_channel=<channel:#twitter>

### api_source=<source>

### max_params_count=<number:3>

### check_friends_interval=<seconds:3600>

### old_style_reply

### tmap_size=<number:10404>

### strftime=<format:%m-%d %H:%M>

### untiny_whole_urls

### bitlify=<username>:<apikey>:<minlength:20>

### unuify

## Extended commands through the CTCP ACTION

### list (ls)

	/me list NICK [NUMBER]

### fav (favorite, favourite, unfav, unfavorite, unfavourite)

	/me fav [ID...]
	/me unfav [ID...]
	/me fav! [ID...]
	/me fav NICK

### link (ln)

	/me link ID [ID...]

### destroy (del, delete, miss, oops, remove, rm)

	/me destroy [ID...]

### in (location)

	/me in Sugamo, Tokyo, Japan

### reply (re, mention)

	/me reply ID blah, blah...

### utf7

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

## Feed

<http://coderepos.org/share/log/lang/ruby/net-irc/trunk/examples/tig.rb?limit=100&mode=stop_on_copy&format=rss>

## License

Ruby's by cho45

=end

$KCODE = "u" if RUBY_VERSION < "1.9" # json use this

if lp = File.expand_path("lib") and File.directory?(lp) or
   lp = File.expand_path("lib", "..") and File.directory?(lp)
	$LOAD_PATH << lp
end

require "rubygems"
require "net/irc"
require "net/https"
require "uri"
require "socket"
require "time"
require "logger"
require "yaml"
require "pathname"
require "ostruct"
require "json"

module Net::IRC::Constants; RPL_WHOISBOT = "335"; RPL_CREATEONTIME = "329"; end

class TwitterIrcGateway < Net::IRC::Server::Session
	def server_name
		"twittergw"
	end

	def server_version
		rev = %q$Revision$.split[1]
		rev &&= "+r#{rev}"
		"0.0.0#{rev}"
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
		100
	end

	class APIFailed < StandardError; end

	def initialize(*args)
		super
		@groups    = {}
		@channels  = [] # joined channels (groups)
		@nicknames = {}
		@drones    = []
		@config    = Pathname.new(ENV["HOME"]) + ".tig"
		@suffix_bl = []
		#@etags     = {}
		@consums   = []
		@limit     = hourly_limit
		@friends   =
		@sources   =
		@im        =
		@im_thread =
		@utf7      =
		@httpproxy = nil
		load_config
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

		@ratio = (@opts.ratio || "80").split(":")
		@ratio = Struct.new(:timeline, :dm, :mentions).new(*@ratio)
		@ratio.dm       ||= @opts.dm == true ? @opts.mentions ?  3 : 18 : @opts.dm
		@ratio.mentions ||= @opts.mentions == true ? @opts.dm ? 15 : 18 : @opts.mentions

		@check_friends_thread = Thread.start do
			loop do
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
				sleep @opts.check_friends_interval || 3600
			end
		end

		return if @opts.jabber

		@timeline  = TypableMap.new(@opts.tmap_size || 10_404)
		@sources   = @opts.clientspoofing ? fetch_sources : [[api_source, "tig.rb"]]
		@suffix_bl = fetch_suffix_bl

		@check_timeline_thread = Thread.start do
			sleep 2 * (@me.friends_count / 100.to_f).ceil

			loop do
				begin
					check_timeline
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep interval(@ratio.timeline)
			end
		end

		@check_dms_thread = Thread.start do
			loop do
				begin
					check_direct_messages
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep interval(@ratio.dm)
			end
		end if @opts.dm

		@check_mentions_thread = Thread.start do
			sleep interval(@ratio.timeline) / 2

			loop do
				begin
					check_mentions
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep interval(@ratio.mentions)
			end
		end if @opts.mentions
	end

	def on_disconnected
		@check_friends_thread.kill  rescue nil
		@check_timeline_thread.kill rescue nil
		@check_mentions_thread.kill rescue nil
		@check_dms_thread.kill      rescue nil
		@im_thread.kill             rescue nil
		@im.disconnect              rescue nil
	end

	def on_privmsg(m)
		target, mesg = *m.params

		m.ctcps.each {|ctcp| on_ctcp target, ctcp } if m.ctcp?

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

		mesg = escape_urls(mesg)

		if @opts.bitlify
			mesg = bitlify(mesg)
		elsif @opts.unuify
			mesg = unuify(mesg)
		end

		if @utf7
			mesg = Iconv.iconv("UTF-7", "UTF-8", mesg).join
			mesg = mesg.encoding!("ASCII-8BIT")
		end

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

					in_reply_to = nil
					if @opts.old_style_reply and mesg[/\A@(?>([A-Za-z0-9_]{1,15}))[^A-Za-z0-9_]/]
						screen_name = $1
						unless user = friend(screen_name)
							user = api("users/show/#{screen_name}")
						end
						if user and user.status
							in_reply_to = user.status.id
						elsif user
							user = api("users/show/#{user.id}", {}, { :authenticate => user.protected })
							in_reply_to = user.status.id if user.status
						end
					end

					q = { :status => mesg, :source => source }
					q.update(:in_reply_to_status_id => in_reply_to) if in_reply_to
					ret = api("statuses/update", q)
					log oops(ret) if ret.truncated
					ret.user.status = ret
					@me = ret.user
					log "Status updated"
				end
			when target.nick? # Direct message
				ret = api("direct_messages/new", { :user => target, :text => mesg })
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

	def on_ctcp(target, mesg)
		type, mesg = mesg.split(" ", 2)
		method = "on_ctcp_#{type.downcase}".to_sym
		send(method, target, mesg) if respond_to? method, true
	end; private :on_ctcp

	def on_ctcp_action(target, mesg)
		#return unless main_channel.casecmp(target).zero?
		command, *args = mesg.split(" ")
		case command.downcase
		when "call"
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
			#save_config
		when "utf7"
			begin
				require "iconv"
				@utf7 = !@utf7
				log "UTF-7 mode: #{@utf7 ? 'on' : 'off'}"
			rescue LoadError => e
				log "Can't load iconv."
			end
		when "list", "ls"
			if args.empty?
				log "/me list <NICK> [<NUM>]"
				return
			end
			nick = args.first
			if not nick.nick? or
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
		when /\A(un)?fav(?:ou?rite)?(!)?\z/
		# fav, unfav, favorite, unfavorite, favourite, unfavourite
			method   = $1.nil? ? "create" : "destroy"
			force    = !!$2
			entered  = $&.capitalize
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
					when status = @timeline[tid_or_nick]
						statuses.push status
					when friend = friend(tid_or_nick)
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
		when "link", "ln"
			args.each do |tid|
				if status = @timeline[tid]
					log "#{@opts.tid % tid}: #{permalink(status)}"
				else
					log "No such ID #{@opts.tid % tid}"
				end
			end
		when /\Aratios?\z/
			unless args.empty?
				args = args.first.split(":") if args.size == 1
				if @opts.dm and @opts.mentions and args.size < 3
					log "/me ratios <timeline> <dm> <mentions>"
					return
				elsif @opts.dm and args.size < 2
					log "/me ratios <timeline> <dm>"
					return
				elsif @opts.mentions and args.size < 2
					log "/me ratios <timeline> <mentions>"
					return
				end
				ratios = args.map {|ratio| ratio.to_f }
				if ratios.any? {|ratio| ratio <= 0.0 }
					log "Ratios must be greater than 0.0 and fractional values are permitted."
					return
				end
				@ratio.timeline = ratios[0]
				if @opts.dm
					@ratio.dm       = ratios[1]
					@ratio.mentions = ratios[2] if @opts.mentions
				elsif @opts.mentions
					@ratio.mentions = ratios[1]
				end
			end
			log "Intervals: #{@ratio.map {|ratio| interval ratio }.inspect}"
		when /\A(?:de(?:stroy|l(?:ete)?)|miss|oops|r(?:emove|m))\z/
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
			if b
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
			end
		when "name"
			name = mesg.split(" ", 2)[1]
			unless name.nil?
				@me = api("account/update_profile", { :name => name })
				@me.status.user = @me if @me.status
				log "You are named #{@me.name}."
			end
		when "email"
			# FIXME
			email = args.first
			unless email.nil?
				@me = api("account/update_profile", { :email => email })
				@me.status.user = @me if @me.status
			end
		when "url"
			# FIXME
			url = args.first || ""
			@me = api("account/update_profile", { :url => url })
			@me.status.user = @me if @me.status
		when "in", "location"
			location = mesg.split(" ", 2)[1] || ""
			@me = api("account/update_profile", { :location => location })
			@me.status.user = @me if @me.status
			location = (@me.location and @me.location.empty?) ? "nowhere" : "in #{@me.location}"
			log "You are #{location} now."
		when /\Adesc(?:ription)?\z/
			# FIXME
			description = mesg.split(" ", 2)[1] || ""
			@me = api("account/update_profile", { :description => description })
			@me.status.user = @me if @me.status
		#when /\Acolou?rs?\z/ # TODO
		#	# bg, text, link, fill and border
		#when "image", "img" # TODO
		#	url = args.first
		#	# DCC SEND
		#when "follow"# TODO
		#when "leave" # TODO
		when /\A(?:mention|re(?:ply)?)\z/ # reply, re, mention
			tid = args.first
			if status = @timeline[tid]
				text = mesg.split(" ", 3)[2]
				screen_name = "@#{status.user.screen_name}"
				if text.nil? or not text.include?(screen_name)
					text = "#{screen_name} #{text}"
				end
				ret = api("statuses/update", { :status => text, :source => source,
				                               :in_reply_to_status_id => status.id })
				log oops(ret) if ret.truncated
				msg = generate_status_message(status.text)
				url = permalink(status)
				log "Status updated (In reply to #{@opts.tid % tid}: #{msg} <#{url}>)"
				ret.user.status = ret
				@me = ret.user
			end
		when /\Aspoo(o+)?f\z/
			@sources = args.empty? \
			         ? @sources.size == 1 || $1 ? fetch_sources($1 && $1.size) \
			                                    : [[api_source, "tig.rb"]] \
			         : args.map {|src| [src.upcase != "WEB" ? src : "", "=#{src}"] }
			log @sources.map {|src| src[1] }.sort.join(", ")
		when "bot", "drone"
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
			save_config
		when "home", "h"
			if args.empty?
				log "/me home <NICK>"
				return
			end
			nick = args.first
			if not nick.nick? or
			   api("users/username_available", { :username => nick }).valid
				post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
				return
			end
			log "http://twitter.com/#{nick}"
		end unless command.nil?
	rescue APIFailed => e
		log e.inspect
	end; private :on_ctcp_action

	def on_whois(m)
		nick = m.params[0]
		unless nick.nick?
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
		channel = m.params[0]
		case
		when channel.casecmp(main_channel).zero?
			users = [@me]
			users.concat @friends.reverse if @friends
			users.each {|friend| whoreply channel, friend }
			post server_name, RPL_ENDOFWHO, @nick, channel
		when (@groups.key?(channel) and @friends)
			@groups[channel].each do |nick|
				whoreply channel, friend(nick)
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

			@channels << channel
			@channels.uniq!
			post @prefix, JOIN, channel
			post server_name, MODE, channel, "+mtio", @nick
			save_config
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel.casecmp(main_channel).zero?

		@channels.delete(channel)
		post @prefix, PART, channel, "Ignore group #{channel}, but setting is alive yet."
	end

	def on_invite(m)
		nick, channel = *m.params
		if not nick.nick? or @nick.casecmp(nick).zero?
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
			((@groups[channel] ||= []) << friend.screen_name).uniq!
			join channel, [friend]
			save_config
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
				(@groups[channel] ||= []).delete(friend.screen_name)
				post prefix(friend), PART, channel, "Removed: #{msg}"
				save_config
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
				log "Fixed: #{status.text}"
			else
				log "Status updated"
			end
		rescue LoadError
		end
	end

	def on_mode(m)
		channel = m.params[0]

		unless m.params[1]
			if channel.ch?
				mode = "+mt"
				mode += "i" unless channel.casecmp(main_channel).zero?
				post server_name, RPL_CHANNELMODEIS, @nick, channel, mode
				#post server_name, RPL_CREATEONTIME, @nick, channel, 0
			elsif channel.casecmp(@nick).zero?
				post server_name, RPL_UMODEIS, @nick, @nick, "+o"
			end
		end
	end

	private
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

	def check_timeline
		cmd = PRIVMSG
		q   = { :count => 200 }
		if @latest_id ||= nil
			q.update(:since_id => @latest_id)
		elsif not @me.statuses_count.zero? and not @me.friends_count.zero?
			cmd = NOTICE
		end

		api("statuses/friends_timeline", q).reverse_each do |status|
			@latest_id = status.id
			status.user.status = status
			user = status.user
			tid  = @timeline.push(status)
			tid  = nil unless @opts.tid

			@log.debug [status.id, user.screen_name, status.text].inspect

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
			@groups.each do |channel, members|
				next unless members.include?(user.screen_name)
				message(status, channel, tid, nil, cmd)
			end
		end
	end

	def generate_status_message(mesg)
		mesg = decode_utf7(mesg)
		mesg.gsub!("&gt;", ">")
		mesg.gsub!("&lt;", "<")
		#mesg.gsub!(/\r\n|[\r\n\t\u00A0\u1680\u180E\u2002-\u200D\u202F\u205F\u2060\uFEFF]/, " ")
		mesg.gsub!(/\r\n|[\r\n\t]/, " ")
		mesg.sub!(/#{Regexp.union(*@suffix_bl)}\z/, "") unless @suffix_bl.empty?
		mesg = untinyurl(mesg)
		mesg.strip
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

	def check_mentions
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
		end
	end

	def check_direct_messages
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
		end
	end

	def check_friends
		if @friends.nil?
			@friends = page("statuses/friends/#{@me.id}", @me.friends_count)
			if @opts.athack
				join main_channel, @friends
			else
				rest = @friends.map do |i|
					prefix = "+" #@drones.include?(i.id) ? "%" : "+" # FIXME ~&%
					"#{prefix}#{i.screen_name}"
				end.reverse.inject("@#{@nick}") do |r, nick|
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
			new_ids    = page("friends/ids/#{@me.id}", @me.friends_count)
			friend_ids = @friends.reverse.map {|friend| friend.id }

			(friend_ids - new_ids).each do |id|
				@friends.delete_if do |friend|
					if friend.id == id
						post prefix(friend), PART, main_channel, ""
						@me.friends_count -= 1
					end
				end
			end

			new_ids -= friend_ids
			unless new_ids.empty?
				new_friends = page("statuses/friends/#{@me.id}", new_ids.size)
				join main_channel, new_friends.delete_if {|friend|
					@friends.any? {|i| i.id == friend.id }
				}.reverse
				@friends.concat new_friends
				@me.friends_count += new_friends.size
			end
		end
	end

	def whoreply(channel, user)
		#     "<channel> <user> <host> <server> <nick>
		#         ( "H" / "G" > ["*"] [ ( "@" / "+" ) ]
		#             :<hopcount> <real name>"
		prefix = prefix(user)
		server = api_base.host
		real   = user.name
		mode   = case prefix.nick
			when @nick                     then "@"
			#when @drones.include?(user.id) then "%" # FIXME
			else                                "+"
		end
		post server_name, RPL_WHOREPLY, @nick, channel,
		     prefix.user, prefix.host, server, prefix.nick, "H*#{mode}", "0 #{real}"
	end

	def join(channel, users)
		max_params_count = @opts.max_params_count || 3
		params = []
		users.each do |user|
			prefix = prefix(user)
			post prefix, JOIN, channel
			params << prefix.nick
			next if params.size < max_params_count

			post server_name, MODE, channel, "+#{"v" * params.size}", *params
			params = []
		end
		post server_name, MODE, channel, "+#{"v" * params.size}", *params unless params.empty?
		users
	end

	def interval(ratio)
		now   = Time.now
		max   = @opts.maxlimit
		limit = 0.98 * @limit # 98% of the rate limit
		i     = 3600.0        # an hour in seconds
		i *= @ratio.inject {|sum, r| sum.to_f + r.to_f } +
		     @consums.delete_if {|t| t < now }.size
		i /= ratio.to_f
		i /= (max and 0 < max and max < limit) ? max : limit
	rescue => e
		@log.error e.inspect
		100
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

	def save_config
		config = {
			:groups    => @groups,
			:channels  => @channels,
			#:nicknames => @nicknames,
			:drones    => @drones,
		}
		@config.open("w") {|f| YAML.dump(config, f) }
	end

	def load_config
		@config.open do |f|
			config     = YAML.load(f)
			@groups    = config[:groups]    || {}
			@channels  = config[:channels]  || []
			#@nicknames = config[:nicknames] || {}
			@drones    = config[:drones]    || []
		end
	rescue Errno::ENOENT
	end

	def require_post?(path)
		%r{
			\A
			(?: status(?:es)?/update \z
			  | direct_messages/new \z
			  | friendships/create/
			  | account/ (?: end_session \z
			               | update_ )
			  | favou?ri(?:ing|tes)/create/
			  | notifications/
			  | blocks/create/ )
		}x === path
	end

	def api(path, query = {}, opts = {})
		path.sub!(%r{\A/+}, "")
		query = query.to_query_str

		authenticate = opts.fetch(:authenticate, true)

		uri = api_base(authenticate)
		uri.path += path
		uri.path += ".json" if path != "users/username_available"
		uri.query = query unless query.empty?
		@log.debug uri.inspect

		header = {}
		credentials = authenticate ? [@real, @pass] : nil
		req = case
			when path.include?("/destroy/")
				http_req :delete, uri, header, credentials
			when require_post?(path)
				http_req :post,   uri, header, credentials
			else
				http_req :get,    uri, header, credentials
		end

		ret = http(uri, 30, 30).request req

		#@etags[path] = ret["ETag"]

		if authenticate
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
		elsif ret["X-RateLimit-Remaining"]
			@limit_remaining_for_ip = ret["X-RateLimit-Remaining"].to_i
			@log.debug "IP based limit: #{@limit_remaining_for_ip}"
		end

		case ret
		when Net::HTTPOK # 200
			# Avoid Twitter's invalid JSON
			json = ret.body.strip
			json.sub!(/"request"\s*:\s*NULL\s*(?=[,}])/) {|m| m.downcase }
			json.sub!(/\A(?:false|true)\z/) {|m| "[#{m}]" }

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
				log "RateLimit: #{(s / 60.0).ceil} min remaining to get timeline"
				sleep s
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

	def page(path, max_count, authenticate = false)
		@limit_remaining_for_ip ||= 52
		limit = 0.98 * @limit_remaining_for_ip # 98% of IP based rate limit
		r     = []
		cpp   = nil # counts per page
		1.upto(limit) do |num|
			ret = api(path, { :page => num }, { :authenticate => authenticate })
			cpp ||= ret.size
			r.concat ret
			break if ret.empty? or num >= max_count / cpp.to_f or
			         ret.size != cpp or r.size >= max_count
		end
		r
	end

	def message(struct, target, tid = nil, str = nil, command = PRIVMSG)
		unless str
			status = struct.is_a?(Status) ? struct : struct.status
			str = status.text
			if command != PRIVMSG
				time = Time.parse(status.created_at) rescue Time.now
				str  = "#{time.strftime(@opts.strftime || "%m-%d %H:%M")} #{str}" # TODO: color
			end
			str = "#{str} #{@opts.tid % tid}" if tid
		end
		user        = (struct.is_a?(User) ? struct : struct.user).dup
		screen_name = user.screen_name

		user.screen_name = @nicknames[screen_name] || screen_name
		prefix = prefix(user)
		str    = generate_status_message(str)

		post prefix, command, target, str
	end

	def log(str)
		post server_name, NOTICE, main_channel, str.gsub(/\r\n|[\r\n]/, " ")
	end

	def untinyurl(text)
		text.gsub(@opts.untiny_whole_urls ? URI.regexp(%w[http https]) : %r{
			http:// (?:
				(?: bit\.ly | (?: tin | rub) yurl\.com
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
		login, key, len = @opts.bitlify.split(":", 3)
		unless login and key
			raise "bit.ly API key"
		end

		len      = (len || 20).to_i
		longurls = URI.extract(text, %w[http https]).uniq.map! do |url|
			URI.rstrip_unpaired_paren(url)
		end.reject {|url| url.size < len }

		return text if longurls.empty?

		bitly = URI("http://api.bit.ly/shorten")
		bitly.query = {
			:version => "2.0.1", :format => "json", :longUrl => longurls,
		}.to_query_str(";")
		@log.debug bitly

		req = http_req(:get, bitly, {}, [login, key])
		res = http(bitly, 5, 10).request(req)
		res = JSON.parse(res.body)
		res = res["results"]

		longurls.each do |longurl|
			text.gsub!(longurl) do |m|
				res[m] && res[m]["shortUrl"] || m
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
			url = URI.rstrip_unpaired_paren(url)
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

	def resolve_http_redirect(uri, limit = 3)
		return uri if limit.zero? or uri.nil?

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

	def decode_utf7(str)
		begin
			require "iconv"
			str.sub!(/\A(?:.+ > |.+\z)/) {|m| Iconv.iconv("UTF-8", "UTF-7", m).join }
			#FIXME str = "[utf7]: #{str}" if str =~ /[^a-z0-9\s]/i
			str
		rescue LoadError, Iconv::IllegalSequence
			str
		end
	end

	def fetch_sources(n = nil)
		n    = n.to_i
		uri  = URI("http://wedata.net/databases/TwitterSources/items.json")
		json = http(uri, 5, 10).request(http_req(:get, uri)).body
		sources = JSON.parse json
		sources.map! {|item| [item["data"]["source"], item["name"]] }.push ["", "web"]
		if (1 ... sources.size).include?(n)
			sources = Array.new(n) { sources.delete_at(rand(sources.size)) }.compact
		end
		sources
	rescue => e
		@log.error e.inspect
		log "An error occured while loading wedata.net."
		@sources || [[api_source, "tig.rb"]]
	end

	def fetch_suffix_bl(r = [])
		uri = URI("http://svn.coderepos.org/share/platform/twitterircgateway/suffixesblacklist.txt")
		source = http(uri, 5, 10).request(http_req(:get, uri)).body
		source.encoding!("UTF-8") if source.respond_to?(:encoding) and source.encoding == Encoding::BINARY
		source.split
	rescue Errno::ECONNREFUSED, Timeout::Error => e
		@log.error "Failed to get suffix_bl data from #{uri.host}: #{e.inspect}"
		""
	end

	def http_req(method, uri, header = {}, credentials = nil)
		accepts = ["*/*;q=0.1"]
		#require "mime/types"; accepts.unshift MIME::Types.of(uri.path).first.simplified
		types   = { "json" => "application/json", "txt" => "text/plain" }
		ext     = uri.path[/[^.]+\z/]
		accepts.unshift types[ext] if types.key?(ext)

		header["User-Agent"]      ||= user_agent
		header["Accept"]          ||= accepts.join(",")
		header["Accept-Charset"]  ||= "UTF-8,*;q=0.0" if ext != "json"
		#header["Accept-Language"] ||= @opts.lang # "en-us,en;q=0.9,ja;q=0.5"
		#header["If-None-Match"]   ||= @etags[uri.to_s] if @etags[uri.to_s]

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

	def http(uri, open_timeout = nil, read_timeout = nil)
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
			http.verify_mode = OpenSSL::SSL::VERIFY_NONE
		end
		http
	rescue => e
		@log.error e
	end

	def exists_url?(uri, limit = 1)
		ret = nil
		return ret if limit.zero? or uri.nil?

		req = http_req :head, uri
		http(uri, 3, 2).request(req) do |res|
			ret = case res
				when Net::HTTPSuccess
					true
				when Net::HTTPRedirection
					uri = resolve_http_redirect(uri)
					exists_url?(uri, limit - 1)
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

	def escape_urls(text)
		original_text = text.dup
		urls = []
		(text.split(/[\s<>]+/) + [text]).each do |str|
			next if /%[0-9A-Fa-f]{2}/ === str
			# URI::UNSAFE + "#"
			escaped_str = URI.escape(str, %r{[^-_.!~*'()a-zA-Z0-9;/?:@&=+$,\[\]#]})
			URI.extract(escaped_str, %w[http https]).each do |url|
				url = URI(URI.rstrip_unpaired_paren(url))
				if not urls.include?(uri.to_s) and exists_url?(uri)
					urls << uri.to_s
				end
			end if escaped_str != str
		end
		urls.each do |url|
			unescaped_url = URI.unescape(url)
			unescaped_url.encoding!("ASCII-8BIT")
			text.gsub!(unescaped_url) { url }
		end
		log "Percent encoded: #{text}" if text != original_text
		text
	rescue => e
		@log.error e
		text
	end

	def oops(status)
		"Oops! Your update was over 140 characters. We sent the short version" <<
		" to your friends (they can view the entire update on the Web <" <<
		permalink(status) << ">)."
	end

	def user_agent
		"#{self.class}/#{server_version} (#{File.basename(__FILE__)}; Net::IRC::Server)" <<
		" Ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM})"
	end

	def permalink(struct)
		path = struct.is_a?(Status) ? "#{struct.user.screen_name}/statuses/#{struct.id}" \
		                            : struct.screen_name
		"http://twitter.com/#{path}"
	end

	def source
		@sources[rand(@sources.size)].first
	end

	def initial_message
		super
		post server_name, RPL_ISUPPORT, @nick,
		     "NETWORK=Twitter", "CHANTYPES=#", "NICKLEN=15", "TOPICLEN=420",
		     "PREFIX=(hov)%@+", "CHANMODES=#{available_channel_modes}",
		     "are supported by this server"
	end

	User   = Struct.new(:id, :name, :screen_name, :location, :description, :url,
	                    :following, :notifications, :protected, :time_zone,
	                    :utc_offset, :created_at, :friends_count, :followers_count,
	                    :statuses_count, :favourites_count, :verified, :verified_profile,
	                    :profile_image_url, :profile_background_color, :profile_text_color,
	                    :profile_link_color, :profile_sidebar_fill_color,
	                    :profile_sidebar_border_color, :profile_background_image_url,
	                    :profile_background_tile, :status)
	Status = Struct.new(:id, :text, :source, :created_at, :truncated, :favorited,
	                    :in_reply_to_status_id, :in_reply_to_user_id,
	                    :in_reply_to_screen_name, :user)
	DM     = Struct.new(:id, :text, :created_at,
	                    :sender_id, :sender_screen_name, :sender,
	                    :recipient_id, :recipient_screen_name, :recipient)

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
		]

		def initialize(size = nil)
			@seq  = Roman
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
		undef update, merge, merge!, replace
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
			else
				members = keys
				members.concat TwitterIrcGateway::User.members
				members.concat TwitterIrcGateway::Status.members
				members.concat TwitterIrcGateway::DM.members
				members.map! {|m| m.to_sym }
				members.uniq!
				Struct.new(*members).new
		end
		each do |k, v|
			struct[k.to_sym] = v.respond_to?(:to_tig_struct) ? v.to_tig_struct : v
		end
		struct
	end

	# { :f => nil }     #=> "f"
	# { "f" => "" }     #=> "f="
	# { "f" => "v" }    #=> "f=v"
	# { "f" => [1, 2] } #=> "f=1&f=2"
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
		/\A[#&+!]/ === self
	end

	def nick? # Twitter screen_name (username)
		/\A[A-Za-z0-9_]{1,15}\z/ === self
	end

	def encoding! enc
		force_encoding enc if respond_to? :force_encoding
	end
end

module URI::Escape
	# URI.escape("あ１") #=> "%E3%81%82\xEF\xBC\x91"
	# URI("file:///４")  #=> #<URI::Generic:0x9d09db0 URL:file:/４>
	#   "\\d" -> "0-9" for Ruby 1.9
	alias :_orig_escape :escape
	def escape str, unsafe = %r{[^-_.!~*'()a-zA-Z0-9;/?:@&=+$,\[\]]}
		_orig_escape(str, unsafe)
	end
	alias :encode :escape

	def encode_component str, unsafe = /[^-_.!~*'()a-zA-Z0-9 ]/
		_orig_escape(str, unsafe).tr(" ", "+")
	end

	def rstrip_unpaired_paren str
		str.sub(%r{(/[^/()]*(?:\([^/()]*\)[^/()]*)*)\)[^/()]*\z}, "\\1")
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
