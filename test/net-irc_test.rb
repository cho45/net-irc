require File.dirname(__FILE__) + '/test_helper.rb'

require "test/unit"
require "stringio"

class Net::IrcTest < Test::Unit::TestCase
	include Net::IRC
	include Constants

	def test_constatns
		welcome = Net::IRC::Constants.const_get("RPL_WELCOME")
		assert_equal "001", welcome
		assert_equal "RPL_WELCOME", Net::IRC::COMMANDS[welcome]
		assert_equal Net::IRC::Constants::RPL_WELCOME, welcome
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

		assert_equal "NOTICE test\r\n", Message.new(nil, NOTICE, "test").to_s
	end

	def test_server_client
		port = rand(0xffff) + 1000

		server, client = nil, nil
		Thread.start do
			server = Net::IRC::Server.new("localhost", port, TestServerSession, {
				:out => StringIO.new,
			})
			server.start
		end

		Thread.start do
			client = TestClient.new("localhost", port, {
				:nick => "foonick",
				:user => "foouser",
				:real => "foo real name",
				:pass => "foopass",
				:out  => StringIO.new,
			})
			client.start
		end

		assert_equal "PASS foopass\r\n", TestServerSession.testq.pop.to_s
		assert_equal "NICK foonick\r\n", TestServerSession.testq.pop.to_s
		assert_equal "USER foouser 0 * :foo real name\r\n", TestServerSession.testq.pop.to_s

		assert_equal "001 foonick :Welcome to the Internet Relay Network foonick!foouser@localhost\r\n", TestClient.testq.pop.to_s
		assert_equal "002 foonick :Your host is Net::IRC::Server::Session, running version 0.0.0\r\n", TestClient.testq.pop.to_s

		client.instance_eval do
			post PRIVMSG, "#channel", "message a b c"
		end

		message = TestServerSession.testq.pop
		assert_instance_of Net::IRC::Message, message
		assert_equal "PRIVMSG #channel :message a b c\r\n", message.to_s

		#client.instance_variable_set(:@prefix, Prefix.new("foonick!foouser@localhost"))

		# test channel management
		TestServerSession.instance.instance_eval do
			Thread.exclusive do
				post client.prefix,          JOIN,   "#test"
				post nil,                    NOTICE, "#test", "sep1"

				post "test1!test@localhost", JOIN,   "#test"
				post "test2!test@localhost", JOIN,   "#test"
				post nil,                    NOTICE, "#test", "sep2"

				post nil,                    RPL_NAMREPLY, client.prefix.nick, "@", "#test", "foo1 foo2 foo3 @foo4 +foo5"
				post nil,                    NOTICE, "#test", "sep3"

				post nil,                    RPL_NAMREPLY, client.prefix.nick, "@", "#test1", "foo1 foo2 foo3 @foo4 +foo5"
				post "foo4!foo@localhost",   QUIT,   "message"
				post "foo5!foo@localhost",   PART,   "#test1", "message"
				post client.prefix,          KICK,   "#test", "foo1", "message"
				post client.prefix,          MODE,   "#test", "+o", "foo2"
				post nil,                    NOTICE, "#test", "sep4"
			end
		end

		while m = TestClient.testq.pop.to_s
			break if m == "NOTICE #test sep1\r\n"
		end

		c = client.instance_variable_get(:@channels)
		assert_instance_of Hash,  c
		assert_instance_of Hash,  c["#test"]
		assert_instance_of Array, c["#test"][:modes]
		assert_instance_of Array, c["#test"][:users]
		assert_equal ["foonick"], c["#test"][:users]

		while m = TestClient.testq.pop.to_s
			break if m == "NOTICE #test sep2\r\n"
		end

		assert_equal ["foonick", "test1", "test2"], c["#test"][:users]

		while m = TestClient.testq.pop.to_s
			break if m == "NOTICE #test sep3\r\n"
		end
		assert_equal ["foonick", "test1", "test2", "foo1", "foo2", "foo3", "foo4", "foo5"], c["#test"][:users]
		assert c["#test"][:modes].include?(["s", nil])
		assert c["#test"][:modes].include?(["o", "foo4"])
		assert c["#test"][:modes].include?(["v", "foo5"])

		while m = TestClient.testq.pop.to_s
			break if m == "NOTICE #test sep4\r\n"
		end
		assert_equal ["foonick", "test1", "test2", "foo2", "foo3", "foo5"], c["#test"][:users]
		assert_equal ["foo1", "foo2", "foo3"], c["#test1"][:users]
		assert !c["#test"][:modes].include?(["o", "foo4"])
		assert  c["#test"][:modes].include?(["v", "foo5"])
		assert !c["#test1"][:modes].include?(["v", "foo5"])
		assert  c["#test"][:modes].include?(["o", "foo2"])
	end

	class TestServerSession < Net::IRC::Server::Session
		@@testq = SizedQueue.new(1)
		@@instance = nil

		def self.testq
			@@testq
		end

		def self.instance
			@@instance
		end

		def initialize(*args)
			super
			@@instance = self
		end

		def on_message(m)
			@@testq << m
		end
	end

	class TestClient < Net::IRC::Client
		@@testq = SizedQueue.new(1)
		@@instance = nil

		def self.testq
			@@testq
		end

		def self.instance
			@@instance
		end

		def initialize(*args)
			super
			@@instance = self
		end

		def on_message(m)
			@@testq << m
		end
	end
end
