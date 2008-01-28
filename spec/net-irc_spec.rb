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
