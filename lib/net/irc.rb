#!ruby

require "ostruct"
require "socket"
require "thread"
require "logger"
require "monitor"

module Net; end

module Net::IRC
	VERSION = "0.0.5"
	class IRCException < StandardError; end

	require "net/irc/constants"
	require "net/irc/pattern"

	autoload :Message,   "net/irc/message"
	autoload :Client,    "net/irc/client"
	autoload :Server,    "net/irc/server"

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
			_, *ret = *self.match(/^([^\s!]+)(?:!([^\s@]+)@(\S+))?$/)
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

