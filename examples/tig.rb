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
		name: username mentions secure tid

		# Same as TwitterIrcGateway.exe.config.sample
		#   (90, 360 and 300 seconds)
		#name: username dm ratio=4:1 maxlimit=50
		#name: username dm ratio=20:5:6 maxlimit=62 mentions
		#
		# <http://cheebow.info/chemt/archives/2009/04/posttwit.html>
		#   (60, 360 and 150 seconds)
		#name: username dm ratio=30:12:5 maxlimit=94 mentions
		#
		# for Jabber
		#name: username jabber=username@example.com:jabberpasswd secure
	}

### athack

If `athack` client option specified,
all nick in join message is leading with @.

So if you complemente nicks (e.g. Irssi),
it's good for Twitter like reply command (@nick).

In this case, you will see torrent of join messages after connected,
because NAMES list can't send @ leading nick (it interpreted op.)

### tid[=<color>[,<bgcolor>]]

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
	    43:6 |      42s |    5m |      N/A |
	  43:3:3 |      42s |   10m |      10m |
	---------+----------+-------+----------|
	 80:3:15 |      45s |   20m |       4m |
	---------+----------+-------+----------|
	 30:4:15 |       1m | 7m30s |       2m |
	   1:1:1 |     110s |  110s |     110s |
	---------------------------------------+

### dm[=<ratio>]

### mentions[=<ratio>]

### maxlimit=<hourly_limit>

### secure

Force SSL connection for API with credentials.

### clientspoofing

### httpproxy=[<user>[:<password>]@]<address>[:<port>]

### main_channel=<#channel>

### api_source=<source>

### max_params_count=<number>

### check_friends_interval=<seconds>

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

$LOAD_PATH << "lib" << "../lib"
$KCODE = "u" if RUBY_VERSION < "1.9" # json use this

require "rubygems"
require "net/irc"
require "net/http"
require "uri"
require "socket"
require "time"
require "logger"
require "yaml"
require "pathname"
require "ostruct"
require "json"

module Net::IRC::Constants; RPL_WHOISBOT = "335" end

