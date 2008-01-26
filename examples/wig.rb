#!/usr/bin/env ruby

require "tig.rb"

class WasserIrcGateway < TwitterIrcGateway
	@@name     = "wassergw"
	@@version  = "0.0.0"
	@@channel  = "#wasser"
	@@api_base = URI("http://api.wassr.jp/")
end

if __FILE__ == $0
	Net::IRC::Server.new("localhost", 16670, WasserIrcGateway).start
end



