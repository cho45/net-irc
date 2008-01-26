#!/usr/bin/env ruby


require "net/irc"


class LingrIrcGateway < Net::IRC::Server::Session
	def on_user(m)
		super
		@real, @opts = @real.split(/\s/)
		@log.info "Client Options: #{@opts.inspect}"
	end

	def on_privmsg(m)
	end
end

Net::IRC::Server.new("localhost", 16669, LingrIrcGateway).start

