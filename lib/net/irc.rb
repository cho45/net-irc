#!ruby

require "ostruct"
require "socket"
require "thread"
require "logger"

module Net; end

module Net::IRC
	VERSION = "0.0.0"
	class IRCException < StandardError; end

	module PATTERN # :nodoc:
		# letter     =  %x41-5A / %x61-7A       ; A-Z / a-z
		# digit      =  %x30-39                 ; 0-9
		# hexdigit   =  digit / "A" / "B" / "C" / "D" / "E" / "F"
		# special    =  %x5B-60 / %x7B-7D
		#                  ; "[", "]", "\", "`", "_", "^", "{", "|", "}"
		LETTER   = 'A-Za-z'
		DIGIT    = '\d'
		HEXDIGIT = "#{DIGIT}A-Fa-f"
		SPECIAL  = '\x5B-\x60\x7B-\x7D'

		# shortname  =  ( letter / digit ) *( letter / digit / "-" )
		#               *( letter / digit )
		#                 ; as specified in RFC 1123 [HNAME]
		# hostname   =  shortname *( "." shortname )
		SHORTNAME = "[#{LETTER}#{DIGIT}](?:[-#{LETTER}#{DIGIT}]*[#{LETTER}#{DIGIT}])?"
		HOSTNAME  = "#{SHORTNAME}(?:\\.#{SHORTNAME})*"

		# servername =  hostname
		SERVERNAME = HOSTNAME

		# nickname   =  ( letter / special ) *8( letter / digit / special / "-" )
		#NICKNAME = "[#{LETTER}#{SPECIAL}\\w][-#{LETTER}#{DIGIT}#{SPECIAL}]*"
		NICKNAME = "\\S+" # for multibytes

		# user       =  1*( %x01-09 / %x0B-0C / %x0E-1F / %x21-3F / %x41-FF )
		#                 ; any octet except NUL, CR, LF, " " and "@"
		USER = '[\x01-\x09\x0B-\x0C\x0E-\x1F\x21-\x3F\x41-\xFF]+'

		# ip4addr    =  1*3digit "." 1*3digit "." 1*3digit "." 1*3digit
		IP4ADDR = "[#{DIGIT}]{1,3}(?:\\.[#{DIGIT}]{1,3}){3}"
		# ip6addr    =  1*hexdigit 7( ":" 1*hexdigit )
		# ip6addr    =/ "0:0:0:0:0:" ( "0" / "FFFF" ) ":" ip4addr
		IP6ADDR = "(?:[#{HEXDIGIT}]+(?::[#{HEXDIGIT}]+){7}|0:0:0:0:0:(?:0|FFFF):#{IP4ADDR})"
		# hostaddr   =  ip4addr / ip6addr
		HOSTADDR = "(?:#{IP4ADDR}|#{IP6ADDR})"

		# host       =  hostname / hostaddr
		HOST = "(?:#{HOSTNAME}|#{HOSTADDR})"

		# prefix     =  servername / ( nickname [ [ "!" user ] "@" host ] )
		PREFIX = "(?:#{NICKNAME}(?:(?:!#{USER})?@#{HOST})?|#{SERVERNAME})"

		# nospcrlfcl =  %x01-09 / %x0B-0C / %x0E-1F / %x21-39 / %x3B-FF
		#                 ; any octet except NUL, CR, LF, " " and ":"
		NOSPCRLFCL = '\x01-\x09\x0B-\x0C\x0E-\x1F\x21-\x39\x3B-\xFF'

		# command    =  1*letter / 3digit
		COMMAND = "(?:[#{LETTER}]+|[#{DIGIT}]{3})"

		# SPACE      =  %x20        ; space character
		# middle     =  nospcrlfcl *( ":" / nospcrlfcl )
		# trailing   =  *( ":" / " " / nospcrlfcl )
		# params     =  *14( SPACE middle ) [ SPACE ":" trailing ]
		#            =/ 14( SPACE middle ) [ SPACE [ ":" ] trailing ]
		MIDDLE = "[#{NOSPCRLFCL}][:#{NOSPCRLFCL}]*"
		TRAILING = "[: #{NOSPCRLFCL}]*"
		PARAMS = "(?:((?: #{MIDDLE}){0,14})(?: :(#{TRAILING}))?|((?: #{MIDDLE}){14})(?::?)?(#{TRAILING}))"

		# crlf       =  %x0D %x0A   ; "carriage return" "linefeed"
		# message    =  [ ":" prefix SPACE ] command [ params ] crlf
		CRLF = '\x0D\x0A'
		MESSAGE = "(?::(#{PREFIX}) )?(#{COMMAND})#{PARAMS}\s*#{CRLF}"

		CLIENT_PATTERN  = /\A#{NICKNAME}(?:(?:!#{USER})?@#{HOST})\z/on
		MESSAGE_PATTERN = /\A#{MESSAGE}\z/on
	end # PATTERN

	module Constants # :nodoc:
		RPL_WELCOME           = '001'
		RPL_YOURHOST          = '002'
		RPL_CREATED           = '003'
		RPL_MYINFO            = '004'
		RPL_BOUNCE            = '005'
		RPL_USERHOST          = '302'
		RPL_ISON              = '303'
		RPL_AWAY              = '301'
		RPL_UNAWAY            = '305'
		RPL_NOWAWAY           = '306'
		RPL_WHOISUSER         = '311'
		RPL_WHOISSERVER       = '312'
		RPL_WHOISOPERATOR     = '313'
		RPL_WHOISIDLE         = '317'
		RPL_ENDOFWHOIS        = '318'
		RPL_WHOISCHANNELS     = '319'
		RPL_WHOWASUSER        = '314'
		RPL_ENDOFWHOWAS       = '369'
		RPL_LISTSTART         = '321'
		RPL_LIST              = '322'
		RPL_LISTEND           = '323'
		RPL_UNIQOPIS          = '325'
		RPL_CHANNELMODEIS     = '324'
		RPL_NOTOPIC           = '331'
		RPL_TOPIC             = '332'
		RPL_INVITING          = '341'
		RPL_SUMMONING         = '342'
		RPL_INVITELIST        = '346'
		RPL_ENDOFINVITELIST   = '347'
		RPL_EXCEPTLIST        = '348'
		RPL_ENDOFEXCEPTLIST   = '349'
		RPL_VERSION           = '351'
		RPL_WHOREPLY          = '352'
		RPL_ENDOFWHO          = '315'
		RPL_NAMREPLY          = '353'
		RPL_ENDOFNAMES        = '366'
		RPL_LINKS             = '364'
		RPL_ENDOFLINKS        = '365'
		RPL_BANLIST           = '367'
		RPL_ENDOFBANLIST      = '368'
		RPL_INFO              = '371'
		RPL_ENDOFINFO         = '374'
		RPL_MOTDSTART         = '375'
		RPL_MOTD              = '372'
		RPL_ENDOFMOTD         = '376'
		RPL_YOUREOPER         = '381'
		RPL_REHASHING         = '382'
		RPL_YOURESERVICE      = '383'
		RPL_TIM               = '391'
		RPL_                  = '392'
		RPL_USERS             = '393'
		RPL_ENDOFUSERS        = '394'
		RPL_NOUSERS           = '395'
		RPL_TRACELINK         = '200'
		RPL_TRACECONNECTING   = '201'
		RPL_TRACEHANDSHAKE    = '202'
		RPL_TRACEUNKNOWN      = '203'
		RPL_TRACEOPERATOR     = '204'
		RPL_TRACEUSER         = '205'
		RPL_TRACESERVER       = '206'
		RPL_TRACESERVICE      = '207'
		RPL_TRACENEWTYPE      = '208'
		RPL_TRACECLASS        = '209'
		RPL_TRACERECONNECT    = '210'
		RPL_TRACELOG          = '261'
		RPL_TRACEEND          = '262'
		RPL_STATSLINKINFO     = '211'
		RPL_STATSCOMMANDS     = '212'
		RPL_ENDOFSTATS        = '219'
		RPL_STATSUPTIME       = '242'
		RPL_STATSOLINE        = '243'
		RPL_UMODEIS           = '221'
		RPL_SERVLIST          = '234'
		RPL_SERVLISTEND       = '235'
		RPL_LUSERCLIENT       = '251'
		RPL_LUSEROP           = '252'
		RPL_LUSERUNKNOWN      = '253'
		RPL_LUSERCHANNELS     = '254'
		RPL_LUSERME           = '255'
		RPL_ADMINME           = '256'
		RPL_ADMINLOC1         = '257'
		RPL_ADMINLOC2         = '258'
		RPL_ADMINEMAIL        = '259'
		RPL_TRYAGAIN          = '263'
		ERR_NOSUCHNICK        = '401'
		ERR_NOSUCHSERVER      = '402'
		ERR_NOSUCHCHANNEL     = '403'
		ERR_CANNOTSENDTOCHAN  = '404'
		ERR_TOOMANYCHANNELS   = '405'
		ERR_WASNOSUCHNICK     = '406'
		ERR_TOOMANYTARGETS    = '407'
		ERR_NOSUCHSERVICE     = '408'
		ERR_NOORIGIN          = '409'
		ERR_NORECIPIENT       = '411'
		ERR_NOTEXTTOSEND      = '412'
		ERR_NOTOPLEVEL        = '413'
		ERR_WILDTOPLEVEL      = '414'
		ERR_BADMASK           = '415'
		ERR_UNKNOWNCOMMAND    = '421'
		ERR_NOMOTD            = '422'
		ERR_NOADMININFO       = '423'
		ERR_FILEERROR         = '424'
		ERR_NONICKNAMEGIVEN   = '431'
		ERR_ERRONEUSNICKNAME  = '432'
		ERR_NICKNAMEINUSE     = '433'
		ERR_NICKCOLLISION     = '436'
		ERR_UNAVAILRESOURCE   = '437'
		ERR_USERNOTINCHANNEL  = '441'
		ERR_NOTONCHANNEL      = '442'
		ERR_USERONCHANNEL     = '443'
		ERR_NOLOGIN           = '444'
		ERR_SUMMONDISABLED    = '445'
		ERR_USERSDISABLED     = '446'
		ERR_NOTREGISTERED     = '451'
		ERR_NEEDMOREPARAMS    = '461'
		ERR_ALREADYREGISTRED  = '462'
		ERR_NOPERMFORHOST     = '463'
		ERR_PASSWDMISMATCH    = '464'
		ERR_YOUREBANNEDCREEP  = '465'
		ERR_YOUWILLBEBANNED   = '466'
		ERR_KEYSE             = '467'
		ERR_CHANNELISFULL     = '471'
		ERR_UNKNOWNMODE       = '472'
		ERR_INVITEONLYCHAN    = '473'
		ERR_BANNEDFROMCHAN    = '474'
		ERR_BADCHANNELKEY     = '475'
		ERR_BADCHANMASK       = '476'
		ERR_NOCHANMODES       = '477'
		ERR_BANLISTFULL       = '478'
		ERR_NOPRIVILEGES      = '481'
		ERR_CHANOPRIVSNEEDED  = '482'
		ERR_CANTKILLSERVER    = '483'
		ERR_RESTRICTED        = '484'
		ERR_UNIQOPPRIVSNEEDED = '485'
		ERR_NOOPERHOST        = '491'
		ERR_UMODEUNKNOWNFLAG  = '501'
		ERR_USERSDONTMATCH    = '502'
		RPL_SERVICEINFO       = '231'
		RPL_ENDOFSERVICES     = '232'
		RPL_SERVICE           = '233'
		RPL_NONE              = '300'
		RPL_WHOISCHANOP       = '316'
		RPL_KILLDONE          = '361'
		RPL_CLOSING           = '362'
		RPL_CLOSEEND          = '363'
		RPL_INFOSTART         = '373'
		RPL_MYPORTIS          = '384'
		RPL_STATSCLINE        = '213'
		RPL_STATSNLINE        = '214'
		RPL_STATSILINE        = '215'
		RPL_STATSKLINE        = '216'
		RPL_STATSQLINE        = '217'
		RPL_STATSYLINE        = '218'
		RPL_STATSVLINE        = '240'
		RPL_STATSLLINE        = '241'
		RPL_STATSHLINE        = '244'
		RPL_STATSSLINE        = '244'
		RPL_STATSPING         = '246'
		RPL_STATSBLINE        = '247'
		RPL_STATSDLINE        = '250'
		ERR_NOSERVICEHOST     = '492'

		PASS     = 'PASS'
		NICK     = 'NICK'
		USER     = 'USER'
		OPER     = 'OPER'
		MODE     = 'MODE'
		SERVICE  = 'SERVICE'
		QUIT     = 'QUIT'
		SQUIT    = 'SQUIT'
		JOIN     = 'JOIN'
		PART     = 'PART'
		TOPIC    = 'TOPIC'
		NAMES    = 'NAMES'
		LIST     = 'LIST'
		INVITE   = 'INVITE'
		KICK     = 'KICK'
		PRIVMSG  = 'PRIVMSG'
		NOTICE   = 'NOTICE'
		MOTD     = 'MOTD'
		LUSERS   = 'LUSERS'
		VERSION  = 'VERSION'
		STATS    = 'STATS'
		LINKS    = 'LINKS'
		TIME     = 'TIME'
		CONNECT  = 'CONNECT'
		TRACE    = 'TRACE'
		ADMIN    = 'ADMIN'
		INFO     = 'INFO'
		SERVLIST = 'SERVLIST'
		SQUERY   = 'SQUERY'
		WHO      = 'WHO'
		WHOIS    = 'WHOIS'
		WHOWAS   = 'WHOWAS'
		KILL     = 'KILL'
		PING     = 'PING'
		PONG     = 'PONG'
		ERROR    = 'ERROR'
		AWAY     = 'AWAY'
		REHASH   = 'REHASH'
		DIE      = 'DIE'
		RESTART  = 'RESTART'
		SUMMON   = 'SUMMON'
		USERS    = 'USERS'
		WALLOPS  = 'WALLOPS'
		USERHOST = 'USERHOST'
		ISON     = 'ISON'
	end

	COMMANDS = Constants.constants.inject({}) {|r,i| # :nodoc:
		r[Constants.const_get(i)] = i
		r
	}

	class Prefix < String
		def nick
			extract[0]
		end

		def user
			extract[1]
		end

		def host
			extract[2]
		end

		# Extract prefix string to [nick, user, host] Array.
		def extract
			_, *ret = *self.match(/^([^\s!]+)!([^\s@]+)@(\S+)$/)
			ret
		end
	end

	# Encoding to CTCP message. Prefix and postfix \x01.
	def ctcp_encoding(str)
		str = str.gsub(/\\/, "\\\\\\\\").gsub(/\x01/, '\a')
		str = str.gsub(/\x10/, "\x10\x10").gsub(/\x00/, "\x10\x30").gsub(/\x0d/, "\x10r").gsub(/\x0a/, "\x10n")
		"\x01#{str}\x01"
	end
	module_function :ctcp_encoding

	# Decoding to CTCP message. Remove \x01.
	def ctcp_decoding(str)
		str = str.gsub(/\x01/, "")
		str = str.gsub(/\x10n/, "\x0a").gsub(/\x10r/, "\x0d").gsub(/\x10\x30/, "\x00").gsub(/\x10\x10/, "\x10")
		str = str.gsub(/\\a/, "\x01").gsub(/\\\\/, "\\")
		str
	end
	module_function :ctcp_decoding
