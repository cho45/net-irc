# coding: ASCII-8BIT
module Net::IRC::PATTERN # :nodoc:
	# letter     =  %x41-5A / %x61-7A       ; A-Z / a-z
	# digit      =  %x30-39                 ; 0-9
	# hexdigit   =  digit / "A" / "B" / "C" / "D" / "E" / "F"
	# special    =  %x5B-60 / %x7B-7D
	#                  ; "[", "]", "\", "`", "_", "^", "{", "|", "}"
	LETTER   = 'A-Za-z'
	DIGIT    = '0-9'
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
	#NICKNAME = "[#{LETTER}#{SPECIAL}#{DIGIT}_][-#{LETTER}#{DIGIT}#{SPECIAL}]*"
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
	PARAMS = "(?:((?: #{MIDDLE}){0,14})(?: :(#{TRAILING}))?|((?: #{MIDDLE}){14}):?(#{TRAILING}))"

	# crlf       =  %x0D %x0A   ; "carriage return" "linefeed"
	# message    =  [ ":" prefix SPACE ] command [ params ] crlf
	CRLF = '\x0D\x0A'
	MESSAGE = "(?::(#{PREFIX}) )?(#{COMMAND})#{PARAMS}\s*#{CRLF}"

	CLIENT_PATTERN  = /\A#{NICKNAME}(?:(?:!#{USER})?@#{HOST})\z/on
	MESSAGE_PATTERN = /\A#{MESSAGE}\z/on
end # PATTERN
