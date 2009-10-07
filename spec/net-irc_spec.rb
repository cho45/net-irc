#!/usr/bin/env ruby
# coding: ASCII-8BIT
# vim:encoding=UTF-8:

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "net/irc"
include Net::IRC
include Constants

describe Net::IRC::Message, "construct" do

	it "should generate message correctly" do
		m = Message.new("foo", "PRIVMSG", ["#channel", "message"])
		m.to_s.should == ":foo PRIVMSG #channel message\r\n"

		m = Message.new("foo", "PRIVMSG", ["#channel", "message with space"])
		m.to_s.should == ":foo PRIVMSG #channel :message with space\r\n"

		m = Message.new(nil, "PRIVMSG", ["#channel", "message"])
		m.to_s.should == "PRIVMSG #channel message\r\n"

		m = Message.new(nil, "PRIVMSG", ["#channel", "message with space"])
		m.to_s.should == "PRIVMSG #channel :message with space\r\n"

		m = Message.new(nil, "MODE", [
			"#channel",
			"+ooo",
			"nick1",
			"nick2",
			"nick3"
		])
		m.to_s.should == "MODE #channel +ooo nick1 nick2 nick3\r\n"

		m = Message.new(nil, "KICK", [
			"#channel,#channel1",
			"nick1,nick2",
		])
		m.to_s.should == "KICK #channel,#channel1 nick1,nick2\r\n"
	end

	it "should have ctcp? method" do
		m = Message.new("foo", "PRIVMSG", ["#channel", "\x01ACTION foo\x01"])
		m.ctcp?.should be_true
	end

	it "should behave as Array contains params" do
		m = Message.new("foo", "PRIVMSG", ["#channel", "message"])
		m[0].should   == m.params[0]
		m[1].should   == m.params[1]
		m.to_a.should == ["#channel", "message"]

		channel, message = *m
		channel.should == "#channel"
		message.should == "message"
	end

	it "#to_a should return duplicated array" do
		m = Message.new("foo", "PRIVMSG", ["#channel", "message"])
		m[0].should   == m.params[0]
		m[1].should   == m.params[1]
		m.to_a.should == ["#channel", "message"]
		m.to_a.clear
		m.to_a.should == ["#channel", "message"]
	end
end

describe Net::IRC::Message, "parse" do
	it "should parse correctly following RFC." do
		m = Message.parse("PRIVMSG #channel message\r\n")
		m.prefix.should  == ""
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "message"]

		m = Message.parse("PRIVMSG #channel :message leading :\r\n")
		m.prefix.should  == ""
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "message leading :"]

		m = Message.parse("PRIVMSG #channel middle :message leading :\r\n")
		m.prefix.should  == ""
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "middle", "message leading :"]

		m = Message.parse("PRIVMSG #channel middle message with middle\r\n")
		m.prefix.should  == ""
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "middle", "message", "with", "middle"]

		m = Message.parse(":prefix PRIVMSG #channel message\r\n")
		m.prefix.should  == "prefix"
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "message"]

		m = Message.parse(":prefix PRIVMSG #channel :message leading :\r\n")
		m.prefix.should  == "prefix"
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "message leading :"]
	end

	it "should allow multibyte " do
		m = Message.parse(":てすと PRIVMSG #channel :message leading :\r\n")
		m.prefix.should  == "てすと"
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "message leading :"]
	end

	it "should allow space at end" do
		m = Message.parse("JOIN #foobar \r\n")
		m.prefix.should  == ""
		m.command.should == "JOIN"
		m.params.should  == ["#foobar"]
	end
end

describe Net::IRC::Constants, "lookup" do
	it "should lookup numeric replies from Net::IRC::COMMANDS" do
		welcome = Net::IRC::Constants.const_get("RPL_WELCOME")
		welcome.should == "001"
		Net::IRC::COMMANDS[welcome].should == "RPL_WELCOME"
	end
end

describe Net::IRC::Prefix, "" do
	it "should be kind of String" do
		Prefix.new("").should be_kind_of(String)
	end

	it "should parse prefix correctly." do
		prefix = Prefix.new("foo!bar@localhost")
		prefix.extract.should == ["foo", "bar", "localhost"]

		prefix = Prefix.new("foo!-bar@localhost")
		prefix.extract.should == ["foo", "-bar", "localhost"]

		prefix = Prefix.new("foo!+bar@localhost")
		prefix.extract.should == ["foo", "+bar", "localhost"]

		prefix = Prefix.new("foo!~bar@localhost")
		prefix.extract.should == ["foo", "~bar", "localhost"]
	end

	it "should allow multibyte in nick." do
		prefix = Prefix.new("あああ!~bar@localhost")
		prefix.extract.should == ["あああ", "~bar", "localhost"]
	end

	it "should allow lame prefix." do
		prefix = Prefix.new("nick")
		prefix.extract.should == ["nick", nil, nil]
	end

	it "has nick method" do
		prefix = Prefix.new("foo!bar@localhost")
		prefix.nick.should == "foo"
	end

	it "has user method" do
		prefix = Prefix.new("foo!bar@localhost")
		prefix.user.should == "bar"
	end

	it "has host method" do
		prefix = Prefix.new("foo!bar@localhost")
		prefix.host.should == "localhost"
	end