end

class Net::IRC::Message
	include Net::IRC

	class InvalidMessage < Net::IRC::IRCException; end

	attr_reader :prefix, :command, :params

	# Parse string and return new Message.
	# If the string is invalid message, this method raises Net::IRC::Message::InvalidMessage.
	def self.parse(str)
		_, prefix, command, *rest = *PATTERN::MESSAGE_PATTERN.match(str)
		raise InvalidMessage, "Invalid message: #{str.dump}" unless _

		case
		when rest[0] && !rest[0].empty?
			middle, trailer, = *rest
		when rest[2] && !rest[2].empty?
			middle, trailer, = *rest[2, 2]
		when rest[1]
			params  = []
			trailer = rest[1]
		when rest[3]
			params  = []
			trailer = rest[3]
		else
			params  = []
		end

		params ||= middle.split(/ /)[1..-1]
		params << trailer if trailer

		new(prefix, command, params)
	end

	def initialize(prefix, command, params)
		@prefix  = Prefix.new(prefix.to_s)
		@command = command
		@params  = params
	end

	# Same as @params[n].
	def [](n)
		@params[n]
	end

	# Iterate params.
	def each(&block)
		@params.each(&block)
	end

	# Stringfy message to raw IRC message.
	def to_s
		str = ""

		str << ":#{@prefix} " unless @prefix.empty?
		str << @command

		if @params
			f = false
			@params.each do |param|
				str << " "
				if !f && (param.size == 0 || / / =~ param || /^:/ =~ param)
					str << ":#{param}"
					f = true
				else
					str << param
				end
			end
		end

		str << "\x0D\x0A"

		str
	end
	alias to_str to_s

	# Same as params.
	def to_a
		@params
	end

	# If the message is CTCP, return true.
	def ctcp?
		message = @params[1]
		message[0] == 1 && message[message.length-1] == 1
	end

	def inspect
		'#<%s:0x%x prefix:%s command:%s params:%s>' % [
			self.class,
			self.object_id,
			@prefix,
			@command,
			@params.inspect
		]
	end

