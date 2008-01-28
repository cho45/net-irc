#!/usr/bin/env ruby
=begin

# wig.rb

Wasser IRC Gateway


## Client opts

Options specified by after irc realname.

Configuration example for tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	wasser {
		host: localhost
		port: 16670
		name: username@example.com athack
		password: password on wasser
		in-encoding: utf8
		out-encoding: utf8
	}

### athack

If `athack` client options specified,
all nick in join message is leading with @.

So if you complemente nicks (ex. irssi),
it's good for twitter like reply command (@nick).

In this case, you will see torrent of join messages after connected,
because NAMES list can't send @ leading nick (it interpreted op.)

## Licence

Ruby's by cho45

=end

$LOAD_PATH << File.dirname(__FILE__)

require "tig.rb"

class WasserIrcGateway < TwitterIrcGateway
	def server_name
		"wassergw"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#wasser"
	end

	def api_base
		@api_base ||= URI("http://api.wasser.jp/")
	end
end

if __FILE__ == $0
	Net::IRC::Server.new("localhost", 16670, WasserIrcGateway).start
end



