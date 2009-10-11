#!ruby

require "ostruct"
require "socket"
require "logger"
require "monitor"

module Net; end

module Net::IRC
	VERSION = "0.0.9".freeze
	class IRCException < StandardError; end

	require "net/irc/constants"
	require "net/irc/pattern"

	autoload :Message, "net/irc/message"
	autoload :Client,  "net/irc/client"
	autoload :Server,  "net/irc/server"

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

		# Extract Prefix String to [nick, user, host] Array.
		def extract
			_, *ret = *self.match(/\A([^\s!]+)(?:!([^\s@]+)@(\S+))?\z/)
			ret
		end
	end

	# Encode to CTCP message. Prefix and postfix \x01.
	def ctcp_encode(str)
		"\x01#{ctcp_quote(str)}\x01"
	end
	#alias :ctcp_encoding :ctcp_encode
	module_function :ctcp_encode #, :ctcp_encoding

	# Decode from CTCP message delimited with \x01.
	def ctcp_decode(str)
		ctcp_dequote(str.delete("\x01"))
	end
	#alias :ctcp_decoding :ctcp_decode
	module_function :ctcp_decode #, :ctcp_decoding

	def ctcp_quote(str)
		low_quote(str.gsub("\\", "\\\\\\\\").gsub("\x01", "\\a"))
	end
	module_function :ctcp_quote

	def ctcp_dequote(str)
		low_dequote(str).gsub("\\a", "\x01").gsub(/\\(.|\z)/m, "\\1")
	end
	module_function :ctcp_dequote

	private
	def low_quote(str)
		str.gsub("\x10", "\x10\x10").gsub("\x00", "\x10\x30").gsub("\r", "\x10r").gsub("\n", "\x10n")
	end

	def low_dequote(str)
		str.gsub("\x10n", "\n").gsub("\x10r", "\r").gsub("\x10\x30", "\x00").gsub("\x10\x10", "\x10")
	end
end