end # Message

class Net::IRC::Client
	include Net::IRC
	include Constants

	attr_reader :host, :port, :opts
	attr_reader :prefix, :channels

	def initialize(host, port, opts={})
		@host = host
		@port = port
		@opts = OpenStruct.new(opts)
		@log  = @opts.logger || Logger.new($stdout)
		@channels = {
#			"#channel" => {
#				:modes => [],
#				:users => [],
#			}
		}
	end

	# Connect to server and start loop.
	def start
		@socket = TCPSocket.open(@host, @port)
		on_connected
		post PASS,  @opts.pass if @opts.pass
		post NICK,  @opts.nick
		post USER,  @opts.user, "0", "*", @opts.real
		while l = @socket.gets
			begin
				@log.debug "RECEIVE: #{l.chomp}"
				m = Message.parse(l)
				next if on_message(m) === true
				name = "on_#{(COMMANDS[m.command.upcase] || m.command).downcase}"
				send(name, m) if respond_to?(name)
			rescue Exception => e
				warn e
				warn e.backtrace.join("\r\t")
				raise
			rescue Message::InvalidMessage
				@log.error "MessageParse: " + l.inspect
			end
		end
	rescue IOError
	ensure
		finish
	end

	# Close connection to server.
	def finish
		begin
			@socket.close
		rescue
		end
		on_disconnected
	end

	# Catch all messages.
	# If this method return true, aother callback will not be called.
	def on_message(m)
	end

	# Default RPL_WELCOME callback.
	# This sets @prefix from the message.
	def on_rpl_welcome(m)
		@prefix = Prefix.new(m[1][/\S+!\S+@\S+/])
	end

	# Default PING callback. Response PONG.
	def on_ping(m)
		post PONG, @nick
	end

	# For managing channel
	def on_rpl_namreply(m)
		type    = m[1]
		channel = m[2]
		init_channel(channel)

		m[3].split(/\s+/).each do |u|
			_, mode, nick = *u.match(/^([@+]?)(.+)/)

			@channels[channel][:users] << nick
			@channels[channel][:users].uniq!

			case mode
			when "@" # channel operator
				@channels[channel][:modes] << ["o", nick]
			when "+" # voiced (under moderating mode)
				@channels[channel][:modes] << ["v", nick]
			end
		end

		case type
		when "@" # secret
			@channels[channel][:modes] << ["s", nil]
		when "*" # private
			@channels[channel][:modes] << ["p", nil]
		when "=" # public
		end

		@channels[channel][:modes].uniq!
	end

	# For managing channel
	def on_part(m)
		nick    = m.prefix.nick
		channel = m[0]
		init_channel(channel)

		info = @channels[channel]
		if info
			info[:users].delete(nick)
			info[:modes].delete_if {|u|
				u[1] == nick
			}
		end
	end

	# For managing channel
	def on_quit(m)
		nick = m.prefix.nick

		@channels.each do |channel, info|
			info[:users].delete(nick)
			info[:modes].delete_if {|u|
				u[1] == nick
			}
		end
	end

	# For managing channel
	def on_kick(m)
		users = m[1].split(/,/)
		m[0].split(/,/).each do |chan|
			init_channel(chan)
			info = @channels[chan]
			if info
				users.each do |nick|
					info[:users].delete(nick)
					info[:modes].delete_if {|u|
						u[1] == nick
					}
				end
			end
		end
	end

	# For managing channel
	def on_join(m)
		nick    = m.prefix.nick
		channel = m[0]
		init_channel(channel)

		@channels[channel][:users] << nick
		@channels[channel][:users].uniq!
	end

	# For managing channel
	def on_mode(m)
		channel = m[0]
		init_channel(channel)

		positive_mode = []
		negative_mode = []

		mode = positive_mode
		arg_pos = 0
		m[1].each_byte do |c|
			case c
			when ?+
				mode = positive_mode
			when ?-
				mode = negative_mode
			when ?o, ?v, ?k, ?l, ?b, ?e, ?I
				mode << [c.chr, m[arg_pos + 2]]
				arg_pos += 1
			else
				mode << [c.chr, nil]
			end
		end
		mode = nil

		negative_mode.each do |m|
			@channels[channel][:modes].delete(m)
		end

		positive_mode.each do |m|
			@channels[channel][:modes] << m
		end

		@channels[channel][:modes].uniq!
		[negative_mode, positive_mode]
	end

	# For managing channel
	def init_channel(channel)
		@channels[channel] ||= {
			:modes => [],
			:users => [],
		}
	end

	# Do nothing.
	# This is for avoiding error on calling super.
	# So you can always call super at subclass.
	def method_missing(name, *args)
	end

	# Call when socket connected.
	def on_connected
	end

	# Call when socket closed.
	def on_disconnected
	end

	private

	# Post message to server.
	#
	#     include Net::IRC::Constans
	#     post PRIVMSG, "#channel", "foobar"
	def post(command, *params)
		m = Message.new(nil, command, params.map {|s|
			s.gsub(/[\r\n]/, " ")
		})
		@log.debug "SEND: #{m.to_s.chomp}"
		@socket << m
	end
