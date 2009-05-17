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

	twitter {
		host: localhost
		port: 16668
		name: username@example.com mentions secure tid
		# for Jabber
		#name: username@example.com jabber=username@example.com:jabberpasswd mentions secure
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
use jabber to get friends timeline.

You must setup im notifing settings in the site and
install "xmpp4r-simple" gem.

	$ sudo gem install xmpp4r-simple

Be careful for managing password.

### alwaysim

Use IM instead of any APIs (e.g. post)

### ratio=<timeline>:<friends>[:<mentions>]

77:1[:12] by default. 47 seconds, an hour and 5 minutes.

### mentions[=<ratio>]

### maxlimit=<hourly limit>

### secure

### clientspoofing

### httpproxy=[<user>[:<password>]@]<address>[:<port>]

### main_channel=<#channel>

### api_source=<source>

Force SSL for API.

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
require "net/https"
require "uri"
require "socket"
require "time"
require "logger"
require "yaml"
require "pathname"
require "cgi"
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
		@opts["main_channel"] || "#twitter"
	end

	def api_base
		URI("http://twitter.com/")
	end

	def api_source
		"#{@opts["api_source"] || "tigrb"}"
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
		@limit     = hourly_limit
		load_config
	end

	def on_user(m)
		super

		@real, *@opts = (@opts.name || @real).split(/\s+/)
		@opts = @opts.inject({}) do |r, i|
			key, value = i.split("=")
			key = "mentions" if key == "replies" # backcompat
			r.update key => case value
				when nil                      then true
				when /\A\d+\z/                then value.to_i
				when /\A(?:\d+\.\d*|\.\d+)\z/ then value.to_f
				else                               value
			end
		end

		retry_count = 0
		begin
			@me = api("account/verify_credentials")
		rescue APIFailed => e
			@log.error e.inspect
			sleep 3
			retry_count += 1
			retry if retry_count < 3
			log "Failed to access API 3 times." <<
			    " Please check Twitter Status <http://status.twitter.com/> and try again later."
			finish
		end

		@user   = "id=%09d" % @me["id"]
		@host   = hostname(@me)
		@prefix = Prefix.new("#{@me["screen_name"]}!#{@user}@#{@host}")

		#post NICK, @me["screen_name"] if @nick != @me["screen_name"]
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+mt"
		post server_name, MODE, main_channel, "+o", @prefix.nick
		post @prefix, TOPIC, main_channel, generate_status_message(@me["status"])

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
					log 'Installl "xmpp4r-simple" gem or check your ID/pass.'
					finish
				end
			else
				@opts.delete("jabber")
				log "This gateway does not support Jabber bot."
			end
		end

		log "Client Options: #{@opts.inspect}"
		@log.info "Client Options: #{@opts.inspect}"

		@ratio = (@opts["ratio"] || "77:1").split(":")
		@ratio = Struct.new(:timeline, :friends, :mentions).new(*@ratio)
		@ratio[:mentions] ||= @opts["mentions"] == true ? 12 : @opts["mentions"]

		@timeline = []
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
				sleep interval(@ratio[:friends])
			end
		end

		return if @opts["jabber"]

		@sources   = @opts["clientspoofing"] ? fetch_sources : [[api_source, "tig.rb"]]
		@suffix_bl = fetch_suffix_bl

		sleep 3
		@check_timeline_thread = Thread.start do
			loop do
				begin
					check_timeline
					# check_direct_messages
				rescue APIFailed => e
					@log.error e.inspect
				rescue Exception => e
					@log.error e.inspect
					e.backtrace.each do |l|
						@log.error "\t#{l}"
					end
				end
				sleep interval(@ratio[:timeline])
			end
		end

		return unless @opts["mentions"]

		sleep 3
		@check_mentions_thread = Thread.start do
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
				sleep interval(@ratio[:mentions])
			end
		end
	end

	def on_disconnected
		@check_friends_thread.kill  rescue nil
		@check_timeline_thread.kill rescue nil
		@check_mentions_thread.kill rescue nil
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
				if @opts["alwaysim"] and @im and @im.connected? # in jabber mode, using jabber post
					ret = @im.deliver(jabber_bot_id, mesg)
					post @prefix, TOPIC, main_channel, mesg
				else
					previous = @me["status"]
					if ((Time.now - Time.parse(previous["created_at"])).to_i < 60 rescue true) and
					   mesg.strip == previous["text"]
						log "You can't submit the same status twice in a row."
						return
					end
					ret = api("statuses/update", { :status => mesg, :source => source })
					log oops(ret) if ret["truncated"]
					ret.delete("user")
					@me.update("status" => ret)
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
		_, command, *args = mesg.split(/\s+/)
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
			@log.debug [nick, mesg]
			to = nick == @nick ? server_name : nick
			res = api("statuses/user_timeline/#{nick}", { :count => "#{count}" }).reverse_each do |s|
				@log.debug s
				time = Time.parse(s["created_at"]) rescue Time.now
				post to, NOTICE, main_channel,
				     "#{time.strftime "%m-%d %H:%M"} #{generate_status_message(s)}"
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
					@tmap.each_value do |v|
						if v["id"] == id
							statuses.push v
							break
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
					when friend = @friends.find {|i| i["screen_name"].casecmp(tid_or_nick).zero? }
						statuses.push friend["status"]
					else
						log "No such ID/NICK #{colored_tid(tid_or_nick)}"
					end
				end
			end
			@favorites ||= []
			statuses.each do |status|
				if not force and method == "create" and
				   @favorites.find {|i| i["id"] == status["id"] }
					log "The status is already favorited! <#{permalink(status)}>"
					next
				end
				res = api("favorites/#{method}/#{status["id"]}")
				log "#{entered}: #{res["user"]["screen_name"]}: #{res["text"]}"
				if method == "create"
					@favorites.push res
				else
					@favorites.delete_if {|i| i["id"] == res["id"] }
				end
				sleep 0.5
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
				if @opts["mentions"] and args.size < 3
					log "/me ratios <timeline> <friends> <mentions>"
					return
				elsif args.size == 1
					log "/me ratios <timeline> <friends>"
					return
				end
				ratios = args.map {|ratio| ratio.to_f }
				if ratios.any? {|ratio| ratio <= 0.0 }
					log "Ratios must be greater than 0.0 and fractional values are permitted."
					return
				end
				@ratio[:timeline] = ratios[0]
				@ratio[:friends]  = ratios[1]
				@ratio[:mentions] = ratios[2] if @opts["mentions"]
			end
			log "Intervals: " << @ratio.map {|ratio| interval(ratio).round }.join(", ")
		when /\A(?:de(?:stroy|l(?:ete)?)|miss|oops|r(?:emove|m))\z/
		# destroy, delete, del, remove, rm, miss, oops
			statuses = []
			if args.empty?
				statuses.push @me["status"]
			else
				args.each do |tid|
					if status = @tmap[tid]
						if "id=%09d" % status["user"]["id"] == @user
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
				res = api("statuses/destroy/#{status["id"]}")
				@tmap.delete_if {|k, v| v["id"] == res["id"] }
				b = status["id"] == @me["status"]["id"]
				log "Destroyed: #{res["text"]}"
				sleep 0.5
			end
			if b
				@me = api("account/verify_credentials")
				post @prefix, TOPIC, main_channel, generate_status_message(@me["status"])
			end
		when "name"
			name = mesg.split(/\s+/, 3)[2]
			unless name.nil?
				api("account/update_profile", { :name => name })
				log "You are named #{name}."
			end
		when "email"
			# FIXME
			email = args.first
			unless email.nil?
				api("account/update_profile", { :email => email })
			end
		when "url"
			# FIXME
			url = args.first || ""
			api("account/update_profile", { :url => url })
		when "in", "location"
			location = mesg.split(/\s+/, 3)[2] || ""
			api("account/update_profile", { :location => location })
			location = location.empty? ? "nowhere" : "in #{location}"
			log "You are #{location} now."
		when /\Adesc(?:ription)?\z/
			# FIXME
			description = mesg.split(/\s+/, 3)[2] || ""
			api("account/update_profile", { :description => description })
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
				text = mesg.split(/\s+/, 4)[3]
				ret  = api("statuses/update", { :status => text, :source => source,
				                                :in_reply_to_status_id => "#{status["id"]}" })
				log oops(ret) if ret["truncated"]
				msg = generate_status_message(status)
				url = permalink(status)
				log "Status updated (In reply to #{colored_tid(tid)}: #{msg} <#{url}>)"
				ret.delete("user")
				@me.update("status" => ret)
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
				unless user = @friends.find {|i| i["screen_name"].casecmp(bot).zero? }
					post server_name, ERR_NOSUCHNICK, bot, "No such nick/channel"
					next
				end
				if @drones.delete(user["id"])
					mode = "-#{mode}"
					log "#{bot} is no longer a bot."
				else
					@drones << user["id"]
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
		user = users.find {|i| i["screen_name"].casecmp(nick).zero? }
		unless user
			ret = api("users/username_available", { :username => nick })
			if ret and not ret["valid"]
				user = api("users/show/#{nick}")
			end
		end
		if user
			host = hostname user
			desc = user["name"]
			desc << " / #{user["description"]}".gsub(/\s+/, " ") unless user["description"].empty?
			idle = (Time.now - Time.parse(user["status"]["created_at"])).to_i rescue 0
			sion = Time.parse(user["created_at"]).to_i rescue 0
			post server_name, RPL_WHOISUSER,   @nick, nick, "id=%09d" % user["id"], host, "*", desc
			post server_name, RPL_WHOISSERVER, @nick, nick, api_base.host, "SoMa neighborhood of San Francisco, CA"
			post server_name, RPL_WHOISIDLE,   @nick, nick, "#{idle}", "#{sion}", "seconds idle, signon time"
			post server_name, RPL_ENDOFWHOIS,  @nick, nick, "End of WHOIS list"
			if @drones.include?(user["id"])
				post server_name, RPL_WHOISBOT, @nick, nick, "is a \002Bot\002 on #{server_name}"
			end
		else
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
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
		when @groups.key?(channel)
			@groups[channel].each do |name|
				whoreply channel, @friends.find {|i| i["screen_name"] == name }
			end
			post server_name, RPL_ENDOFWHO, @nick, channel
		else
			post server_name, ERR_NOSUCHNICK, @nick, "No such nick/channel"
		end
		def whoreply(channel, u)
			#     "<channel> <user> <host> <server> <nick>
			#         ( "H" / "G" > ["*"] [ ( "@" / "+" ) ]
			#             :<hopcount> <real name>"
			nick = u["screen_name"]
			user = "id=%09d" % u["id"]
			host = hostname u
			serv = api_base.host
			real = u["name"]
			mode = case u["screen_name"]
				when @me["screen_name"]        then "@"
				#when @drones.include?(u["id"]) then "%" # FIXME
				else                                "+"
			end
			post server_name, RPL_WHOREPLY, @nick, channel, user, host, serv, nick, "H*#{mode}", "0 #{real}"
		end
	end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		channels.each do |channel|
			next if channel.casecmp(main_channel).zero?

			@channels << channel
			@channels.uniq!
			post @prefix, JOIN, channel
			post server_name, MODE, channel, "+mti"
			post server_name, MODE, channel, "+o", @prefix.nick
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

		f = (@friends || []).find {|i| i["screen_name"].casecmp(nick).zero? }
		if f
			((@groups[channel] ||= []) << f["screen_name"]).uniq!
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

		f = (@friends || []).find {|i| i["screen_name"].casecmp(nick).zero? }
		if f
			(@groups[channel] ||= []).delete(f["screen_name"])
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
		return unless channel.casecmp(main_channel).zero?

		begin
			require "levenshtein"
			topic    = m.params[1]
			previous = @me["status"]
			distance = Levenshtein.normalized_distance(previous["text"], topic)

			return if distance.zero?

			status = api("statuses/update", { :status => topic, :source => source })
			log oops(ret) if status["truncated"]
			status.delete("user")
			@me.update("status" => status)

			if distance < 0.2
				deleted = api("statuses/destroy/#{previous["id"]}")
				@tmap.delete_if {|k, v| v["id"] == deleted["id"] }
				log "Fixed: #{status["text"]}"
			else
				log "Status updated"
			end
		rescue LoadError
		end
	end

	private
	def check_timeline
		q = { :count => "200" }
		q[:since_id] = @timeline.last.to_s unless @timeline.empty?
		api("statuses/friends_timeline", q).reverse_each do |status|
			id = status["id"]
			next if id.nil? or @timeline.include?(id)

			@timeline << id
			tid  = @tmap.push(status.dup)
			mesg = generate_status_message(status)
			user = status.delete("user")
			nick = user["screen_name"]

			mesg << " " << colored_tid(tid) if @opts["tid"]

			@log.debug [id, nick, mesg]
			if nick == @me["screen_name"] # 自分のときは TOPIC に
				post @prefix, TOPIC, main_channel, mesg
			else
				message(user, main_channel, mesg)
				uid = user["id"]
				@friends.each do |i|
					if i["id"] == uid
						i.update("status" => status)
						break
					end
				end
			end
			@groups.each do |channel, members|
				next unless members.include?(nick)
				message(user, channel, mesg)
			end
		end
		@log.debug "@timeline.size = #{@timeline.size}"
		@timeline = @timeline.last(200)
	end

	def generate_status_message(status)
		mesg = status["text"]
		@log.debug mesg

		mesg = decode_utf7(mesg)
		# time = Time.parse(status["created_at"]) rescue Time.now
		m = { "&quot;" => "\"", "&lt;" => "<", "&gt;" => ">", "&amp;" => "&", "\n" => " " }
		mesg = mesg.gsub(Regexp.union(*m.keys)) { m[$&] }
		mesg = mesg.sub(/\s*#{Regexp.union(*@suffix_bl)}\s*\z/, "") if @suffix_bl
		mesg = untinyurl(mesg)
	end

	def generate_prefix(u, athack = false)
		nick = u["screen_name"]
		nick = "@#{nick}" if athack
		user = "id=%09d" % u["id"]
		host = hostname u
		"#{nick}!#{user}@#{host}"
	end

	def check_mentions
		return if @timeline.size < 200
		@prev_mention_id ||= @timeline.last
		api("statuses/mentions", {
			:count    => "200",
			:since_id => @prev_mention_id.to_s
		}).reverse_each do |mention|
			id = @prev_mention_id = mention["id"]
			next if id.nil? or @timeline.include?(id)

			@timeline << id
			user = mention["user"]
			mesg = generate_status_message(mention)
			tid  = @tmap.push(mention)

			mesg << " " << colored_tid(tid) if @opts["tid"]

			@log.debug [id, user["screen_name"], mesg]
			message(user, main_channel, mesg)
		end
	end

	def check_direct_messages
		q = { :count => "200" }
		q[:since_id] = @prev_dm_id.to_s if @prev_dm_id
		api("direct_messages", q).reverse_each do |mesg|
			@prev_dm_id = mesg["id"]

			time = Time.parse(mesg["created_at"]) rescue Time.now + 1

			next if not q.key?(:since_id) and time < Time.now

			user = mesg["sender"]
			text = mesg["text"]
			@log.debug [user["screen_name"], text, time].inspect
			message(user, @nick, text)
		end
	end

	def check_friends
		first   = @friends.nil?
		athack  = @opts["athack"]
		friends = api("statuses/friends")
		if first and not athack
			names_list = friends.map do |i|
				name   = i["screen_name"]
				#prefix = @drones.include?(i["id"]) ? "%" : "+" # FIXME
				prefix = "+"
				"#{prefix}#{name}"
			end
			names_list = names_list.push("@#{@nick}").reverse.join(" ")
			post server_name, RPL_NAMREPLY,   @nick, "=", main_channel, names_list
			post server_name, RPL_ENDOFNAMES, @nick, main_channel, "End of NAMES list"
		else
			return if not first and friends.size.zero? # 304 ETag

			prv_friends = (@friends || []).map {|friend| generate_prefix friend, athack }
			now_friends = friends.map {|friend| generate_prefix friend, athack }

			# Twitter API bug?
			return if not first and (now_friends.length - prv_friends.length).abs > 10

			(prv_friends - now_friends).each {|part| post part, PART, main_channel, "" }
			params = []
			(now_friends - prv_friends).each do |join|
				post join, JOIN, main_channel
				params << join[/\A[^!]+/]
				next if params.size < 3

				post server_name, MODE, main_channel, "+#{"v" * params.size}", *params
				params = []
			end
			post server_name, MODE, main_channel, "+#{"v" * params.size}", *params unless params.empty?
		end
		@friends = friends
	end

	def interval(ratio)
		i     = 3600.0       # an hour in seconds
		limit = 0.9 * @limit # 90% of limit
		max   = @opts["maxlimit"]
		i *= @ratio.inject {|sum, i| sum.to_f + i.to_f }
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
			config = YAML.load(f)
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

	def api(path, q = {}, opt = {})
		@etags ||= {}

		path      = path.sub(%r{\A/+}, "")
		uri       = api_base.dup
		uri.port  = 443 if @opts["secure"]
		uri.query = q.inject([]) {|r,(k,v)| v ? r << "#{k}=#{URI.escape(v, /[^-.!~*'()\w]/n)}" : r }.join("&")
		uri.path += path
		uri.path += ".json" if path != "users/username_available"
		@log.debug uri.inspect

		http = case
			when RE_HTTPPROXY === @opts["httpproxy"]
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
		http.use_ssl      = !!@opts["secure"]
		http.verify_mode  = OpenSSL::SSL::VERIFY_NONE if http.use_ssl?

		req = case
			when path.include?("/destroy/") then Net::HTTP::Delete.new uri.request_uri
			when require_post?(path)        then Net::HTTP::Post.new   uri.path
			else                                 Net::HTTP::Get.new    uri.request_uri
		end
		req.add_field "User-Agent",      user_agent
		req.add_field "Accept",          "application/json,*/*;q=0.1"
		req.add_field "Accept-Charset",  "UTF-8,*"
		#req.add_field "Accept-Language", @opts["lang"] # "en-us,en;q=0.9,ja;q=0.5"
		req.add_field "If-None-Match",   @etags[path] if @etags[path]
		req.basic_auth @real, @pass
		req.body = uri.query if req.request_body_permitted?

		ret = http.request req

		@etags[path] = ret["ETag"]

		hourly_limit = ret["X-RateLimit-Limit"].to_i
		if not hourly_limit.zero? and @limit != hourly_limit
			msg = "The rate limit per hour was changed: #{@limit} to #{hourly_limit}"
			log msg
			@log.info msg
			@limit = hourly_limit
		end

		case ret
		when Net::HTTPOK # 200
			# Workaround for Twitter's bug: {"request":NULL, ...}
			json = ret.body.sub(/"request"\s*:\s*NULL\s*(?=[,}])/) {|v| v.downcase }
			res  = JSON.parse json
			if res.is_a?(Hash) and res["error"] # and not res["response"]
				if @error != res["error"]
					@error = res["error"]
					log @error
				end
				raise APIFailed, res["error"]
			end
			res
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

	def message(sender, target, str)
		#str.gsub!(/&#(x)?([0-9a-f]+);/i) do
		#	[$1 ? $2.hex : $2.to_i].pack("U")
		#end
		screen_name = sender["screen_name"]
		sender["screen_name"] = @nicknames[screen_name] || screen_name
		prefix = generate_prefix(sender)
		post prefix, PRIVMSG, target, str
	end

	def log(str)
		str.gsub!(/\r\n|[\r\n]/, " ")
		post server_name, NOTICE, main_channel, str
	end

	def untinyurl(text)
		text.gsub(%r{
			http:// (?:
				bit\.ly | (?:(preview\.)? tin | rub) yurl\.com |
				is\.gd | ff\.im | twurl.nl | blip\.fm | u\.nu
			) /~?[0-9a-z=-]+ (\?)?
		}ix) do |url|
			uri = URI(url)
			uri.host  = uri.host.sub($1, "") if $1
			uri.query = nil if $2
			fetch_location_header(uri).to_s
		end
	end

	def fetch_location_header(uri, limit = 3)
		return uri if limit == 0
		req = Net::HTTP::Head.new uri.request_uri
		req.add_field "User-Agent", user_agent
		RE_HTTPPROXY.match(@opts["httpproxy"])
		http = Net::HTTP.new uri.host, uri.port, $3, $4.to_i, $1, $2
		http.open_timeout = 3
		http.read_timeout = 2
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
		req = Net::HTTP::Get.new uri.request_uri
		req.add_field("User-Agent", user_agent)
		RE_HTTPPROXY.match(@opts["httpproxy"])
		http = Net::HTTP.new(uri.host, uri.port, $3, $4.to_i, $1, $2)
		http.open_timeout = 5
		http.read_timeout = 10
		begin
			res = http.request req
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
		c = @opts["tid"] # expect: 0..15, true, "0,1"
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
		hosts << "protected" if user["protected"]
		hosts << "bot"       if @drones.include?(user["id"])
		hosts.join("/")
	end

	def user_agent
		"#{self.class}/#{server_version} (#{File.basename(__FILE__)}; Net::IRC::Server)" <<
		" Ruby/#{RUBY_VERSION} (#{RUBY_PLATFORM})"
	end

	def permalink(status); "#{api_base}#{status["user"]["screen_name"]}/statuses/#{status["id"]}" end
	def source;            @sources[rand(@sources.size)].first                                    end

	RE_HTTPPROXY = /\A(?:([^:@]+)(?::([^@]+))?@)?([^:]+)(?::(\d+))?\z/

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