end

describe Net::IRC, "utilities" do
	it "has ctcp_encode method" do
		message = ctcp_encode "ACTION hehe"
		message.should == "\x01ACTION hehe\x01"

		message = ctcp_encode "ACTION \x01 \x5c "
		message.should == "\x01ACTION \x5c\x61 \x5c\x5c \x01"

		message = ctcp_encode "ACTION \x00 \x0a \x0d \x10 "
		message.should == "\x01ACTION \x100 \x10n \x10r \x10\x10 \x01"
	end

	it "has ctcp_decode method" do
		message = ctcp_decode "\x01ACTION hehe\x01"
		message.should == "ACTION hehe"

		message = ctcp_decode "\x01ACTION \x5c\x61 \x5c\x5c \x01"
		message.should == "ACTION \x01 \x5c "

		message = ctcp_decode "\x01ACTION \x100 \x10n \x10r \x10\x10 \x01"
		message.should == "ACTION \x00 \x0a \x0d \x10 "
	end
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

	def self.testq
		@@testq
	end

	def on_message(m)
		@@testq << m
	end
end

describe Net::IRC, "server and client" do
	before :all do
		@port = nil
		@server, @client = nil, nil

		Thread.abort_on_exception = true
		@tserver = Thread.start do
			@server = Net::IRC::Server.new("localhost", @port, TestServerSession, {
				:logger => Logger.new(nil),
			})
			@server.start
		end

		Thread.pass
		true until @server.instance_variable_get(:@serv)

		@port = @server.instance_variable_get(:@serv).addr[1]

		@tclient = Thread.start do
			@client = TestClient.new("localhost", @port, {
				:nick   => "foonick",
				:user   => "foouser",
				:real   => "foo real name",
				:pass   => "foopass",
				:logger => Logger.new(nil),
			})
			@client.start
		end

		Thread.pass
		true until @client
	end

	server_q = TestServerSession.testq
	client_q = TestClient.testq

	it "client should send pass/nick/user sequence." do
		server_q.pop.to_s.should == "PASS foopass\r\n"
		server_q.pop.to_s.should == "NICK foonick\r\n"
		server_q.pop.to_s.should == "USER foouser 0 * :foo real name\r\n"
	end

	it "server should send 001,002,003 numeric replies." do
		client_q.pop.to_s.should match(/^:net-irc 001 foonick :Welcome to the Internet Relay Network \S+!\S+@\S+/)
		client_q.pop.to_s.should match(/^:net-irc 002 foonick :Your host is .+?, running version /)
		client_q.pop.to_s.should match(/^:net-irc 003 foonick :This server was created /)
	end

	it "client posts PRIVMSG and server receives it." do
		@client.instance_eval do
			post PRIVMSG, "#channel", "message a b c"
		end

		message = server_q.pop
		message.should be_a_kind_of(Net::IRC::Message)
		message.to_s.should == "PRIVMSG #channel :message a b c\r\n"
	end

	if defined? Encoding
		it "dummy encoding: client posts PRIVMSG and server receives it." do
			@client.instance_eval do
				s = "てすと".force_encoding("UTF-8")
				post PRIVMSG, "#channel", s
			end

			message = server_q.pop
			message.should be_a_kind_of(Net::IRC::Message)
			message.to_s.should == "PRIVMSG #channel てすと\r\n"
		end

		it "dummy encoding: client posts PRIVMSG and server receives it." do
			@client.instance_eval do
				s = "てすと".force_encoding("UTF-8")
				s.encode!("ISO-2022-JP")
				post PRIVMSG, "#channel", s
			end

			message = server_q.pop
			message.should be_a_kind_of(Net::IRC::Message)
			message.to_s.should == "PRIVMSG #channel \e$B$F$9$H\e(B\r\n"
		end
	end

	it "should allow lame RPL_WELCOME (not prefix but nick)" do
		client = @client
		TestServerSession.instance.instance_eval do
			Thread.exclusive do
				post "server", RPL_WELCOME, client.prefix.nick, "Welcome to the Internet Relay Network #{client.prefix.nick}"
				post nil,      NOTICE, "#test", "sep1"
			end
		end
		Thread.pass
		true until client_q.pop.to_s == "NOTICE #test sep1\r\n"
		client.prefix.should == "foonick"
	end

#	it "should destroy closed session" do
#	end

	after :all do
		@server.finish
		@client.finish
		@tserver.kill
		@tclient.kill
		@server = @client = @tserver = @tclient = nil
	end
end

