require File.dirname(__FILE__) + '/test_helper.rb'

require "test/unit"
class Net::IrcTest < Test::Unit::TestCase
	include Net::IRC

	def test_constatns
		welcome = Net::IRC::Constants.const_get("RPL_WELCOME")
		assert_equal "001", welcome
		assert_equal "RPL_WELCOME", Net::IRC::COMMANDS[welcome]
	end

	def test_message
		[
			":foobar 001 nick :Welcome to the Internet Relay Network foo@bar\r\n",
			":foobar 002 nick :Your host is foobar, running version 0.1\r\n",
			":foobar 003 nick :This server was created Sat Jan 26 10:12:58 +0900 2008\r\n",
			":foobar 004 nick :foobar `Tynoq` v0.1\r\n",
			":\343\201\202\343\201\202\343\201\202 PRIVMSG target message\r\n", # violate RFC but expect ok
		].each do |l|
			m = nil
			assert_nothing_raised do
				m = Message.parse(l)
			end
			assert_equal l, Message.new(m.prefix, m.command, m.params).to_s
		end
	end
end
