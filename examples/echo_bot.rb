#!/usr/bin/env ruby


$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "rubygems"
require "net/irc"

require "pp"

class EchoBot < Net::IRC::Client
	def initialize(*args)
		super
	end

  def on_rpl_welcome(m)
    post JOIN, "#bot_test"
  end

  def on_privmsg(m)
    post NOTICE, m[0], m[1]
  end
end

EchoBot.new("foobar", "6667", {
	:nick => "foobartest",
	:user => "foobartest",
	:real => "foobartest",
}).start