end # Client

class Net::IRC::Server
	def initialize(host, port, session_class, opts={})
		@host          = host
		@port          = port
		@session_class = session_class
		@opts          = OpenStruct.new(opts)
		@sessions      = []
	end

	# Start server loop.
	def start
		@serv = TCPServer.new(@host, @port)
		@log  = @opts.logger || Logger.new($stdout)
		@log.info "Host: #{@host} Port:#{@port}"
		@accept = Thread.start do
			loop do
				Thread.start(@serv.accept) do |s|
					begin
						@log.info "Client connected, new session starting..."
						s = @session_class.new(self, s, @log, @opts)
						@sessions << s
						s.start
					rescue Exception => e
						puts e
						puts e.backtrace
					ensure
						@sessions.delete(s)
					end
				end
			end
		end
		@accept.join
	end

	# Close all sessions.
	def finish
		Thread.exclusive do
			@accept.kill
			begin
				@serv.close
			rescue
			end
			@sessions.each do |s|
				s.finish
			end
		end
	end


	class Session
		include Net::IRC
		include Constants

		attr_reader :prefix, :nick, :real, :host

		# Override subclass.
		def server_name
			"Net::IRC::Server::Session"
		end

		# Override subclass.
		def server_version
			"0.0.0"
		end

		# Override subclass.
		def avaiable_user_modes
			"eixwy"
		end

		# Override subclass.
		def avaiable_channel_modes
			"spknm"
		end

		def initialize(server, socket, logger, opts={})
			@server, @socket, @log, @opts = server, socket, logger, opts
		end

		def self.start(*args)
			new(*args).start
		end

		# Start session loop.
		def start
			on_connected
			while l = @socket.gets
				begin
					@log.debug "RECEIVE: #{l.chomp}"
					m = Message.parse(l)
					next if on_message(m) === true
					if m.command == QUIT
						on_quit if respond_to?(:on_quit)
						break
					else
						name = "on_#{(COMMANDS[m.command.upcase] || m.command).downcase}"
						send(name, m) if respond_to?(name)
					end
				rescue Message::InvalidMessage
					@log.error "MessageParse: " + l.inspect
				end
			end
		rescue IOError
		ensure
			finish
		end

		# Close this session.
		def finish
			begin
				@socket.close
			rescue
			end
			on_disconnected
		end

		# Default PASS callback.
		# Set @pass.
		def on_pass(m)
			@pass = m.params[0]
		end

		# Default NICK callback.
		# Set @nick.
		def on_nick(m)
			@nick = m.params[0]
		end


		# Default USER callback.
		# Set @user, @real, @host and call inital_message.
		def on_user(m)
			@user, @real = m.params[0], m.params[3]
			@host = @socket.peeraddr[2]
			@prefix = Prefix.new("#{@nick}!#{@user}@#{@host}")
			inital_message
		end

		# Call when socket connected.
		def on_connected
		end

		# Call when socket closed.
		def on_disconnected
		end

		# Catch all messages.
		# If this method return true, aother callback will not be called.
		def on_message(m)
		end

		# Do nothing.
		# This is for avoiding error on calling super.
		# So you can always call super at subclass.
		def method_missing(name, *args)
		end

		private
		# Post message to server.
		#
		#     include Net::IRC::Constans
		#     post prefix, PRIVMSG, "#channel", "foobar"
		def post(prefix, command, *params)
			m = Message.new(prefix, command, params.map {|s|
				s.gsub(/[\r\n]/, " ")
			})
			@log.debug "SEND: #{m.to_s.chomp}"
			@socket << m
		end

		# Call when client connected.
		# Send RPL_WELCOME sequence. If you want to customize, override this method at subclass.
		def inital_message
			post nil, RPL_WELCOME,  @nick, "Welcome to the Internet Relay Network #{@prefix}"
			post nil, RPL_YOURHOST, @nick, "Your host is #{server_name}, running version #{server_version}"
			post nil, RPL_CREATED,  @nick, "This server was created #{Time.now}"
			post nil, RPL_MYINFO,   @nick, "#{server_name} #{server_version} #{avaiable_user_modes} #{avaiable_channel_modes}"
		end
	end
end # Server
