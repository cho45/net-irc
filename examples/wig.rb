#!/usr/bin/env ruby
=begin

# wig.rb

Wassr IRC Gateway


## Client opts

Options specified by after irc realname.

Configuration example for tiarra ( http://coderepos.org/share/wiki/Tiarra ).

	wassr {
		host: localhost
		port: 16670
		name: username@example.com athack
		password: password on wassr
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

class WassrIrcGateway < TwitterIrcGateway
	def server_name
		"wassrgw"
	end

	def server_version
		"0.0.0"
	end

	def main_channel
		"#wassr"
	end

	def api_base
		@api_base ||= URI("http://api.wassr.jp/")
	end
end

if __FILE__ == $0
	require "optparse"

	opts = {
		:port   => 16670,
		:host   => "localhost",
		:debug  => false,
		:log    => nil,
		:debug  => false,
	}

	OptionParser.new do |parser|
		parser.instance_eval do
			self.banner  = <<-EOB.gsub(/^\t+/, "")
				Usage: #{$0} [opts]

			EOB

			separator ""

			separator "Options:"
			on("-p", "--port [PORT=#{opts[:port]}]", "listen port number") do |port|
				opts[:port] = port
			end

			on("-h", "--host [HOST=#{opts[:host]}]", "listen host") do |host|
				opts[:host] = host
			end

			on("-l", "--log LOG", "log file") do |log|
				opts[:log] = log
			end

			on("--debug", "Enable debug mode") do |debug|
				opts[:log]   = $stdout
				opts[:debug] = true
			end

			parse!(ARGV)
		end
	end

	opts[:logger] = Logger.new(opts[:log], "daily")
	opts[:logger].level = opts[:debug] ? Logger::DEBUG : Logger::INFO

	def daemonize(debug=false)
		return yield if $DEBUG || debug
		Process.fork do
			Process.setsid
			Dir.chdir "/"
			trap("SIGINT")  { exit! 0 }
			trap("SIGTERM") { exit! 0 }
			trap("SIGHUP")  { exit! 0 }
			File.open("/dev/null") {|f|
				STDIN.reopen  f
				STDOUT.reopen f
				STDERR.reopen f
			}
			yield
		end
		exit! 0
	end

	daemonize(opts[:debug]) do
		Net::IRC::Server.new(opts[:host], opts[:port], WassrIrcGateway, opts).start
	end
end



