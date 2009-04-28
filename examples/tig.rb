#!/usr/bin/env ruby
# vim:fileencoding=utf-8:
# -*- coding: utf-8 -*-
=begin

# tig.rb

Ruby version of TwitterIrcGateway
( http://www.misuzilla.org/dist/net/twitterircgateway/ )

## Launch

	$ ruby tig.rb

If you want to help:

	$ ruby tig.rb --help

## Configuration

Options specified by after IRC realname.

Configuration example for Tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	twitter {
		host: localhost
		port: 16668
		name: username@example.com athack jabber=username@example.com:jabberpasswd tid ratio=32:1 mentions=6 maxlimit=70
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

### tid[=<color>]

Apply ID to each message for make favorites by CTCP ACTION.

	/me fav ID [ID...]

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

### mentions[=<ratio>]

### maxlimit=<hourly limit>

### checkrls=<interval seconds>

### secure

### clientspoofing

Force SSL for API.

## Extended commands through the CTCP ACTION

### list (ls)

	/me list NICK [NUMBER]

### fav (favorite, favourite, unfav, unfavorite, unfavourite)

	/me fav [ID...]
	/me unfav [ID...]

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

## License

Ruby's by cho45

=end

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

$KCODE = "u" # json use this

require "rubygems"
require "net/irc"
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

	class APIFailed < StandardError; end

	def initialize(*args)
		super
		@groups     = {}
		@channels   = [] # joined channels (groups)
		@nicknames  = {}
		@user_agent = "#{self.class}/#{server_version} (#{File.basename(__FILE__)})"
		@config     = Pathname.new(ENV["HOME"]) + ".tig"
		load_config
	end

#	def on_nick(m)
#		@nicknames[@nick] = m.params[0]
#	end

	def on_user(m)
		super
		@real, *@opts = (@opts.name || @real).split(/\s+/)
		@opts = @opts.inject({}) do |r,i|
			key, value = i.split("=")
			key = "mentions" if key == "replies" # backcompat
			r.update(key => value || true)
		end

		@me = api("account/verify_credentials")
		if @me
			@user   = @me["id"].to_s
			@host   = hostname(@me)
			@prefix = Prefix.new("#{@me["screen_name"]}!#{@user}@#{@host}")
			#post NICK, @me["screen_name"] if @nick != @me["screen_name"]
		end
		post @prefix, JOIN, main_channel
		post server_name, MODE, main_channel, "+o", @prefix.nick
		post @prefix, TOPIC, main_channel, generate_status_message(@me["status"]) if @me

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

		@hourly_limit = hourly_limit

		@check_rate_limit_thread = Thread.start do
			loop do
				begin
					check_rate_limit
				rescue APIFailed => e
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
		sleep 3

		@ratio = (@opts["ratio"] || "11:3").split(":").map {|r| r.to_f }
		@ratio = Struct.new(:timeline, :friends, :mentions).new(*@ratio)
		@ratio[:mentions] = (@opts["mentions"] == true ? 5 : @opts["mentions"]).to_f
		footing = @ratio.inject {|sum, ratio| sum + ratio }
		@ratio.each_pair {|m, v| @ratio[m] = v / footing }

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

		sleep 10
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
		@check_friends_thread.kill    rescue nil
		@check_mentions_thread.kill   rescue nil
		@check_timeline_thread.kill   rescue nil
		@check_rate_limit_thread.kill rescue nil
		@im_thread.kill               rescue nil
		@im.disconnect                rescue nil
	end

	def on_privmsg(m)
		return on_ctcp(m[0], ctcp_decoding(m[1])) if m.ctcp?
		retry_count = 3
		ret = nil
		target, mesg = *m.params
		if @utf7
			mesg = Iconv.iconv("UTF-7", "UTF-8", mesg).join
			mesg = mesg.force_encoding("ASCII-8BIT") if mesg.respond_to?(:force_encoding)
		end
		begin
			if target =~ /^#/
				if @opts["alwaysim"] && @im && @im.connected? # in jabber mode, using jabber post
					ret = @im.deliver(jabber_bot_id, mesg)
					post @prefix, TOPIC, main_channel, mesg
				else
					src = @sources[rand(@sources.size)].first
					ret = api("statuses/update", { :status => mesg, :source => src })
					if ret["truncated"]
						log "Oops! Your update was over 140 characters. We sent the short version" <<
						    " to your friends (they can view the entire update on the Web <" <<
						    permalink(ret) << ">)."
					end
					ret.delete("user")
					@me.update("status" => ret)
				end
			else
				# direct message
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
			else
				log "Some Error Happened on Sending #{mesg}. #{e}"
			end
		end
	end

	def on_ctcp(target, mesg)
		_, command, *args = mesg.split(/\s+/)
		case command
		when "call"
			return log("/me call <Twitter_screen_name> as <IRC_nickname>") if args.size < 2
			screen_name = args[0]
			nickname    = args[2] || args[1] # allow omitting 'as'
			if nickname == "is"
				@nicknames.delete(screen_name)
				log "Removed the nickname for #{screen_name}"
			else
				@nicknames[screen_name] = nickname
				log "Call #{screen_name} as #{nickname}"
			end
		when "utf7"
			begin
				require "iconv"
				@utf7 = !@utf7
				log "UTF-7 mode: #{@utf7 ? 'on' : 'off'}"
			rescue LoadError => e
				log "Can't load iconv."
			end
		when "list", "ls"
			return log("/me list <NICK> [<NUM>]") if args.empty?
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
		when /^(un)?fav(?:ou?rite)?$/
		# fav, favorite, favourite, unfav, unfavorite, unfavourite
			method   = $1.nil? ? "create" : "destroy"
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
					return log("You've never favorite yet. No favorites to unfavorite.") if @favorites.empty?
					statuses.push @favorites.last
				end
			else
				args.each do |tid|
					if status = @tmap[tid]
						statuses.push status
					else
						log "No such ID #{colored_tid(tid)}"
					end
				end
			end
			@favorites ||= []
			statuses.each do |status|
				res = api("favorites/#{method}/#{status["id"]}")
				log "#{entered}: #{res["user"]["screen_name"]}: #{res["text"]}"
				if method == "create"
					@favorites.push res
				else
					@favorites.delete_if {|i| i["id"] == res["id"] }
				end
				sleep 1
			end
		when "link", "ln"
			args.each do |tid|
				if @tmap[tid]
					log "#{colored_tid(tid)}: #{permalink(@tmap[tid])}"
				else
					log "No such ID #{colored_tid(tid)}"
				end
			end
#		when /^ratios?$/
#			if !args.empty?
#				if args.size < 2 ||
#				   (@opts["mentions"] && args.size < 3)
#					return log("/me ratios <timeline> <frends>[ <mentions>]")
#				end
#				ratios = args.map {|ratio| ratio.to_f }
#				if ratios.any? {|ratio| ratio <= 0.0 }
#					return log("Ratios must be greater than 0.0 and fractional values are permitted.")
#				end
#				footing = ratios.inject {|sum, ratio| sum + ratio }
#				@ratio[:timeline] = ratios[0]
#				@ratio[:friends]  = ratios[1]
#				@ratio[:mentions] = ratios[2] if @opts["mentions"]
#				@ratio.each_pair {|m, v| @ratio[m] = v / footing }
#			end
#			intervals = @ratio.map {|ratio| interval ratio }
#			log "Intervals: #{intervals.join(", ")}"
		when /^(?:de(?:stroy|l(?:ete)?)|miss|oops|r(?:emove|m))$/
		# destroy, delete, del, remove, rm, miss, oops
			statuses = []
			if args.empty?
				statuses.push @me["status"]
			else
				args.each do |tid|
					if status = @tmap[tid]
						if status["user"]["screen_name"] == @nick
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
				sleep 1
			end
			@me = api("account/verify_credentials") if b
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
		when /^desc(?:ription)?$/
			# FIXME
			description = mesg.split(/\s+/, 3)[2] || ""
			api("account/update_profile", { :description => description })
#		when /^colou?rs?$/
#			# FIXME
#			# bg, text, link, fill and border
#		when "image", "img"
#			# FIXME
#			url = args.first
#			# TODO: DCC SEND
#		when "follow"
#			# FIXME
#		when "leave"
#			# FIXME
		when /^(?:mention|re(?:ply)?)$/ # reply, re, mention
			tid = args.first
			if status = @tmap[tid]
				text = mesg.split(/\s+/, 4)[3]
				src  = @sources[rand(@sources.size)].first
				ret  = api("statuses/update", { :status => text, :source => src,
				                                :in_reply_to_status_id => "#{status["id"]}" })
				if ret["truncated"]
					log "Oops! Your update was over 140 characters. We sent the short version" <<
					    " to your friends (they can view the entire update on the Web <" <<
					    permalink(ret) << ">)."
				end
				msg = generate_status_message(status)
				url = permalink(status)
				log "Status updated (In reply to #{colored_tid(tid)}: #{msg} <#{url}>)"
				ret.delete("user")
				@me.update("status" => ret)
			end
		when /^spoo(o+)?f$/
			@sources = args.empty? \
			         ? @sources.size == 1 || $1 ? fetch_sources($1 && $1.size) \
			                                    : [[api_source, "tig.rb"]] \
			         : args.map {|source| [source.upcase != "WEB" ? source : "", "=#{source}"] }
			log @sources.map {|source| source[1] }.sort.join(", ")
		end
	rescue APIFailed => e
		log e.inspect
	end

	def on_whois(m)
		nick  = m.params[0]
		users = []
		users.push @me if @me
		users.concat @friends if @friends
		f = users.find {|i| i["screen_name"].upcase == nick.upcase } ||
		    api("users/show/#{nick}") rescue nil
		if f
			host = hostname f
			desc = f["name"]
			desc << " / #{f["description"]}".gsub(/\s+/, " ") unless f["description"].empty?
			idle = (Time.now - Time.parse(f["status"]["created_at"])).to_i rescue 0
			sion = Time.parse(f["created_at"]).to_i rescue 0
			post server_name, RPL_WHOISUSER,   @nick, nick, "#{f["id"]}", host, "*", desc
			post server_name, RPL_WHOISSERVER, @nick, nick, api_base.host, "SoMa neighborhood of San Francisco, CA"
			post server_name, RPL_WHOISIDLE,   @nick, nick, "#{idle}", "#{sion}", "seconds idle, signon time"
			post server_name, RPL_ENDOFWHOIS,  @nick, nick, "End of WHOIS list"
		else
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	def on_who(m)
		channel = m.params[0]
		case
		when channel.downcase == main_channel
			users = []
			users.push @me if @me
			users.concat @friends if @friends
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
			user = u["id"].to_s
			host = hostname u
			serv = api_base.host
			real = u["name"]
			post server_name, RPL_WHOREPLY, @nick, channel, user, host, serv, nick, "H*@", "0 #{real}"
		end
	end

	def on_join(m)
		channels = m.params[0].split(/\s*,\s*/)
		channels.each do |channel|
			next if channel.downcase == main_channel

			@channels << channel
			@channels.uniq!
			post @prefix, JOIN, channel
			post server_name, MODE, channel, "+o", @nick
			save_config
		end
	end

	def on_part(m)
		channel = m.params[0]
		return if channel.downcase == main_channel

		@channels.delete(channel)
		post @nick, PART, channel, "Ignore group #{channel}, but setting is alive yet."
	end

	def on_invite(m)
		nick, channel = *m.params
		return if channel.downcase == main_channel

		f = (@friends || []).find {|i| i["screen_name"].upcase == nick.upcase }
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

		f = (@friends || []).find {|i| i["screen_name"].upcase == nick.upcase }
		if f
			(@groups[channel] ||= []).delete(f["screen_name"])
			post nick, PART, channel
			save_config
		else
			post server_name, ERR_NOSUCHNICK, nick, "No such nick/channel"
		end
	end

	private
	def check_timeline
		q = { :count => "200" }
		q[:since_id] = @timeline.last.to_s if @timeline.last
		api("statuses/friends_timeline", q).reverse_each do |status|
			id = status["id"]
			next if id.nil? || @timeline.include?(id)

			@timeline << id
			user = status["user"]
			nick = user["screen_name"]
			mesg = generate_status_message(status)
			tid  = @tmap.push(status)

			if @opts["tid"]
				mesg << " " << colored_tid(tid)
			end

			@log.debug [id, nick, mesg]
			if nick == @nick # 自分のときは TOPIC に
				post @prefix, TOPIC, main_channel, mesg
			else
				message(user, main_channel, mesg)
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
		mesg = mesg.sub(/\s*#{Regexp.union(*@suffix_bl)}\s*$/, "") if @suffix_bl
		mesg = untinyurl(mesg)
	end

	def generate_prefix(u, athack = false)
		nick = u["screen_name"]
		nick = "@#{nick}" if athack
		user = u["id"]
		host = hostname u
		"#{nick}!#{user}@#{host}"
	end

	def check_mentions
		time = @prev_time_m || Time.now
		@prev_time_m = Time.now
		api("statuses/mentions").reverse_each do |mention|
			id = mention["id"]
			next if id.nil? || @timeline.include?(id)

			created_at = Time.parse(mention["created_at"]) rescue next
			next if created_at < time

			@timeline << id
			user = mention["user"]
			mesg = generate_status_message(mention)
			tid  = @tmap.push(mention)

			if @opts["tid"]
				mesg << " " << colored_tid(tid)
			end

			@log.debug [id, user["screen_name"], mesg]
			message(user, main_channel, mesg)
		end
	end

	def check_direct_messages
		time = @prev_time_d || Time.now
		@prev_time_d = Time.now
		api("direct_messages", { :since => time.httpdate }).reverse_each do |mesg|
			user = mesg["sender"]
			text = mesg["text"]
			time = Time.parse(mesg["created_at"])
			@log.debug [user["screen_name"], text, time].inspect
			message(user, @nick, text)
		end
	end

	def check_friends
		first = true unless @friends
		athack = @opts["athack"]
		@friends ||= []
		friends = api("statuses/friends")
		if first && !athack
			names_list = friends.map {|i| "+#{i["screen_name"]}" }.join(" ")
			post server_name, RPL_NAMREPLY,   @nick, "=", main_channel, names_list
			post server_name, RPL_ENDOFNAMES, @nick, main_channel, "End of NAMES list"
		else
			prv_friends = @friends.map {|friend| generate_prefix friend, athack }
			now_friends = friends.map {|friend| generate_prefix friend, athack }

			# Twitter API bug?
			return if !first && (now_friends.length - prv_friends.length).abs > 10

			(prv_friends - now_friends).each {|part| post part, PART, main_channel, "" }
			sleep 1
			(now_friends - prv_friends).each {|join| post join, JOIN, main_channel }
		end
		@friends = friends
	end

	def check_rate_limit
		@log.debug rate_limit = api("account/rate_limit_status")
		if rate_limit.key?("hourly_limit") && @hourly_limit != rate_limit["hourly_limit"]
			msg = "Rate limit was changed: #{@hourly_limit} to #{rate_limit["hourly_limit"]}"
			log msg
			@log.info msg
			@hourly_limit = rate_limit["hourly_limit"]
		end
		# rate_limit["remaining_hits"] < 1
		# rate_limit["reset_time_in_seconds"] - Time.now.to_i
	end

	def interval(ratio)
		max   = (@opts["maxlimit"] || 100).to_i
		limit = @hourly_limit < max ? @hourly_limit : max
		f     = 3600 / (limit * ratio).round rescue nil
		@log.debug "Interval: #{f} seconds"
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
							body = msg.body.sub(/^(.+?)(?:\(([^()]+)\))?: /, "")
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

	def require_post?(path)
		%r{
			^
			(?: status(?:es)?/update $
			  | direct_messages/new $
			  | friendships/create/
			  | account/ (?: end_session $
			               | update_ )
			  | favou?ri(?:ing|tes)/create/
			  | notifications/
			  | blocks/create/ )
		}x === path
	end

	def api(path, q = {}, opt = {})
		ret     = {}
		headers = { "User-Agent" => @user_agent }
		headers["If-Modified-Since"] = q["since"] if q.key?("since")

		q["source"] ||= api_source

		path = path.sub(%r{^/+}, "")
		uri  = api_base.dup
		if @opts["secure"]
			uri.scheme = "https"
			uri.port   = 443
		end
		uri.path += "#{path}.json"
		uri.query = q.inject([]) {|r,(k,v)| v ? r << "#{k}=#{URI.escape(v, /[^-.!~*'()\w]/n)}" : r }.join("&")
		case
		when require_post?(path)
			req = Net::HTTP::Post.new(uri.path, headers)
			req.body = uri.query
		when path.include?("/destroy/") # require_delete?
			req = Net::HTTP::Delete.new(uri.path, headers)
			req.body = uri.query
		else
			req = Net::HTTP::Get.new(uri.request_uri, headers)
		end
		req.basic_auth(@real, @pass)
		@log.debug uri.inspect

		http = Net::HTTP.new(uri.host, uri.port)
		if uri.scheme == "https"
			http.use_ssl     = true
			http.verify_mode = OpenSSL::SSL::VERIFY_NONE # FIXME
		end
		case ret = http.request(req)
		when Net::HTTPOK # 200
			ret = JSON.parse(ret.body)
			if ret.kind_of?(Hash) && !opt[:suppress_errors] && ret["error"]
				raise APIFailed, "Server Returned Error: #{ret["error"]}"
			end
			ret
		when Net::HTTPNotModified # 304
			[]
		when Net::HTTPBadRequest # 400
			# exceeded the rate limitation
			raise APIFailed, "#{ret.code}: #{ret.message}"
		else
			raise APIFailed, "Server Returned #{ret.code} #{ret.message}"
		end
	rescue Errno::ETIMEDOUT, JSON::ParserError, IOError, Timeout::Error, Errno::ECONNRESET => e
		raise APIFailed, e.inspect
	end

	def message(sender, target, str)
#		str.gsub!(/&#(x)?([0-9a-f]+);/i) do
#			[$1 ? $2.hex : $2.to_i].pack("U")
#		end
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
			http://
			(?:
			 (?: (preview\.)? tin | rub) yurl\.com
			   | is\.gd | bit\.ly | ff\.im | twurl.nl | blip\.fm
			)
			/~?[0-9a-z=-]+
		}ix) do |m|
			uri = URI(m)
			uri.host = uri.host.sub($1, "") if $1
			Net::HTTP.start(uri.host, uri.port) do |http|
				http.open_timeout = 3
				begin
					http.head(uri.request_uri, { "User-Agent" => @user_agent })["Location"] || m
				rescue Timeout::Error
					m
				end
			end
		end
	end

	def decode_utf7(str)
		begin
			require "iconv"
			str = str.sub(/^.+ > |^.+/) {|m| Iconv.iconv("UTF-8", "UTF-7", m).join }
			#FIXME str = "[utf7]: #{str}" if str =~ /[^a-z0-9\s]/i
			str
		rescue LoadError
		rescue Iconv::IllegalSequence
		end
		str
	end

	def fetch_sources(n = nil)
		json = Net::HTTP.get "wedata.net", "/databases/TwitterSources/items.json"
		sources = JSON.parse json
		sources.map! {|item| [item["data"]["source"], item["name"]] }.push ["", "web"]
		if n.is_a?(Integer) && n < sources.size
			sources = Array.new(n) { sources.delete_at(rand(sources.size)) }.compact
		end
		sources
	rescue => e
		@log.error e.inspect
		log "An error occured while loading wedata.net."
		@sources
	end

	def fetch_suffix_bl(r = [])
		source = Net::HTTP.get("svn.coderepos.org", "/share/platform/twitterircgateway/suffixesblacklist.txt")
		if source.respond_to?(:encoding) and source.encoding == Encoding::BINARY
			source.force_encoding("UTF-8")
		end
		source.split
	rescue
		r
	end

	def hostname(user)
		user["protected"] ? "protected.#{api_base.host}" : api_base.host
	end

	def colored_tid(tid)
		"\x03%s[%s]\x0f" % [@opts["tid"] || 10, tid]
	end

	def permalink(status)
		"#{api_base}#{status["user"]["screen_name"]}/statuses/#{status["id"]}"
	end

	class TypableMap < Hash
		Roman = %w[
			k g ky gy s z sh j t d ch n ny h b p hy by py m my y r ry w v q
		].unshift("").map do |consonant|
			case consonant
				when "y", /^.{2}/ then %w|a u o|
				when "q"          then %w|a i e o|
				else                   %w|a i u e o|
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

#	def daemonize(foreground = false)
#		[:INT, :TERM, :HUP].each do |sig|
#			Signal.trap sig, "EXIT"
#		end
#		return yield if $DEBUG || foreground
#		Process.fork do
#			Process.setsid
#			Dir.chdir "/"
#			STDIN.reopen  "/dev/null"
#			STDOUT.reopen "/dev/null", "a"
#			STDERR.reopen STDOUT
#			yield
#		end
#		exit! 0
#	end

#	daemonize(opts[:debug] || opts[:foreground]) do
		Net::IRC::Server.new(opts[:host], opts[:port], TwitterIrcGateway, opts).start
#	end
end
