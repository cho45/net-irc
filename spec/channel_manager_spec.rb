#!spec

$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "rubygems"
require "spec"
require "thread"
require "net/irc"
require "net/irc/client/channel_manager"
include Net::IRC
include Constants

class ChannelManagerTestServerSession < Net::IRC::Server::Session
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

class ChannelManagerTestClient < Net::IRC::Client
	include Net::IRC::Client::ChannelManager
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
		Thread.start do
			@server = Net::IRC::Server.new("localhost", @port, ChannelManagerTestServerSession, {
				:logger => Logger.new(nil),
			})
			@server.start
		end

		Thread.pass
		true until @server.instance_variable_get(:@serv)

		@port = @server.instance_variable_get(:@serv).addr[1]

		Thread.start do
			@client = ChannelManagerTestClient.new("localhost", @port, {
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

	server_q = ChannelManagerTestServerSession.testq
	client_q = ChannelManagerTestClient.testq

	it "client should manage channel mode/users correctly" do
		client = @client
		client.instance_variable_set(:@prefix, Prefix.new("foonick!foouser@localhost"))

		true until ChannelManagerTestServerSession.instance
		ChannelManagerTestServerSession.instance.instance_eval do
			Thread.exclusive do
				post client.prefix,          JOIN,   "#test"
				post nil,                    NOTICE, "#test", "sep1"
			end
		end

		true until client_q.pop.to_s == "NOTICE #test sep1\r\n"

		c = @client.instance_variable_get(:@channels)
		c.synchronize do
			c.should                       be_a_kind_of(Hash)
			c["#test"].should              be_a_kind_of(Hash)
			c["#test"][:modes].should      be_a_kind_of(Array)
			c["#test"][:users].should      be_a_kind_of(Array)
			c["#test"][:users].should      == ["foonick"]
		end

		ChannelManagerTestServerSession.instance.instance_eval do
			Thread.exclusive do
				post "test1!test@localhost", JOIN,   "#test"
				post "test2!test@localhost", JOIN,   "#test"
				post nil,                    NOTICE, "#test", "sep2"
			end
		end

		true until client_q.pop.to_s == "NOTICE #test sep2\r\n"
		c.synchronize do
			c["#test"][:users].should      == ["foonick", "test1", "test2"]
		end

		ChannelManagerTestServerSession.instance.instance_eval do
			Thread.exclusive do
				post nil,                    RPL_NAMREPLY, client.prefix.nick, "@", "#test", "foo1 foo2 foo3 @foo4 +foo5"
				post nil,                    NOTICE, "#test", "sep3"
			end
		end

		true until client_q.pop.to_s == "NOTICE #test sep3\r\n"
		c.synchronize do
			c["#test"][:users].should      == ["foonick", "test1", "test2", "foo1", "foo2", "foo3", "foo4", "foo5"]
			c["#test"][:modes].should      include([:s, nil])
			c["#test"][:modes].should      include([:o, "foo4"])
			c["#test"][:modes].should      include([:v, "foo5"])
		end

		ChannelManagerTestServerSession.instance.instance_eval do
			Thread.exclusive do
				post nil,                    RPL_NAMREPLY, client.prefix.nick, "@", "#test1", "foo1 foo2 foo3 @foo4 +foo5"
				post "foo4!foo@localhost",   QUIT,   "message"
				post "foo5!foo@localhost",   PART,   "#test1", "message"
				post client.prefix,          KICK,   "#test", "foo1", "message"
				post client.prefix,          MODE,   "#test", "+o", "foo2"
				post nil,                    NOTICE, "#test", "sep4"
			end
		end

		true until client_q.pop.to_s == "NOTICE #test sep4\r\n"
		c.synchronize do
			c["#test"][:users].should      == ["foonick", "test1", "test2", "foo2", "foo3", "foo5"]
			c["#test1"][:users].should     == ["foo1", "foo2", "foo3"]
			c["#test"][:modes].should_not  include([:o, "foo4"])
			c["#test"][:modes].should      include([:v, "foo5"])
			c["#test1"][:modes].should_not include([:v, "foo5"])
			c["#test"][:modes].should      include([:o, "foo2"])
		end

		ChannelManagerTestServerSession.instance.instance_eval do
			Thread.exclusive do
				post "foonick!test@localhost",  NICK, "foonick2"
				post "foonick2!test@localhost", NICK, "foonick"
				post "foo2!test@localhost",     NICK, "bar2"
				post "foo3!test@localhost",     NICK, "bar3"
				post nil,                     NOTICE, "#test", "sep5"
			end
		end

		true until client_q.pop.to_s == "NOTICE #test sep5\r\n"
		c.synchronize do
			c["#test"][:users].should      == ["foonick", "test1", "test2", "bar2", "bar3", "foo5"]
			c["#test1"][:users].should     == ["foo1", "bar2", "bar3"]
			c["#test"][:modes].should_not  include([:o, "foo4"])
			c["#test"][:modes].should      include([:v, "foo5"])
			c["#test1"][:modes].should_not include([:v, "foo5"])
			c["#test"][:modes].should_not  include([:o, "foo2"])
			c["#test"][:modes].should      include([:o, "bar2"])
		end
	end

	after :all do
		@server.finish
		@client.finish
	end
end