class TwitterIrcGateway < Net::IRC::Server::Session
	def server_name
		"twittergw"
	end

	def server_version
		rev = %q$Revision$.split[1]
		rev &&= "+r#{rev}"
		"0.0.0#{rev}"
	end

	def main_channel
		@opts.main_channel || "#twitter"
	end

	def api_base
		scheme = @opts.secure ? "https" : "http"
		URI("#{scheme}://twitter.com/")
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
		@timeline  = []
		@groups    = {}
		@channels  = [] # joined channels (groups)
		@nicknames = {}
		@drones    = []
		@config    = Pathname.new(ENV["HOME"]) + ".tig"
		@suffix_bl = []
		@etags     = {}
		@limit     = hourly_limit
		@tmap      = TypableMap.new
		@friends   =
		@im        =
		@im_thread =
		@utf7      = nil
		load_config
	end

	def on_user(m)
		super

		@real, *@opts = (@opts.name || @real).split(/ +/)
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

		retry_count = 0
		begin
			@me = api("account/update_profile") #api("account/verify_credentials")
		rescue APIFailed => e
			@log.error e.inspect
			sleep 1
			retry_count += 1
			retry if retry_count < 3
			log "Failed to access API 3 times." <<
			    " Please check Twitter Status <http://status.twitter.com/> and try again later."
			finish
		end

		@user   = "id=%09d" % @me.id
		@host   = hostname(@me)
		@prefix = Prefix.new("#{@me.screen_name}!#{@user}@#{@host}")

		#post NICK, @me.screen_name if @nick != @me.screen_name
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+mto", @prefix.nick
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
		return on_ctcp(m[0], ctcp_decoding(m[1])) if m.ctcp?

		target, mesg = *m.params
		ret          = nil
		retry_count  = 3

		if @utf7
			mesg = Iconv.iconv("UTF-7", "UTF-8", mesg).join
			mesg = mesg.force_encoding("ASCII-8BIT") if mesg.respond_to?(:force_encoding)
		end

		begin
			if target =~ /\A#/
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
					ret = api("statuses/update", { :status => mesg, :source => source })
					log oops(ret) if ret.truncated
					ret.user.status = ret
					@me = ret.user
				end
			else # direct message
				ret = api("direct_messages/new", { :user => target, :text => mesg })
			end
			raise APIFailed, "API failed" unless ret
			log "Status Updated"
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
		_, command, *args = mesg.split(/ +/)
		case command
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
			unless (1..200).include?(count = args[1].to_i)
				count = 20
			end
			to  = nick == @nick ? server_name : nick
			res = api("statuses/user_timeline/#{nick}",
			          { :count => count }, { :authenticate => false })
			res.reverse_each do |s|
				time = Time.parse(s.created_at) rescue Time.now
				post to, NOTICE, main_channel,
				     "#{time.strftime "%m-%d %H:%M"} #{generate_status_message(s.text)}"
			end
			unless res
				post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			end
		when /\A(un)?fav(?:ou?rite)?(!)?\z/
		# fav, unfav, favorite, unfavorite, favourite, unfavourite
			method   = $1.nil? ? "create" : "destroy"
			force    = !!$2
			entered  = $&.capitalize
			statuses = []
			if args.empty?
				if method == "create"
					id = @timeline.last
					@tmap.any? do |tid, v|
						if v.id == id
							statuses.push v
						end
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
					when status = @tmap[tid_or_nick]
						statuses.push status
					when friend = (@friends || []).find {|i| i.screen_name.casecmp(tid_or_nick).zero? }
						if friend.status
							statuses.push friend.status
						else
							log "#{tid_or_nick} has no status."
						end
					else
						log "No such ID/NICK #{colored_tid(tid_or_nick)}"
					end
				end
			end
			@favorites ||= []
			statuses.each do |status|
				if not force and method == "create" and
				   @favorites.find {|i| i.id == status.id }
					log "The status is already favorited! <#{permalink(status)}>"
					next
				end
				res = api("favorites/#{method}/#{status.id}")
				log "#{entered}: #{res.user.screen_name}: #{generate_status_message(res.text)}"
				if method == "create"
					@favorites.push res
				else
					@favorites.delete_if {|i| i.id == res.id }
				end
			end
		when "link", "ln"
			args.each do |tid|
				if @tmap[tid]
					log "#{colored_tid(tid)}: #{permalink(@tmap[tid])}"
				else
					log "No such ID #{colored_tid(tid)}"
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
					if status = @tmap[tid]
						if "id=%09d" % status.user.id == @user
							statuses.push status
						else
							log "The status you specified by the ID #{colored_tid(tid)} is not yours."
						end
					else
						log "No such ID #{colored_tid(tid)}"
					end
				end
			end
			b = false
			statuses.each do |status|
				res = api("statuses/destroy/#{status.id}")
				@tmap.delete_if {|tid, v| v.id == res.id }
				b = @me.status and @me.status.id == status.id
				log "Destroyed: #{res.text}"
			end
			if b
				sleep 2
				@me = api("account/update_profile") #api("account/verify_credentials")
				if @me.status
					@me.status.user = @me
					msg = generate_status_message(@me.status.text)
					@tmap.any? do |tid, v|
						if v.id == @me.status.id
							msg << " " << colored_tid(tid)
						end
					end
					post @prefix, TOPIC, main_channel, msg
				end
			end
		when "name"
			name = mesg.split(/ +/, 3)[2]
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
			location = mesg.split(/ +/, 3)[2] || ""
			@me = api("account/update_profile", { :location => location })
			@me.status.user = @me if @me.status
			location = @me.location and @me.location.empty? ? "nowhere" : "in #{@me.location}"
			log "You are #{location} now."
		when /\Adesc(?:ription)?\z/
			# FIXME
			description = mesg.split(/ +/, 3)[2] || ""
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
			if status = @tmap[tid]
				text = mesg.split(/ +/, 4)[3]
				ret  = api("statuses/update", { :status => text, :source => source,
				                                :in_reply_to_status_id => status.id })
				log oops(ret) if ret.truncated
				msg = generate_status_message(status.text)
				url = permalink(status)
				log "Status updated (In reply to #{colored_tid(tid)}: #{msg} <#{url}>)"
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
				user = (@friends || []).find {|i| i.screen_name.casecmp(bot).zero? }
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
		end
	rescue APIFailed => e
		log e.inspect
	end

	def on_whois(m)
		nick  = m.params[0]
		users = [@me]
		users.concat @friends if @friends
		user = users.find {|i| i.screen_name.casecmp(nick).zero? }
		if not user and nick.size < 16
			ret = api("users/username_available", { :username => nick })
			# TODO: 404 suspended
			if ret and not ret.valid
				user = api("users/show/#{nick}", {}, { :authenticate => false })
			end
		end
		unless user
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
			return
		end

		host      = hostname user
		desc      = user.name
		desc      = "#{desc} / #{user.description}".gsub(/\s+/, " ") if user.description and not user.description.empty?
		signon_at = Time.parse(user.created_at).to_i rescue 0
		idle_sec  = (Time.now - (user.status ? Time.parse(user.status.created_at) : signon_at)).to_i rescue 0
		location  = user.location
		location  = "SoMa neighborhood of San Francisco, CA" if location.nil? or location.empty?
		post server_name, RPL_WHOISUSER,   @nick, nick, "id=%09d" % user.id, host, "*", desc
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
				whoreply channel, @friends.find {|i| i.screen_name == nick }
			end
			post server_name, RPL_ENDOFWHO, @nick, channel
		else
			post server_name, ERR_NOSUCHNICK, @nick, "No such nick/channel"
		end
	end

	def whoreply(channel, u)
		#     "<channel> <user> <host> <server> <nick>
		#         ( "H" / "G" > ["*"] [ ( "@" / "+" ) ]
		#             :<hopcount> <real name>"
		nick = u.screen_name
		nick = "@#{nick}" if @opts.athack
		user = "id=%09d" % u.id
		host = hostname u
		serv = api_base.host
		real = u.name
		mode = case u.screen_name
			when @me.screen_name        then "@"
			#when @drones.include?(u.id) then "%" # FIXME
			else                                "+"
		end
		post server_name, RPL_WHOREPLY, @nick, channel, user, host, serv, nick, "H*#{mode}", "0 #{real}"
	end; private :whoreply

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		channels.each do |channel|
			next if channel.casecmp(main_channel).zero?

			@channels << channel
			@channels.uniq!
			post @prefix, JOIN, channel
			post server_name, MODE, channel, "+mtio", @prefix.nick
			save_config
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel.casecmp(main_channel).zero?

		@channels.delete(channel)
		post @nick, PART, channel, "Ignore group #{channel}, but setting is alive yet."
	end

	def on_invite(m)
		nick, channel = *m.params
		return if channel.casecmp(main_channel).zero?

		f = (@friends || []).find {|i| i.screen_name.casecmp(nick).zero? }
		if f
			((@groups[channel] ||= []) << f.screen_name).uniq!
			post generate_prefix(f), JOIN, channel
			post server_name, MODE, channel, "+v", nick
			save_config
		else
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	def on_kick(m)
		channel, nick, mes = *m.params
		return if channel == main_channel

		f = (@friends || []).find {|i| i.screen_name.casecmp(nick).zero? }
		if f
			(@groups[channel] ||= []).delete(f.screen_name)
			post nick, PART, channel
			save_config
		else
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
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
				@tmap.delete_if {|k, v| v.id == deleted.id }
				log "Fixed: #{status.text}"
			else
				log "Status updated"
			end
		rescue LoadError
		end
	end

	private
	def check_timeline
		q = { :count => 200 }
		q[:since_id] = @timeline.last unless @timeline.empty?
		api("statuses/friends_timeline", q).reverse_each do |status|
			id = status.id
			next if id.nil? or @timeline.include?(id)

			@timeline << id

			status.user.status = status
			tid  = @opts.tid ? @tmap.push(status) : nil
			user = status.user

			@log.debug [id, user.screen_name, status.text]

			if user.id == @me.id
				mesg = generate_status_message(status.text)
				mesg << " " << colored_tid(tid) if @opts.tid
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
					end
				end

				message(status, main_channel, tid)
			end
			@groups.each do |channel, members|
				next unless members.include?(user.screen_name)
				message(status, channel, tid)
			end
		end
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline = @timeline.last(200)
	end

	def generate_status_message(mesg)
		@log.debug mesg.gsub(/\r\n|[\r\n]/, "<\\n>")

		mesg = decode_utf7(mesg)
		#mesg = mesg.gsub(/&[gl]t;|\r\n|[\r\n\t\u00A0\u1680\u180E\u2002-\u200D\u202F\u205F\u2060\uFEFF]/) do
		mesg = mesg.gsub(/&[gl]t;|\r\n|[\r\n\t]/) do
			case $&
			when "&lt;" then "<"
			when "&gt;" then ">"
			else " "
			end
		end
		mesg = mesg.sub(/\s*#{Regexp.union(*@suffix_bl)}\s*\z/, "") unless @suffix_bl.empty?
		mesg = untinyurl(mesg)
	end

	def generate_prefix(u)
		nick = u.screen_name
		nick = "@#{nick}" if @opts.athack
		user = "id=%09d" % u.id
		host = hostname u
		"#{nick}!#{user}@#{host}"
	end

	def check_mentions
		return if @timeline.empty?
		@prev_mention_id ||= @timeline.first
		api("statuses/mentions", {
			:count    => 200,
			:since_id => @prev_mention_id
		}).reverse_each do |mention|
			id = @prev_mention_id = mention.id
			next if id.nil? or @timeline.include?(id)

			@timeline << id

			mention.user.status = mention
			tid  = @opts.tid ? @tmap.push(mention) : nil
			user = mention.user

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
		api("direct_messages",
		    @prev_dm_id ? { :count => 200, :since_id => @prev_dm_id } \
		                : { :count => 1 }).reverse_each do |mesg|
			id   = @prev_dm_id = mesg.id
			user = mesg.sender
			tid  = nil
			text = generate_status_message(mesg.text)
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
						post generate_prefix(friend), PART, main_channel, ""
					end
				end
			end

			new_ids -= friend_ids
			unless new_ids.empty?
				new_friends = page("statuses/friends/#{@me.id}", new_ids.size)
				join main_channel, new_friends.delete_if do |friend|
					@friends.any? {|i| i.id == friend.id }
				end.reverse
				@friends.concat new_friends
			end
		end
	end

	def join(channel, users)
		max_params_count = @opts.max_params_count || 3
		params = []
		users.each do |user|
			post generate_prefix(user), JOIN, channel
			nick = user.screen_name
			nick = "@#{nick}" if @opts.athack
			params << nick
			next if params.size < max_params_count

			post server_name, MODE, channel, "+#{"v" * params.size}", *params
			params = []
		end
		post server_name, MODE, channel, "+#{"v" * params.size}", *params unless params.empty?
		users
	end

	def interval(ratio)
		i     = 3600.0       # an hour in seconds
		limit = 0.98 * @limit # 98% of rate limit
		max   = @opts.maxlimit
		i *= @ratio.inject {|sum, r| sum.to_f + r.to_f }
		i /= ratio.to_f
		i /= (max and max < limit) ? max : limit
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
						@log.debug [msg.from, msg.body]
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

	def api(path, q = {}, opts = { :authenticate => true })
		path = path.sub(%r{\A/+}, "")
		q    = q.inject([]) do |r, (k, v)|
			r << "#{k}=#{URI.escape(v.to_s, /[^-.!~*'()A-Za-z0-9_]/)}" unless v.nil?
			r
		end.join("&")

		uri = api_base
		if not opts[:authenticate] and @opts.secure
			uri.scheme = "http"
			uri = URI(uri.to_s)
		end
		uri.path += path
		uri.path += ".json" if path != "users/username_available"
		uri.query = q unless q.empty?
		@log.debug uri.inspect

		require "net/https" if uri.is_a? URI::HTTPS

		http = case
			when httpproxy_regex === @opts.httpproxy
				Net::HTTP.new(uri.host, uri.port, $3, $4.to_i, $1, $2)
			when ENV["HTTP_PROXY"], ENV["http_proxy"]
				proxy = URI(ENV["HTTP_PROXY"] || ENV["http_proxy"])
				Net::HTTP.new(uri.host, uri.port,
				              proxy.host, proxy.port, proxy.user, proxy.password)
			else
				Net::HTTP.new(uri.host, uri.port)
		end
		http.open_timeout = 30 # nil by default
		http.read_timeout = 30 # 60 by default
		if uri.is_a? URI::HTTPS
			http.use_ssl     = true
			http.verify_mode = OpenSSL::SSL::VERIFY_NONE
		end

		req = case
			when path.include?("/destroy/") then Net::HTTP::Delete.new uri.request_uri
			when require_post?(path)        then Net::HTTP::Post.new   uri.path
			else                                 Net::HTTP::Get.new    uri.request_uri
		end
		req["User-Agent"]      = user_agent
		req["Accept"]          = "application/json,*/*;q=0.1"
		req["Accept-Language"] = @opts.lang # "en-us,en;q=0.9,ja;q=0.5"
		#req["If-None-Match"]   = @etags[path] if @etags[path]
		if req.request_body_permitted?
			req["Content-Type"] ||= "application/x-www-form-urlencoded"
			req.body = uri.query
		end
		req.basic_auth @real, @pass if opts[:authenticate]

		ret = http.request req

		@etags[path] = ret["ETag"]

		if opts[:authenticate]
			hourly_limit = ret["X-RateLimit-Limit"].to_i
			if not hourly_limit.zero? and @limit != hourly_limit
				msg = "The rate limit per hour was changed: #{@limit} to #{hourly_limit}"
				log msg
				@log.info msg
				@limit = hourly_limit
			end
		elsif ret["X-RateLimit-Remaining"]
			@limit_remaining_for_ip = ret["X-RateLimit-Remaining"].to_i
			@log.debug "IP based limit: #{@limit_remaining_for_ip}"
		end

		case ret
		when Net::HTTPOK # 200
			# Avoid Twitter's invalid JSON
			json = ret.body.strip
			json = json.sub(/"request"\s*:\s*NULL\s*(?=[,}])/) {|m| m.downcase }
			json = json.sub(/\A(?:false|true)\z/) {|m| "[#{m}]" }

			res = JSON.parse json
			if res.is_a?(Hash) and res["error"] # and not res["response"]
				if @error != res["error"]
					@error = res["error"]
					log @error
				end
				raise APIFailed, res["error"]
			end
			res.to_tig_struct
		when Net::HTTPNotModified # 304
			[]
		when Net::HTTPBadRequest # 400: exceeded the rate limitation
			if ret.key?("X-RateLimit-Reset")
				s = Time.at(ret["X-RateLimit-Reset"].to_i) - Time.now
				log "#{(s / 60.0).ceil} min remaining."
				#sleep s
			end
			raise APIFailed, "#{ret.code}: #{ret.message}"
		when Net::HTTPUnauthorized # 401
			log "Please check your username/email and password combination."
			raise APIFailed, "#{ret.code}: #{ret.message}"
		else
			raise APIFailed, "Server Returned #{ret.code} #{ret.message}"
		end
	rescue Errno::ETIMEDOUT, JSON::ParserError, IOError, Timeout::Error, Errno::ECONNRESET => e
		raise APIFailed, e.inspect
	end

	def page(interface, max_count, authenticate = false)
		@limit_remaining_for_ip ||= 52
		limit = 0.98 * @limit_remaining_for_ip # 98% of IP based rate limit
		r     = []
		cpp   = nil # counts per page
		1.upto(limit) do |num|
			ret = api(interface, { :page => num }, { :authenticate => authenticate })
			cpp ||= ret.size
			r.concat ret
			break if ret.empty? or num >= max_count / cpp.to_f or
			         ret.size != cpp or r.size >= max_count
		end
		r
	end

	def message(struct, target, tid =nil, str = nil)
		unless str
			str = struct.is_a?(Status) ? struct.text : struct.status.text
			str = "#{str} #{colored_tid(tid)}" if tid
		end
		user        = (struct.is_a?(User) ? struct : struct.user).dup
		screen_name = user.screen_name
		user.screen_name = @nicknames[screen_name] || screen_name
		prefix = generate_prefix(user)
		str    = generate_status_message(str)

		post prefix, PRIVMSG, target, str
	end

	def log(str)
		post server_name, NOTICE, main_channel, str.gsub(/\r\n|[\r\n]/, " ")
	end

	def untinyurl(text)
		text.gsub(%r{
			http:// (?:
				(?: bit\.ly | (?:(preview\.)? tin | rub) yurl\.com |
				    is\.gd | cli\.gs | tr\.im | u\.nu | airme\.us |
					 ff\.im | twurl.nl | bkite\.com | tumblr\.com
			   ) / [0-9a-z=-]+ (\?)? |
				blip\.fm/~ (?>[0-9a-z]+) (?!/)
			)
		}ix) do |url|
			uri = URI(url)
			uri.host  = uri.host.sub($1, "") if $1
			uri.query = nil if $2
			"#{fetch_location_header(uri) || url}"
		end
	end

	def fetch_location_header(uri, limit = 3)
		return uri if limit == 0 or uri.nil? or uri.is_a? URI::HTTPS

		httpproxy_regex.match(@opts.httpproxy)
		http = Net::HTTP.new uri.host, uri.port, $3, $4.to_i, $1, $2
		http.open_timeout = 3
		http.read_timeout = 2

		req = Net::HTTP::Head.new uri.request_uri, { "User-Agent" => user_agent }

		begin
			http.request(req) do |res|
				if res.is_a?(Net::HTTPRedirection) and res.key?("Location")
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
					uri = fetch_location_header(location, limit - 1)
				end
			end
		rescue Timeout::Error, Net::HTTPBadResponse
		end
		uri
	end

	def decode_utf7(str)
		begin
			require "iconv"
			str = str.sub(/\A(?:.+ > |.+\z)/) {|m| Iconv.iconv("UTF-8", "UTF-7", m).join }
			#FIXME str = "[utf7]: #{str}" if str =~ /[^a-z0-9\s]/i
			str
		rescue LoadError, Iconv::IllegalSequence
			str
		end
	end

	def fetch_sources(n = nil)
		json = http_get URI("http://wedata.net/databases/TwitterSources/items.json")
		sources = JSON.parse json
		sources.map! {|item| [item["data"]["source"], item["name"]] }.push ["", "web"]
		if n.is_a?(Integer) and n < sources.size
			sources = Array.new(n) { sources.delete_at(rand(sources.size)) }.compact
		end
		sources
	rescue => e
		@log.error e.inspect
		log "An error occured while loading wedata.net."
		@sources || [[api_source, "tig.rb"]]
	end

	def fetch_suffix_bl(r = [])
		source = http_get URI("http://svn.coderepos.org/share/platform/twitterircgateway/suffixesblacklist.txt")
		if source.respond_to?(:encoding) and source.encoding == Encoding::BINARY
			source.force_encoding("UTF-8")
		end
		source.split
	rescue
		r
	end

	def http_get(uri)
		accepts = ["*/*;q=0.1"]
		#require "mime/types"; accepts.unshift MIME::Types.of(uri.path).first.simplified
		types   = { "json" => "application/json", "txt" => "text/plain" }
		ext     = uri.path[/[^.]+\z/]
		accepts.unshift types[ext] if types.key?(ext)

		httpproxy_regex.match(@opts.httpproxy)
		http = Net::HTTP.new(uri.host, uri.port, $3, $4.to_i, $1, $2)
		http.open_timeout = 5
		http.read_timeout = 10

		req = Net::HTTP::Get.new uri.request_uri, {
			"User-Agent" => user_agent,
			"Accept"     => accepts.join(","),
		}
		req["Accept-Charset"] = "UTF-8,*;q=0.0" if ext != "json"
		#req["If-None-Match"]  = @etags[uri.to_s] if @etags[uri.to_s]

		begin
			res = http.request req
			@etags[uri.to_s] = res["ETag"]
			res.body
		rescue Timeout::Error
		end
	end

	def oops(status)
		"Oops! Your update was over 140 characters. We sent the short version" <<
		" to your friends (they can view the entire update on the Web <" <<
		permalink(status) << ">)."
	end

	def colored_tid(tid)
		c = @opts.tid # expect: 0..15, true, "0,1"
		b = nil
		if c.is_a?(String) and c.include?(",")
			c, b = c.split(",", 2)
			c = c.to_i
			b = b.to_i
		end
		c = 10 unless c.is_a?(Integer) and (0 .. 15).include?(c)
		if b.is_a?(Integer) and (0 .. 15).include?(b)
			"\003%02d,%02d[%s]\017" % [c, b, tid]
		else
			"\003%02d[%s]\017"      % [c, tid]
		end
	end

	def hostname(user)
		hosts = [api_base.host]
		hosts << "protected" if user.protected
		hosts << "bot"       if @drones.include?(user.id)
		hosts.join("/")
	end

	def user_agent
		"#{self.class}/#{server_version} (#{File.basename(__FILE__)}; Net::IRC::Server)" <<
		" Ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM})"
	end

	def permalink(status); "#{api_base}#{status.user.screen_name}/statuses/#{status.id}" end
	def source;            @sources[rand(@sources.size)].first                           end
	def httpproxy_regex;   /\A(?:([^:@]+)(?::([^@]+))?@)?([^:]+)(?::(\d+))?\z/           end

	User   = Struct.new(:id, :name, :screen_name, :location, :description, :url,
	                    :following, :notifications, :protected, :time_zone,
	                    :utc_offset, :created_at, :friends_count, :followers_count,
	                    :statuses_count, :favourites_count, :profile_image_url,
	                    :profile_background_color, :profile_text_color,
	                    :profile_link_color, :profile_sidebar_fill_color,
	                    :profile_sidebar_border_color, :profile_background_image_url,
	                    :profile_background_tile, :status)
	Status = Struct.new(:id, :text, :source, :created_at, :truncated, :favorited,
	                    :in_reply_to_status_id, :in_reply_to_user_id,
	                    :in_reply_to_screen_name, :user)

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
			#when keys.all? {|k| TwitterIrcGateway::User.members.include? k.to_sym } # Ruby 1.9
			#when keys.all? {|k| TwitterIrcGateway::User.members.include? k } # Ruby 1.8
			when keys.all? {|k| TwitterIrcGateway::User.members.map {|m| m.to_s }.include? k }
				TwitterIrcGateway::User.new
			when keys.all? {|k| TwitterIrcGateway::Status.members.map {|m| m.to_s }.include? k }
				TwitterIrcGateway::Status.new
			else
				members = (TwitterIrcGateway::User.members + TwitterIrcGateway::Status.members +
				#           keys.map {|m| m.to_sym }).uniq # Ruby 1.9
				           keys).uniq.map {|m| m.to_sym }
				Struct.new(*members).new
		end
		each do |k, v|
			struct[k.to_sym] = v.respond_to?(:to_tig_struct) ? v.to_tig_struct : v
		end
		struct
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
