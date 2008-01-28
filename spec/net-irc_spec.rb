#!/usr/bin/env ruby

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "net/irc"
include Net::IRC
include Constants

require "rubygems"
gem "rspec"
require "spec"

describe Message, "construct" do

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

end

describe Message, "parse" do
	it "should parse correctly following RFC." do
		m = Message.parse("PRIVMSG #channel message\r\n")
		m.prefix.should  == ""
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "message"]

		m = Message.parse("PRIVMSG #channel :message leading :\r\n")
		m.prefix.should  == ""
		m.command.should == "PRIVMSG"
		m.params.should  == ["#channel", "message leading :"]

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
	it "has ctcp_encoding method" do
		message = ctcp_encoding "ACTION hehe"
		message.should == "\x01ACTION hehe\x01"

		message = ctcp_encoding "ACTION \x01 \x5c "
		message.should == "\x01ACTION \x5c\x61 \x5c\x5c \x01"

		message = ctcp_encoding "ACTION \x00 \x0a \x0d \x10 "
		message.should == "\x01ACTION \x100 \x10n \x10r \x10\x10 \x01"
	end

	it "has ctcp_decoding method" do
		message = ctcp_decoding "\x01ACTION hehe\x01"
		message.should == "ACTION hehe"

		message = ctcp_decoding "\x01ACTION \x5c\x61 \x5c\x5c \x01"
		message.should == "ACTION \x01 \x5c "

		message = ctcp_decoding "\x01ACTION \x100 \x10n \x10r \x10\x10 \x01"
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

describe Net::IRC::Server, "server and client" do
	before :all do
		@port = rand(0xffff) + 1000
		@server, @client = nil, nil

		Thread.abort_on_exception = true
		Thread.start do
			@server = Net::IRC::Server.new("localhost", @port, TestServerSession, {
				:out => StringIO.new,
			})
			@server.start
		end

		Thread.start do
			@client = TestClient.new("localhost", @port, {
				:nick => "foonick",
				:user => "foouser",
				:real => "foo real name",
				:pass => "foopass",
				:out  => StringIO.new,
			})
			@client.start
		end
	end

	server_q = TestServerSession.testq
	client_q = TestClient.testq

	it "client should send pass/nick/user sequence." do
		server_q.pop.to_s.should == "PASS foopass\r\n"
		server_q.pop.to_s.should == "NICK foonick\r\n"
		server_q.pop.to_s.should == "USER foouser 0 * :foo real name\r\n"
	end

	it "server should send 001,002,003 numeric replies." do
		client_q.pop.to_s.should match(/^001 foonick :Welcome to the Internet Relay Network \S+!\S+@\S+/)
		client_q.pop.to_s.should match(/^002 foonick :Your host is Net::IRC::Server::Session, running version /)
		client_q.pop.to_s.should match(/^003 foonick :This server was created /)
	end

	it "client posts PRIVMSG and server receives it." do
		@client.instance_eval do
			post PRIVMSG, "#channel", "message a b c"
		end

		message = server_q.pop
		message.should be_a_kind_of(Net::IRC::Message)
		message.to_s.should == "PRIVMSG #channel :message a b c\r\n"
	end


	after :all do
		@server.finish
		@client.finish
	end
end
