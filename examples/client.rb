#!/usr/bin/env ruby


$LOAD_PATH << "lib"
$LOAD_PATH << "../lib"

require "rubygems"
require "net/irc"

require "pp"

class SimpleClient < Net::IRC::Client
	def initialize(*args)
		super
	end
end

SimpleClient.new("foobar", "6667", {
	:nick => "foobartest",
	:user => "foobartest",
	:real => "foobartest",
}).start

